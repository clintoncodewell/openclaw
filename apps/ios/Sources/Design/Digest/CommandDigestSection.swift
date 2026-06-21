import SwiftUI

/// The prominent "what needs you" hero at the top of the Command Center feed: a friendly time-aware
/// greeting + an attention-count pill, then the ranked digest rows (each a deep-link into the relevant
/// screen), or a calm green "all clear" row when nothing needs the operator.
///
/// Lives in its own `CommandPanel(isProminent:true)` matching the gateway hero
/// (`CommandCenterTab.swift:188`). It is a plain `View` (not glued onto `CommandCenterTab`) so the
/// kind → zero-arg destination mapping stays in one place; it MUST be rendered inside the home
/// `NavigationStack` so each row's `NavigationLink` pushes correctly and the system back button works.
struct CommandDigestSection: View {
    /// The ranked load state. Read off the shared `CommandDigestViewModel` the tab owns.
    let state: DigestLoadState
    /// Whether the gateway is connected — gates the hero so it never shows stale rows while offline.
    let gatewayConnected: Bool

    var body: some View {
        // Hide entirely while offline / before the first load: the per-feature cards already carry the
        // "connect to the gateway" messaging, so a duplicated offline hero would be noise.
        if self.gatewayConnected, self.shouldShow {
            CommandPanel(isProminent: true, padding: 12) {
                VStack(alignment: .leading, spacing: 14) {
                    self.header
                    self.content
                }
            }
            .padding(.horizontal, OpenClawProMetric.pagePadding)
        }
    }

    /// Render only once we have a resolved state worth showing: ranked rows or the explicit all-clear calm
    /// state. `.idle` / `.loading` (first paint) and `.offline` / `.error` stay hidden so the hero appears
    /// fully-formed rather than as a spinner or an error block at the very top of the feed.
    private var shouldShow: Bool {
        switch self.state {
        case .loaded, .allClear: true
        case .idle, .loading, .offline, .error: false
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            ProIconBadge(systemName: "sparkles", color: OpenClawBrand.accentHot)
            VStack(alignment: .leading, spacing: 3) {
                Text(Self.greeting())
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(self.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if let count = self.attentionCount, count > 0 {
                // Count-pill pattern reused verbatim from the inbox / health / fleet cards
                // (`CommandCenterTab.swift:590`): bold caption2, white on a brand-colored capsule.
                Text("\(count)")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(OpenClawBrand.accentHot, in: Capsule())
                    .accessibilityLabel("\(count) items need attention")
            }
        }
    }

    private var subtitle: String {
        switch self.state {
        case .allClear:
            "Nothing needs you right now"
        case let .loaded(items):
            items.count == 1 ? "1 thing needs you" : "\(items.count) things need you"
        case .idle, .loading, .offline, .error:
            "What needs you"
        }
    }

    /// Total badge count across rows (each row's `count`, or 1 for a countless signal). nil when all-clear.
    private var attentionCount: Int? {
        guard case let .loaded(items) = self.state else { return nil }
        return items.reduce(0) { $0 + ($1.count ?? 1) }
    }

    /// Time-of-day greeting so the hero reads like a chief-of-staff brief, not a status table.
    private static func greeting() -> String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 5..<12: return "Good morning"
        case 12..<17: return "Good afternoon"
        case 17..<22: return "Good evening"
        default: return "Still up?"
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch self.state {
        case let .loaded(items):
            VStack(spacing: 8) {
                ForEach(items) { item in
                    DigestRowLink(item: item)
                }
            }
        case .allClear:
            CommandEmptyStateRow(
                icon: "checkmark.seal.fill",
                title: "All clear",
                detail: "Nothing needs you right now")
        case .idle, .loading, .offline, .error:
            // Never reached (`shouldShow` gates these out); kept exhaustive for the closed switch.
            EmptyView()
        }
    }
}

/// One tappable digest row that deep-links into the signal's screen. Split out so the kind → zero-arg
/// destination mapping lives in one `@ViewBuilder` switch and each `NavigationLink` carries the row as its
/// label — the established per-card pattern (`CommandCenterTab.swift:574`), so the system back button works
/// for free with no value-based router.
private struct DigestRowLink: View {
    let item: DigestItem

    var body: some View {
        NavigationLink {
            self.destination
        } label: {
            self.row
        }
        .buttonStyle(.plain)
    }

    /// Map the closed `DigestRoute` to its zero-arg destination screen. Each target owns its own `@State`
    /// view model (verified zero-arg inits), so a row pushes the bare screen with no focus payload.
    @ViewBuilder
    private var destination: some View {
        switch self.item.kind.route {
        case .inbox: AgentInboxScreen()
        case .briefs: BriefsInboxScreen()
        case .cost: CostInsightsScreen()
        case .auth: AuthHealthScreen()
        case .fleet: FleetScreen()
        case .health: OpsHealthScreen()
        }
    }

    private var row: some View {
        HStack(alignment: .center, spacing: 12) {
            ProIconBadge(systemName: self.item.kind.icon, color: self.item.severity.color)
            VStack(alignment: .leading, spacing: 3) {
                Text(self.item.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
                Text(self.item.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if let count = self.item.count, count > 0 {
                // Same count-pill pattern as the home cards, colored by the row's severity so a danger row
                // reads red and a warn row amber.
                Text("\(count)")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(self.item.severity.color, in: Capsule())
                    .accessibilityHidden(true)
            }
            Image(systemName: "chevron.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(.tertiary)
        }
    }
}
