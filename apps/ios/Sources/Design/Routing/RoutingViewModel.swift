import Foundation
import OpenClawKit
import OpenClawProtocol
import SwiftUI

/// Closed load state for the Model Routing surface so the view never juggles parallel nullable flags.
/// Mirrors `CostLoadState` / `OpsLoadState`.
enum RoutingLoadState: Equatable {
    case idle
    case loading
    case loaded(RoutingReport)
    case empty
    case offline
    case error(String)

    static func == (lhs: RoutingLoadState, rhs: RoutingLoadState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.loading, .loading), (.empty, .empty), (.offline, .offline):
            true
        case let (.error(l), .error(r)):
            l == r
        case let (.loaded(l), .loaded(r)):
            // Identity by the cheap scalar counts; the screen re-renders fully on any reload.
            l.rows.count == r.rows.count
                && l.catalog.models.count == r.catalog.models.count
                && l.unavailableRowCount == r.unavailableRowCount
        default:
            false
        }
    }
}

/// The fully assembled routing report the screen renders: one row per agent (primary + ordered
/// fallback chain, each tagged available/unavailable from the catalog) plus the catalog itself for the
/// grouped reference section. READ-ONLY — the gateway exposes no non-destructive routing setter: the
/// only writable RPC (`agents.update`) takes a bare `model` string that replaces the whole
/// `{primary, fallbacks}` config object, destroying the fallback chain, so the surface stays a pure
/// derived view.
struct RoutingReport {
    let rows: [AgentRoutingRow]
    let catalog: RoutingCatalog
    let defaultAgentId: String?

    /// Count of agents whose chain has at least one provider-auth-unavailable step, for the header.
    var unavailableRowCount: Int {
        self.rows.reduce(0) { $0 + ($1.hasUnavailableStep ? 1 : 0) }
    }

    var hasAnySignal: Bool {
        !self.rows.isEmpty || !self.catalog.isEmpty
    }
}

/// Drives the Model Routing surface. Like `CostInsightsViewModel` / `OpsHealthViewModel`: a closed
/// load-state enum, a `connected(appModel:)` gate copied verbatim, concurrent reads, a load that
/// preserves the prior report on a transient failure, and lossy per-element JSON decode.
///
/// `load` fires two concurrent reads — `agents.list` (per-agent primary + already-resolved fallback
/// chain) and `models.list` `{"view":"all"}` (availability-annotated catalog) — and folds them into
/// per-agent routing rows cross-referenced against the catalog.
///
/// READ-ONLY by design. The gateway exposes no non-destructive routing setter: the only writable RPC
/// (`agents.update`, `AgentsUpdateParamsSchema`) accepts a bare `model` string, and the handler writes
/// it straight into the agent's `model` config field (`applyAgentConfig`), replacing the whole
/// `{primary, fallbacks}` object. A bare string then reads back as an explicit `fallbacks: []` override
/// (`resolveSelectedModelFallbacksOverride`), wiping the agent's chain AND disabling global default
/// fallbacks. The non-destructive `setAgentEffectiveModelPrimary` helper exists server-side but is wired
/// to no RPC, so there is no primary-only setter to call. The surface therefore stays a pure read view.
@MainActor
@Observable
final class RoutingViewModel {
    private(set) var state: RoutingLoadState = .idle

    var report: RoutingReport? {
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

        // Two concurrent reads. `agents.list` is the primary source (per-agent primary + fallbacks);
        // `models.list` `{"view":"all"}` is the availability-annotated catalog used to tag each step.
        // The catalog failing only drops availability flags (steps render `.unknown`), never the rows.
        async let agentsData = Self.requestData(
            appModel: appModel,
            method: "agents.list",
            paramsJSON: "{}")
        async let modelsData = Self.requestData(
            appModel: appModel,
            method: "models.list",
            paramsJSON: "{\"view\":\"all\"}")

        let agents = await agentsData
        let models = await modelsData

        // `agents.list` is the primary source; if it failed entirely, keep any prior report and only
        // surface an error when the screen is otherwise empty (mirrors the reference VMs).
        guard let agentsData = agents else {
            if case .loaded = self.state { return }
            self.state = .error("Could not load agent routing.")
            return
        }

        let decoded = AgentRoutingLite.decodeList(from: agentsData)
        let catalogModels = models.map { RoutingCatalogModel.decodeList(from: $0) } ?? []
        let catalog = RoutingCatalog(models: catalogModels)
        let rows = decoded.agents.map { AgentRoutingRow(agent: $0, catalog: catalog) }
        let report = RoutingReport(rows: rows, catalog: catalog, defaultAgentId: decoded.defaultId)

        self.state = report.hasAnySignal ? .loaded(report) : .empty
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
