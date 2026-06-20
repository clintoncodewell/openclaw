import Foundation
import OpenClawKit
import OpenClawProtocol
import SwiftUI

/// Closed load state for the Agent Inbox so the view never juggles parallel nullable flags.
/// Mirrors `BriefsLoadState`.
enum InboxLoadState: Equatable {
    case idle
    case loading
    case loaded([InboxApproval])
    case empty
    case offline
    case error(String)
}

/// Closed outcome of an inbox resolve so the caller can't conflate "command is gone" with "command
/// is still pending." `.allowAlwaysUnavailable` must keep the row: the gateway rejected `allow-always`
/// without resolving the record, so the command stays blocked and the user must pick another action.
enum InboxResolveResult: Equatable {
    case resolved
    case allowAlwaysUnavailable
    case transientFailure
}

/// Drives the Agent Inbox: fetches pending exec approvals (`exec.approval.list`), resolves them
/// through the existing canonical path on `NodeAppModel`, and keeps the row list fresh from the
/// live server-event stream. Structure mirrors `BriefsInboxViewModel`.
@MainActor
@Observable
final class AgentInboxViewModel {
    private(set) var state: InboxLoadState = .idle

    /// Approval ids with an in-flight resolve. Buttons for these rows disable while resolving so a
    /// double-tap can't fire two `exec.approval.resolve` calls for the same record.
    private(set) var resolvingIDs: Set<String> = []

    /// Per-row resolve error text, surfaced inline under the failing card.
    private(set) var rowErrors: [String: String] = [:]

    /// Pending approvals visible to this client, newest-first. Empty unless we have a loaded page.
    var approvals: [InboxApproval] {
        guard case let .loaded(approvals) = self.state else { return [] }
        return approvals
    }

    /// Count for the inbox badge / header. Only meaningful on a loaded page.
    var pendingCount: Int {
        if case let .loaded(approvals) = self.state { return approvals.count }
        return 0
    }

    func load(appModel: NodeAppModel, force: Bool) async {
        guard self.connected(appModel: appModel) else {
            self.state = .offline
            return
        }
        if case .loading = self.state, !force { return }
        // Preserve already-loaded rows while refetching so the list never blanks to a spinner —
        // covers pull-to-refresh (force), the scenePhase foreground refresh, and live-event reloads.
        if case .loaded = self.state {} else {
            self.state = .loading
        }

        do {
            // `exec.approval.list` takes no params (handler ignores them) and returns a bare JSON
            // array scoped to records this client may see; no client-side filtering is needed.
            let data = try await appModel.operatorSession.request(
                method: "exec.approval.list",
                paramsJSON: "{}",
                timeoutSeconds: 12)
            let approvals = InboxApproval.decodeList(from: data)
                .sorted { $0.createdAtMs > $1.createdAtMs }
            // Reconcile per-row transient state against the freshly fetched ids so stale errors /
            // resolving flags for rows that have since disappeared don't linger.
            let liveIDs = Set(approvals.map(\.id))
            self.resolvingIDs.formIntersection(liveIDs)
            self.rowErrors = self.rowErrors.filter { liveIDs.contains($0.key) }
            self.state = approvals.isEmpty ? .empty : .loaded(approvals)
        } catch {
            // Keep prior rows visible on a transient refresh failure; only surface an error when we
            // have nothing on screen.
            if case .loaded = self.state { return }
            self.state = .error(Self.errorText(error))
        }
    }

    /// Resolve a pending approval, reusing `NodeAppModel.resolveExecApproval` (which wraps the same
    /// canonical resolver the watch / notification path uses — it sends `exec.approval.resolve`,
    /// clears notifications, and syncs the watch). The row is optimistically removed; on a transient
    /// failure it is restored and an inline error is shown. A reconciling `load` then squares the
    /// list with the gateway's broadcast.
    func resolve(_ approval: InboxApproval, decision: String, appModel: NodeAppModel) async {
        guard !self.resolvingIDs.contains(approval.id) else { return }
        guard case let .loaded(current) = self.state else { return }

        self.resolvingIDs.insert(approval.id)
        self.rowErrors[approval.id] = nil

        // Optimistic removal: drop the row immediately so the inbox feels instant.
        let remaining = current.filter { $0.id != approval.id }
        self.state = remaining.isEmpty ? .empty : .loaded(remaining)

        let result = await appModel.resolveExecApproval(approvalId: approval.id, decision: decision)
        self.resolvingIDs.remove(approval.id)

        if result == .resolved {
            // Reconcile against the gateway (the `exec.approval.resolved` broadcast also triggers a
            // reload via the screen's event subscription; this covers the non-foregrounded path).
            await self.load(appModel: appModel, force: true)
            return
        }

        // Not resolved: the command is still pending on the gateway, so roll the optimistic removal
        // back and surface why inline. `.allowAlwaysUnavailable` is not a failure — the gateway
        // rejected only `allow-always`, so steer the user to a decision the policy accepts rather
        // than letting the row vanish as "approved always".
        let message =
            result == .allowAlwaysUnavailable
                ? "\"Always\" isn't allowed for this command. Choose Approve or Ignore."
                : "Couldn't resolve. Try again."
        guard case let .loaded(now) = self.state else {
            self.restore(approval, into: current)
            self.rowErrors[approval.id] = message
            return
        }
        if !now.contains(where: { $0.id == approval.id }) {
            self.restore(approval, into: now)
        }
        self.rowErrors[approval.id] = message
    }

    /// Re-insert a rolled-back approval keeping the newest-first ordering by `createdAtMs`.
    private func restore(_ approval: InboxApproval, into approvals: [InboxApproval]) {
        var next = approvals.filter { $0.id != approval.id }
        next.append(approval)
        next.sort { $0.createdAtMs > $1.createdAtMs }
        self.state = .loaded(next)
    }

    private func connected(appModel: NodeAppModel) -> Bool {
        guard !appModel.isLocalGatewayFixtureEnabled else { return false }
        guard appModel.isOperatorGatewayConnected else { return false }
        return GatewayStatusBuilder.build(appModel: appModel) == .connected
    }

    private static func errorText(_ error: Error) -> String {
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Could not load the inbox." : trimmed
    }
}
