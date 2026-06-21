import Foundation
import OpenClawKit
import OpenClawProtocol
import SwiftUI

/// Closed load state for the Ops health overview so the view never juggles parallel nullable flags.
/// Mirrors `CostLoadState` / `BriefsLoadState`.
enum OpsLoadState: Equatable {
    case idle
    case loading
    case loaded(RedReport)
    case empty
    case offline
    case error(String)

    static func == (lhs: OpsLoadState, rhs: OpsLoadState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.loading, .loading), (.empty, .empty), (.offline, .offline):
            true
        case let (.error(l), .error(r)):
            l == r
        case let (.loaded(l), .loaded(r)):
            // Identity by the cheap scalar RED headline; the screen re-renders fully on any reload.
            l.requestsWindow == r.requestsWindow
                && l.errorRatePct == r.errorRatePct
                && l.avgMs == r.avgMs
                && l.issueCount == r.issueCount
        default:
            false
        }
    }
}

/// Drives the RED / operational-health overview. Like `CostInsightsViewModel`: a closed load-state enum,
/// a `connected(appModel:)` gate copied verbatim, and a load that preserves the prior report on a
/// transient failure so the screen never blanks to a spinner mid-refresh.
///
/// `load` fires four concurrent gateway reads (`sessions.usage`, `usage.status`, `cron.runs`,
/// `node.list`) plus the already-available `system-presence` and `GatewayStatusBuilder` status off
/// `appModel`. It folds them into one `RedReport`:
/// - RATE: requests = SUM of `daily[].messages` (+ toolCalls) over the newest 1 / 7 day keys; the window
///   headline is `messages.total`.
/// - ERRORS: rate = `messages.errors / messages.total` (clamped at 100%, same denominator as the per-day
///   chart); trend = this-vs-prior-window delta from `daily[]`. The gateway has no error-rate field.
/// - DURATION: avg / p95 from `aggregates.latency` (END-TO-END turn latency, ms; NOT TTFT, which has no
///   source). The sparkline uses `dailyLatency`.
/// - ISSUES: erroring cron entries (reusing `BriefRun` / `BriefStatusKind`), providers with an auth
///   error or a near-quota window, offline paired nodes, and a degraded gateway.
@MainActor
@Observable
final class OpsHealthViewModel {
    private(set) var state: OpsLoadState = .idle

    /// All providers from the most recent `usage.status` decode, healthy and unhealthy, so the screen's
    /// "Provider plans" section can render the full quota table — not just the providers that became
    /// attention issues. Empty until the first successful fetch / when the call is absent. Kept beside the
    /// report (rather than inside `RedReport`) because the report is the derived RED rollup; the raw plan
    /// table is presentation context the rollup doesn't need.
    private(set) var providerSnapshots: [OpsProviderSnapshotLite] = []

    /// 30-day window so one `sessions.usage` call covers the 24h / 7d RED tiles + the per-day sparklines.
    /// All RED series are PER-DAY (no sub-day granularity exists in the aggregates), so 30d is the widest
    /// useful sparkline window without paging.
    private static let sessionsLimit = 200
    /// Pull a generous page of failed cron runs so a noisy day doesn't truncate the attention rollup; the
    /// `cron.runs` handler clamps to 200.
    private static let cronLimit = 50

    var report: RedReport? {
        if case let .loaded(report) = self.state { return report }
        return nil
    }

    func load(appModel: NodeAppModel, force: Bool) async {
        guard self.connected(appModel: appModel) else {
            self.state = .offline
            return
        }
        if case .loading = self.state, !force { return }
        // Preserve already-loaded content while refetching so the overview never blanks to a spinner —
        // covers pull-to-refresh (force) and the scenePhase foreground refresh (force == false).
        if case .loaded = self.state {} else {
            self.state = .loading
        }

        // Four concurrent reads. `sessions.usage` is the primary RED source (range 30d, all agents). The
        // `daily[]` day keys are formatted in the gateway MACHINE's local timezone (`formatDayKey`,
        // `session-cost-usage.ts:964`), not UTC and not the `mode:'gateway'` offset — exactly like Cost. The
        // client never depends on that zone: it only parses/sums/reformats the keys as opaque calendar-day
        // strings. The other three feed the attention rollup and
        // each fail independently: a nil from any one only drops that one issue category, never the RED
        // tiles. `system-presence` + the gateway status are read synchronously off `appModel`.
        async let usageData = Self.requestData(
            appModel: appModel,
            method: "sessions.usage",
            paramsJSON: Self.sessionsParamsJSON())
        async let providerData = Self.requestData(
            appModel: appModel,
            method: "usage.status",
            paramsJSON: "{}")
        async let cronData = Self.requestData(
            appModel: appModel,
            method: "cron.runs",
            paramsJSON: Self.cronParamsJSON())
        async let nodeData = Self.requestData(
            appModel: appModel,
            method: "node.list",
            paramsJSON: "{}")

        let usage = await usageData
        let provider = await providerData
        let cron = await cronData
        let nodes = await nodeData

        // `sessions.usage` is the primary source; if it failed entirely, keep any prior report and only
        // surface an error when the screen is otherwise empty (mirrors the reference VMs).
        guard let usageData = usage, let usageResult = OpsUsageResultLite.decode(from: usageData) else {
            if case .loaded = self.state { return }
            self.state = .error("Could not load operational health.")
            return
        }

        let gatewayStatus = GatewayStatusBuilder.build(appModel: appModel)
        let providerHealth = provider.flatMap { OpsProviderHealthLite.decode(from: $0) }
        // Keep the prior provider table on a transient `usage.status` failure so the plan section doesn't
        // flicker empty mid-refresh; only replace it when the call actually returned providers.
        if let providers = providerHealth?.providers {
            self.providerSnapshots = providers
        }
        let report = Self.buildReport(
            usage: usageResult,
            providerHealth: providerHealth,
            cronRuns: cron.map { Self.decodeFailingRuns(from: $0) } ?? [],
            offlineNodes: nodes.map { OpsNodeLite.decodeList(from: $0).filter(\.isOffline) } ?? [],
            gatewayStatus: gatewayStatus)

        self.state = report.hasAnySignal ? .loaded(report) : .empty
    }

    // MARK: - Params

    /// `sessions.usage` params: 30-day window across all agents. (The gateway's `daily[]` day keys are
    /// bucketed in the gateway machine's local timezone via `formatDayKey`, not UTC; the client treats them
    /// as opaque calendar-day strings, so the bucketing zone never matters here.) Built
    /// through `SessionsUsageParams` so the strict `SessionsUsageParamsSchema`
    /// (`additionalProperties: false`) sees the exact key casing. No `groupBy` — the RED aggregates we
    /// read (daily / latency / messages) are not affected by the model-grouping that Cost uses.
    private static func sessionsParamsJSON() -> String {
        let params = SessionsUsageParams(
            key: nil,
            agentid: nil,
            agentscope: "all",
            startdate: nil,
            enddate: nil,
            mode: AnyCodable("gateway"),
            range: AnyCodable("30d"),
            groupby: nil,
            includehistorical: nil,
            utcoffset: nil,
            limit: Self.sessionsLimit,
            includecontextweight: nil)
        guard let data = try? JSONEncoder().encode(params),
              let json = String(data: data, encoding: .utf8)
        else {
            return "{\"range\":\"30d\",\"agentScope\":\"all\",\"mode\":\"gateway\",\"limit\":\(Self.sessionsLimit)}"
        }
        return json
    }

    /// `cron.runs` params for the failure rollup: all scopes, newest first. No server-side `statuses`
    /// filter — the gateway schema only accepts `ok`/`error`/`skipped` (`CronRunsStatusValueSchema`,
    /// `cron.ts:100-104`) with `additionalProperties:false`, so any extra literal makes
    /// `validateCronRunsParams` reject the whole call (`server-methods/cron.ts:666`) and the query never
    /// runs. We fetch all runs and let `decodeFailingRuns`' client-side `statusKind == .error` filter
    /// narrow to failures (catches both `error` runs and any run carrying a non-null `error`).
    /// Built through `CronRunsParams` (same model Briefs uses) for the exact key casing the handler reads.
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

    /// Lossy `cron.runs` decode reused from Briefs' contract: parse the `{entries:[...]}` envelope as
    /// opaque values, decode each `CronRunLogEntry` on its own, keep only the ones `BriefStatusKind` reads
    /// as `.error` (status in the error set OR a non-null `error`). One bad entry can't blank the rollup.
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

    // MARK: - Report assembly

    /// Fold the `sessions.usage` RED aggregates + the three secondary health sources into a `RedReport`.
    private static func buildReport(
        usage: OpsUsageResultLite,
        providerHealth: OpsProviderHealthLite?,
        cronRuns: [BriefRun],
        offlineNodes: [OpsNodeLite],
        gatewayStatus: GatewayDisplayState) -> RedReport
    {
        let aggregates = usage.aggregates
        let daily = (aggregates?.daily ?? []).sorted { $0.date < $1.date }
        let dailyLatency = (aggregates?.dailyLatency ?? []).sorted { $0.date < $1.date }
        let messages = aggregates?.messages

        let requestsDaily = Self.requestRatePoints(from: daily)
        let errorRateDaily = Self.errorRatePoints(from: daily)
        let latencyDaily = Self.latencyPoints(from: dailyLatency)

        // RATE: window SUMS of daily messages (+ toolCalls) over the newest 1 / 7 day keys. The daily
        // series is sparse (no zero-fill), so we anchor on the newest key and sum on/after the cutoff
        // rather than `suffix(n)`, which would reach further back than n calendar days when days are gappy.
        let requests24h = Self.requestSum(daily, trailingDays: 1)
        let requests7d = Self.requestSum(daily, trailingDays: 7)
        let requestsWindow = messages?.total ?? Self.requestSum(daily, trailingDays: daily.count)

        // ERRORS: window error rate = errors / total messages (user+assistant), the SAME denominator the
        // per-day chart and the trend use, so the headline tile and its sparkline agree numerically. The
        // gateway exposes no error-rate field; this is derived. `messages.errors` counts tool-result errors
        // PLUS assistant error stop-reasons (`session-cost-usage.ts:676-683`), so it can outnumber assistant
        // turns — using `total` (and clamping at 100%) keeps the tile from rendering an impossible rate.
        // Trend = this-vs-prior comparable window delta, from the daily series.
        let errorsWindow = messages?.errors ?? daily.reduce(0) { $0 + ($1.errors ?? 0) }
        let totalMessages = messages?.total ?? daily.reduce(0) { $0 + ($1.messages ?? 0) }
        let errorRatePct = min(Self.percent(errorsWindow, of: totalMessages), 100)
        let errorRateTrendPct = Self.errorRateTrend(daily)

        let issues = Self.buildIssues(
            providerHealth: providerHealth,
            cronRuns: cronRuns,
            offlineNodes: offlineNodes,
            gatewayStatus: gatewayStatus)

        return RedReport(
            requests24h: requests24h,
            requests7d: requests7d,
            requestsWindow: requestsWindow,
            errorRatePct: errorRatePct,
            errorRateTrendPct: errorRateTrendPct,
            errorsWindow: errorsWindow,
            latency: aggregates?.latency,
            requestsDaily: requestsDaily,
            errorRateDaily: errorRateDaily,
            latencyDaily: latencyDaily,
            issues: issues)
    }

    /// Request-rate series: one point per day, value = `messages + toolCalls` (a tool-heavy day still
    /// registers volume). Drops days with an unparseable key.
    private static func requestRatePoints(from daily: [OpsDailyLite]) -> [OpsRatePoint] {
        daily.compactMap { entry in
            guard let date = Self.date(from: entry.date) else { return nil }
            let value = Double((entry.messages ?? 0) + (entry.toolCalls ?? 0))
            return OpsRatePoint(date: date, dayKey: entry.date, value: value)
        }
    }

    /// Per-day error-rate series (%): `errors / messages` for the day. `messages` is the day's user +
    /// assistant count; using it (not just assistant turns) keeps the per-day denominator non-zero on days
    /// the daily bucket reports messages but the window-wide `assistant` split is unavailable.
    private static func errorRatePoints(from daily: [OpsDailyLite]) -> [OpsRatePoint] {
        daily.compactMap { entry in
            guard let date = Self.date(from: entry.date) else { return nil }
            let value = Self.percent(entry.errors ?? 0, of: entry.messages ?? 0)
            return OpsRatePoint(date: date, dayKey: entry.date, value: value)
        }
    }

    /// Per-day latency series: avg + p95 turn duration (ms). Drops days with an unparseable key.
    private static func latencyPoints(from dailyLatency: [OpsDailyLatencyLite]) -> [OpsLatencyPoint] {
        dailyLatency.compactMap { entry in
            guard let date = Self.date(from: entry.date) else { return nil }
            return OpsLatencyPoint(
                date: date,
                dayKey: entry.date,
                avgMs: entry.avgMs ?? 0,
                p95Ms: entry.p95Ms ?? 0)
        }
    }

    /// Sum `messages + toolCalls` over the trailing `trailingDays` calendar-day window. Anchors on the
    /// newest day key and keeps entries on/after the cutoff (comparing the gateway's `YYYY-MM-DD` strings,
    /// which sort lexicographically by calendar date) so no client timezone is involved — same window math
    /// as Cost's `windowCost`.
    private static func requestSum(_ daily: [OpsDailyLite], trailingDays: Int) -> Int {
        guard trailingDays > 0, let newestKey = daily.last?.date, let anchor = Self.date(from: newestKey)
        else {
            return daily.reduce(0) { $0 + ($1.messages ?? 0) + ($1.toolCalls ?? 0) }
        }
        let cutoff = Self.dayKey(for: anchor.addingTimeInterval(-Double(trailingDays - 1) * 86_400))
        return daily
            .filter { $0.date >= cutoff }
            .reduce(0) { $0 + ($1.messages ?? 0) + ($1.toolCalls ?? 0) }
    }

    /// Signed error-rate delta (percentage points) vs the prior comparable window: the rate over the
    /// newest 7 day keys minus the rate over the 7 keys before that. >0 means errors are trending up.
    /// Best-effort — returns 0 when there isn't enough history for a comparison.
    private static func errorRateTrend(_ daily: [OpsDailyLite]) -> Double {
        guard daily.count >= 2 else { return 0 }
        let recent = Array(daily.suffix(7))
        let priorSlice = daily.dropLast(recent.count).suffix(7)
        guard !priorSlice.isEmpty else { return 0 }
        let recentRate = Self.windowErrorRate(recent)
        let priorRate = Self.windowErrorRate(Array(priorSlice))
        return recentRate - priorRate
    }

    /// Error rate (%) across a slice of days: total errors / total messages over the slice.
    private static func windowErrorRate(_ days: [OpsDailyLite]) -> Double {
        let errors = days.reduce(0) { $0 + ($1.errors ?? 0) }
        let messages = days.reduce(0) { $0 + ($1.messages ?? 0) }
        return Self.percent(errors, of: messages)
    }

    /// Roll up the three secondary health sources + the gateway status into ordered attention issues:
    /// gateway degraded first (top-level), then cron failures, then provider auth / quota, then offline
    /// nodes. Cron rows dedupe on jobId so a job that failed repeatedly contributes one row (newest).
    private static func buildIssues(
        providerHealth: OpsProviderHealthLite?,
        cronRuns: [BriefRun],
        offlineNodes: [OpsNodeLite],
        gatewayStatus: GatewayDisplayState) -> [OpsHealthIssue]
    {
        var issues: [OpsHealthIssue] = []

        // The screen's `connected()` gate means we only reach here while `.connected`; a `.connecting` /
        // `.error` flip mid-refresh is still worth surfacing as a degraded-gateway row.
        if let degraded = Self.gatewayDegradedLabel(gatewayStatus) {
            issues.append(.gatewayDegraded(status: degraded))
        }

        var seenJobs = Set<String>()
        for run in cronRuns where seenJobs.insert(run.jobId).inserted {
            issues.append(.cronFailing(job: run.jobName, error: run.error, date: run.date))
        }

        for provider in providerHealth?.providers ?? [] {
            if let error = provider.error, !error.isEmpty {
                issues.append(.providerDown(name: provider.name, error: error))
                continue
            }
            // Only a near-quota window is an attention item; a healthy provider with low usage is silent.
            if provider.worstUsedPercent >= OpsHealthThresholds.providerQuotaWarn {
                issues.append(.providerQuota(
                    name: provider.name,
                    usedPercent: provider.worstUsedPercent,
                    window: provider.worstWindow?.label))
            }
        }

        for node in offlineNodes {
            issues.append(.nodeOffline(name: node.name))
        }

        return issues
    }

    /// Label for a degraded gateway, or nil when it's healthy. `.connected` is the healthy steady state
    /// the screen gates on; the others are surfaced as attention rows.
    private static func gatewayDegradedLabel(_ status: GatewayDisplayState) -> String? {
        switch status {
        case .connected: nil
        case .connecting: "Connecting"
        case .error: "Attention"
        case .disconnected: "Offline"
        }
    }

    /// Integer-safe percentage helper: `numerator / denominator * 100`, 0 when the denominator is 0.
    private static func percent(_ numerator: Int, of denominator: Int) -> Double {
        guard denominator > 0 else { return 0 }
        return Double(numerator) / Double(denominator) * 100
    }

    // MARK: - Date helpers (UTC-pinned formatter, same as Cost)

    // The gateway's `daily[]` keys are bucketed in the gateway machine's local zone (`formatDayKey`,
    // `session-cost-usage.ts:964`), NOT UTC. The client formatter below is pinned to a single fixed zone
    // (UTC) only so the parse -> subtract-days -> reformat round-trip in `requestSum` is internally
    // self-consistent; the keys are treated as opaque calendar-day strings, so the pinned zone never has to
    // match the gateway's bucketing zone.
    private static func date(from dayKey: String) -> Date? {
        Self.dayFormatter.date(from: dayKey)
    }

    private static func dayKey(for date: Date) -> String {
        Self.dayFormatter.string(from: date)
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    // MARK: - Connection gate (copied verbatim from CostInsightsViewModel)

    private func connected(appModel: NodeAppModel) -> Bool {
        guard !appModel.isLocalGatewayFixtureEnabled else { return false }
        guard appModel.isOperatorGatewayConnected else { return false }
        return GatewayStatusBuilder.build(appModel: appModel) == .connected
    }
}

/// Millisecond-latency formatting for the Ops screen, kept local so the screen doesn't depend on Cost's
/// `CostFormatting`. Renders sub-second values as `850ms` and longer turns as `1.4s`.
enum OpsFormatting {
    static func latency(_ milliseconds: Double) -> String {
        guard milliseconds.isFinite, milliseconds > 0 else { return "—" }
        if milliseconds < 1000 {
            return "\(Int(milliseconds.rounded()))ms"
        }
        let seconds = milliseconds / 1000
        return seconds.formatted(.number.precision(.fractionLength(seconds < 10 ? 1 : 0))) + "s"
    }

    static func count(_ value: Int) -> String {
        value.formatted(.number.notation(.compactName))
    }

    /// Error-rate / percentage label with one fraction digit under 10% and none above, so "2.4%" stays
    /// precise while "57%" stays compact.
    static func percent(_ value: Double) -> String {
        guard value.isFinite else { return "—" }
        let fraction = value < 10 ? 1 : 0
        return value.formatted(.number.precision(.fractionLength(fraction))) + "%"
    }

    /// Signed trend label for the error-rate delta, e.g. "+1.2 pts" / "-0.4 pts" / "flat".
    static func trend(_ deltaPoints: Double) -> String {
        guard deltaPoints.isFinite, abs(deltaPoints) >= 0.1 else { return "flat" }
        let sign = deltaPoints > 0 ? "+" : ""
        let magnitude = deltaPoints.formatted(.number.precision(.fractionLength(1)))
        return "\(sign)\(magnitude) pts"
    }
}
