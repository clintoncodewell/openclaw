import Foundation
import SwiftUI

/// The Command Center "what needs you" digest: a single prioritized rollup of the six operator signals
/// already fetched piecemeal across the home cards (pending approvals, failed crons, over-budget spend,
/// dead provider auth, offline nodes, error-rate spike). The models here are deliberately a thin synthesis
/// layer — they carry NO decoders of their own. Every signal is decoded by its existing owner
/// (`InboxApproval.decodeList`, `OpsUsageResultLite.decode`, `CostUsageSummaryLite`, `AuthHealthResultLite`,
/// `FleetNode.decodeList`, plus the `cron.runs` `statusKind == .error` filter Briefs/Ops share) and folded
/// into `DigestItem` by `CommandDigestViewModel`.

// MARK: - Severity

/// Closed digest severity → brand color, mirroring `OpsSeverity` (`Ops/OpsModels.swift:427`) and
/// `BudgetStatus.color` so a digest row, an Ops issue, and a budget pill share one color language. Closed
/// so a row never juggles parallel `isDanger` / `isWarn` booleans.
enum DigestSeverity: Int, Comparable {
    /// Informational / lower-tier warning (an expiring-soon credential, an error-rate at the warn band).
    case info = 0
    /// Amber: attention soon, not yet a hard failure.
    case warn = 1
    /// Red: something is broken or actively blocking and needs you now.
    case danger = 2

    var color: Color {
        switch self {
        case .info: OpenClawBrand.accent
        case .warn: OpenClawBrand.warn
        case .danger: OpenClawBrand.danger
        }
    }

    static func < (lhs: DigestSeverity, rhs: DigestSeverity) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

// MARK: - Signal kind

/// The closed set of digest signals, each carrying its urgency rank, SF Symbol, baseline severity, and the
/// home screen it routes to. Mirrors the closed-enum style of `OpsHealthIssue` (`Ops/OpsModels.swift:345`):
/// the view maps a kind to an icon / destination without re-inspecting raw strings.
///
/// Urgency ranking (lower == more urgent), per the Chief-of-Staff spec: a decision awaiting YOU outranks
/// everything; a failed job or a dead provider auth (both hard, fix-now failures) come next and tie; an
/// over-budget cap is the money signal below those; an offline node is operational-but-recoverable; an
/// expiring-soon credential and an error-rate spike are the lower-tier early warnings. Ties break on count
/// (more items first) in the view model's sort.
enum DigestSignalKind: Hashable {
    /// Pending exec approvals — decisions awaiting you. `exec.approval.list`.
    case approvalsAwaiting
    /// Failed scheduled jobs (distinct failing jobIds). `cron.runs`, client-side `statusKind == .error`.
    case jobsFailed
    /// A provider credential that needs a host-side re-login (expired / missing). `models.authStatus`.
    case authNeedsReauth
    /// Spend at/over a daily or monthly budget cap. `usage.cost` + the shared `CostBudgetStore`.
    case overBudget
    /// Paired nodes the gateway reports disconnected. `node.list`, `status == .offline`.
    case nodeOffline
    /// A provider credential approaching expiry (still valid). `models.authStatus`. Lower-tier warning.
    case authExpiring
    /// Error rate at/over the warn threshold. `sessions.usage`. Lower-tier warning.
    case errorSpike

    /// Urgency rank (lower == more urgent). Drives the primary sort; `jobsFailed` and `authNeedsReauth`
    /// intentionally share rank 1 (both hard failures), broken by count then a stable kind order.
    var urgencyRank: Int {
        switch self {
        case .approvalsAwaiting: 0
        case .jobsFailed: 1
        case .authNeedsReauth: 1
        case .overBudget: 2
        case .nodeOffline: 3
        case .authExpiring: 4
        case .errorSpike: 5
        }
    }

    /// Stable secondary order so two same-rank kinds (jobsFailed vs authNeedsReauth) sort deterministically
    /// when their counts also tie — prompt-cache-style determinism, no flicker between refreshes.
    var tieBreak: Int {
        switch self {
        case .approvalsAwaiting: 0
        case .jobsFailed: 1
        case .authNeedsReauth: 2
        case .overBudget: 3
        case .nodeOffline: 4
        case .authExpiring: 5
        case .errorSpike: 6
        }
    }

    var icon: String {
        switch self {
        case .approvalsAwaiting: "checkmark.shield.fill"
        case .jobsFailed: "exclamationmark.triangle.fill"
        case .authNeedsReauth: "key.slash.fill"
        case .overBudget: "dollarsign.circle.fill"
        case .nodeOffline: "bolt.horizontal.circle.fill"
        case .authExpiring: "key.fill"
        case .errorSpike: "waveform.path.ecg.rectangle.fill"
        }
    }

    /// The home screen a digest row pushes. Returned as a closed case (not an erased `AnyView`) so the
    /// section view stays the single place that maps a kind to its zero-arg destination via a `NavigationLink`.
    var route: DigestRoute {
        switch self {
        case .approvalsAwaiting: .inbox
        case .jobsFailed: .briefs
        case .authNeedsReauth: .auth
        case .overBudget: .cost
        case .nodeOffline: .fleet
        case .authExpiring: .auth
        case .errorSpike: .health
        }
    }
}

// MARK: - Route

/// The fixed set of zero-arg home destinations a digest row can deep-link to. Closed because every target
/// is a payload-free screen already wired with `NavigationLink { Screen() }` on its own card
/// (`CommandCenterTab.swift`); the section view switches on this to build the same per-row link, so the
/// system back button works for free and no value-based router is needed.
enum DigestRoute {
    case inbox
    case briefs
    case cost
    case auth
    case fleet
    case health
}

// MARK: - Item

/// One ranked digest row. Closed shape — `count` is the only optional (a signal like `overBudget` has no
/// natural count), so the view never juggles parallel nullable fields. `id` derives from the kind, so a
/// re-rank reuses row identity (stable diff, no row churn) since each kind appears at most once.
struct DigestItem: Identifiable {
    let kind: DigestSignalKind
    let title: String
    let detail: String
    let count: Int?
    let severity: DigestSeverity

    var id: DigestSignalKind { self.kind }

    /// Sort key: most urgent first (low `urgencyRank`), then by count descending so a 5-failure row beats a
    /// 1-failure row at the same rank, then the stable `tieBreak`. Pure tuple comparison, no mutation.
    var sortKey: (Int, Int, Int) {
        // Negate count so a HIGHER count sorts FIRST under ascending tuple comparison.
        (self.kind.urgencyRank, -(self.count ?? 0), self.kind.tieBreak)
    }
}
