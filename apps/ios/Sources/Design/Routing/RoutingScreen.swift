import OpenClawKit
import SwiftUI

/// The Model Routing surface: per-agent routing cards showing the PRIMARY model + the ordered FALLBACK
/// chain (each step tagged available / unavailable / not-in-catalog against the `models.list` catalog),
/// plus a catalog reference section grouped by provider. Pushed inside Command Center's existing
/// NavigationStack so the system back button works for free.
///
/// FULLY READ-ONLY: the gateway exposes no non-destructive routing setter. The only writable RPC
/// (`agents.update`) takes a bare `model` string that the handler writes straight over the agent's whole
/// `{primary, fallbacks}` config object, which reads back as `fallbacks: []` and wipes the chain (and
/// global default fallbacks). So neither the primary nor the fallback chain is editable here — both
/// render as labeled chips with no edit affordance.
struct RoutingScreen: View {
    @Environment(NodeAppModel.self) private var appModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var viewModel = RoutingViewModel()

    /// The agent id this screen scrolls to + highlights when deep-linked from the Agent Pro roster.
    var focusedAgentId: String?

    var body: some View {
        ZStack {
            OpenClawProBackground()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        self.header
                        self.content
                    }
                    .padding(.top, 14)
                    .padding(.bottom, 18)
                }
                .safeAreaPadding(.bottom, OpenClawProMetric.bottomScrollInset)
                // Bring a deep-linked agent's card into view once rows are present; the card carries
                // `.id(agent.id)` so the highlighted target isn't stranded off-screen below the fold.
                .onChange(of: self.viewModel.report?.rows.count) {
                    self.scrollToFocusedAgent(proxy)
                }
            }
        }
        .navigationTitle("Model Routing")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            await self.viewModel.load(appModel: self.appModel, force: true)
        }
        .task(id: self.scenePhase) {
            guard self.scenePhase == .active else { return }
            await self.viewModel.load(appModel: self.appModel, force: false)
        }
    }

    /// Scroll the deep-linked agent's card to the top when it exists in the loaded roster. No-op when no
    /// focus id was passed or the target isn't in the report (the highlight simply doesn't apply).
    private func scrollToFocusedAgent(_ proxy: ScrollViewProxy) {
        guard let focusedAgentId = self.focusedAgentId,
              self.viewModel.report?.rows.contains(where: { $0.agent.id == focusedAgentId }) == true
        else {
            return
        }
        withAnimation { proxy.scrollTo(focusedAgentId, anchor: .top) }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Model Routing")
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
            return "Loading per-agent model routing"
        case .offline:
            return "Gateway offline"
        case .error:
            return "Routing unavailable"
        case .empty:
            return "No agents configured yet"
        case let .loaded(report):
            let count = report.unavailableRowCount
            if count == 0 { return "\(report.rows.count) agents · all routes available" }
            return count == 1 ? "1 agent has an unavailable route" : "\(count) agents have unavailable routes"
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
                detail: "Connect to the gateway to see model routing.")
        case let .error(message):
            self.emptyState(
                icon: "exclamationmark.triangle.fill",
                title: "Routing unavailable",
                detail: message)
        case .empty:
            self.emptyState(
                icon: "arrow.triangle.branch",
                title: "No agents configured",
                detail: "Routing appears once you have at least one agent.")
        case let .loaded(report):
            self.loadedContent(report)
        }
    }

    @ViewBuilder
    private func loadedContent(_ report: RoutingReport) -> some View {
        self.agentsSection(report)
        self.catalogSection(report)
        self.readOnlyNote
    }

    // MARK: - Per-agent routing cards

    @ViewBuilder
    private func agentsSection(_ report: RoutingReport) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ProSectionHeader(title: "Per-agent routing")
            VStack(spacing: 10) {
                ForEach(report.rows) { row in
                    RoutingAgentCard(
                        row: row,
                        isFocused: row.agent.id == self.focusedAgentId)
                        .id(row.agent.id)
                }
            }
            .padding(.horizontal, OpenClawProMetric.pagePadding)
        }
    }

    // MARK: - Catalog section

    @ViewBuilder
    private func catalogSection(_ report: RoutingReport) -> some View {
        let groups = report.catalog.byProvider
        if !groups.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                ProSectionHeader(title: "Model catalog")
                VStack(spacing: 10) {
                    ForEach(groups) { group in
                        RoutingCatalogCard(group: group)
                    }
                }
                .padding(.horizontal, OpenClawProMetric.pagePadding)
            }
        }
    }

    // MARK: - Notices

    private var readOnlyNote: some View {
        RoutingInlineNote(
            icon: "info.circle",
            text: "Routing is read-only. The gateway exposes no non-destructive setter — the one writable RPC replaces the agent's whole model config with a bare string, which wipes the fallback chain — so primary and fallbacks are shown but not editable here.")
            .padding(.horizontal, OpenClawProMetric.pagePadding)
    }

    // MARK: - Shared states

    private var loadingState: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text("Loading model routing")
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
}

// MARK: - Per-agent routing card

/// One agent's routing card: identity header, the primary model as a `ProStatusRow`, and the fallback
/// chain as a vertical list of capsule chips each with a `ProStatusDot` (green = available, amber =
/// unavailable, secondary = not-in-catalog). Fully read-only — no edit affordance.
private struct RoutingAgentCard: View {
    @Environment(\.colorScheme) private var colorScheme
    let row: AgentRoutingRow
    let isFocused: Bool

    var body: some View {
        ProCard(tint: self.isFocused ? OpenClawBrand.accent : nil, isProminent: self.isFocused, padding: 12) {
            VStack(alignment: .leading, spacing: 12) {
                self.cardHeader
                self.primarySection
                if self.row.agent.hasFallbacks {
                    self.fallbackSection
                }
            }
        }
    }

    private var cardHeader: some View {
        HStack(alignment: .center, spacing: 10) {
            ProIconBadge(systemName: "arrow.triangle.branch", color: OpenClawBrand.accent)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(self.row.agent.name)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    if self.row.agent.isDefault {
                        Text("default")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.secondary)
                    }
                }
                Text(self.headerDetail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            if self.row.hasUnavailableStep {
                ProValuePill(value: "route at risk", color: OpenClawBrand.warn)
            }
        }
    }

    private var headerDetail: String {
        let parts = [self.row.agent.workspace, self.row.agent.runtimeId].compactMap(\.self)
        return parts.isEmpty ? self.row.agent.id : parts.joined(separator: " • ")
    }

    // MARK: Primary

    @ViewBuilder
    private var primarySection: some View {
        if let primary = self.row.primaryStep {
            ProStatusRow(
                icon: "star.fill",
                title: primary.displayLabel,
                detail: "Primary model · \(primary.availability.label)",
                value: nil,
                color: primary.availability.color)
        } else {
            ProStatusRow(
                icon: "star",
                title: "Gateway default",
                detail: "No per-agent primary set",
                value: nil,
                color: .secondary)
        }
    }

    // MARK: Fallbacks

    private var fallbackSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Fallback chain")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            VStack(spacing: 6) {
                ForEach(self.row.fallbackSteps) { step in
                    RoutingStepChip(step: step)
                }
            }
        }
        .padding(.top, 2)
    }
}

// MARK: - Fallback step chip

/// One fallback step row: a numbered slot label, the model leaf name, and a status dot + availability
/// caption. A row (not a `ProCapsule`) so the ordered chain reads top-to-bottom with its availability.
private struct RoutingStepChip: View {
    @Environment(\.colorScheme) private var colorScheme
    let step: RoutingStep

    var body: some View {
        HStack(spacing: 10) {
            ProStatusDot(color: self.step.availability.color)
            Text(self.step.slotLabel)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .leading)
            Text(self.step.displayLabel)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer(minLength: 6)
            Text(self.step.availability.label)
                .font(.caption2.weight(.medium))
                .foregroundStyle(self.step.availability.color)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background {
            RoundedRectangle(cornerRadius: OpenClawProMetric.controlRadius, style: .continuous)
                .fill(self.rowFill)
                .overlay {
                    RoundedRectangle(cornerRadius: OpenClawProMetric.controlRadius, style: .continuous)
                        .strokeBorder(self.rowBorder, lineWidth: 1)
                }
        }
    }

    private var rowFill: Color {
        self.colorScheme == .dark ? Color.white.opacity(0.035) : Color(uiColor: .systemBackground)
    }

    private var rowBorder: Color {
        Color(uiColor: .separator).opacity(self.colorScheme == .dark ? 0.24 : 0.22)
    }
}

// MARK: - Catalog provider card

/// One provider's catalog group: a header (provider name + unavailable count) over capsule chips for
/// each model, green/amber dot by availability. Read-only reference for what the routing chain can name.
private struct RoutingCatalogCard: View {
    let group: RoutingCatalogProviderGroup

    var body: some View {
        ProCard(padding: 12) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text(self.group.provider)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    if self.group.unavailableCount > 0 {
                        ProValuePill(
                            value: "\(self.group.unavailableCount) unavailable",
                            color: OpenClawBrand.warn)
                    } else {
                        ProValuePill(value: "\(self.group.models.count)", color: .secondary)
                    }
                }
                self.modelGrid
            }
        }
    }

    private var modelGrid: some View {
        FlowLayout(spacing: 6) {
            ForEach(self.group.models) { model in
                HStack(spacing: 5) {
                    ProStatusDot(color: model.available ? OpenClawBrand.ok : OpenClawBrand.warn)
                    Text(RoutingFormatting.shortModelLabel(model.name))
                        .font(.caption2.weight(.semibold))
                        .lineLimit(1)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background {
                    Capsule().fill(Color.primary.opacity(0.06))
                }
            }
        }
    }
}

// MARK: - Inline note

/// A small inline note row for in-screen informational states, mirroring `OpsInlineNote`.
private struct RoutingInlineNote: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: self.icon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(self.text)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .proPanelSurface(radius: OpenClawProMetric.cardRadius)
    }
}

// MARK: - Flow layout

/// Minimal wrapping flow layout for the catalog chip grid. iOS 18 `Layout`; keeps each provider's
/// model chips wrapping to the available width without a fixed column count. Internal (not file-private)
/// so the Security Posture screen's scope-chip grids reuse the same layout.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    /// Single wrap predicate shared by both passes so measurement and placement can't drift by a spacing
    /// unit at the right margin (the classic hand-rolled FlowLayout bug that clips the last row).
    /// `rowWidth` is the row's used width WITHOUT trailing spacing; a non-empty row wraps when appending
    /// `spacing + width` would exceed the limit.
    private func wraps(rowWidth: CGFloat, width: CGFloat, limit: CGFloat) -> Bool {
        rowWidth > 0 && rowWidth + self.spacing + width > limit
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rowWidth: CGFloat = 0
        var totalHeight: CGFloat = 0
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if self.wraps(rowWidth: rowWidth, width: size.width, limit: maxWidth) {
                totalHeight += rowHeight + self.spacing
                rowWidth = size.width
                rowHeight = size.height
            } else {
                rowWidth = rowWidth == 0 ? size.width : rowWidth + self.spacing + size.width
                rowHeight = max(rowHeight, size.height)
            }
        }
        totalHeight += rowHeight
        let width = proposal.width ?? rowWidth
        return CGSize(width: width, height: totalHeight)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Void)
    {
        var rowWidth: CGFloat = 0
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if self.wraps(rowWidth: rowWidth, width: size.width, limit: bounds.width) {
                rowWidth = 0
                y += rowHeight + self.spacing
                rowHeight = 0
            }
            let x = rowWidth == 0 ? bounds.minX : bounds.minX + rowWidth + self.spacing
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            rowWidth = rowWidth == 0 ? size.width : rowWidth + self.spacing + size.width
            rowHeight = max(rowHeight, size.height)
        }
    }
}
