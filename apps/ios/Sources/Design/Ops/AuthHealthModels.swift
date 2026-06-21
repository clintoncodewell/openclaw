import Foundation
import OpenClawKit
import OpenClawProtocol
import SwiftUI

/// Lite decode mirror for `models.authStatus` (scope `operator.read`) — the RICH per-profile provider-
/// auth health endpoint, and THE canonical "re-auth needed" signal. No Swift decoder existed for this
/// RPC: the Ops screen's `OpsProviderHealthLite` decodes the THINNER `usage.status` (plan + provider-
/// level error + quota windows), which carries no per-profile OAuth expiry or `reasonCode`. This mirror
/// matches `ModelAuthStatusResult` (`models-auth-status.ts:87`):
///
/// `{ ts, providers: [{ provider, displayName, status, expiry?{at,remainingMs,label},
///    profiles: [{ profileId, type, status, reasonCode?, expiry? }],
///    usage?{ windows, summary?, plan? } }] }`
///
/// Provider/profile `status` is `ok | expiring | expired | missing | static`
/// (`auth-health.ts:27,41`); `reasonCode` is `ok | missing_credential | invalid_expires | expired |
/// unresolved_ref` (`credential-state.ts:11`); profile `type` is `oauth | token | api_key`. A dead
/// OpenAI single-session OAuth surfaces here as provider/profile `status: expired|missing` with a
/// `reasonCode` and an expiry label — exactly the signal that would have caught the OAuth outage early.
///
/// All numeric fields route through `AgentProValueReader` because the gateway emits ints and doubles
/// interchangeably; every array/object element is rebuilt from `JSONSerialization` so one malformed
/// provider/profile row can't blank the whole rollup (the lossy pattern shared with
/// `OpsProviderHealthLite` / `InboxApproval`).

// MARK: - Closed status enum

/// Closed provider/profile auth-health status so the UI maps to a color/label/icon without re-inspecting
/// raw strings. `static` = a non-expiring credential (API key) — healthy, no countdown. Unknown strings
/// fall back to `.unknown` so a future status value renders neutrally rather than crashing the mapping.
enum AuthHealthStatus: String {
    case ok
    case expiring
    case expired
    case missing
    case staticCredential = "static"
    case unknown

    init(raw: String?) {
        switch raw?.lowercased() {
        case "ok": self = .ok
        case "expiring": self = .expiring
        case "expired": self = .expired
        case "missing": self = .missing
        case "static": self = .staticCredential
        default: self = .unknown
        }
    }

    /// True for the states that mean a host-side re-login is needed (no in-app OAuth exists).
    var needsReauth: Bool {
        switch self {
        case .expired, .missing: true
        case .expiring, .ok, .staticCredential, .unknown: false
        }
    }

    /// Amber for an expiring credential (still valid, but a re-login window is opening); the screen
    /// uses this alongside `needsReauth` to decide the card severity.
    var isExpiringSoon: Bool { self == .expiring }

    var color: Color {
        switch self {
        case .ok, .staticCredential: OpenClawBrand.ok
        case .expiring: OpenClawBrand.warn
        case .expired, .missing: OpenClawBrand.danger
        case .unknown: .secondary
        }
    }

    var label: String {
        switch self {
        case .ok: "healthy"
        case .expiring: "expiring"
        case .expired: "expired"
        case .missing: "missing"
        case .staticCredential: "static key"
        case .unknown: "unknown"
        }
    }
}

// MARK: - Expiry

/// Mirror of `ModelAuthExpiry` (`models-auth-status.ts:57`): absolute expiry ms, remaining ms (negative
/// when already expired), and the gateway's human label (e.g. "10d", "2h", "45m"). We render the
/// gateway's `label` verbatim so the countdown matches the host's own formatting.
struct AuthExpiryLite {
    let at: Int?
    let remainingMs: Int?
    let label: String?

    init?(reading raw: [String: Any]?) {
        guard let raw else { return nil }
        self.at = AgentProValueReader.intValue(Self.wrap(raw["at"]))
        self.remainingMs = AgentProValueReader.intValue(Self.wrap(raw["remainingMs"]))
        let rawLabel = (raw["label"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.label = (rawLabel?.isEmpty ?? true) ? nil : rawLabel
        // A node with none of the three fields carries no usable expiry; drop it so the card doesn't
        // render an empty countdown.
        if self.at == nil, self.remainingMs == nil, self.label == nil { return nil }
    }

    /// Fraction of a nominal credential lifetime remaining, for the countdown progress bar. The gateway
    /// gives remaining ms but not the original lifetime, so we clamp against a 24h reference window —
    /// enough to make an imminent expiry visibly drain without claiming a precise percentage.
    var countdownFraction: Double {
        guard let remainingMs = self.remainingMs else { return 0 }
        if remainingMs <= 0 { return 0 }
        let reference = 24.0 * 60.0 * 60.0 * 1000.0
        return min(Double(remainingMs) / reference, 1)
    }

    var isExpired: Bool {
        guard let remainingMs = self.remainingMs else { return false }
        return remainingMs <= 0
    }

    private static func wrap(_ value: Any?) -> AnyCodable? {
        guard let value, !(value is NSNull) else { return nil }
        return AnyCodable(value)
    }
}

// MARK: - Profile

/// Mirror of `ModelAuthStatusProfile` (`models-auth-status.ts:66`): one credential profile under a
/// provider. `reasonCode` is the precise failure reason (`credential-state.ts:11`) shown on a re-auth
/// card. `type` distinguishes an OAuth session (re-login) from a static API key (rotate on the host).
struct AuthProfileLite: Identifiable {
    let profileId: String
    let type: String
    let status: AuthHealthStatus
    let reasonCode: String?
    let expiry: AuthExpiryLite?

    var id: String { self.profileId }

    init(reading raw: [String: Any]) {
        self.profileId = (raw["profileId"] as? String) ?? "profile"
        self.type = (raw["type"] as? String) ?? "token"
        self.status = AuthHealthStatus(raw: raw["status"] as? String)
        let rawReason = (raw["reasonCode"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.reasonCode = (rawReason?.isEmpty ?? true) ? nil : rawReason
        self.expiry = AuthExpiryLite(reading: raw["expiry"] as? [String: Any])
    }

    /// Human profile-type label for the card caption.
    var typeLabel: String {
        switch self.type.lowercased() {
        case "oauth": "OAuth session"
        case "api_key": "API key"
        case "token": "Token"
        default: self.type
        }
    }

    /// Humanized `reasonCode` for the re-auth caption, falling back to nil when `ok`/absent so the card
    /// doesn't print a redundant "ok" reason.
    var reasonText: String? {
        guard let reasonCode = self.reasonCode, reasonCode.lowercased() != "ok" else { return nil }
        switch reasonCode.lowercased() {
        case "missing_credential": return "No credential on the host"
        case "invalid_expires": return "Credential expiry is invalid"
        case "expired": return "Credential expired"
        case "unresolved_ref": return "Credential reference can't be resolved"
        default: return reasonCode.replacingOccurrences(of: "_", with: " ")
        }
    }
}

// MARK: - Provider

/// Mirror of `ModelAuthStatusProvider` (`models-auth-status.ts:74`): a provider's rolled-up auth health
/// plus its per-profile breakdown and optional usage (plan + quota windows). Reuses `OpsUsageWindowLite`
/// (already in `OpsModels.swift`) for the windows so the quota bars render identically to the Ops screen.
struct AuthProviderLite: Identifiable {
    let provider: String
    let displayName: String?
    let status: AuthHealthStatus
    let expiry: AuthExpiryLite?
    let profiles: [AuthProfileLite]
    let plan: String?
    let windows: [OpsUsageWindowLite]

    var id: String { self.provider }

    /// Display label: prefer the human `displayName`, fall back to the raw provider id.
    var name: String {
        let trimmed = self.displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? self.provider : trimmed
    }

    /// True when this provider (or any of its profiles) needs a host-side re-login.
    var needsReauth: Bool {
        self.status.needsReauth || self.profiles.contains { $0.status.needsReauth }
    }

    /// True when the provider is healthy but a credential is approaching expiry — surfaced as an amber
    /// early-warning card distinct from a hard re-auth.
    var isExpiringSoon: Bool {
        self.status.isExpiringSoon || self.profiles.contains { $0.status.isExpiringSoon }
    }

    /// Worst `usedPercent` across the provider's quota windows (0...100+), for the quota bar.
    var worstUsedPercent: Double {
        self.windows.map(\.usedPercentValue).max() ?? 0
    }

    var worstWindow: OpsUsageWindowLite? {
        self.windows.max { $0.usedPercentValue < $1.usedPercentValue }
    }

    /// The first profile carrying a re-auth reason / expiry, for the card's headline caption — the
    /// dead-credential a host-side re-login would clear.
    var leadProfile: AuthProfileLite? {
        self.profiles.first { $0.status.needsReauth }
            ?? self.profiles.first { $0.status.isExpiringSoon }
            ?? self.profiles.first
    }

    init(reading raw: [String: Any]) {
        self.provider = (raw["provider"] as? String) ?? "unknown"
        self.displayName = raw["displayName"] as? String
        self.status = AuthHealthStatus(raw: raw["status"] as? String)
        self.expiry = AuthExpiryLite(reading: raw["expiry"] as? [String: Any])
        let profilesRaw = (raw["profiles"] as? [[String: Any]]) ?? []
        self.profiles = profilesRaw.map(AuthProfileLite.init(reading:))
        let usage = raw["usage"] as? [String: Any]
        let rawPlan = (usage?["plan"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.plan = (rawPlan?.isEmpty ?? true) ? nil : rawPlan
        let windowsRaw = (usage?["windows"] as? [[String: Any]]) ?? []
        self.windows = windowsRaw.map(OpsUsageWindowLite.init(reading:))
    }
}

// MARK: - Result envelope

/// Mirror of `ModelAuthStatusResult` (`models-auth-status.ts:87`): the snapshot timestamp + provider
/// list. `ts == 0` is the gateway's "never loaded" sentinel.
struct AuthHealthResultLite {
    let ts: Int?
    let providers: [AuthProviderLite]

    /// Lossy per-`providers[]`-element decode: parse the envelope, rebuild each provider from a lenient
    /// `[String: Any]` so one malformed provider row can't drop the whole rollup.
    static func decode(from data: Data) -> AuthHealthResultLite? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let providersRaw = (root["providers"] as? [[String: Any]]) ?? []
        let providers = providersRaw.map(AuthProviderLite.init(reading:))
        return AuthHealthResultLite(
            ts: AgentProValueReader.intValue(wrap(root["ts"])),
            providers: providers)
    }

    private static func wrap(_ value: Any?) -> AnyCodable? {
        guard let value, !(value is NSNull) else { return nil }
        return AnyCodable(value)
    }
}

// MARK: - Logout result

/// Mirror of `ModelAuthLogoutResult` (`models-auth-status.ts:93`): the result of `models.authLogout`
/// (scope `operator.admin`) — the removed dead profiles + the in-flight runs it aborted for that
/// provider. Surfaced so the confirm-flow can report exactly what was cleared.
struct AuthLogoutResultLite {
    let provider: String
    let removedProfiles: [String]
    let abortedRunIds: [String]

    static func decode(from data: Data) -> AuthLogoutResultLite? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let provider = (root["provider"] as? String) ?? ""
        let removed = (root["removedProfiles"] as? [Any])?.compactMap { $0 as? String } ?? []
        let aborted = (root["abortedRunIds"] as? [Any])?.compactMap { $0 as? String } ?? []
        return AuthLogoutResultLite(
            provider: provider,
            removedProfiles: removed,
            abortedRunIds: aborted)
    }
}
