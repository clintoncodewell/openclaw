import Foundation
import OpenClawKit
import OpenClawProtocol
import SwiftUI

/// Closed load state for the Fleet dashboard so the view never juggles parallel nullable flags. Mirrors
/// `OpsLoadState` / `CostLoadState`. `loaded` carries the assembled fleet snapshot.
enum FleetLoadState: Equatable {
    case idle
    case loading
    case loaded(FleetSnapshot)
    case empty
    case offline
    case error(String)

    static func == (lhs: FleetLoadState, rhs: FleetLoadState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.loading, .loading), (.empty, .empty), (.offline, .offline):
            true
        case let (.error(l), .error(r)):
            l == r
        case let (.loaded(l), .loaded(r)):
            // Identity by the cheap scalar counts; the screen re-renders fully on any reload.
            l.nodes.count == r.nodes.count
                && l.onlineCount == r.onlineCount
                && l.agents.count == r.agents.count
                && l.gatewayConnected == r.gatewayConnected
        default:
            false
        }
    }
}

/// The assembled fleet view: every known node (online + offline + pending), the read-only agent roster,
/// the live-presence count, and the gateway's connection state. A plain value so the screen re-renders
/// fully on reload; the equality above keys on the scalar counts only.
struct FleetSnapshot: Equatable {
    let nodes: [FleetNode]
    let agents: [AgentRoutingLite]
    /// Live-presence beacon count from `system-presence` — complementary to `node.list`'s inventory.
    let presenceCount: Int
    let gatewayConnected: Bool

    /// Nodes the gateway reports as holding a live websocket session.
    var onlineCount: Int {
        self.nodes.count { $0.status == .online }
    }

    /// Paired-but-disconnected nodes — the offline rollup that `node.list` surfaces and `system-presence`
    /// cannot (presence only carries live beacons).
    var offlineCount: Int {
        self.nodes.count { $0.status == .offline }
    }

    static func == (lhs: FleetSnapshot, rhs: FleetSnapshot) -> Bool {
        lhs.nodes.count == rhs.nodes.count
            && lhs.onlineCount == rhs.onlineCount
            && lhs.agents.count == rhs.agents.count
            && lhs.presenceCount == rhs.presenceCount
            && lhs.gatewayConnected == rhs.gatewayConnected
    }
}

/// Drives the Fleet dashboard. Like `OpsHealthViewModel`: a closed load-state enum, a `connected(appModel:)`
/// gate copied verbatim, and a load that preserves the prior snapshot on a transient failure so the screen
/// never blanks to a spinner mid-refresh.
///
/// `load` fires two concurrent gateway reads (`node.list`, `agents.list`) plus the already-cheap
/// `system-presence`, and reads the gateway status synchronously off `appModel` via `GatewayStatusBuilder`.
/// `invoke` issues a single `node.invoke` against one node + command, mapping the response / error codes
/// into a closed `FleetActionResult`.
@MainActor
@Observable
final class FleetViewModel {
    private(set) var state: FleetLoadState = .idle

    /// Per-node in-flight + last-result map, keyed by `"\(nodeId):\(command)"`, so the detail screen can
    /// show a spinner on the tapped action and render its outcome inline without threading state through
    /// the view. Kept beside the load state because it's transient UI feedback, not part of the snapshot.
    private(set) var actionResults: [String: FleetActionResult] = [:]
    private(set) var inFlightActions: Set<String> = []

    var snapshot: FleetSnapshot? {
        if case let .loaded(snapshot) = self.state { return snapshot }
        return nil
    }

    func load(appModel: NodeAppModel, force: Bool) async {
        guard self.connected(appModel: appModel) else {
            self.state = .offline
            return
        }
        if case .loading = self.state, !force { return }
        // Preserve already-loaded content while refetching so the fleet never blanks to a spinner —
        // covers pull-to-refresh (force) and the scenePhase foreground refresh (force == false).
        if case .loaded = self.state {} else {
            self.state = .loading
        }

        // Two concurrent reads + the cheap presence beacon. `node.list` is the inventory source; if it
        // failed entirely, keep any prior snapshot and only surface an error when the screen is otherwise
        // empty (mirrors the reference VMs). `agents.list` / `system-presence` each fail independently: a
        // nil from either only drops that section, never the node inventory.
        async let nodeData = Self.requestData(appModel: appModel, method: "node.list", paramsJSON: "{}")
        async let agentData = Self.requestData(appModel: appModel, method: "agents.list", paramsJSON: "{}")
        async let presenceData = Self.requestData(appModel: appModel, method: "system-presence", paramsJSON: "{}")

        let nodes = await nodeData
        let agents = await agentData
        let presence = await presenceData

        guard let nodeData = nodes else {
            if case .loaded = self.state { return }
            self.state = .error("Could not load the fleet.")
            return
        }

        let fleetNodes = FleetNode.decodeList(from: nodeData)
            .sorted(by: Self.nodeOrder)
        let agentRows = agents.map { AgentRoutingLite.decodeList(from: $0).agents } ?? []
        let presenceCount = presence.flatMap { Self.decodePresenceCount(from: $0) } ?? 0
        let gatewayConnected = GatewayStatusBuilder.build(appModel: appModel) == .connected

        let snapshot = FleetSnapshot(
            nodes: fleetNodes,
            agents: agentRows,
            presenceCount: presenceCount,
            gatewayConnected: gatewayConnected)

        let hasAnySignal = !snapshot.nodes.isEmpty || !snapshot.agents.isEmpty || snapshot.presenceCount > 0
        self.state = hasAnySignal ? .loaded(snapshot) : .empty
    }

    // MARK: - Node action invocation

    /// Invoke one status-read command against a node via `node.invoke`. Builds the params through the
    /// strict `NodeInvokeParams` model so the gateway's `NodeInvokeParamsSchema`
    /// (`gateway-protocol/.../nodes.ts:124-132`, `additionalProperties:false`) sees the exact key casing.
    /// `idempotencyKey` is REQUIRED and non-empty — a fresh UUID per tap dedupes accidental double-taps
    /// without suppressing an intentional re-run. `timeoutMs` 12s allows the gateway's APNs wake + wait
    /// window for a disconnected node before it returns `NOT_CONNECTED`.
    func invoke(_ action: FleetAction, on node: FleetNode, appModel: NodeAppModel) async {
        let key = Self.actionKey(nodeId: node.nodeId, command: action.command)
        guard !self.inFlightActions.contains(key) else { return }
        self.inFlightActions.insert(key)
        self.actionResults[key] = nil
        defer { self.inFlightActions.remove(key) }

        let result = await Self.runInvoke(
            nodeId: node.nodeId,
            command: action.command,
            appModel: appModel)
        self.actionResults[key] = result
    }

    /// Invoke an arbitrary declared command id (used for the dangerous-command path the detail screen
    /// gates behind a confirmation dialog). Same plumbing as `invoke`, but keyed off the raw command so a
    /// server-side-enabled dangerous command (e.g. `camera.snap`) routes through one path.
    func invokeCommand(_ command: String, on node: FleetNode, appModel: NodeAppModel) async {
        let key = Self.actionKey(nodeId: node.nodeId, command: command)
        guard !self.inFlightActions.contains(key) else { return }
        self.inFlightActions.insert(key)
        self.actionResults[key] = nil
        defer { self.inFlightActions.remove(key) }

        let result = await Self.runInvoke(nodeId: node.nodeId, command: command, appModel: appModel)
        self.actionResults[key] = result
    }

    func result(nodeId: String, command: String) -> FleetActionResult? {
        self.actionResults[Self.actionKey(nodeId: nodeId, command: command)]
    }

    func isInFlight(nodeId: String, command: String) -> Bool {
        self.inFlightActions.contains(Self.actionKey(nodeId: nodeId, command: command))
    }

    static func actionKey(nodeId: String, command: String) -> String {
        "\(nodeId):\(command)"
    }

    // MARK: - Invoke plumbing

    /// Issue the `node.invoke` request and map success / gateway-error codes into a `FleetActionResult`.
    /// Static + nonisolated work-free so the `@MainActor` VM stays free of decode/error-mapping bodies.
    private static func runInvoke(
        nodeId: String,
        command: String,
        appModel: NodeAppModel) async -> FleetActionResult
    {
        guard let paramsJSON = Self.invokeParamsJSON(nodeId: nodeId, command: command) else {
            return .error("Could not build the request.")
        }
        do {
            // 15s client timeout > the 12s server `timeoutMs` so the APNs-wake path can resolve before the
            // socket request itself times out.
            let data = try await appModel.operatorSession.request(
                method: "node.invoke",
                paramsJSON: paramsJSON,
                timeoutSeconds: 15)
            return Self.successResult(from: data, command: command)
        } catch let responseError as GatewayResponseError {
            return Self.mapResponseError(responseError)
        } catch {
            return .error(error.localizedDescription)
        }
    }

    /// Build the strict `node.invoke` params. `idempotencyKey` is a fresh UUID (REQUIRED, non-empty per
    /// the schema). `timeoutMs` 12000 is the server-side per-invoke budget.
    private static func invokeParamsJSON(nodeId: String, command: String) -> String? {
        let params = NodeInvokeParams(
            nodeid: nodeId,
            command: command,
            params: nil,
            timeoutms: 12_000,
            idempotencykey: UUID().uuidString)
        guard let data = try? JSONEncoder().encode(params),
              let json = String(data: data, encoding: .utf8)
        else {
            return nil
        }
        return json
    }

    /// On `ok:true`, summarize the payload for the inline result. The payload shape is per-command and
    /// unknown to the client, so we render a compact one-liner (key list / count / scalar) rather than
    /// claiming a typed shape we can't verify across every node command.
    private static func successResult(from data: Data, command: String) -> FleetActionResult {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .ok(summary: "Command completed.")
        }
        // `node.invoke` wraps the node's reply under `payload` (`nodes.ts:1330`); fall back to the root.
        let payload = (root["payload"] as? [String: Any]) ?? root
        return .ok(summary: Self.summarize(payload: payload, command: command))
    }

    /// One-line digest of an arbitrary node payload. Prefers a human field the node commonly returns,
    /// else reports the field names so the operator sees the call actually produced data.
    private static func summarize(payload: [String: Any], command: String) -> String {
        for key in ["status", "state", "message", "summary", "result"] {
            if let value = payload[key] as? String, !value.isEmpty {
                return value
            }
        }
        let keys = payload.keys.sorted()
        if keys.isEmpty { return "Command completed." }
        let shown = keys.prefix(4).joined(separator: ", ")
        let suffix = keys.count > 4 ? ", …" : ""
        return "Returned: \(shown)\(suffix)"
    }

    /// Map a `GatewayResponseError` from `node.invoke` to a closed result. The gateway nests the meaningful
    /// discriminator under `details.code` (`NOT_CONNECTED` / `QUEUED_UNTIL_FOREGROUND`,
    /// `nodes.ts:1240/1378`); the channel surfaces that nested value as `details["code"]` and moves the
    /// outer `UNAVAILABLE` to `details["errorCode"]` (`GatewayChannel.swift:151-171`). We read the nested
    /// code first, then fall back to the top-level `error.code`.
    private static func mapResponseError(_ error: GatewayResponseError) -> FleetActionResult {
        let detailCode = (error.details["code"]?.value as? String) ?? ""
        let topCode = error.code
        let reason = error.detailsReason ?? error.message

        if detailCode == "QUEUED_UNTIL_FOREGROUND" { return .queuedUntilForeground }
        if detailCode == "NOT_CONNECTED" { return .notConnected }
        // Authorization / allowlist rejections — the command isn't in the node's declared+allowlisted set,
        // or the operator lacks the scope. Surfaced as `notAllowed` so the UI explains it rather than
        // showing a raw transport error.
        if topCode == "FORBIDDEN" || topCode == "UNAUTHORIZED" || topCode == "INVALID_REQUEST" {
            return .notAllowed(reason: reason)
        }
        return .error(reason)
    }

    // MARK: - Decode helpers

    /// `system-presence` returns a bare `[PresenceEntry]` array (no envelope), so we count the elements
    /// directly. A failed decode contributes 0 rather than blanking the screen.
    private static func decodePresenceCount(from data: Data) -> Int? {
        guard let entries = try? JSONDecoder().decode([PresenceEntry].self, from: data) else {
            return nil
        }
        return entries.count
    }

    /// Fleet sort: online first (by status rank), then by name within a status bucket so the order is
    /// stable across reloads.
    private static func nodeOrder(_ lhs: FleetNode, _ rhs: FleetNode) -> Bool {
        let lhsRank = lhs.status.sortRank
        let rhsRank = rhs.status.sortRank
        if lhsRank != rhsRank { return lhsRank < rhsRank }
        return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
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

    // MARK: - Connection gate (copied verbatim from OpsHealthViewModel / CostInsightsViewModel)

    private func connected(appModel: NodeAppModel) -> Bool {
        guard !appModel.isLocalGatewayFixtureEnabled else { return false }
        guard appModel.isOperatorGatewayConnected else { return false }
        return GatewayStatusBuilder.build(appModel: appModel) == .connected
    }
}
