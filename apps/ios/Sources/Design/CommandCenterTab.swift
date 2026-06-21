import OpenClawChatUI
import OpenClawProtocol
import SwiftUI

struct CommandCenterTab: View {
    static let recentSessionsFetchLimit = 200

    @Environment(NodeAppModel.self) private var appModel
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.scenePhase) private var scenePhase
    @State private var defaultChatSessionEntry: OpenClawChatSessionEntry?
    @State private var recentChatSessions: [OpenClawChatSessionEntry] = []
    /// Pending exec-approval count for the Inbox card badge. Fetched from the same
    /// `exec.approval.list` path the Agent Inbox uses and refreshed from the live approval events, so
    /// the badge stays in sync without standing up a second source of truth.
    @State private var inboxPendingCount: Int = 0
    /// Today's spend (USD) for the Cost card subtitle / budget badge, fetched from `usage.cost`
    /// `{"days":1}` — the same primary RPC the Cost dashboard uses — so the card and the screen agree
    /// without a second source of truth. `nil` until the first successful fetch / while offline.
    @State private var costTodayUSD: Double?
    /// 30-day spend (USD) for the Cost card's monthly-budget pill, fetched alongside today's spend so a
    /// monthly-only cap overage surfaces on the card even when no daily cap is set. `nil` until loaded.
    @State private var costMonthUSD: Double?
    /// Client-side budget caps, shared with the Cost dashboard. Drives the over/near-budget pill.
    @State private var budget = CostBudgetStore()
    /// Lightweight operational-health summary for the Health card subtitle / count pill and the inline
    /// at-a-glance strip, fetched from the same `sessions.usage` RED aggregates the Health screen reads so
    /// the card and the screen agree without a second source of truth. `nil` until loaded / while offline.
    @State private var healthSummary: CommandHealthSummary?
    /// Lightweight fleet roll-up for the Fleet card subtitle / offline-count pill, fetched from the same
    /// `node.list` inventory the Fleet dashboard reads so the card and the screen agree without a second
    /// source of truth. `nil` until loaded / while offline.
    @State private var fleetSummary: CommandFleetSummary?
    var headerTitle: String = "OpenClaw"
    var headerLeadingAction: OpenClawSidebarHeaderAction?
    var showsHeaderMark: Bool = true
    var openChat: () -> Void
    var openSettings: () -> Void

    enum WorkRoute {
        case chat(String?)
        case settings
    }

    struct WorkItem: Identifiable {
        let id: String
        let icon: String
        let title: String
        let detail: String
        let state: String
        let trailing: String
        let color: Color
        let progress: Double?
        let route: WorkRoute
    }

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                ZStack {
                    CommandControlBackground()
                    self.commandAmbientOverlay
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            self.header
                            self.gatewayCard
                            self.healthStrip
                            self.inboxCard
                            self.briefsCard
                            self.costCard
                            self.healthCard
                            self.fleetCard
                            self.routingCard
                            self.authHealthCard
                            self.tracesCard
                            if Self.usesSplitSectionsLayout(
                                horizontalSizeClass: self.horizontalSizeClass,
                                containerWidth: geometry.size.width)
                            {
                                HStack(alignment: .top, spacing: 12) {
                                    self.defaultChatSessionSection
                                        .frame(maxWidth: .infinity, alignment: .topLeading)
                                    self.recentSessions
                                        .frame(maxWidth: .infinity, alignment: .topLeading)
                                }
                                .padding(.horizontal, OpenClawProMetric.pagePadding)
                            } else {
                                self.defaultChatSessionSection
                                    .padding(.horizontal, OpenClawProMetric.pagePadding)
                                self.recentSessions
                                    .padding(.horizontal, OpenClawProMetric.pagePadding)
                            }
                        }
                        .padding(.top, 18)
                        .padding(.bottom, 18)
                    }
                    .safeAreaPadding(.bottom, OpenClawProMetric.bottomScrollInset)
                }
            }
            .navigationBarHidden(true)
        }
        // Share this one store with the pushed Cost dashboard so a budget edited in its sheet updates
        // this card's pill/subtitle live, instead of each surface owning an independent in-memory copy.
        .environment(\.costBudgetStore, self.budget)
        .task(id: self.recentSessionsRefreshID) {
            await self.refreshRecentSessionsIfNeeded()
        }
        .task(id: self.inboxBadgeRefreshID) {
            await self.refreshInboxPendingCount()
        }
        .task(id: self.inboxBadgeRefreshID) {
            await self.refreshCostToday()
        }
        .task(id: self.inboxBadgeRefreshID) {
            await self.refreshHealth()
        }
        .task(id: self.inboxBadgeRefreshID) {
            await self.refreshFleet()
        }
        .task {
            await self.observeInboxPendingCount()
        }
    }

    static func usesSplitSectionsLayout(
        horizontalSizeClass: UserInterfaceSizeClass?,
        containerWidth: CGFloat) -> Bool
    {
        guard horizontalSizeClass == .regular else { return false }
        return containerWidth >= 1000
    }

    static func shouldShowHeaderMark(
        hasLeadingAction: Bool,
        showsHeaderMark: Bool) -> Bool
    {
        !hasLeadingAction && showsHeaderMark
    }

    private var header: some View {
        OpenClawAdaptiveHeaderRow(
            title: self.headerTitle,
            subtitle: self.gatewaySubtitle,
            titleFont: .title3.weight(.semibold),
            subtitleFont: .caption,
            subtitleLineLimit: 1)
        {
            if let headerLeadingAction {
                OpenClawSidebarHeaderLeadingSlot(action: headerLeadingAction)
            } else if Self.shouldShowHeaderMark(
                hasLeadingAction: headerLeadingAction != nil,
                showsHeaderMark: self.showsHeaderMark)
            {
                OpenClawProMark(size: 28, shadowRadius: 5)
            }
        } accessory: {
            Button(action: self.openSettings) {
                ProCapsule(
                    title: self.gatewayStateText,
                    color: self.gatewayStatusColor,
                    icon: self.gatewayConnected ? "checkmark.circle.fill" : "wifi.slash")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Gateway \(self.gatewayStateText)")
            .accessibilityHint("Opens Settings / Gateway")
        }
        .padding(.horizontal, OpenClawProMetric.pagePadding)
    }

    private var commandAmbientOverlay: some View {
        Group {
            if self.colorScheme == .light {
                LinearGradient(
                    colors: [
                        Color.white.opacity(0.05),
                        Color.clear,
                    ],
                    startPoint: .top,
                    endPoint: .bottom)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }
        }
    }

    private var gatewayCard: some View {
        CommandPanel(isProminent: true, padding: 12) {
            VStack(alignment: .leading, spacing: 10) {
                self.cardHeader(
                    title: "Gateway",
                    value: self.gatewayStateText,
                    color: self.gatewayStatusColor,
                    icon: self.gatewayConnected ? "checkmark.circle.fill" : "wifi.slash")

                HStack(spacing: 0) {
                    self.gatewayFact(
                        icon: "network",
                        title: "Connection",
                        value: self.gatewayConnected ? "Online" : "Offline",
                        color: self.gatewayStatusColor)
                    Divider().frame(height: 38)
                    self.gatewayFact(
                        icon: "server.rack",
                        title: "Address",
                        value: self.gatewayAddressText,
                        color: OpenClawBrand.accent)
                    Divider().frame(height: 38)
                    self.gatewayFact(
                        icon: "person.2.fill",
                        title: "Agents",
                        value: self.gatewayAgentCountText,
                        color: OpenClawBrand.accentHot)
                }
                .padding(.vertical, 9)
                .background {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(self.colorScheme == .dark ? Color.black.opacity(0.16) : Color.black.opacity(0.026))
                        .overlay {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(
                                    Color.primary.opacity(self.colorScheme == .dark ? 0.08 : 0.045),
                                    lineWidth: 1)
                        }
                }
            }
        }
        .padding(.horizontal, OpenClawProMetric.pagePadding)
    }

    private var briefsCard: some View {
        NavigationLink {
            BriefsInboxScreen()
        } label: {
            CommandPanel(padding: 12) {
                HStack(alignment: .center, spacing: 12) {
                    ProIconBadge(systemName: "doc.text.magnifyingglass", color: OpenClawBrand.accent)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Briefs")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                        Text(self.gatewayConnected
                            ? "Scheduled reports from every job"
                            : "Connect to the gateway to view reports")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, OpenClawProMetric.pagePadding)
    }

    private var costCard: some View {
        NavigationLink {
            CostInsightsScreen()
        } label: {
            CommandPanel(padding: 12) {
                HStack(alignment: .center, spacing: 12) {
                    ProIconBadge(systemName: "chart.line.uptrend.xyaxis", color: OpenClawBrand.accent)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Cost")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                        Text(self.costSubtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    if let pill = self.costBudgetPill {
                        Text(pill.label)
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(pill.color, in: Capsule())
                            .accessibilityLabel("Budget \(pill.label)")
                    }
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, OpenClawProMetric.pagePadding)
    }

    private var costSubtitle: String {
        guard self.gatewayConnected else {
            return "Connect to the gateway to view spend"
        }
        guard let today = self.costTodayUSD else {
            return "Spend & usage analytics"
        }
        return "\(CostFormatting.currency(today)) today"
    }

    /// Over/near-budget pill for the Cost card, mirroring the inbox badge style. Shown when any budget is
    /// set, alerts are on, and the worst of the daily/monthly caps is at/over `0.8`. Uses `worstStatus`
    /// so a monthly-only cap overage surfaces even with no daily cap; an unloaded spend coerces to 0,
    /// which can only under-report (never falsely fire), and reconciles on the next refresh.
    private var costBudgetPill: (label: String, color: Color)? {
        guard self.gatewayConnected, self.budget.alertsEnabled, self.budget.anyBudgetSet else { return nil }
        let status = self.budget.worstStatus(
            todaySpend: self.costTodayUSD ?? 0,
            monthSpend: self.costMonthUSD ?? 0)
        guard status.isNearOrOver else { return nil }
        return (label: status.pillLabel, color: status.color)
    }

    /// Navigation card for the RED / operational-health overview, modeled exactly on `costCard`: a
    /// `CommandPanel` row pushing `OpsHealthScreen`, with a danger count pill (mirroring the inbox badge)
    /// when issues need attention. Subtitle reflects connection + the lightweight `healthSummary`.
    private var healthCard: some View {
        NavigationLink {
            OpsHealthScreen()
        } label: {
            CommandPanel(padding: 12) {
                HStack(alignment: .center, spacing: 12) {
                    ProIconBadge(systemName: "waveform.path.ecg", color: OpenClawBrand.accent)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Health")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                        Text(self.healthSubtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    if self.gatewayConnected, let count = self.healthSummary?.issueCount, count > 0 {
                        Text("\(count)")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(OpenClawBrand.danger, in: Capsule())
                            .accessibilityLabel("\(count) issues need attention")
                    }
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, OpenClawProMetric.pagePadding)
    }

    private var healthSubtitle: String {
        guard self.gatewayConnected else {
            return "Connect to the gateway to view health"
        }
        guard let summary = self.healthSummary else {
            return "Request, error & latency at a glance"
        }
        switch summary.issueCount {
        case 0:
            return "All systems healthy"
        case 1:
            return "1 issue needs attention"
        default:
            return "\(summary.issueCount) issues need attention"
        }
    }

    /// Navigation card for the Fleet dashboard, modeled exactly on `healthCard`: a `CommandPanel` row
    /// pushing `FleetScreen`, with a danger offline-count pill (mirroring the health issue pill) when paired
    /// nodes are disconnected. Subtitle reflects connection + the lightweight `fleetSummary`. This is a NEW
    /// peer card; the Agent Pro Instances sub-view (presence-only, no actions) stays as-is.
    private var fleetCard: some View {
        NavigationLink {
            FleetScreen()
        } label: {
            CommandPanel(padding: 12) {
                HStack(alignment: .center, spacing: 12) {
                    ProIconBadge(systemName: "externaldrive.connected.to.line.below", color: OpenClawBrand.accent)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Fleet")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                        Text(self.fleetSubtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    if self.gatewayConnected, let offline = self.fleetSummary?.offlineCount, offline > 0 {
                        Text("\(offline)")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(OpenClawBrand.danger, in: Capsule())
                            .accessibilityLabel("\(offline) nodes offline")
                    }
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, OpenClawProMetric.pagePadding)
    }

    private var fleetSubtitle: String {
        guard self.gatewayConnected else {
            return "Connect to the gateway to view fleet"
        }
        guard let summary = self.fleetSummary else {
            return "Nodes, agents & gateway at a glance"
        }
        let nodeWord = summary.nodeCount == 1 ? "node" : "nodes"
        return "\(summary.nodeCount) \(nodeWord), \(summary.onlineCount) online"
    }

    /// Navigation card for the Model Routing surface, modeled exactly on `healthCard` / `costCard`: a
    /// `CommandPanel` row pushing `RoutingScreen`. Read-only by default (the fallback chain has no typed
    /// setter; the optional primary-model write is admin-gated inside the screen).
    private var routingCard: some View {
        NavigationLink {
            RoutingScreen()
        } label: {
            CommandPanel(padding: 12) {
                HStack(alignment: .center, spacing: 12) {
                    ProIconBadge(systemName: "arrow.triangle.branch", color: OpenClawBrand.accent)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Model Routing")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                        Text(self.gatewayConnected
                            ? "Primary + fallback chain per agent"
                            : "Connect to the gateway to view routing")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, OpenClawProMetric.pagePadding)
    }

    /// Navigation card for the Provider Auth health surface, modeled on `healthCard`: a `CommandPanel`
    /// row pushing `AuthHealthScreen` — the rich per-profile OAuth/expiry endpoint that would catch a
    /// provider auth outage early. Read + one admin destructive action (clear dead credential).
    private var authHealthCard: some View {
        NavigationLink {
            AuthHealthScreen()
        } label: {
            CommandPanel(padding: 12) {
                HStack(alignment: .center, spacing: 12) {
                    ProIconBadge(systemName: "key.fill", color: OpenClawBrand.accent)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Provider Auth")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                        Text(self.gatewayConnected
                            ? "OAuth & credential health per provider"
                            : "Connect to the gateway to view auth")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, OpenClawProMetric.pagePadding)
    }

    /// Thin always-visible RED strip under the gateway card: error-rate + p95 latency at a glance, so the
    /// home screen surfaces the two signals an operator checks most without opening the overview. Hidden
    /// until connected + loaded, so it never shows misleading zeros.
    @ViewBuilder
    private var healthStrip: some View {
        if self.gatewayConnected, let summary = self.healthSummary, summary.hasSignal {
            CommandPanel(padding: 10) {
                HStack(spacing: 0) {
                    self.healthStripCell(
                        icon: "exclamationmark.triangle.fill",
                        title: "Error rate",
                        value: OpsFormatting.percent(summary.errorRatePct),
                        color: summary.errorColor)
                    Divider().frame(height: 26)
                    self.healthStripCell(
                        icon: "timer",
                        title: "p95 latency",
                        value: summary.p95Label,
                        color: OpenClawBrand.accentHot)
                    Divider().frame(height: 26)
                    self.healthStripCell(
                        icon: "checkmark.seal.fill",
                        title: "Attention",
                        value: summary.issueCount == 0 ? "Clear" : "\(summary.issueCount)",
                        color: summary.issueCount == 0 ? OpenClawBrand.ok : OpenClawBrand.danger)
                }
            }
            .padding(.horizontal, OpenClawProMetric.pagePadding)
        }
    }

    private func healthStripCell(icon: String, title: String, value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(color)
                Text(title)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Text(value)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
    }

    private var tracesCard: some View {
        NavigationLink {
            TraceListScreen()
        } label: {
            CommandPanel(padding: 12) {
                HStack(alignment: .center, spacing: 12) {
                    ProIconBadge(
                        systemName: "point.3.connected.trianglepath.dotted",
                        color: OpenClawBrand.accent)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Runs")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                        Text(self.gatewayConnected
                            ? "Inspect recent runs & tool calls"
                            : "Connect to the gateway to inspect runs")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, OpenClawProMetric.pagePadding)
    }

    private var inboxCard: some View {
        NavigationLink {
            AgentInboxScreen()
        } label: {
            CommandPanel(padding: 12) {
                HStack(alignment: .center, spacing: 12) {
                    ProIconBadge(systemName: "tray.full.fill", color: OpenClawBrand.accentHot)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Inbox")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                        Text(self.inboxSubtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    if self.gatewayConnected, self.inboxPendingCount > 0 {
                        Text("\(self.inboxPendingCount)")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(OpenClawBrand.accentHot, in: Capsule())
                            .accessibilityLabel("\(self.inboxPendingCount) pending approvals")
                    }
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, OpenClawProMetric.pagePadding)
    }

    private var inboxSubtitle: String {
        guard self.gatewayConnected else {
            return "Connect to the gateway to review approvals"
        }
        switch self.inboxPendingCount {
        case 0:
            return "Inbox zero — nothing waiting"
        case 1:
            return "1 decision needs you"
        default:
            return "\(self.inboxPendingCount) decisions need you"
        }
    }

    private func gatewayFact(icon: String, title: String, value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(color)
                Text(title)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Text(value)
                .font(.caption.weight(.semibold))
                .foregroundStyle(title == "Connection" ? color : .primary)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
    }

    private var defaultChatSessionSection: some View {
        CommandPanel(padding: 12) {
            VStack(spacing: 10) {
                self.cardHeader(
                    title: "Agent session",
                    value: nil,
                    color: OpenClawBrand.accent)

                Button {
                    self.open(.chat(nil))
                } label: {
                    CommandSessionRow(item: self.defaultChatWorkItem)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var recentSessions: some View {
        CommandPanel(padding: 12) {
            VStack(spacing: 10) {
                self.cardHeader(
                    title: "Recent sessions",
                    value: nil,
                    color: .secondary)

                if self.recentSessionPreviewRows.isEmpty {
                    CommandEmptyStateRow(
                        icon: self.gatewayConnected ? "bubble.left.and.text.bubble.right.fill" : "wifi.slash",
                        title: self.gatewayConnected ? "No recent sessions" : "Gateway offline",
                        detail: self
                            .gatewayConnected ? "Start a chat and it will appear here." : "Connect to the gateway.")
                } else {
                    VStack(spacing: 8) {
                        ForEach(self.recentSessionPreviewRows) { item in
                            Button {
                                self.open(item.route)
                            } label: {
                                CommandSessionRow(item: item)
                            }
                            .buttonStyle(.plain)
                        }

                        if self.hasMoreRecentSessions {
                            NavigationLink {
                                CommandSessionsScreen(openChat: self.openChat)
                            } label: {
                                CommandViewMoreRow()
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    private func cardHeader(
        title: String,
        value: String?,
        color: Color,
        icon: String? = nil,
        badgeValue: String? = nil,
        action: (() -> Void)? = nil) -> some View
    {
        HStack(spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            if let badgeValue {
                Text(badgeValue)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(OpenClawBrand.accentHot, in: Capsule())
            }
            Spacer(minLength: 8)
            if let value {
                if let action {
                    Button(value, action: action)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(color)
                } else {
                    HStack(spacing: 4) {
                        if let icon {
                            Image(systemName: icon)
                                .font(.caption2.weight(.bold))
                        }
                        Text(value)
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(color)
                }
            }
        }
    }

    private var gatewayConnected: Bool {
        GatewayStatusBuilder.build(appModel: self.appModel) == .connected
    }

    private var gatewayStateText: String {
        guard !self.gatewayConnected else { return "Healthy" }
        let status = self.appModel.gatewayDisplayStatusText.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercased = status.lowercased()
        if lowercased.contains("approval") { return "Approval" }
        if lowercased.contains("reconnect") { return "Reconnecting" }
        if lowercased.contains("connect") { return "Connecting" }
        if lowercased.contains("idle") { return "Idle" }
        return "Offline"
    }

    private var gatewayStatusColor: Color {
        self.gatewayConnected ? OpenClawBrand.ok : .secondary
    }

    private var gatewayAddressText: String {
        self.normalized(self.appModel.gatewayRemoteAddress)
            ?? self.normalized(self.appModel.gatewayServerName)
            ?? "Unknown"
    }

    private var gatewayAgentCountText: String {
        guard self.gatewayConnected else { return "—" }
        return "\(self.appModel.gatewayAgents.count)"
    }

    private var defaultChatWorkItem: WorkItem {
        let isOpen = self.appModel.chatSessionKey == self.appModel.defaultChatSessionKey
        return WorkItem(
            id: "default-chat",
            icon: isOpen ? "bubble.left.and.text.bubble.right.fill" : "bubble.left.fill",
            title: self.appModel.activeAgentName,
            detail: self.defaultChatActivityText,
            state: isOpen ? "open" : "default",
            trailing: "chat",
            color: isOpen ? OpenClawBrand.accent : OpenClawBrand.ok,
            progress: nil,
            route: .chat(nil))
    }

    private var defaultChatActivityText: String {
        guard let updatedAt = defaultChatSessionEntry?.updatedAt, updatedAt > 0 else {
            return "No recent activity"
        }
        return Self.relativeTimeText(forMilliseconds: updatedAt)
    }

    private var recentSessionRows: [WorkItem] {
        self.sessionItems
    }

    private var recentSessionPreviewRows: [WorkItem] {
        Array(self.recentSessionRows.prefix(3))
    }

    private var hasMoreRecentSessions: Bool {
        self.sessionWorkItems.count > self.recentSessionPreviewRows.count
    }

    private var recentSessionsRefreshID: String {
        [
            self.sessionListMode,
            self.appModel.chatSessionKey,
            self.scenePhase == .active ? "active" : "inactive",
        ].joined(separator: ":")
    }

    private var sessionListAvailable: Bool {
        self.appModel.isLocalChatFixtureEnabled || self.appModel.isOperatorGatewayConnected
    }

    /// Re-fetch the inbox badge whenever the app foregrounds or the gateway connection flips, mirroring
    /// the recent-sessions refresh trigger so the badge is correct on first paint and after reconnect.
    private var inboxBadgeRefreshID: String {
        [
            self.gatewayConnected ? "connected" : "offline",
            self.scenePhase == .active ? "active" : "inactive",
        ].joined(separator: ":")
    }

    private var sessionListMode: String {
        self.appModel.chatTransportModeID
    }

    private var sessionItems: [WorkItem] {
        self.sessionWorkItems
    }

    private var sessionWorkItems: [WorkItem] {
        let currentSessionKey = self.appModel.chatSessionKey
        return self.recentChatSessions
            .filter { Self.isRecentChatSession($0.key, defaultSessionKey: self.appModel.defaultChatSessionKey) }
            .map { session in
                Self.sessionWorkItem(for: session, currentSessionKey: currentSessionKey)
            }
    }

    private func open(_ route: WorkRoute) {
        switch route {
        case let .chat(sessionKey):
            self.appModel.openChat(sessionKey: sessionKey)
            self.openChat()
        case .settings:
            self.openSettings()
        }
    }

    private func refreshRecentSessionsIfNeeded() async {
        guard self.scenePhase == .active else { return }
        guard self.sessionListAvailable else {
            if self.defaultChatSessionEntry != nil {
                self.defaultChatSessionEntry = nil
            }
            if !self.recentChatSessions.isEmpty {
                self.recentChatSessions = []
            }
            return
        }

        do {
            let transport = self.appModel.makeChatTransport()
            let response = try await transport.listSessions(limit: Self.recentSessionsFetchLimit)
            self.defaultChatSessionEntry = response.sessions.first {
                $0.key == self.appModel.defaultChatSessionKey
            }
            self.recentChatSessions = Self.sessionChoices(
                response.sessions,
                currentSessionKey: self.appModel.chatSessionKey,
                defaultSessionKey: self.appModel.defaultChatSessionKey)
        } catch {
            self.defaultChatSessionEntry = nil
            self.recentChatSessions = []
        }
    }

    /// Fetch the pending-approval count for the Inbox badge via the same `exec.approval.list` path the
    /// Agent Inbox uses (bare array, no params), keeping a single fetch contract. Zeroed when offline.
    private func refreshInboxPendingCount() async {
        guard self.scenePhase == .active, self.gatewayConnected else {
            if self.inboxPendingCount != 0 { self.inboxPendingCount = 0 }
            return
        }
        do {
            let data = try await self.appModel.operatorSession.request(
                method: "exec.approval.list",
                paramsJSON: "{}",
                timeoutSeconds: 12)
            self.inboxPendingCount = InboxApproval.decodeList(from: data).count
        } catch {
            // Leave the last known count on a transient failure; the next foreground / event refresh
            // reconciles it.
        }
    }

    /// Fetch today's spend for the Cost card subtitle / budget badge via
    /// `usage.cost {"days":1,"agentScope":"all","mode":"gateway"}` — byte-for-byte the same params the
    /// Cost dashboard uses for its "today" slice — so the card and the screen agree on the number.
    /// `mode: gateway` scopes the single-day window to the gateway host's local day (the same basis the
    /// daily rollup keys use), and `agentScope: all` matches the dashboard's all-agents total; without
    /// both, the card could show a non-zero "today" while the dashboard read 0 from a UTC-keyed slice.
    /// Cleared when offline; the last known value is kept on a transient failure.
    private func refreshCostToday() async {
        guard self.scenePhase == .active, self.gatewayConnected else {
            if self.costTodayUSD != nil { self.costTodayUSD = nil }
            if self.costMonthUSD != nil { self.costMonthUSD = nil }
            return
        }
        // Two gateway-scoped window sums: today (daily-cap pill + subtitle) and 30d (monthly-cap pill),
        // both `mode: gateway` / `agentScope: all` to match the dashboard. Each updates independently so
        // one failing leaves the other's last-known value intact.
        async let todayThrowing = self.appModel.operatorSession.request(
            method: "usage.cost",
            paramsJSON: "{\"days\":1,\"agentScope\":\"all\",\"mode\":\"gateway\"}",
            timeoutSeconds: 12)
        async let monthThrowing = self.appModel.operatorSession.request(
            method: "usage.cost",
            paramsJSON: "{\"range\":\"30d\",\"agentScope\":\"all\",\"mode\":\"gateway\"}",
            timeoutSeconds: 12)
        let todayData = try? await todayThrowing
        let monthData = try? await monthThrowing
        if let data = todayData,
           let summary = try? JSONDecoder().decode(CostUsageSummaryLite.self, from: data) {
            self.costTodayUSD = summary.totalCost ?? 0
        }
        if let data = monthData,
           let summary = try? JSONDecoder().decode(CostUsageSummaryLite.self, from: data) {
            self.costMonthUSD = summary.totalCost ?? 0
        }
    }

    /// Fetch the lightweight RED summary for the Health card subtitle / count pill and the inline strip.
    /// Two concurrent reads mirror the Health screen's own sources: `sessions.usage` for the error-rate +
    /// p95 latency at-a-glance, and `cron.runs` (error statuses only) for the cron-failure count that
    /// dominates the attention rollup. Provider / node issues live behind the full screen; the card's
    /// count is the cheap, always-correct-direction cron count (it can only under-report, reconciling on
    /// open). Cleared when offline; the last known value is kept on a transient failure.
    private func refreshHealth() async {
        guard self.scenePhase == .active, self.gatewayConnected else {
            if self.healthSummary != nil { self.healthSummary = nil }
            return
        }
        async let usageThrowing = self.appModel.operatorSession.request(
            method: "sessions.usage",
            paramsJSON: "{\"range\":\"30d\",\"agentScope\":\"all\",\"mode\":\"gateway\",\"limit\":200}",
            timeoutSeconds: 12)
        // No server-side `statuses` filter: the gateway schema only accepts `ok`/`error`/`skipped`
        // (`cron.ts:100-104`, `additionalProperties:false`), so any extra literal makes the whole
        // `cron.runs` call fail validation and return nothing. Fetch all runs; `distinctFailingJobCount`
        // narrows to `statusKind == .error` client-side.
        async let cronThrowing = self.appModel.operatorSession.request(
            method: "cron.runs",
            paramsJSON: "{\"scope\":\"all\",\"sortDir\":\"desc\",\"limit\":50}",
            timeoutSeconds: 12)
        let usageData = try? await usageThrowing
        let cronData = try? await cronThrowing
        guard let usageData, let usage = OpsUsageResultLite.decode(from: usageData) else { return }
        let summary = CommandHealthSummary(usage: usage, cronFailures: cronData)
        self.healthSummary = summary
    }

    /// Lightweight Fleet card summary, fetched from the same `node.list` inventory the Fleet dashboard
    /// reads (scope `operator.read`, always held). Stores total / online / offline node counts for the card
    /// subtitle + the offline pill. Cleared when offline; the last known value is kept on a transient
    /// failure so the card doesn't flicker mid-refresh.
    private func refreshFleet() async {
        guard self.scenePhase == .active, self.gatewayConnected else {
            if self.fleetSummary != nil { self.fleetSummary = nil }
            return
        }
        let nodeData = try? await self.appModel.operatorSession.request(
            method: "node.list",
            paramsJSON: "{}",
            timeoutSeconds: 12)
        guard let nodeData else { return }
        let nodes = FleetNode.decodeList(from: nodeData)
        self.fleetSummary = CommandFleetSummary(nodes: nodes)
    }

    /// Keep the badge live while foregrounded: the gateway broadcasts `exec.approval.requested` /
    /// `exec.approval.resolved` to approvals-scoped clients, so a request raised or resolved anywhere
    /// (this app, the watch, a notification action) bumps the badge without polling.
    private func observeInboxPendingCount() async {
        let stream = await self.appModel.operatorSession.subscribeServerEvents(bufferingNewest: 200)
        for await event in stream {
            if Task.isCancelled { return }
            switch event.event {
            case "exec.approval.requested", "exec.approval.resolved":
                await self.refreshInboxPendingCount()
            default:
                continue
            }
        }
    }

    private static func sessionChoices(
        _ sessions: [OpenClawChatSessionEntry],
        currentSessionKey: String,
        defaultSessionKey: String) -> [OpenClawChatSessionEntry]
    {
        let sorted = sessions.sorted { ($0.updatedAt ?? 0) > ($1.updatedAt ?? 0) }
        var result: [OpenClawChatSessionEntry] = []
        var included = Set<String>()

        if Self.isRecentChatSession(currentSessionKey, defaultSessionKey: defaultSessionKey),
           let current = sorted.first(where: { $0.key == currentSessionKey })
        {
            result.append(current)
            included.insert(current.key)
        }

        for session in sorted {
            guard !included.contains(session.key) else { continue }
            guard Self.isRecentChatSession(session.key, defaultSessionKey: defaultSessionKey) else { continue }
            result.append(session)
            included.insert(session.key)
            if result.count >= 4 { break }
        }

        return result
    }

    static func sessionWorkItem(
        for session: OpenClawChatSessionEntry,
        currentSessionKey: String) -> WorkItem
    {
        let isCurrent = session.key == currentSessionKey
        return WorkItem(
            id: "chat-session-\(session.key)",
            icon: isCurrent ? "bubble.left.and.text.bubble.right.fill" : "bubble.left.fill",
            title: Self.sessionTitle(session),
            detail: Self.sessionDetail(session),
            state: isCurrent ? "open" : "recent",
            trailing: "chat",
            color: isCurrent ? OpenClawBrand.accent : OpenClawBrand.ok,
            progress: nil,
            route: .chat(session.key))
    }

    fileprivate static func sessionTitle(_ session: OpenClawChatSessionEntry) -> String {
        if let title = redactedSessionTitle(for: session.key) {
            return title
        }

        let displayName = session.displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let displayName, !displayName.isEmpty {
            return Self.redactedSessionTitle(for: displayName) ?? displayName
        }
        let subject = session.subject?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let subject, !subject.isEmpty {
            return Self.redactedSessionTitle(for: subject) ?? subject
        }
        return session.key
    }

    fileprivate static func redactedSessionTitle(for key: String) -> String? {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercased = trimmed.lowercased()
        guard !trimmed.isEmpty else { return nil }
        if lowercased.contains(":ios-") {
            return "iOS chat"
        }
        if lowercased.hasPrefix("telegram:") {
            return "Telegram chat"
        }
        if lowercased.hasPrefix("user:+") {
            return "Direct chat"
        }
        if lowercased.hasPrefix("cron:") {
            return Self.humanizedSessionKey(String(trimmed.dropFirst("cron:".count)))
        }
        return nil
    }

    fileprivate static func humanizedSessionKey(_ key: String) -> String? {
        let words = key
            .replacingOccurrences(of: "_", with: "-")
            .split(separator: "-")
            .map(String.init)
            .filter { !$0.isEmpty }
        guard !words.isEmpty else { return nil }

        return words
            .map { word in
                switch word.lowercased() {
                case "ai", "api", "ios", "qmd", "url":
                    word.uppercased()
                default:
                    word.prefix(1).uppercased() + String(word.dropFirst())
                }
            }
            .joined(separator: " ")
    }

    fileprivate static func sessionDetail(_ session: OpenClawChatSessionEntry) -> String {
        if let updatedAt = session.updatedAt, updatedAt > 0 {
            return self.relativeTimeText(forMilliseconds: updatedAt)
        }
        return session.key
    }

    fileprivate static func relativeTimeText(forMilliseconds milliseconds: Double) -> String {
        let date = Date(timeIntervalSince1970: milliseconds / 1000)
        let formatter = RelativeDateTimeFormatter()
        formatter.dateTimeStyle = .numeric
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: .now)
    }

    fileprivate nonisolated static func isHiddenInternalSession(_ key: String) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return trimmed == "onboarding" || trimmed.hasSuffix(":onboarding")
    }

    nonisolated static func isRecentChatSession(_ key: String, defaultSessionKey: String) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if trimmed == defaultSessionKey { return false }
        let normalized = trimmed.lowercased()
        let defaultBase = self.sessionBaseKey(defaultSessionKey)
        if !normalized.contains(":"),
           self.isDirectSessionBase(normalized, defaultBase: defaultBase)
        {
            return false
        }
        if self.isHiddenInternalSession(trimmed) { return false }
        return !self.isAgentDeviceSession(trimmed, defaultSessionKey: defaultSessionKey)
    }

    private nonisolated static func isAgentDeviceSession(_ key: String, defaultSessionKey: String) -> Bool {
        let parts = key
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count >= 3, parts[0].lowercased() == "agent" else { return false }
        guard parts.count == 3 || parts[3].lowercased() == "thread" else { return false }

        let base = String(parts[2]).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let defaultKey = self.sessionBaseKey(defaultSessionKey)
        return self.isDirectSessionBase(base, defaultBase: defaultKey)
    }

    private nonisolated static func isDirectSessionBase(_ base: String, defaultBase: String) -> Bool {
        base == defaultBase || base == "main" || base == "global" || base.hasPrefix("node-")
    }

    private nonisolated static func sessionBaseKey(_ key: String) -> String {
        let parts = key
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count >= 3, parts[0].lowercased() == "agent" else {
            return key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        return String(parts[2]).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private var gatewaySubtitle: String {
        if let server = normalized(appModel.gatewayServerName) {
            return "\(self.appModel.activeAgentName) on \(server)"
        }
        if let address = normalized(appModel.gatewayRemoteAddress) {
            return "\(self.appModel.activeAgentName) via \(address)"
        }
        return self.appModel.gatewayDisplayStatusText
    }

    private func normalized(_ value: String?) -> String? {
        Self.normalized(value)
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

struct CommandSessionsScreen: View {
    @Environment(NodeAppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss
    @State private var sessions: [OpenClawChatSessionEntry] = []
    @State private var isLoading = false
    @State private var loadErrorText: String?
    let headerLeadingAction: OpenClawSidebarHeaderAction?
    let openChat: () -> Void

    init(headerLeadingAction: OpenClawSidebarHeaderAction? = nil, openChat: @escaping () -> Void) {
        self.headerLeadingAction = headerLeadingAction
        self.openChat = openChat
    }

    var body: some View {
        ZStack {
            CommandControlBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    self.header
                    self.sessionsPanel
                }
                .padding(.top, 16)
                .padding(.bottom, 18)
            }
            .safeAreaPadding(.bottom, OpenClawProMetric.bottomScrollInset)
        }
        .navigationTitle("Sessions")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: self.refreshID) {
            await self.refreshSessions()
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            if let headerLeadingAction {
                OpenClawSidebarHeaderLeadingSlot(action: headerLeadingAction)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Sessions")
                    .font(.system(size: 27, weight: .bold, design: .rounded))
                Text(self.headerDetail)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, OpenClawProMetric.pagePadding)
    }

    private var sessionsPanel: some View {
        CommandPanel(padding: 0) {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Text("Recent sessions")
                        .font(.subheadline.weight(.bold))
                    Spacer(minLength: 8)
                    if self.isLoading {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 3)

                if let loadErrorText {
                    CommandEmptyStateRow(
                        icon: "exclamationmark.triangle.fill",
                        title: "Sessions unavailable",
                        detail: loadErrorText)
                        .padding(.horizontal, 10)
                        .padding(.bottom, 10)
                } else if self.sessionRows.isEmpty {
                    CommandEmptyStateRow(
                        icon: self.appModel
                            .isCommandSessionListAvailable ? "bubble.left.and.text.bubble.right.fill" : "wifi.slash",
                        title: self.appModel.isCommandSessionListAvailable ? "No recent sessions" : "Gateway offline",
                        detail: self.appModel
                            .isCommandSessionListAvailable ? "Start a chat and it will appear here." :
                            "Connect to the gateway.")
                        .padding(.horizontal, 10)
                        .padding(.bottom, 10)
                } else {
                    VStack(spacing: 8) {
                        ForEach(self.sessionRows) { item in
                            Button {
                                self.open(item)
                            } label: {
                                CommandSessionRow(item: item)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
                }
            }
        }
        .padding(.horizontal, OpenClawProMetric.pagePadding)
    }

    private var headerDetail: String {
        if self.isLoading, self.sessions.isEmpty { return "Loading recent sessions" }
        let count = self.sessionRows.count
        if count == 0 {
            return self.appModel.isCommandSessionListAvailable ? "No recent sessions" : "Gateway offline"
        }
        return "\(count) \(count == 1 ? "session" : "sessions")"
    }

    private var sessionRows: [CommandCenterTab.WorkItem] {
        self.sessions
            .filter { CommandCenterTab.isRecentChatSession(
                $0.key,
                defaultSessionKey: self.appModel.defaultChatSessionKey) }
            .sorted { ($0.updatedAt ?? 0) > ($1.updatedAt ?? 0) }
            .map {
                CommandCenterTab.sessionWorkItem(
                    for: $0,
                    currentSessionKey: self.appModel.chatSessionKey)
            }
    }

    private var refreshID: String {
        self.appModel.commandSessionListMode
    }

    private func open(_ item: CommandCenterTab.WorkItem) {
        switch item.route {
        case let .chat(sessionKey):
            self.appModel.openChat(sessionKey: sessionKey)
            self.dismiss()
            self.openChat()
        case .settings:
            break
        }
    }

    private func refreshSessions() async {
        guard self.appModel.isCommandSessionListAvailable else {
            self.sessions = []
            self.loadErrorText = nil
            return
        }

        self.isLoading = true
        self.loadErrorText = nil
        defer { self.isLoading = false }

        do {
            let transport = self.appModel.makeChatTransport()
            let response = try await transport.listSessions(limit: CommandCenterTab.recentSessionsFetchLimit)
            self.sessions = response.sessions
        } catch {
            self.sessions = []
            self.loadErrorText = "Try again after the gateway reconnects."
        }
    }
}

extension NodeAppModel {
    fileprivate var isCommandSessionListAvailable: Bool {
        self.isLocalChatFixtureEnabled || self.isOperatorGatewayConnected
    }

    fileprivate var commandSessionListMode: String {
        self.chatTransportModeID
    }
}

/// The cheap RED snapshot the Command Center home shows on the Health card + inline strip: window-wide
/// error rate, window p95 turn latency (ms), and an attention count. Derived from the same
/// `sessions.usage` aggregates the full Health screen reads, so the card and the screen agree. The count
/// is just the cron-failure count (the dominant, always-available attention signal); the full screen adds
/// provider / node / gateway issues, so the card can only under-report and reconciles on open.
struct CommandHealthSummary {
    let errorRatePct: Double
    let p95Ms: Double
    let hasLatency: Bool
    let issueCount: Int

    init(usage: OpsUsageResultLite, cronFailures: Data?) {
        // Error rate uses total messages (user+assistant) as the denominator and clamps at 100%, matching
        // the Health screen's tile. `messages.errors` counts tool-result errors plus assistant error
        // stop-reasons (`session-cost-usage.ts:676-683`), so dividing by `assistant` alone could exceed
        // 100%; `total` keeps the card and screen numerically aligned.
        let messages = usage.aggregates?.messages
        let errors = messages?.errors ?? 0
        let total = messages?.total ?? 0
        self.errorRatePct = total > 0 ? min(Double(errors) / Double(total) * 100, 100) : 0

        let latency = usage.aggregates?.latency
        self.p95Ms = latency?.p95Ms ?? 0
        self.hasLatency = (latency?.count ?? 0) > 0

        self.issueCount = Self.distinctFailingJobCount(cronFailures)
    }

    /// True when there's any RED signal to show (an error rate, a latency sample, or an open issue), so
    /// the strip hides on a brand-new account rather than showing 0% / — / Clear.
    var hasSignal: Bool {
        self.errorRatePct > 0 || self.hasLatency || self.issueCount > 0
    }

    var errorColor: Color {
        if self.errorRatePct >= OpsHealthThresholds.errorRateDanger { return OpenClawBrand.danger }
        if self.errorRatePct >= OpsHealthThresholds.errorRateWarn { return OpenClawBrand.warn }
        return OpenClawBrand.ok
    }

    var p95Label: String {
        self.hasLatency ? OpsFormatting.latency(self.p95Ms) : "—"
    }

    /// Distinct failing jobs in the `cron.runs` error page, deduped on jobId so a job that failed
    /// repeatedly counts once — matching the Health screen's per-job attention rows.
    private static func distinctFailingJobCount(_ data: Data?) -> Int {
        guard let data else { return 0 }
        struct Envelope: Decodable {
            let entries: [AnyCodable]?
        }
        let decoder = JSONDecoder()
        guard let envelope = try? decoder.decode(Envelope.self, from: data),
              let rawEntries = envelope.entries
        else {
            return 0
        }
        var seenJobs = Set<String>()
        for raw in rawEntries {
            guard let entryData = try? JSONEncoder().encode(raw),
                  let entry = try? decoder.decode(CronRunLogEntry.self, from: entryData),
                  let run = BriefRun(entry: entry),
                  run.statusKind == .error
            else {
                continue
            }
            seenJobs.insert(run.jobId)
        }
        return seenJobs.count
    }
}

/// The cheap node roll-up the Command Center home shows on the Fleet card: total known nodes, the live
/// (online) count for the subtitle, and the offline (paired-but-disconnected) count for the danger pill.
/// Derived from the same `node.list` inventory the full Fleet dashboard reads, so the card and the screen
/// agree without a second source of truth.
struct CommandFleetSummary {
    let nodeCount: Int
    let onlineCount: Int
    let offlineCount: Int

    init(nodes: [FleetNode]) {
        self.nodeCount = nodes.count
        self.onlineCount = nodes.count { $0.status == .online }
        self.offlineCount = nodes.count { $0.status == .offline }
    }
}
