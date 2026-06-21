import Foundation
import OpenClawKit
import OpenClawProtocol
import SwiftUI

/// Closed load state for the Provider Auth health surface so the view never juggles parallel nullable
/// flags. Mirrors `OpsLoadState` / `CostLoadState`.
enum AuthHealthLoadState: Equatable {
    case idle
    case loading
    case loaded(AuthHealthReport)
    case empty
    case offline
    case error(String)

    static func == (lhs: AuthHealthLoadState, rhs: AuthHealthLoadState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.loading, .loading), (.empty, .empty), (.offline, .offline):
            true
        case let (.error(l), .error(r)):
            l == r
        case let (.loaded(l), .loaded(r)):
            l.providers.count == r.providers.count
                && l.reauthCount == r.reauthCount
                && l.expiringCount == r.expiringCount
        default:
            false
        }
    }
}

/// The assembled provider-auth report: every provider from `models.authStatus`, ordered worst-first so
/// the providers needing a re-login surface at the top. `reauthCount` / `expiringCount` drive the
/// header + the Command Center card badge.
struct AuthHealthReport {
    let providers: [AuthProviderLite]

    /// Providers needing a host-side re-login (expired/missing), most-urgent ordering already applied.
    var reauthProviders: [AuthProviderLite] {
        self.providers.filter(\.needsReauth)
    }

    var expiringProviders: [AuthProviderLite] {
        self.providers.filter { $0.isExpiringSoon && !$0.needsReauth }
    }

    var reauthCount: Int { self.reauthProviders.count }
    var expiringCount: Int { self.expiringProviders.count }

    var hasAnySignal: Bool { !self.providers.isEmpty }
}

/// Result of the admin `models.authLogout` action, so the screen reports a precise outcome and falls
/// back to read-only on a scope-narrowed device. A closed mode/result shape (success / missing-scope /
/// failure) rather than parallel nullable flags the caller must keep in sync.
enum AuthLogoutOutcome: Equatable {
    case cleared(removed: Int, aborted: Int)
    case missingScope
    case failed(String)
}

/// Drives the Provider Auth health surface. Like `OpsHealthViewModel`: a closed load-state enum, a
/// `connected(appModel:)` gate copied verbatim, a load that preserves the prior report on a transient
/// failure, and lossy decode.
///
/// `load` calls `models.authStatus` — the RICH per-profile OAuth/expiry endpoint (vs the thinner
/// `usage.status` the Ops Health screen reads). `{"refresh":false}` on a normal load (60s TTL cache);
/// `{"refresh":true}` on pull-to-refresh to bypass the cache + re-probe.
///
/// ACTION: the only provider-auth mutation the gateway exposes is `models.authLogout` (scope
/// `operator.admin`) — it removes dead profiles + aborts in-flight runs for the provider so the next
/// HOST-side login is clean. There is NO RPC to TRIGGER a provider OAuth re-login from the app
/// (`web.login.*` is CHANNEL web/QR login, not provider OAuth), so the card SURFACES "re-auth needed"
/// and can clear the dead credential, but re-login happens on the gateway host.
@MainActor
@Observable
final class AuthHealthViewModel {
    private(set) var state: AuthHealthLoadState = .idle

    /// Set true once `models.authLogout` 403s with a missing-scope error, so the screen drops the
    /// "Clear dead credential" action and shows a read-only "needs admin" notice.
    private(set) var adminActionUnavailable = false

    /// The provider currently being logged out, so the card shows a spinner + blocks re-entry.
    private(set) var loggingOutProvider: String?

    var report: AuthHealthReport? {
        if case let .loaded(report) = self.state { return report }
        return nil
    }

    func load(appModel: NodeAppModel, force: Bool) async {
        guard self.connected(appModel: appModel) else {
            self.state = .offline
            return
        }
        if case .loading = self.state, !force { return }
        // Preserve already-loaded content while refetching so the surface never blanks to a spinner —
        // covers pull-to-refresh (force) and the scenePhase foreground refresh (force == false).
        if case .loaded = self.state {} else {
            self.state = .loading
        }

        // `{"refresh":true}` on a forced (pull-to-refresh) load bypasses the 60s TTL cache and re-probes
        // the credential store; a normal foreground refresh uses the cache to stay cheap.
        let paramsJSON = force ? "{\"refresh\":true}" : "{\"refresh\":false}"
        let data = await Self.requestData(
            appModel: appModel,
            method: "models.authStatus",
            paramsJSON: paramsJSON)

        guard let data, let result = AuthHealthResultLite.decode(from: data) else {
            if case .loaded = self.state { return }
            self.state = .error("Could not load provider auth status.")
            return
        }

        let ordered = Self.orderProviders(result.providers)
        let report = AuthHealthReport(providers: ordered)
        self.state = report.hasAnySignal ? .loaded(report) : .empty
    }

    // MARK: - Admin action: clear dead credential

    /// Clear a provider's dead credential via `models.authLogout {provider}` (scope `operator.admin`,
    /// controlPlaneWrite). This does NOT re-login — it removes the dead profiles + aborts in-flight runs
    /// so the next HOST-side login starts clean. On a `missing scope` error the device's grant was
    /// narrowed; we surface `.missingScope`, set `adminActionUnavailable`, and the card reverts to a
    /// read-only nudge. After a successful clear we reload (`force`) so the now-`missing` provider's
    /// fresh status is reflected.
    func clearDeadCredential(appModel: NodeAppModel, provider: String) async -> AuthLogoutOutcome {
        guard self.connected(appModel: appModel) else { return .failed("Gateway offline.") }
        guard self.loggingOutProvider == nil else { return .failed("Another action is in progress.") }

        self.loggingOutProvider = provider
        defer { self.loggingOutProvider = nil }

        let paramsJSON = Self.logoutParamsJSON(provider: provider)
        let data: Data
        do {
            data = try await appModel.operatorSession.request(
                method: "models.authLogout",
                paramsJSON: paramsJSON,
                timeoutSeconds: 12)
        } catch {
            if Self.isMissingScopeError(error) {
                self.adminActionUnavailable = true
                return .missingScope
            }
            return .failed(Self.errorMessage(error))
        }

        let result = AuthLogoutResultLite.decode(from: data)
        let removed = result?.removedProfiles.count ?? 0
        let aborted = result?.abortedRunIds.count ?? 0
        await self.load(appModel: appModel, force: true)
        return .cleared(removed: removed, aborted: aborted)
    }

    // MARK: - Ordering

    /// Worst-first ordering so providers needing a re-login surface at the top: re-auth needed, then
    /// expiring-soon, then healthy — alphabetical within each band for stable output.
    private static func orderProviders(_ providers: [AuthProviderLite]) -> [AuthProviderLite] {
        func rank(_ provider: AuthProviderLite) -> Int {
            if provider.needsReauth { return 0 }
            if provider.isExpiringSoon { return 1 }
            return 2
        }
        return providers.sorted { lhs, rhs in
            let lhsRank = rank(lhs)
            let rhsRank = rank(rhs)
            if lhsRank != rhsRank { return lhsRank < rhsRank }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    // MARK: - Params

    private static func logoutParamsJSON(provider: String) -> String {
        // Encode via JSONEncoder so every special character in the provider id is escaped correctly —
        // hand-escaping only the double-quote would emit malformed JSON for a `\`/control char. (Provider
        // ids are a controlled gateway vocabulary so this is robustness, not an injection vector.)
        guard let data = try? JSONEncoder().encode(["provider": provider]),
              let json = String(data: data, encoding: .utf8)
        else {
            return "{}"
        }
        return json
    }

    private static func requestData(
        appModel: NodeAppModel,
        method: String,
        paramsJSON: String) async -> Data?
    {
        do {
            return try await appModel.operatorSession.request(
                method: method,
                paramsJSON: paramsJSON,
                timeoutSeconds: 12)
        } catch {
            return nil
        }
    }

    // MARK: - Error classification

    /// Over the WS path a scope-denied call returns `INVALID_REQUEST` with message
    /// `missing scope: operator.admin` (`server-methods.ts:255`), so match the message substring.
    private static func isMissingScopeError(_ error: Error) -> Bool {
        guard let responseError = error as? GatewayResponseError else { return false }
        return responseError.message.localizedCaseInsensitiveContains("missing scope")
    }

    private static func errorMessage(_ error: Error) -> String {
        if let responseError = error as? GatewayResponseError {
            return responseError.message
        }
        return error.localizedDescription
    }

    // MARK: - Connection gate (copied verbatim from CostInsightsViewModel)

    private func connected(appModel: NodeAppModel) -> Bool {
        guard !appModel.isLocalGatewayFixtureEnabled else { return false }
        guard appModel.isOperatorGatewayConnected else { return false }
        return GatewayStatusBuilder.build(appModel: appModel) == .connected
    }
}
