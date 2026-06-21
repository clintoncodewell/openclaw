import Foundation
import OpenClawKit
import OpenClawProtocol
import SwiftUI

/// Closed load state for the Command Center digest so the view never juggles parallel nullable flags.
/// Mirrors `OpsLoadState` / `InboxLoadState`. `.allClear` is distinct from `.loaded([])`: it is the calm
/// "nothing needs you" state we render with a green empty row, NOT an error or an empty-while-loading gap.
enum DigestLoadState {
    case idle
    case loading
    case loaded([DigestItem])
    case allClear
    case offline
    case error(String)
}

/// Drives the Command Center "what needs you" digest. Like `OpsHealthViewModel`: a closed load-state enum,
/// a `connected(appModel:)` gate copied verbatim, and a load that preserves the prior ranked list on a
/// transient failure so the hero never blanks to a spinner mid-refresh.
///
/// `load` fires SIX concurrent gateway reads — the EXACT same RPCs the individual home cards already fetch —
/// and folds each through its EXISTING decoder, never a parallel one:
/// - `exec.approval.list` `{}` → `InboxApproval.decodeList` → pending-decision count + worst `riskKind`.
/// - `cron.runs` (all scopes, newest-first) → the shared `statusKind == .error` filter → distinct failing jobIds.
/// - `usage.cost` today + 30d → `CostUsageSummaryLite` → the injected `CostBudgetStore.worstStatus`.
/// - `models.authStatus` `{"refresh":false}` → `AuthHealthResultLite.decode` → re-auth / expiring provider counts.
/// - `node.list` `{}` → `FleetNode.decodeList` → offline (paired-but-disconnected) count.
/// - `sessions.usage` 30d → `OpsUsageResultLite.decode` → window error rate vs `OpsHealthThresholds`.
///
/// Each source fails INDEPENDENTLY: a nil from any one read only drops that one signal, never the whole
/// digest. The budget store is injected (not owned) so the digest and the Cost screen read one source of
/// truth — a cap edited on the Cost dashboard re-ranks the over-budget row here on the next refresh.
@MainActor
@Observable
final class CommandDigestViewModel {
    private(set) var state: DigestLoadState = .idle

    /// Cron page size: a generous window so a noisy day doesn't truncate the failing-job rollup. The
    /// `cron.runs` handler clamps to 200; this matches the card's own `refreshHealth` page (50).
    private static let cronLimit = 50
    /// `sessions.usage` window: 30d, all agents — the same single call the Health card / screen read for the
    /// RED aggregates. Matches `CommandCenterTab.refreshHealth` byte-for-byte.
    private static let sessionsLimit = 200
    /// Minimum window message volume before the error-rate spike row is allowed to surface, so a tiny
    /// sample (one error in a few turns) can't pin a misleading "elevated error rate" to the hero.
    private static let errorSpikeMinVolume = 30

    /// `budget` is the SHARED `CostBudgetStore` injected from `CommandCenterTab` (its `@State budget`), not a
    /// fresh instance — so a cap edited on the pushed Cost screen reflects in the digest's over-budget row.
    func load(appModel: NodeAppModel, budget: CostBudgetStore, force: Bool) async {
        guard self.connected(appModel: appModel) else {
            self.state = .offline
            return
        }
        if case .loading = self.state, !force { return }
        // Preserve already-ranked content while refetching so the hero never blanks to a spinner — covers
        // pull-to-refresh (force) and the scenePhase foreground refresh (force == false). Mirrors the
        // reference VMs (`OpsHealthViewModel.load:82`).
        if case .loaded = self.state {} else if case .allClear = self.state {} else {
            self.state = .loading
        }

        // Six concurrent reads, each the SAME RPC + params the matching home card already issues. They are
        // independent: a nil from any one only drops that one signal category from the rollup, never the
        // others. (`OpsHealthViewModel.load:93-108` pattern.)
        async let approvalData = Self.requestData(
            appModel: appModel,
            method: "exec.approval.list",
            paramsJSON: "{}")
        async let cronData = Self.requestData(
            appModel: appModel,
            method: "cron.runs",
            paramsJSON: Self.cronParamsJSON())
        async let costTodayData = Self.requestData(
            appModel: appModel,
            method: "usage.cost",
            paramsJSON: "{\"days\":1,\"agentScope\":\"all\",\"mode\":\"gateway\"}")
        async let costMonthData = Self.requestData(
            appModel: appModel,
            method: "usage.cost",
            paramsJSON: "{\"range\":\"30d\",\"agentScope\":\"all\",\"mode\":\"gateway\"}")
        async let authData = Self.requestData(
            appModel: appModel,
            method: "models.authStatus",
            paramsJSON: "{\"refresh\":false}")
        async let nodeData = Self.requestData(
            appModel: appModel,
            method: "node.list",
            paramsJSON: "{}")
        async let usageData = Self.requestData(
            appModel: appModel,
            method: "sessions.usage",
            paramsJSON: "{\"range\":\"30d\",\"agentScope\":\"all\",\"mode\":\"gateway\",\"limit\":\(Self.sessionsLimit)}")

        let approval = await approvalData
        let cron = await cronData
        let costToday = await costTodayData
        let costMonth = await costMonthData
        let auth = await authData
        let nodes = await nodeData
        let usage = await usageData

        // Every read failed transiently: keep whatever the hero already shows rather than blanking it, and
        // only surface an error when there's nothing prior. (Matches the reference VMs' transient handling.)
        let allFailed = approval == nil && cron == nil && costToday == nil && costMonth == nil
            && auth == nil && nodes == nil && usage == nil
        if allFailed {
            if case .loaded = self.state { return }
            if case .allClear = self.state { return }
            self.state = .error("Could not load your digest.")
            return
        }

        var items: [DigestItem] = []
        if let item = Self.approvalsItem(approval) { items.append(item) }
        if let item = Self.jobsFailedItem(cron) { items.append(item) }
        if let authItems = Self.authItems(auth) { items.append(contentsOf: authItems) }
        if let item = Self.overBudgetItem(today: costToday, month: costMonth, budget: budget) { items.append(item) }
        if let item = Self.nodeOfflineItem(nodes) { items.append(item) }
        if let item = Self.errorSpikeItem(usage) { items.append(item) }

        // Rank most-urgent first (urgencyRank asc), then count desc, then a stable kind order — see
        // `DigestItem.sortKey`. Deterministic so the hero doesn't reshuffle between identical refreshes.
        items.sort { lhs, rhs in lhs.sortKey < rhs.sortKey }

        self.state = items.isEmpty ? .allClear : .loaded(items)
    }

    // MARK: - Signal folding (each reuses an EXISTING decoder; no parallel models)

    /// Pending exec approvals — decisions awaiting you. Every returned `InboxApproval` IS a pending decision
    /// (`Inbox/AgentInboxViewModel` contract); the worst `riskKind` across them sets the row severity so a
    /// dangerous command (deny / warning) reads red while a routine review reads amber/accent.
    private static func approvalsItem(_ data: Data?) -> DigestItem? {
        guard let data else { return nil }
        let approvals = InboxApproval.decodeList(from: data)
        guard !approvals.isEmpty else { return nil }
        let worst = Self.worstRisk(approvals)
        let severity = Self.severity(forRisk: worst)
        let noun = approvals.count == 1 ? "decision" : "decisions"
        return DigestItem(
            kind: .approvalsAwaiting,
            title: "\(approvals.count) \(noun) awaiting you",
            detail: Self.approvalsDetail(approvals),
            count: approvals.count,
            severity: severity)
    }

    /// Worst risk across pending approvals so the row escalates to the most dangerous command, not the first.
    private static func worstRisk(_ approvals: [InboxApproval]) -> InboxRiskKind {
        if approvals.contains(where: { $0.riskKind == .danger }) { return .danger }
        if approvals.contains(where: { $0.riskKind == .caution }) { return .caution }
        return .normal
    }

    /// Map the inbox risk classification to digest severity: a blocked/warned command is danger, an
    /// elevated-access command is warn, a routine review is the accent info tier.
    private static func severity(forRisk risk: InboxRiskKind) -> DigestSeverity {
        switch risk {
        case .danger: .danger
        case .caution: .warn
        case .normal: .info
        }
    }

    /// One-line approvals detail: the most-dangerous command's text when present, else the first command.
    private static func approvalsDetail(_ approvals: [InboxApproval]) -> String {
        let lead = approvals.first { $0.riskKind == .danger }
            ?? approvals.first { $0.riskKind == .caution }
            ?? approvals.first
        guard let lead else { return "Tap to review and approve" }
        let command = lead.displayCommand
        return command.isEmpty ? "Tap to review and approve" : command
    }

    /// Failed scheduled jobs. Reuses the `cron.runs` lossy decode + `statusKind == .error` filter shared by
    /// Briefs / Ops, deduped on `jobId` so a job that failed repeatedly is one row (`OpsHealthViewModel:390`).
    private static func jobsFailedItem(_ data: Data?) -> DigestItem? {
        guard let data else { return nil }
        let failing = Self.decodeFailingRuns(from: data)
        guard !failing.isEmpty else { return nil }
        var seenJobs = Set<String>()
        var distinct: [BriefRun] = []
        for run in failing where seenJobs.insert(run.jobId).inserted {
            distinct.append(run)
        }
        guard let newest = distinct.max(by: { $0.date < $1.date }) else { return nil }
        let noun = distinct.count == 1 ? "job" : "jobs"
        let detail = newest.error?.trimmingCharacters(in: .whitespacesAndNewlines)
        return DigestItem(
            kind: .jobsFailed,
            title: "\(distinct.count) scheduled \(noun) failed",
            detail: (detail?.isEmpty ?? true) ? newest.jobName : "\(newest.jobName): \(detail ?? "")",
            count: distinct.count,
            severity: .danger)
    }

    /// Provider auth: a dead credential (expired/missing) is the urgent re-auth row; an expiring-soon
    /// credential is a lower-tier early-warning row. Reuses `AuthHealthResultLite.decode` +
    /// `AuthProviderLite.needsReauth` / `isExpiringSoon`. Returns up to two items (re-auth and expiring are
    /// distinct kinds at different urgency tiers), or nil when every provider is healthy.
    private static func authItems(_ data: Data?) -> [DigestItem]? {
        guard let data, let result = AuthHealthResultLite.decode(from: data) else { return nil }
        let reauth = result.providers.filter(\.needsReauth)
        // Only count providers that are EXPIRING but not already needing re-auth, so a dead provider isn't
        // double-counted across both rows.
        let expiring = result.providers.filter { $0.isExpiringSoon && !$0.needsReauth }
        var items: [DigestItem] = []
        if !reauth.isEmpty {
            let noun = reauth.count == 1 ? "provider" : "providers"
            items.append(DigestItem(
                kind: .authNeedsReauth,
                title: "\(reauth.count) \(noun) need re-auth",
                detail: "\(reauth.map(\.name).joined(separator: ", ")) — sign in on the host",
                count: reauth.count,
                severity: .danger))
        }
        if !expiring.isEmpty {
            let noun = expiring.count == 1 ? "credential" : "credentials"
            items.append(DigestItem(
                kind: .authExpiring,
                title: "\(expiring.count) \(noun) expiring soon",
                detail: expiring.map(\.name).joined(separator: ", "),
                count: expiring.count,
                severity: .warn))
        }
        return items.isEmpty ? nil : items
    }

    /// Over-budget spend. Reuses `CostUsageSummaryLite` for today + 30d totals and the SHARED
    /// `CostBudgetStore.worstStatus`, gated on `isNearOrOver` (the same gate the Cost card pill uses). An
    /// unloaded spend coerces to 0, which can only under-report (never falsely fire). `.over` is the urgent
    /// danger tier; a `.near` cap is the amber warn tier.
    private static func overBudgetItem(today: Data?, month: Data?, budget: CostBudgetStore) -> DigestItem? {
        guard budget.alertsEnabled, budget.anyBudgetSet else { return nil }
        let todaySpend = Self.cost(from: today)
        let monthSpend = Self.cost(from: month)
        let status = budget.worstStatus(todaySpend: todaySpend, monthSpend: monthSpend)
        guard status.isNearOrOver else { return nil }
        let severity: DigestSeverity = status.isOver ? .danger : .warn
        return DigestItem(
            kind: .overBudget,
            title: status.isOver ? "Spend is over budget" : "Spend is near your budget",
            detail: Self.budgetDetail(todaySpend: todaySpend, monthSpend: monthSpend),
            count: nil,
            severity: severity)
    }

    /// Decode a `usage.cost` window total (USD). Reuses `CostUsageSummaryLite.totalCost`; 0 on a missing /
    /// failed read so the budget compare can only under-report.
    private static func cost(from data: Data?) -> Double {
        guard let data, let summary = try? JSONDecoder().decode(CostUsageSummaryLite.self, from: data) else {
            return 0
        }
        return summary.totalCost ?? 0
    }

    /// Budget caption: lead with the larger of the two window spends, e.g. "$42 today" / "$1,180 this
    /// month", so the dollar figure shown is the one that drove the worst status.
    private static func budgetDetail(todaySpend: Double, monthSpend: Double) -> String {
        if monthSpend > todaySpend {
            return "\(CostFormatting.currency(monthSpend)) this month"
        }
        return "\(CostFormatting.currency(todaySpend)) today"
    }

    /// Offline paired nodes. Reuses `FleetNode.decodeList` + `status == .offline` (the same offline signal
    /// `CommandFleetSummary.offlineCount` shows on the Fleet card).
    private static func nodeOfflineItem(_ data: Data?) -> DigestItem? {
        guard let data else { return nil }
        let offline = FleetNode.decodeList(from: data).filter { $0.status == .offline }
        guard !offline.isEmpty else { return nil }
        let noun = offline.count == 1 ? "node is" : "nodes are"
        return DigestItem(
            kind: .nodeOffline,
            title: "\(offline.count) paired \(noun) offline",
            detail: offline.map(\.name).joined(separator: ", "),
            count: offline.count,
            severity: .warn)
    }

    /// Error-rate spike. Reuses `OpsUsageResultLite.decode` + `CommandHealthSummary` (the SAME error-rate
    /// derivation the Health card / strip use) and the shared `OpsHealthThresholds`: surfaces at/over the
    /// warn band, escalates to danger at/over the danger band.
    private static func errorSpikeItem(_ data: Data?) -> DigestItem? {
        guard let data, let usage = OpsUsageResultLite.decode(from: data) else { return nil }
        // `cronFailures: nil` — the cron failures are already their own digest row; here we only need the
        // error-rate aggregate, so we skip re-decoding the cron page into the issue count.
        let summary = CommandHealthSummary(usage: usage, cronFailures: nil)
        let rate = summary.errorRatePct
        // Require a minimum window volume before flagging: a handful of turns with one error would yield a
        // high percentage and pin a misleading "elevated error rate" to the top of the feed. The digest is
        // the at-a-glance hero, so it should only nag when the spike is statistically meaningful.
        let totalMessages = usage.aggregates?.messages?.total ?? 0
        guard totalMessages >= Self.errorSpikeMinVolume, rate >= OpsHealthThresholds.errorRateWarn else {
            return nil
        }
        let severity: DigestSeverity = rate >= OpsHealthThresholds.errorRateDanger ? .danger : .warn
        return DigestItem(
            kind: .errorSpike,
            title: "Error rate is elevated",
            detail: "\(OpsFormatting.percent(rate)) of recent turns errored",
            count: nil,
            severity: severity)
    }

    // MARK: - cron.runs helpers (mirrors OpsHealthViewModel; those are file-private there)

    /// `cron.runs` params: all scopes, newest first, no server-side `statuses` filter — the gateway schema
    /// rejects any extra literal (`additionalProperties:false`, `cron.ts:100-104`), so we fetch all runs and
    /// filter client-side. Built through `CronRunsParams` (the model Briefs / Ops use) for the exact key
    /// casing the handler reads, with a hand-written fallback if encoding ever fails.
    private static func cronParamsJSON() -> String {
        let params = CronRunsParams(
            scope: AnyCodable("all"),
            id: nil,
            jobid: nil,
            runid: nil,
            limit: Self.cronLimit,
            offset: nil,
            statuses: nil,
            status: nil,
            deliverystatuses: nil,
            deliverystatus: nil,
            query: nil,
            sortdir: AnyCodable("desc"))
        guard let data = try? JSONEncoder().encode(params),
              let json = String(data: data, encoding: .utf8)
        else {
            return "{\"scope\":\"all\",\"sortDir\":\"desc\",\"limit\":\(Self.cronLimit)}"
        }
        return json
    }

    /// Lossy `cron.runs` decode keeping only `statusKind == .error` runs — the SAME contract as
    /// `OpsHealthViewModel.decodeFailingRuns` / `CommandHealthSummary.distinctFailingJobCount` (both
    /// file-private to their owners, so the shared logic is mirrored here, not duplicated as a new public
    /// decoder). Parse the `{entries:[...]}` envelope as opaque values, decode each `CronRunLogEntry` on its
    /// own, keep only failures; one bad entry can't blank the rollup.
    private static func decodeFailingRuns(from data: Data) -> [BriefRun] {
        struct Envelope: Decodable {
            let entries: [AnyCodable]?
        }
        let decoder = JSONDecoder()
        guard let envelope = try? decoder.decode(Envelope.self, from: data),
              let rawEntries = envelope.entries
        else {
            return []
        }
        var runs: [BriefRun] = []
        runs.reserveCapacity(rawEntries.count)
        for raw in rawEntries {
            guard let entryData = try? JSONEncoder().encode(raw),
                  let entry = try? decoder.decode(CronRunLogEntry.self, from: entryData),
                  let run = BriefRun(entry: entry),
                  run.statusKind == .error
            else {
                continue
            }
            runs.append(run)
        }
        return runs
    }

    // MARK: - Request helper (mirrors OpsHealthViewModel.requestData)

    /// One gateway read that swallows transport errors into `nil` so each `async let` source can fail
    /// independently without throwing out of the concurrent gather. 12s timeout matches every reference VM.
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

    // MARK: - Live freshness

    /// Keep the digest live while foregrounded: the gateway broadcasts `exec.approval.requested` /
    /// `exec.approval.resolved` to approvals-scoped clients, so a decision raised or resolved anywhere bumps
    /// the approvals row (and re-ranks the hero) without polling. Mirrors
    /// `CommandCenterTab.observeInboxPendingCount` (`CommandCenterTab.swift:987`).
    func observeApprovalEvents(appModel: NodeAppModel, budget: CostBudgetStore) async {
        let stream = await appModel.operatorSession.subscribeServerEvents(bufferingNewest: 200)
        for await event in stream {
            if Task.isCancelled { return }
            switch event.event {
            case "exec.approval.requested", "exec.approval.resolved":
                await self.load(appModel: appModel, budget: budget, force: true)
            default:
                continue
            }
        }
    }

    // MARK: - Connection gate (copied verbatim from CostInsightsViewModel)

    private func connected(appModel: NodeAppModel) -> Bool {
        guard !appModel.isLocalGatewayFixtureEnabled else { return false }
        guard appModel.isOperatorGatewayConnected else { return false }
        return GatewayStatusBuilder.build(appModel: appModel) == .connected
    }
}
