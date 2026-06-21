import Foundation
import OpenClawKit
import OpenClawProtocol
import SwiftUI

/// Closed load state for the Security Posture surface. Mirrors the reference VMs.
enum SecurityPostureLoadState: Equatable {
    case idle
    case loading
    case loaded(SecurityPostureReport)
    case empty
    case offline
    case error(String)

    static func == (lhs: SecurityPostureLoadState, rhs: SecurityPostureLoadState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.loading, .loading), (.empty, .empty), (.offline, .offline):
            true
        case let (.error(l), .error(r)):
            l == r
        case let (.loaded(l), .loaded(r)):
            l.localScopes.scopes.count == r.localScopes.scopes.count
                && l.devices.count == r.devices.count
                && l.policy?.posture.label == r.policy?.posture.label
        default:
            false
        }
    }
}

/// The assembled security-posture report: this device's scopes/role (local), the paired-device roster
/// (`device.pair.list`), and the current approval policy (`exec.approvals.get`). The live pending feed
/// is held separately on the view model (it mutates from broadcast events independently of the report).
struct SecurityPostureReport {
    let localScopes: LocalDeviceScopes
    let devices: [PairedDeviceLite]
    /// `nil` when `exec.approvals.get` failed or the device lacks `operator.admin` to read the policy —
    /// the card then states the policy is unavailable rather than fabricating a posture.
    let policy: ApprovalPolicyLite?
    /// True when the policy read returned a missing-scope error (device lacks admin), so the screen can
    /// distinguish "couldn't read" from "policy genuinely absent".
    let policyNeedsAdmin: Bool

    var hasAnySignal: Bool {
        !self.localScopes.scopes.isEmpty || !self.devices.isEmpty || self.policy != nil
    }
}

/// Drives the Security Posture surface. Like the reference VMs: closed load state, `connected` gate
/// copied verbatim, concurrent reads, preserve-on-refetch, lossy decode.
///
/// HONEST SCOPE — this is a POSTURE surface, NOT an audit log. `load` reads:
/// - this device's scopes/role LOCALLY (`DeviceAuthStore`, no RPC),
/// - `device.pair.list` (scope `operator.pairing`) for the paired roster,
/// - `exec.approvals.get` (scope `operator.admin`) for the current approval policy,
/// - `exec.approval.list` (scope `operator.approvals`) once to SEED the live pending feed.
///
/// The pending feed is then kept current from the `exec.approval.requested` / `exec.approval.resolved`
/// broadcast (`CommandCenterTab.swift:849`) via `observeApprovalEvents` — SESSION-LOCAL, resets on
/// relaunch. There is NO historical security-event / resolved-decision endpoint, so resolved rows exist
/// only for approvals resolved while this screen is open; the screen states that plainly.
@MainActor
@Observable
final class SecurityPostureViewModel {
    private(set) var state: SecurityPostureLoadState = .idle

    /// The session-local approvals feed: pending requests + resolutions observed live, newest first.
    /// Seeded from `exec.approval.list` on load, then mutated from the broadcast. Capped so a long
    /// session doesn't grow it unbounded.
    private(set) var approvalFeed: [ApprovalFeedEntry] = []

    private static let feedLimit = 50

    var report: SecurityPostureReport? {
        if case let .loaded(report) = self.state { return report }
        return nil
    }

    func load(appModel: NodeAppModel, force: Bool) async {
        guard self.connected(appModel: appModel) else {
            self.state = .offline
            return
        }
        if case .loading = self.state, !force { return }
        if case .loaded = self.state {} else {
            self.state = .loading
        }

        // This device's scopes are local — no RPC. Read first so the posture card renders even if every
        // RPC below fails (a fully offline-but-paired device still shows its own grant). The local device
        // id comes from the same `DeviceIdentityStore` the model uses for its gateway auth tokens.
        let localScopes = LocalDeviceScopes(deviceId: DeviceIdentityStore.loadOrCreate().deviceId)

        // Three concurrent reads + the policy error captured separately (we must distinguish a
        // missing-admin-scope denial from a genuine failure). Each is independent: a nil from any one
        // drops only that section.
        async let devicesData = Self.requestData(
            appModel: appModel,
            method: "device.pair.list",
            paramsJSON: "{}")
        async let policyResult = Self.requestPolicy(appModel: appModel)
        async let pendingData = Self.requestData(
            appModel: appModel,
            method: "exec.approval.list",
            paramsJSON: "{}")

        let devices = await devicesData
        let policy = await policyResult
        let pending = await pendingData

        let pairedDevices = devices.map { PairedDeviceLite.decodePairedList(from: $0) } ?? []

        // Seed the live feed once from the pending list (skip on a forced refresh that already has a
        // feed, so we don't wipe live-observed resolutions). Pending rows are newest-first by createdAt.
        if self.approvalFeed.isEmpty, let pending {
            let pendingEntries = InboxApproval.decodeList(from: pending)
                .map(ApprovalFeedEntry.init(pending:))
                .sorted { $0.timestamp > $1.timestamp }
            self.approvalFeed = Array(pendingEntries.prefix(Self.feedLimit))
        }

        let report = SecurityPostureReport(
            localScopes: localScopes,
            devices: pairedDevices,
            policy: policy.policy,
            policyNeedsAdmin: policy.needsAdmin)

        self.state = report.hasAnySignal ? .loaded(report) : .empty
    }

    // MARK: - Live approvals feed (broadcast-driven, session-local)

    /// Keep the pending feed current from the live broadcast while the screen is foregrounded. A
    /// `requested` event prepends a new pending row (reusing the `exec.approval.list` decode for the
    /// request body); a `resolved` event flips the matching pending row to a resolved entry carrying the
    /// decision. SESSION-LOCAL — there's no historical endpoint, so this only tracks activity observed
    /// while open. Mirrors the broadcast handling already wired in `CommandCenterTab` / `AgentInbox`.
    func observeApprovalEvents(appModel: NodeAppModel) async {
        let stream = await appModel.operatorSession.subscribeServerEvents(bufferingNewest: 200)
        for await event in stream {
            if Task.isCancelled { return }
            switch event.event {
            case "exec.approval.requested":
                // Re-seed pending rows from the authoritative list rather than parse the broadcast
                // payload's request shape, so a `requested` row always matches the Inbox's decode.
                await self.refreshPending(appModel: appModel)
            case "exec.approval.resolved":
                self.applyResolved(payload: event.payload)
            default:
                continue
            }
        }
    }

    /// Re-fetch the pending list and merge any new pending rows into the feed, preserving already-
    /// observed resolved entries (which the list no longer contains — once resolved, a record leaves the
    /// pending map). Dedupe on id so a re-seed doesn't duplicate a row.
    private func refreshPending(appModel: NodeAppModel) async {
        guard let data = await Self.requestData(
            appModel: appModel,
            method: "exec.approval.list",
            paramsJSON: "{}")
        else {
            return
        }
        let pending = InboxApproval.decodeList(from: data).map(ApprovalFeedEntry.init(pending:))
        var existingIds = Set(self.approvalFeed.map(\.id))
        var merged = self.approvalFeed
        for entry in pending where existingIds.insert(entry.id).inserted {
            merged.insert(entry, at: 0)
        }
        self.approvalFeed = Array(merged.prefix(Self.feedLimit))
    }

    /// Flip the matching pending row to a resolved entry from the `exec.approval.resolved` payload
    /// (`{ id, decision, resolvedBy }`, `exec-approval.ts:465`). When the row isn't in the feed (the
    /// screen opened after it was raised), append a resolved entry with the broadcast's command text.
    ///
    /// `EventFrame.payload` is an `AnyCodable` whose nested objects decode to `[String: AnyCodable]`
    /// (not `[String: Any]`), so we round-trip it through `JSONSerialization` rather than casting the
    /// inner values directly — the same lossy decode contract the rest of the surface uses.
    private func applyResolved(payload: AnyCodable?) {
        guard let payload,
              let data = try? JSONEncoder().encode(payload),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return
        }
        guard let id = (dict["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty
        else {
            return
        }
        let decision = dict["decision"] as? String
        let priorIndex = self.approvalFeed.firstIndex { $0.id == id }
        let command = priorIndex.map { self.approvalFeed[$0].command }
            ?? (dict["command"] as? String)
            ?? "command"
        let origin = priorIndex.map { self.approvalFeed[$0].origin } ?? "Unknown source"
        let resolvedEntry = ApprovalFeedEntry(
            resolvedId: id,
            decision: decision,
            command: command,
            origin: origin)
        if let priorIndex {
            self.approvalFeed[priorIndex] = resolvedEntry
        } else {
            self.approvalFeed.insert(resolvedEntry, at: 0)
            self.approvalFeed = Array(self.approvalFeed.prefix(Self.feedLimit))
        }
    }

    // MARK: - Policy read (admin-gated)

    /// Read `exec.approvals.get`, classifying a missing-scope denial separately so the screen shows a
    /// "needs admin to read policy" notice instead of treating the policy as absent.
    private static func requestPolicy(
        appModel: NodeAppModel) async -> (policy: ApprovalPolicyLite?, needsAdmin: Bool)
    {
        do {
            let data = try await appModel.operatorSession.request(
                method: "exec.approvals.get",
                paramsJSON: "{}",
                timeoutSeconds: 12)
            return (ApprovalPolicyLite.decode(from: data), false)
        } catch {
            if let responseError = error as? GatewayResponseError,
               responseError.message.localizedCaseInsensitiveContains("missing scope")
            {
                return (nil, true)
            }
            return (nil, false)
        }
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

    // MARK: - Connection gate (copied verbatim from CostInsightsViewModel)

    private func connected(appModel: NodeAppModel) -> Bool {
        guard !appModel.isLocalGatewayFixtureEnabled else { return false }
        guard appModel.isOperatorGatewayConnected else { return false }
        return GatewayStatusBuilder.build(appModel: appModel) == .connected
    }
}
