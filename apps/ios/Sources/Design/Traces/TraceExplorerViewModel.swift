import Foundation
import OpenClawKit
import OpenClawProtocol
import SwiftUI

/// Closed load state for the Run Explorer list so the view never juggles parallel nullable flags.
/// Mirrors `CostLoadState` / `InboxLoadState` / `BriefsLoadState`.
enum TraceListLoadState: Equatable {
    case idle
    case loading
    case loaded([RunRow])
    case empty
    case offline
    case error(String)

    static func == (lhs: TraceListLoadState, rhs: TraceListLoadState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.loading, .loading), (.empty, .empty), (.offline, .offline):
            true
        case let (.error(l), .error(r)):
            l == r
        case let (.loaded(l), .loaded(r)):
            // Cheap identity by row ids/order; the list re-renders fully on any reload.
            l.map(\.id) == r.map(\.id)
        default:
            false
        }
    }
}

/// Drives the Run Explorer run list. One `sessions.usage` call (range 30d, all agents, `groupBy: instance`
/// so each row is a concrete session a `chat.history` timeline can be fetched against, not a collapsed
/// family) yields the per-session rollups the rows render. Structure mirrors `CostInsightsViewModel`:
/// a closed load-state enum, a `connected(appModel:)` gate copied verbatim, and a load that preserves the
/// prior rows on a transient failure so the list never blanks to a spinner mid-refresh.
@MainActor
@Observable
final class TraceExplorerViewModel {
    private(set) var state: TraceListLoadState = .idle

    /// 30-day window, all agents, ~50 rows — the same window the Cost dashboard uses, so a session that
    /// shows up there shows up here.
    private static let sessionsLimit = 50

    var rows: [RunRow] {
        if case let .loaded(rows) = self.state { return rows }
        return []
    }

    func load(appModel: NodeAppModel, force: Bool) async {
        guard self.connected(appModel: appModel) else {
            self.state = .offline
            return
        }
        if case .loading = self.state, !force { return }
        // Preserve already-loaded rows while refetching so the list never blanks to a spinner — covers
        // pull-to-refresh (force) and the foreground refresh (force == false).
        if case .loaded = self.state {} else {
            self.state = .loading
        }

        let data: Data
        do {
            data = try await appModel.operatorSession.request(
                method: "sessions.usage",
                paramsJSON: Self.sessionsParamsJSON(),
                timeoutSeconds: 12)
        } catch {
            // Keep any prior rows on a transient failure; only surface an error when otherwise empty.
            if case .loaded = self.state { return }
            self.state = .error(Self.errorText(error))
            return
        }

        guard let result = SessionsRunListResultLite.decode(from: data) else {
            if case .loaded = self.state { return }
            self.state = .error("Could not read recent runs.")
            return
        }

        let rows = Self.buildRows(from: result.sessions ?? [])
        self.state = rows.isEmpty ? .empty : .loaded(rows)
    }

    // MARK: - Params

    /// `sessions.usage` params: strict-validated by `SessionsUsageParamsSchema`
    /// (`packages/gateway-protocol/src/schema/sessions.ts:498-536`, `additionalProperties: false`), built
    /// through the `SessionsUsageParams` Swift model so the exact key casing is guaranteed.
    /// `groupBy: instance` keeps rows as concrete sessions (each has a `chat.history` transcript); the
    /// Cost dashboard uses `family`, but the timeline needs an instance key to fetch.
    private static func sessionsParamsJSON() -> String {
        let params = SessionsUsageParams(
            key: nil,
            agentid: nil,
            agentscope: "all",
            startdate: nil,
            enddate: nil,
            mode: nil,
            range: AnyCodable("30d"),
            groupby: AnyCodable("instance"),
            includehistorical: nil,
            utcoffset: nil,
            limit: Self.sessionsLimit,
            includecontextweight: nil)
        guard let data = try? JSONEncoder().encode(params),
              let json = String(data: data, encoding: .utf8)
        else {
            return "{\"range\":\"30d\",\"agentScope\":\"all\",\"groupBy\":\"instance\",\"limit\":\(Self.sessionsLimit)}"
        }
        return json
    }

    // MARK: - Row assembly

    /// Map decoded entries to rows: keep only sessions that actually recorded activity (a row with no
    /// usage and no tool calls has no timeline worth drilling into), then sort newest-activity-first.
    private static func buildRows(from entries: [SessionUsageEntryLite]) -> [RunRow] {
        entries
            .filter { entry in
                entry.usage != nil || entry.toolCallCount > 0 || (entry.updatedAt ?? 0) > 0
            }
            .map { RunRow(entry: $0) }
            .sorted { ($0.lastActivityMs ?? 0) > ($1.lastActivityMs ?? 0) }
    }

    // MARK: - Connection gate (copied verbatim from AgentInboxViewModel)

    private func connected(appModel: NodeAppModel) -> Bool {
        guard !appModel.isLocalGatewayFixtureEnabled else { return false }
        guard appModel.isOperatorGatewayConnected else { return false }
        return GatewayStatusBuilder.build(appModel: appModel) == .connected
    }

    private static func errorText(_ error: Error) -> String {
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Could not load recent runs." : trimmed
    }
}
