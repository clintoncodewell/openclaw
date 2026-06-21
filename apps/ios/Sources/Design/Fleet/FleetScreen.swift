import OpenClawKit
import OpenClawProtocol
import SwiftUI

/// The Fleet dashboard: every KNOWN node (Mac / iPhone / desktop, online AND offline-but-paired) from
/// `node.list`, the gateway's own connection state, and the read-only agent roster from `agents.list`.
/// Pushed inside Command Center's existing NavigationStack so the system back button works for free.
///
/// REAL signals shown: per-node connection status, device class, platform / version, capabilities,
/// declared commands, last-seen, and one-tap STATUS-READ actions where the node declares the command.
/// Complementary to the Agent Pro Instances sub-view (which renders `system-presence` beacons only, has
/// no offline nodes, and no actions) — Fleet is the richer `node.list`-backed surface.
///
/// HONEST about reachable actions: only default-allowlisted status reads render as one-tap buttons;
/// invasive-capture commands appear only if an operator has already enabled them server-side
/// (`gateway.nodes.allowCommands`) AND behind a confirmation dialog. The app never paints an affordance it
/// cannot actually invoke.
struct FleetScreen: View {
    @Environment(NodeAppModel.self) private var appModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var viewModel = FleetViewModel()

    var body: some View {
        ZStack {
            OpenClawProBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    self.header
                    self.content
                }
                .padding(.top, 14)
                .padding(.bottom, 18)
            }
            .safeAreaPadding(.bottom, OpenClawProMetric.bottomScrollInset)
        }
        .navigationTitle("Fleet")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            await self.viewModel.load(appModel: self.appModel, force: true)
        }
        .task(id: self.scenePhase) {
            guard self.scenePhase == .active else { return }
            await self.viewModel.load(appModel: self.appModel, force: false)
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Fleet")
                .font(.system(size: 27, weight: .bold, design: .rounded))
            Text(self.headerDetail)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, OpenClawProMetric.pagePadding)
    }

    private var headerDetail: String {
        switch self.viewModel.state {
        case .idle, .loading:
            return "Loading nodes, agents & gateway"
        case .offline:
            return "Gateway offline"
        case .error:
            return "Fleet unavailable"
        case .empty:
            return "No nodes paired yet"
        case let .loaded(snapshot):
            let nodeWord = snapshot.nodes.count == 1 ? "node" : "nodes"
            return "\(snapshot.nodes.count) \(nodeWord) • \(snapshot.onlineCount) online"
        }
    }

    // MARK: - Content router

    @ViewBuilder
    private var content: some View {
        switch self.viewModel.state {
        case .idle, .loading:
            self.loadingState
        case .offline:
            self.emptyState(
                icon: "wifi.slash",
                title: "Gateway offline",
                detail: "Connect to the gateway to view the fleet.")
        case let .error(message):
            self.emptyState(
                icon: "exclamationmark.triangle.fill",
                title: "Fleet unavailable",
                detail: message)
        case .empty:
            self.emptyState(
                icon: "square.grid.2x2",
                title: "No nodes paired",
                detail: "Pair a Mac or iPhone node to see it here.")
        case let .loaded(snapshot):
            self.loadedContent(snapshot)
        }
    }

    @ViewBuilder
    private func loadedContent(_ snapshot: FleetSnapshot) -> some View {
        self.gatewaySection(snapshot)
        self.nodesSection(snapshot)
        self.agentsSection(snapshot)
    }

    // MARK: - Gateway row

    @ViewBuilder
    private func gatewaySection(_ snapshot: FleetSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ProSectionHeader(title: "Gateway")
            CommandPanel(padding: 12) {
                HStack(alignment: .center, spacing: 12) {
                    ProIconBadge(
                        systemName: "antenna.radiowaves.left.and.right",
                        color: snapshot.gatewayConnected ? OpenClawBrand.ok : .secondary)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Gateway")
                            .font(.subheadline.weight(.semibold))
                        Text(snapshot.gatewayConnected
                            ? "\(snapshot.presenceCount) live presence beacons"
                            : "Not connected")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    ProValuePill(
                        value: snapshot.gatewayConnected ? "online" : "offline",
                        color: snapshot.gatewayConnected ? OpenClawBrand.ok : .secondary)
                }
            }
            .padding(.horizontal, OpenClawProMetric.pagePadding)
        }
    }

    // MARK: - Nodes list

    @ViewBuilder
    private func nodesSection(_ snapshot: FleetSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ProSectionHeader(title: self.nodesHeaderTitle(snapshot))
            ProCard(padding: 0) {
                if snapshot.nodes.isEmpty {
                    self.inlineEmptyRow(
                        icon: "square.grid.2x2",
                        title: "No nodes reported",
                        detail: "The gateway returned no known nodes.")
                        .padding(14)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(snapshot.nodes.enumerated()), id: \.element.id) { index, node in
                            NavigationLink {
                                FleetNodeDetail(node: node, viewModel: self.viewModel)
                            } label: {
                                self.nodeRow(node)
                            }
                            .buttonStyle(.plain)
                            if index < snapshot.nodes.count - 1 {
                                Divider().padding(.leading, 60)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, OpenClawProMetric.pagePadding)
        }
    }

    private func nodesHeaderTitle(_ snapshot: FleetSnapshot) -> String {
        snapshot.offlineCount > 0 ? "Nodes · \(snapshot.offlineCount) offline" : "Nodes"
    }

    private func nodeRow(_ node: FleetNode) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ProIconBadge(systemName: node.icon, color: node.status.color)
            VStack(alignment: .leading, spacing: 4) {
                Text(node.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(self.nodeRowDetail(node))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                if let lastSeen = node.lastSeenLabel {
                    Text("Last seen \(lastSeen)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 6) {
                ProValuePill(value: node.status.label, color: node.status.color)
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
    }

    /// Subtitle line: platform • version • caps count, dropping any empty piece so a sparse node doesn't
    /// render dangling separators.
    private func nodeRowDetail(_ node: FleetNode) -> String {
        let capsLabel = node.caps.isEmpty ? nil : "\(node.caps.count) caps"
        let parts = [
            Self.normalized(node.platform),
            Self.normalized(node.version),
            capsLabel,
        ].compactMap(\.self)
        return parts.isEmpty ? "Node \(node.nodeId)" : parts.joined(separator: " • ")
    }

    // MARK: - Agents list (read-only)

    @ViewBuilder
    private func agentsSection(_ snapshot: FleetSnapshot) -> some View {
        if !snapshot.agents.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                ProSectionHeader(title: "Agents")
                ProCard(padding: 0) {
                    VStack(spacing: 0) {
                        ForEach(Array(snapshot.agents.enumerated()), id: \.element.id) { index, agent in
                            self.agentRow(agent)
                            if index < snapshot.agents.count - 1 {
                                Divider().padding(.leading, 60)
                            }
                        }
                    }
                }
                .padding(.horizontal, OpenClawProMetric.pagePadding)
            }
        }
    }

    private func agentRow(_ agent: AgentRoutingLite) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ProIconBadge(systemName: "cpu", color: OpenClawBrand.accent)
            VStack(alignment: .leading, spacing: 4) {
                Text(agent.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(agent.primary ?? "Gateway default model")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if agent.isDefault {
                ProValuePill(value: "default", color: OpenClawBrand.accent)
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
    }

    // MARK: - Shared states

    private var loadingState: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text("Loading the fleet")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, OpenClawProMetric.pagePadding)
    }

    private func emptyState(icon: String, title: String, detail: String) -> some View {
        CommandEmptyStateRow(icon: icon, title: title, detail: detail)
            .padding(.horizontal, OpenClawProMetric.pagePadding)
    }

    private func inlineEmptyRow(icon: String, title: String, detail: String) -> some View {
        HStack(spacing: 12) {
            ProIconBadge(systemName: icon, color: .secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
        }
    }

    private static func normalized(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}
