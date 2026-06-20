import SwiftUI

/// Client-side spend-budget configuration for the Cost dashboard.
///
/// Budgets are intentionally **client-side only**. An exhaustive grep over `src/gateway`, `src/config`,
/// and `packages/gateway-protocol` for budget/spendLimit/costLimit/quota/dailyLimit/monthlyLimit found
/// no configurable cost cap: the only "budget" mechanisms are connection-count rate limiting
/// (`preauth-connection-budget.ts`), control-plane RPC rate limiting (`control-plane-rate-limit.ts`),
/// and per-session token-context-window management (`contextBudgetStatus`) — none is a spend cap.
/// `usage.status` returns the upstream provider plan's `usedPercent`, but that is read-only and is the
/// provider's own quota, not a cap the user sets. So the caps live in `UserDefaults`; only the spend
/// *numbers* compared against them come from `usage.cost` / `sessions.usage`. No gateway round-trip.
///
/// Wrapped in a `@MainActor @Observable` store (rather than scattering `@AppStorage` across views) so
/// the dashboard, the Command Center card, and the edit sheet all read one source of truth and the
/// derived under/near/over status is computed in exactly one place.
@MainActor
@Observable
final class CostBudgetStore {
    static let dailyKey = "cost.budget.dailyUSD"
    static let monthlyKey = "cost.budget.monthlyUSD"
    static let alertsKey = "cost.budget.alertsEnabled"

    /// Daily USD cap. `0` means "off" (no daily budget set). Tracked stored property persisted to
    /// `UserDefaults` on write and hydrated in `init`, matching `NodeAppModel`'s persistence pattern
    /// (the app's `@Observable` models persist scalars via `UserDefaults`, not `@AppStorage`, so
    /// `@Bindable` projections stay unambiguous).
    var dailyUSD: Double {
        didSet { UserDefaults.standard.set(max(0, self.dailyUSD), forKey: Self.dailyKey) }
    }

    /// Monthly (rolling 30-day) USD cap. `0` means "off".
    var monthlyUSD: Double {
        didSet { UserDefaults.standard.set(max(0, self.monthlyUSD), forKey: Self.monthlyKey) }
    }

    /// Whether over-budget banners / Command Center status pills are surfaced. On by default so a set
    /// budget is actionable without a second opt-in; the user can mute alerts while keeping the caps.
    var alertsEnabled: Bool {
        didSet { UserDefaults.standard.set(self.alertsEnabled, forKey: Self.alertsKey) }
    }

    init() {
        let defaults = UserDefaults.standard
        self.dailyUSD = defaults.double(forKey: Self.dailyKey)
        self.monthlyUSD = defaults.double(forKey: Self.monthlyKey)
        // Default alerts on when the key has never been written (the common first-launch case).
        self.alertsEnabled = defaults.object(forKey: Self.alertsKey) as? Bool ?? true
    }

    var dailyEnabled: Bool { self.dailyUSD > 0 }
    var monthlyEnabled: Bool { self.monthlyUSD > 0 }
    var anyBudgetSet: Bool { self.dailyEnabled || self.monthlyEnabled }

    /// Under/near/over status of a spend value against the daily cap.
    func dailyStatus(spend: Double) -> BudgetStatus {
        Self.status(spend: spend, cap: self.dailyUSD)
    }

    /// Under/near/over status of a spend value against the monthly cap.
    func monthlyStatus(spend: Double) -> BudgetStatus {
        Self.status(spend: spend, cap: self.monthlyUSD)
    }

    /// The single worst status across both caps, used for the Command Center pill and screen banner so
    /// the surface always reflects the most urgent of the two.
    func worstStatus(todaySpend: Double, monthSpend: Double) -> BudgetStatus {
        let daily = self.dailyStatus(spend: todaySpend)
        let monthly = self.monthlyStatus(spend: monthSpend)
        return daily.severity >= monthly.severity ? daily : monthly
    }

    /// Compare spend against a cap. `cap <= 0` is "off"; `>= 1.0` of the cap is over, `>= 0.8` is near.
    private static func status(spend: Double, cap: Double) -> BudgetStatus {
        guard cap > 0 else { return .off }
        let fraction = spend / cap
        if fraction >= 1.0 {
            return .over(fraction: fraction, overBy: spend - cap)
        }
        if fraction >= 0.8 {
            return .near(fraction: fraction)
        }
        return .under(fraction: max(0, fraction))
    }
}

/// Closed budget status so the UI never juggles parallel "isOver" / "isNear" booleans. The associated
/// `fraction` (spend ÷ cap) drives the progress bar; `overBy` is the dollar overspend for the banner.
enum BudgetStatus: Equatable {
    case off
    case under(fraction: Double)
    case near(fraction: Double)
    case over(fraction: Double, overBy: Double)

    /// Severity rank for picking the worst of two caps. Higher == more urgent.
    var severity: Int {
        switch self {
        case .off: 0
        case .under: 1
        case .near: 2
        case .over: 3
        }
    }

    /// Fraction of cap consumed, clamped to `[0, 1]` for the progress bar fill.
    var barFraction: Double {
        switch self {
        case .off: 0
        case let .under(fraction): max(0, min(fraction, 1))
        case let .near(fraction): max(0, min(fraction, 1))
        case .over: 1
        }
    }

    /// Brand color: under == ok (green), near == warn (amber), over == danger (red).
    var color: Color {
        switch self {
        case .off: .secondary
        case .under: OpenClawBrand.ok
        case .near: OpenClawBrand.warn
        case .over: OpenClawBrand.danger
        }
    }

    /// Short pill label for the Command Center card / banner ("OK" / "NEAR" / "OVER").
    var pillLabel: String {
        switch self {
        case .off: ""
        case .under: "OK"
        case .near: "NEAR"
        case .over: "OVER"
        }
    }

    var isOver: Bool {
        if case .over = self { return true }
        return false
    }

    var isNearOrOver: Bool {
        self.severity >= BudgetStatus.near(fraction: 0).severity
    }
}

// MARK: - Shared store environment

extension EnvironmentValues {
    /// Carries the single `CostBudgetStore` instance from its owner (`CommandCenterTab`) down to the
    /// pushed Cost dashboard. `@Observable` tracking is per-instance and `UserDefaults` writes don't
    /// cross-notify, so two independent stores backing the same keys would let the screen's edits go
    /// unseen by the card's budget pill until the tab is recreated. Sharing one instance keeps the card
    /// and the screen live. `nil` when no owner injected one (previews / standalone use); the screen
    /// falls back to its own store in that case.
    @Entry var costBudgetStore: CostBudgetStore?
}
