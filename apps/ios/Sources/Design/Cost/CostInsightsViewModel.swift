import Foundation
import OpenClawKit
import OpenClawProtocol
import SwiftUI

/// Closed load state for the Cost dashboard so the view never juggles parallel nullable flags.
/// Mirrors `InboxLoadState` / `BriefsLoadState`.
enum CostLoadState: Equatable {
    case idle
    case loading
    case loaded(CostReport)
    case empty
    case offline
    case error(String)

    static func == (lhs: CostLoadState, rhs: CostLoadState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.loading, .loading), (.empty, .empty), (.offline, .offline):
            true
        case let (.error(l), .error(r)):
            l == r
        case let (.loaded(l), .loaded(r)):
            // Identity by the cheap scalar window totals; the screen re-renders fully on any reload.
            l.todayUSD == r.todayUSD && l.last7USD == r.last7USD && l.last30USD == r.last30USD
        default:
            false
        }
    }
}

/// The selected reporting window for the top totals strip and the trend chart.
enum CostRange: String, CaseIterable, Identifiable {
    case today
    case sevenDay
    case thirtyDay

    var id: String { self.rawValue }

    var label: String {
        switch self {
        case .today: "Today"
        case .sevenDay: "7 days"
        case .thirtyDay: "30 days"
        }
    }

    /// How many trailing days of the 30-day `daily` series this window covers.
    var trailingDays: Int {
        switch self {
        case .today: 1
        case .sevenDay: 7
        case .thirtyDay: 30
        }
    }
}

/// Drives the Cost & Usage dashboard. Reuses the same `usage.cost` summary the Agent Pro overview
/// already fetches for the top totals + daily trend, and adds one `sessions.usage` call (range 30d,
/// `groupBy: family`) for the per-model / per-agent / model-mix breakdown the overview path does not
/// fetch. Structure mirrors `AgentInboxViewModel` / `BriefsInboxViewModel`: a closed load-state enum, a
/// `connected(appModel:)` gate copied verbatim, and a load that preserves the prior report on a
/// transient failure so the screen never blanks to a spinner mid-refresh.
@MainActor
@Observable
final class CostInsightsViewModel {
    private(set) var state: CostLoadState = .idle

    /// The window the totals strip + chart are scoped to. Changing it re-slices the already-loaded
    /// 30-day series locally; it does not refetch (the 30-day window is the superset of all three).
    var range: CostRange = .thirtyDay

    /// 30-day window so the single `usage.cost` / `sessions.usage` pair covers every range; the
    /// today / 7d totals are sliced from the 30-day `daily` series client-side.
    private static let windowDays = 30
    private static let sessionsLimit = 200

    var report: CostReport? {
        if case let .loaded(report) = self.state { return report }
        return nil
    }

    /// Spend value for the currently-selected range, for the headline metric + budget comparison.
    func spend(for range: CostRange) -> Double {
        guard let report = self.report else { return 0 }
        switch range {
        case .today: return report.todayUSD
        case .sevenDay: return report.last7USD
        case .thirtyDay: return report.last30USD
        }
    }

    func load(appModel: NodeAppModel, force: Bool) async {
        guard self.connected(appModel: appModel) else {
            self.state = .offline
            return
        }
        if case .loading = self.state, !force { return }
        // Preserve already-loaded content while refetching so the dashboard never blanks to a spinner —
        // covers pull-to-refresh (force) and the scenePhase foreground refresh (force == false).
        if case .loaded = self.state {} else {
            self.state = .loading
        }

        // Three concurrent reads: `usage.cost` 30d for the trend + 7d/30d totals, `usage.cost`
        // `{"days":1,"mode":"gateway"}` for today's spend (a key-independent window SUM scoped to the
        // gateway host's local day — see `todayParamsJSON`), and `sessions.usage` for the per-model /
        // per-agent / model-mix aggregates. All scoped `agentScope: all` so the dashboard reflects every
        // agent's spend, not just the active one.
        async let costData = Self.requestData(
            appModel: appModel,
            method: "usage.cost",
            paramsJSON: Self.costParamsJSON())
        async let todayData = Self.requestData(
            appModel: appModel,
            method: "usage.cost",
            paramsJSON: Self.todayParamsJSON())
        async let sessionsData = Self.requestData(
            appModel: appModel,
            method: "sessions.usage",
            paramsJSON: Self.sessionsParamsJSON())

        let cost = await costData
        let today = await todayData
        let sessions = await sessionsData

        // `usage.cost` is the primary source; if it failed entirely, keep any prior report and only
        // surface an error when the screen is otherwise empty (mirrors the reference VMs).
        guard let costData = cost,
              let summary = try? JSONDecoder().decode(CostUsageSummaryLite.self, from: costData)
        else {
            if case .loaded = self.state { return }
            self.state = .error("Could not load usage costs.")
            return
        }

        let todaySummary = today.flatMap { try? JSONDecoder().decode(CostUsageSummaryLite.self, from: $0) }
        let sessionsResult = sessions.flatMap { SessionsUsageResultLite.decode(from: $0) }
        let report = Self.buildReport(summary: summary, today: todaySummary, sessions: sessionsResult)

        // A report with no trend and no breakdown means the account simply has no recorded spend yet.
        let hasAnySignal = report.last30USD > 0
            || !report.dailyTrend.isEmpty
            || report.hasModelBreakdown
            || report.hasAgentBreakdown
        self.state = hasAnySignal ? .loaded(report) : .empty
    }

    // MARK: - Params

    /// `usage.cost` params: 30-day window across all agents. `range` + `agentScope` are read straight
    /// off `params` by the handler (no strict validator), so a hand-built JSON string is the simplest
    /// encode. `agentScope: all` is valid only when no `agentId` is supplied (`usage.ts:983`).
    /// `mode: gateway` aligns the window's day boundaries with the gateway host's local day — the same
    /// timezone the daily-rollup keys use (`formatDayKey`, `session-cost-usage.ts:964`) — so the trend
    /// buckets and the today slice share one basis.
    private static func costParamsJSON() -> String {
        "{\"range\":\"30d\",\"agentScope\":\"all\",\"mode\":\"gateway\"}"
    }

    /// `usage.cost` params for today's spend: a single-day window summed by the gateway. `{"days":1}`
    /// resolves to `[gatewayLocalMidnight, gatewayLocalEndOfDay]` under `mode: gateway`
    /// (`usage.ts:288-300, 368-373`), and `totals.totalCost` is a key-independent SUM over that window
    /// — so it never depends on matching a client-recomputed day key against the server's local-TZ
    /// rollup keys, which would miss the bucket whenever the gateway host isn't on UTC.
    private static func todayParamsJSON() -> String {
        "{\"days\":1,\"agentScope\":\"all\",\"mode\":\"gateway\"}"
    }

    /// `sessions.usage` params: strict-validated by `SessionsUsageParamsSchema`
    /// (`packages/gateway-protocol/src/schema/sessions.ts:498-536`, `additionalProperties: false`), so
    /// we build them through the `SessionsUsageParams` Swift model to guarantee the exact key casing
    /// (`agentScope`, `groupBy`, …). `mode`/`range`/`groupBy` are `AnyCodable` string enums.
    /// `groupBy: family` collapses per-instance models into model families for a cleaner breakdown.
    private static func sessionsParamsJSON() -> String {
        let params = SessionsUsageParams(
            key: nil,
            agentid: nil,
            agentscope: "all",
            startdate: nil,
            enddate: nil,
            mode: nil,
            range: AnyCodable("30d"),
            groupby: AnyCodable("family"),
            includehistorical: nil,
            utcoffset: nil,
            limit: Self.sessionsLimit,
            includecontextweight: nil)
        guard let data = try? JSONEncoder().encode(params),
              let json = String(data: data, encoding: .utf8)
        else {
            return "{\"range\":\"30d\",\"agentScope\":\"all\",\"groupBy\":\"family\",\"limit\":\(Self.sessionsLimit)}"
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

    // MARK: - Report assembly

    /// Fold the `usage.cost` 30-day daily series + grand totals, the dedicated `{"days":1}` today
    /// window, and the `sessions.usage` aggregates into the `CostReport` the screen renders. The 7d
    /// total is summed from the 30-day daily series; today comes from its own gateway-scoped window so
    /// it stays timezone-correct.
    private static func buildReport(
        summary: CostUsageSummaryLite,
        today: CostUsageSummaryLite?,
        sessions: SessionsUsageResultLite?) -> CostReport
    {
        let daily = (summary.daily ?? []).sorted { $0.date < $1.date }
        let trend = Self.trendPoints(from: daily)

        // Today's spend/tokens come from a dedicated gateway-scoped `{"days":1}` window SUM, not a
        // client-keyed slice of the 30-day series: the rollup's day keys are formatted in the gateway
        // host's timezone (`formatDayKey`), so a UTC key recomputed here would miss the bucket whenever
        // the gateway isn't on UTC. Fall back to 0 (not a stale daily entry) when that call is absent.
        let todayUSD = today?.totalCost ?? 0
        let todayTokens = today?.totalTokens ?? 0
        let last7USD = Self.windowCost(daily, trailingDays: 7)
        let last30USD = summary.totalCost ?? Self.windowCost(daily, trailingDays: 30)
        let last30Tokens = summary.totalTokens ?? daily.reduce(0) { $0 + ($1.totalTokens ?? 0) }

        let aggregates = sessions?.aggregates
        let byModel = aggregates?.byModel ?? []
        let byAgent = aggregates?.byAgent ?? []
        let modelMix = Self.modelMixDays(from: aggregates?.modelDaily ?? [])

        return CostReport(
            todayUSD: todayUSD,
            last7USD: last7USD,
            last30USD: last30USD,
            todayTokens: todayTokens,
            last30Tokens: last30Tokens,
            dailyTrend: trend,
            byModel: byModel,
            byAgent: byAgent,
            modelMixDays: modelMix,
            cacheStatus: sessions?.cacheStatus ?? Self.cacheStatus(from: summary))
    }

    /// Map decoded `usage.cost` daily entries to chart points, dropping any with an unparseable date.
    private static func trendPoints(from daily: [CostUsageDailyEntryLite]) -> [CostTrendPoint] {
        daily.compactMap { entry in
            guard let date = Self.date(from: entry.date) else { return nil }
            return CostTrendPoint(
                date: date,
                dayKey: entry.date,
                cost: entry.totalCost ?? 0,
                tokens: entry.totalTokens ?? 0)
        }
    }

    /// Sum the cost of entries inside the trailing `trailingDays` calendar-day window. The gateway's
    /// daily series is sparse — only days with usage appear, no zero-fill (`session-cost-usage.ts:558`)
    /// — so `suffix(n)` would count the last n *populated* days and reach further back than n calendar
    /// days when usage is scattered. Anchor the window on the newest day key present and keep entries
    /// whose date key is on/after the cutoff, comparing the gateway's own `YYYY-MM-DD` strings (which
    /// sort lexicographically by calendar date) so no client timezone is involved.
    private static func windowCost(_ daily: [CostUsageDailyEntryLite], trailingDays: Int) -> Double {
        guard trailingDays > 0, let newestKey = daily.last?.date,
              let anchor = Self.date(from: newestKey)
        else {
            return daily.reduce(0) { $0 + ($1.totalCost ?? 0) }
        }
        let cutoff = Self.dayKey(for: anchor.addingTimeInterval(-Double(trailingDays - 1) * 86_400))
        return daily
            .filter { $0.date >= cutoff }
            .reduce(0) { $0 + ($1.totalCost ?? 0) }
    }

    /// Derive model-mix days from the per-day-per-model series: a date with more than one distinct
    /// (provider, model) pair is treated as a model-mix / fallback day. The gateway emits no explicit
    /// fallback event, so this is a derived signal. Models within a day are ordered cost-desc so the
    /// transition label reads "top model → runner-up".
    private static func modelMixDays(from modelDaily: [DailyModelLite]) -> [ModelMixDay] {
        var byDay: [String: [DailyModelLite]] = [:]
        for entry in modelDaily {
            byDay[entry.date, default: []].append(entry)
        }
        var days: [ModelMixDay] = []
        for (dayKey, entries) in byDay {
            // Distinct model labels only; a single model running multiple times is not a mix.
            let labelled = entries
                .sorted { ($0.cost ?? 0) > ($1.cost ?? 0) }
                .compactMap { Self.modelLabel($0) }
            var seen = Set<String>()
            let distinct = labelled.filter { seen.insert($0).inserted }
            guard distinct.count > 1, let date = Self.date(from: dayKey) else { continue }
            days.append(ModelMixDay(dayKey: dayKey, date: date, models: distinct))
        }
        return days.sorted { $0.dayKey > $1.dayKey }
    }

    private static func modelLabel(_ entry: DailyModelLite) -> String? {
        let model = entry.model?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !model.isEmpty { return CostFormatting.shortModelLabel(model) }
        let provider = entry.provider?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return provider.isEmpty ? nil : provider
    }

    private static func cacheStatus(from summary: CostUsageSummaryLite) -> CostCacheStatusLite? {
        guard let raw = summary.cacheStatus else { return nil }
        return CostCacheStatusLite(
            status: raw["status"]?.value as? String,
            cachedFiles: AgentProValueReader.intValue(raw["cachedFiles"]),
            pendingFiles: AgentProValueReader.intValue(raw["pendingFiles"]),
            staleFiles: AgentProValueReader.intValue(raw["staleFiles"]),
            refreshedAt: AgentProValueReader.intValue(raw["refreshedAt"]))
    }

    // MARK: - Date helpers

    /// Parse a gateway `YYYY-MM-DD` day key into a fixed-UTC `Date` for chart plotting and for the
    /// trailing-window date arithmetic in `windowCost`. The formatter is UTC-fixed purely so parsing and
    /// reformatting a date *label* round-trips without DST/offset drift — it is not a claim about the
    /// gateway's bucketing timezone (which is the host's local zone via `formatDayKey`).
    private static func date(from dayKey: String) -> Date? {
        Self.dayFormatter.date(from: dayKey)
    }

    /// Format a `Date` back to a `YYYY-MM-DD` key on the same UTC-fixed basis as `date(from:)`, so day
    /// arithmetic on parsed keys stays self-consistent. Not used to derive "today" (that comes from a
    /// gateway-scoped window SUM, which is timezone-correct by construction).
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

    // MARK: - Connection gate (copied verbatim from AgentInboxViewModel)

    private func connected(appModel: NodeAppModel) -> Bool {
        guard !appModel.isLocalGatewayFixtureEnabled else { return false }
        guard appModel.isOperatorGatewayConnected else { return false }
        return GatewayStatusBuilder.build(appModel: appModel) == .connected
    }
}

/// Number / currency formatting for the Cost screen, replicated from `AgentProTab.currency` /
/// `.compactNumber` so the screen does not depend on `AgentProTab`. USD with 0–2 fraction digits;
/// compact token notation ("1.2M"). `shortModelLabel` mirrors `AgentProTab.shortModelLabel`.
enum CostFormatting {
    static func currency(_ value: Double) -> String {
        value.formatted(.currency(code: "USD").precision(.fractionLength(0...2)))
    }

    static func compactNumber(_ value: Int) -> String {
        value.formatted(.number.notation(.compactName))
    }

    static func shortModelLabel(_ model: String) -> String {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "default" }
        let leaf = trimmed.split(separator: "/").last.map(String.init) ?? trimmed
        return leaf
            .replacingOccurrences(of: "claude-", with: "")
            .replacingOccurrences(of: "gpt-", with: "")
    }

    /// Display label for a `ModelUsageLite` row: prefer the short model name, fall back to provider.
    static func label(for model: ModelUsageLite) -> String {
        if let name = model.model?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return self.shortModelLabel(name)
        }
        if let provider = model.provider?.trimmingCharacters(in: .whitespacesAndNewlines), !provider.isEmpty {
            return provider
        }
        return "unknown"
    }
}
