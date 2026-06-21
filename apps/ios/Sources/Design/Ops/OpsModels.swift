import Foundation
import OpenClawKit
import OpenClawProtocol
import SwiftUI

/// Lite decode mirrors for the RED / operational-health overview. The Ops screen reads four gateway
/// RPCs and folds them into one `RedReport`:
///
/// - `sessions.usage` → `OpsUsageResultLite` for the RED series Cost deliberately drops. Cost's
///   `SessionsUsageResultLite` / `AggregatesLite` (`Cost/CostModels.swift:82-87`) decode ONLY
///   `byModel` / `byProvider` / `byAgent` / `modelDaily`; they intentionally drop `aggregates.daily`,
///   `aggregates.latency`, `aggregates.dailyLatency`, and `aggregates.messages` — which are exactly the
///   RED signals (request rate, error count, turn latency). This sibling decodes those four buckets and
///   nothing else, so Cost's narrow decode is untouched.
/// - `usage.status` → `OpsProviderHealthLite` for provider auth / plan-quota health. No Swift decoder
///   existed for this RPC, so it is new here. Shape matches `UsageSummary` (`provider-usage.types.ts`).
/// - `cron.runs` → reuses `CronRunLogEntry` + `BriefRun` / `BriefStatusKind` (Briefs) verbatim for the
///   cron-failure rollup; no new model needed.
/// - `node.list` → `OpsNodeLite` for explicit offline-node rows (`connected == false` on a paired node).
///   `NodeListNode` (`node-list-types.ts`) had no Swift model; this decodes only the health fields.
///
/// REAL signals surfaced by these mirrors: request rate (daily messages + toolCalls), error count /
/// rate (daily + window errors), turn latency avg / p95 / min / max (window + per-day), cron failures,
/// provider auth errors + plan quota %, node online / offline state.
/// OMITTED (no gateway source): TTFT (does not exist anywhere in the protocol — `latency` is END-TO-END
/// turn duration, not time-to-first-token), and per-HOUR granularity (the only sub-day buckets are
/// per-session quarter-hour counts, never folded into `aggregates`, so every RED series here is PER-DAY).
/// All numeric fields route through `AgentProValueReader` because the gateway emits ints and doubles
/// interchangeably for counts / costs / latency.

// MARK: - sessions.usage (RED siblings)

/// Decode mirror of `SessionsUsageResult` (`src/shared/usage-types.ts:75-87`), narrowed to the RED
/// aggregates. A sibling of Cost's `SessionsUsageResultLite` — kept separate so the two decodes never
/// fight over which `aggregates.*` fields they keep.
struct OpsUsageResultLite: Decodable {
    let updatedAt: Int?
    let startDate: String?
    let endDate: String?
    let aggregates: OpsAggregatesLite?
}

/// Mirror of `SessionsUsageAggregates` (`usage-types.ts:54-73`), narrowed to the four RED buckets Cost
/// drops: the per-day rate/error series (`daily`), the window-wide latency summary (`latency`), the
/// per-day latency series (`dailyLatency`), and the window-wide message counts (`messages`).
struct OpsAggregatesLite: Decodable {
    let daily: [OpsDailyLite]?
    let latency: OpsLatencyLite?
    let dailyLatency: [OpsDailyLatencyLite]?
    let messages: OpsMessageCountsLite?
}

/// One `aggregates.daily[]` element (`usage-types.ts:65-72`): the request-rate + error series, per day.
/// `messages` = user+assistant message count for the day; `toolCalls` = tool invocations; `errors` =
/// tool-result errors plus assistant turns that ended in error/aborted/timeout. We treat
/// `messages + toolCalls` as the request-rate point so a tool-heavy day still registers volume.
struct OpsDailyLite: Decodable {
    let date: String
    let tokens: Int?
    let cost: Double?
    let messages: Int?
    let toolCalls: Int?
    let errors: Int?

    /// Hand-decode from a lenient `[String: Any]` element so a malformed numeric (int-vs-double) can't
    /// drop the row; mirrors the per-element rebuild Cost uses for its breakdown arrays.
    init(reading raw: [String: Any]) {
        self.date = raw["date"] as? String ?? ""
        self.tokens = AgentProValueReader.intValue(Self.wrap(raw["tokens"]))
        self.cost = AgentProValueReader.doubleValue(Self.wrap(raw["cost"]))
        self.messages = AgentProValueReader.intValue(Self.wrap(raw["messages"]))
        self.toolCalls = AgentProValueReader.intValue(Self.wrap(raw["toolCalls"]))
        self.errors = AgentProValueReader.intValue(Self.wrap(raw["errors"]))
    }

    private static func wrap(_ value: Any?) -> AnyCodable? {
        guard let value, !(value is NSNull) else { return nil }
        return AnyCodable(value)
    }
}

/// Mirror of `SessionLatencyStats` (`session-cost-usage.types.ts:117-123`): the window-wide turn-latency
/// summary, all in MILLISECONDS. `p95Ms` is the MAX of the per-session p95 (an approximation, not a true
/// recomputed percentile, per `usage-aggregates.ts:87-98`), so the UI labels it "p95" without
/// overclaiming. This is END-TO-END turn latency, NOT TTFT — TTFT has no gateway source.
struct OpsLatencyLite: Decodable {
    let count: Int?
    let avgMs: Double?
    let p95Ms: Double?
    let minMs: Double?
    let maxMs: Double?

    init(reading raw: [String: Any]) {
        self.count = AgentProValueReader.intValue(Self.wrap(raw["count"]))
        self.avgMs = AgentProValueReader.doubleValue(Self.wrap(raw["avgMs"]))
        self.p95Ms = AgentProValueReader.doubleValue(Self.wrap(raw["p95Ms"]))
        self.minMs = AgentProValueReader.doubleValue(Self.wrap(raw["minMs"]))
        self.maxMs = AgentProValueReader.doubleValue(Self.wrap(raw["maxMs"]))
    }

    private static func wrap(_ value: Any?) -> AnyCodable? {
        guard let value, !(value is NSNull) else { return nil }
        return AnyCodable(value)
    }
}

/// One `aggregates.dailyLatency[]` element (`SessionDailyLatency`, `session-cost-usage.types.ts:125-127`):
/// per-day turn latency, used as the latency sparkline. Same ms units / p95-approximation caveat as
/// `OpsLatencyLite`.
struct OpsDailyLatencyLite: Decodable {
    let date: String
    let count: Int?
    let avgMs: Double?
    let p95Ms: Double?
    let minMs: Double?
    let maxMs: Double?

    init(reading raw: [String: Any]) {
        self.date = raw["date"] as? String ?? ""
        self.count = AgentProValueReader.intValue(Self.wrap(raw["count"]))
        self.avgMs = AgentProValueReader.doubleValue(Self.wrap(raw["avgMs"]))
        self.p95Ms = AgentProValueReader.doubleValue(Self.wrap(raw["p95Ms"]))
        self.minMs = AgentProValueReader.doubleValue(Self.wrap(raw["minMs"]))
        self.maxMs = AgentProValueReader.doubleValue(Self.wrap(raw["maxMs"]))
    }

    private static func wrap(_ value: Any?) -> AnyCodable? {
        guard let value, !(value is NSNull) else { return nil }
        return AnyCodable(value)
    }
}

/// Mirror of `SessionMessageCounts` (`session-cost-usage.types.ts:138-145`): the window-wide grand
/// totals. `total` (user+assistant) backs the headline "requests in window" number AND is the error-rate
/// denominator: `errors / total` is the client-derived error rate (the gateway exposes no separate
/// error-rate field). `total` is used rather than `assistant` because `errors` counts tool-result errors
/// plus assistant error stop-reasons, which can exceed the assistant-turn count; the rate is clamped at
/// 100%. The per-day chart uses the same `errors / total` so tile and sparkline agree.
struct OpsMessageCountsLite: Decodable {
    let total: Int?
    let user: Int?
    let assistant: Int?
    let toolCalls: Int?
    let toolResults: Int?
    let errors: Int?

    init(reading raw: [String: Any]) {
        self.total = AgentProValueReader.intValue(Self.wrap(raw["total"]))
        self.user = AgentProValueReader.intValue(Self.wrap(raw["user"]))
        self.assistant = AgentProValueReader.intValue(Self.wrap(raw["assistant"]))
        self.toolCalls = AgentProValueReader.intValue(Self.wrap(raw["toolCalls"]))
        self.toolResults = AgentProValueReader.intValue(Self.wrap(raw["toolResults"]))
        self.errors = AgentProValueReader.intValue(Self.wrap(raw["errors"]))
    }

    private static func wrap(_ value: Any?) -> AnyCodable? {
        guard let value, !(value is NSNull) else { return nil }
        return AnyCodable(value)
    }
}

extension OpsUsageResultLite {
    /// Decode the `sessions.usage` object's RED aggregates. A plain `JSONDecoder` is attempted first;
    /// the lenient path rebuilds every array / object element from `JSONSerialization` so one malformed
    /// numeric (int-vs-double, missing field) can't blank the whole overview. Mirrors the lossy
    /// fast-path / lenient-rebuild pattern in `SessionsUsageResultLite.decode` (`Cost/CostModels.swift`).
    static func decode(from data: Data) -> OpsUsageResultLite? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let aggregatesRaw = root["aggregates"] as? [String: Any]
        let aggregates = OpsAggregatesLite(
            daily: Self.decodeDaily(aggregatesRaw?["daily"]),
            latency: Self.decodeLatency(aggregatesRaw?["latency"]),
            dailyLatency: Self.decodeDailyLatency(aggregatesRaw?["dailyLatency"]),
            messages: Self.decodeMessages(aggregatesRaw?["messages"]))
        return OpsUsageResultLite(
            updatedAt: root["updatedAt"] as? Int,
            startDate: root["startDate"] as? String,
            endDate: root["endDate"] as? String,
            aggregates: aggregates)
    }

    private static func decodeDaily(_ raw: Any?) -> [OpsDailyLite]? {
        guard let elements = raw as? [[String: Any]] else { return nil }
        return elements.map(OpsDailyLite.init(reading:)).filter { !$0.date.isEmpty }
    }

    private static func decodeDailyLatency(_ raw: Any?) -> [OpsDailyLatencyLite]? {
        guard let elements = raw as? [[String: Any]] else { return nil }
        return elements.map(OpsDailyLatencyLite.init(reading:)).filter { !$0.date.isEmpty }
    }

    private static func decodeLatency(_ raw: Any?) -> OpsLatencyLite? {
        guard let object = raw as? [String: Any] else { return nil }
        return OpsLatencyLite(reading: object)
    }

    private static func decodeMessages(_ raw: Any?) -> OpsMessageCountsLite? {
        guard let object = raw as? [String: Any] else { return nil }
        return OpsMessageCountsLite(reading: object)
    }
}

// MARK: - usage.status (provider health)

/// Decode mirror of `UsageSummary` (`usage.status` handler, `usage.ts:953-956` →
/// `loadProviderUsageSummary`; shape `provider-usage.types.ts:17-20`). No Swift decoder existed for this
/// RPC. UNHEALTHY for a provider = `error != nil` (auth / fetch failure) OR any window `usedPercent`
/// at/over the quota threshold (`OpsHealthThresholds.providerQuotaWarn`).
struct OpsProviderHealthLite: Decodable {
    let updatedAt: Int?
    let providers: [OpsProviderSnapshotLite]

    /// Lossy per-`providers[]`-element decode: parse the envelope, then rebuild each provider from a
    /// lenient `[String: Any]` so one malformed provider row can't drop the whole rollup.
    static func decode(from data: Data) -> OpsProviderHealthLite? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let providersRaw = (root["providers"] as? [[String: Any]]) ?? []
        let providers = providersRaw.map(OpsProviderSnapshotLite.init(reading:))
        return OpsProviderHealthLite(
            updatedAt: root["updatedAt"] as? Int,
            providers: providers)
    }
}

/// Mirror of `ProviderUsageSnapshot` (`provider-usage.types.ts:8-15`). `plan` is a display string;
/// `error` is a provider-level auth / fetch failure message; `windows` carry per-window quota usage.
struct OpsProviderSnapshotLite: Decodable, Identifiable {
    let provider: String
    let displayName: String?
    let plan: String?
    let error: String?
    let windows: [OpsUsageWindowLite]

    var id: String { self.provider }

    /// Display label: prefer the human `displayName`, fall back to the raw provider id.
    var name: String {
        let trimmed = self.displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? self.provider : trimmed
    }

    /// Highest `usedPercent` across all windows (0...100+), used to size the quota bar + decide the
    /// near-quota warning. 0 when the provider reports no windows.
    var worstUsedPercent: Double {
        self.windows.map(\.usedPercentValue).max() ?? 0
    }

    /// The window driving `worstUsedPercent`, for the quota-row caption (which window is closest to cap).
    var worstWindow: OpsUsageWindowLite? {
        self.windows.max { $0.usedPercentValue < $1.usedPercentValue }
    }

    init(reading raw: [String: Any]) {
        self.provider = (raw["provider"] as? String) ?? "unknown"
        self.displayName = raw["displayName"] as? String
        self.plan = raw["plan"] as? String
        self.error = (raw["error"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let windowsRaw = (raw["windows"] as? [[String: Any]]) ?? []
        self.windows = windowsRaw.map(OpsUsageWindowLite.init(reading:))
    }
}

/// Mirror of `UsageWindow` (`provider-usage.types.ts:1-6`): one quota window. `resetAt` is epoch ms.
struct OpsUsageWindowLite: Decodable, Identifiable {
    let label: String
    let usedPercent: Double?
    let resetAt: Int?

    var id: String { self.label }
    var usedPercentValue: Double { self.usedPercent ?? 0 }

    init(reading raw: [String: Any]) {
        self.label = (raw["label"] as? String) ?? "window"
        self.usedPercent = AgentProValueReader.doubleValue(Self.wrap(raw["usedPercent"]))
        self.resetAt = AgentProValueReader.intValue(Self.wrap(raw["resetAt"]))
    }

    private static func wrap(_ value: Any?) -> AnyCodable? {
        guard let value, !(value is NSNull) else { return nil }
        return AnyCodable(value)
    }
}

// MARK: - node.list (offline nodes)

/// Decode mirror of one `node.list` `nodes[]` element (`NodeListNode`, `node-list-types.ts:1-29`),
/// narrowed to the health fields. `node.list` had no Swift model; we keep only what the offline-node
/// rollup needs. UNHEALTHY = a paired node with `connected == false`. The presence-count "N online" still
/// comes from the already-wired `system-presence` (`[PresenceEntry]`); this adds the explicit per-node
/// offline rows.
struct OpsNodeLite: Decodable, Identifiable {
    let nodeId: String
    let displayName: String?
    let connected: Bool?
    let paired: Bool?
    let lastSeenAtMs: Int?

    var id: String { self.nodeId }

    /// Display label: prefer the human name, fall back to the node id.
    var name: String {
        let trimmed = self.displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? self.nodeId : trimmed
    }

    /// A paired node the gateway reports as disconnected — the only offline signal we surface. Unpaired /
    /// pending nodes are not "offline"; they were never expected to be holding a connection.
    var isOffline: Bool {
        self.paired == true && self.connected == false
    }

    init(reading raw: [String: Any]) {
        self.nodeId = (raw["nodeId"] as? String) ?? "node"
        self.displayName = raw["displayName"] as? String
        self.connected = raw["connected"] as? Bool
        self.paired = raw["paired"] as? Bool
        self.lastSeenAtMs = AgentProValueReader.intValue(Self.wrap(raw["lastSeenAtMs"]))
    }

    private static func wrap(_ value: Any?) -> AnyCodable? {
        guard let value, !(value is NSNull) else { return nil }
        return AnyCodable(value)
    }

    /// Lossy per-`nodes[]`-element decode of the `node.list` envelope (`{ts, nodes:[...]}`,
    /// `nodes.ts:980-1002`). One malformed node element can't blank the rollup.
    static func decodeList(from data: Data) -> [OpsNodeLite] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let nodesRaw = root["nodes"] as? [[String: Any]]
        else {
            return []
        }
        return nodesRaw.map(OpsNodeLite.init(reading:))
    }
}

// MARK: - Health issue (closed enum)

/// One "what needs attention" item. Closed so the view maps to a color / icon / row without re-inspecting
/// raw status strings. Severity maps to `OpenClawBrand.ok/warn/danger` exactly like `BriefStatusKind`.
enum OpsHealthIssue: Identifiable {
    case gatewayDegraded(status: String)
    case cronFailing(job: String, error: String?, date: Date)
    case providerDown(name: String, error: String)
    case providerQuota(name: String, usedPercent: Double, window: String?)
    case nodeOffline(name: String)

    var id: String {
        switch self {
        case let .gatewayDegraded(status): "gateway:\(status)"
        case let .cronFailing(job, _, date): "cron:\(job):\(date.timeIntervalSince1970)"
        case let .providerDown(name, _): "provider-down:\(name)"
        case let .providerQuota(name, _, window): "provider-quota:\(name):\(window ?? "")"
        case let .nodeOffline(name): "node:\(name)"
        }
    }

    /// Severity drives the row's status color, mirroring `BriefStatusKind.color`. Cron failures and a
    /// down provider / offline node are hard failures (danger); a near-quota provider and a degraded
    /// (connecting / attention) gateway are warnings (warn).
    var severity: OpsSeverity {
        switch self {
        case .gatewayDegraded: .warn
        case .cronFailing: .danger
        case .providerDown: .danger
        case .providerQuota: .warn
        case .nodeOffline: .danger
        }
    }

    var icon: String {
        switch self {
        case .gatewayDegraded: "wifi.exclamationmark"
        case .cronFailing: "exclamationmark.triangle.fill"
        case .providerDown: "key.slash.fill"
        case .providerQuota: "gauge.with.dots.needle.67percent"
        case .nodeOffline: "bolt.horizontal.circle.fill"
        }
    }

    var title: String {
        switch self {
        case .gatewayDegraded: "Gateway degraded"
        case let .cronFailing(job, _, _): job
        case let .providerDown(name, _): name
        case let .providerQuota(name, _, _): name
        case let .nodeOffline(name): name
        }
    }

    var detail: String {
        switch self {
        case let .gatewayDegraded(status):
            "Gateway is \(status.lowercased())"
        case let .cronFailing(_, error, _):
            error ?? "Scheduled job failed"
        case let .providerDown(_, error):
            error
        case let .providerQuota(_, usedPercent, window):
            if let window {
                "\(Int(usedPercent.rounded()))% of \(window) quota used"
            } else {
                "\(Int(usedPercent.rounded()))% of quota used"
            }
        case .nodeOffline:
            "Paired node is offline"
        }
    }

    /// Short pill value summarizing the issue's status, colored by severity in the row.
    var pillValue: String {
        switch self {
        case .gatewayDegraded: "degraded"
        case .cronFailing: "failed"
        case .providerDown: "auth"
        case let .providerQuota(_, usedPercent, _): "\(Int(usedPercent.rounded()))%"
        case .nodeOffline: "offline"
        }
    }
}

/// Closed severity → brand color, so issues / tiles share one mapping (mirrors `BriefStatusKind.color`).
enum OpsSeverity {
    case ok
    case warn
    case danger

    var color: Color {
        switch self {
        case .ok: OpenClawBrand.ok
        case .warn: OpenClawBrand.warn
        case .danger: OpenClawBrand.danger
        }
    }
}

/// Tunable thresholds for the derived RED health verdicts, kept in one place so the view model and the
/// screen agree. All are client-side derivations — the gateway exposes no error-rate or "at-risk" field.
enum OpsHealthThresholds {
    /// Error-rate (%) at/over which the error tile turns danger; the amber band starts at half this.
    static let errorRateDanger: Double = 10
    static let errorRateWarn: Double = 3
    /// Provider window quota (%) at/over which we raise a near-quota attention item + amber the bar.
    static let providerQuotaWarn: Double = 90
}

// MARK: - Derived RED report

/// One point on a per-day RED sparkline (requests/day or error-rate/day). PER-DAY only — the gateway
/// aggregates carry no sub-day granularity (quarter-hour buckets are per-session and never folded in).
struct OpsRatePoint: Identifiable {
    let date: Date
    let dayKey: String // YYYY-MM-DD
    let value: Double

    var id: String { self.dayKey }
}

/// One point on the per-day latency sparkline: avg + p95 turn duration (ms) for the day.
struct OpsLatencyPoint: Identifiable {
    let date: Date
    let dayKey: String // YYYY-MM-DD
    let avgMs: Double
    let p95Ms: Double

    var id: String { self.dayKey }
}

/// The fully assembled RED + health overview the screen renders.
///
/// RATE: `requests24h` / `requests7d` are window SUMS of `daily[].messages` (+ toolCalls) over the
/// newest 1 / 7 day keys; `requestsWindow` is the window-wide `messages.total`. DURATION: `avgMs` /
/// `p95Ms` from `aggregates.latency` (END-TO-END turn latency, ms; p95 is a max-of-session-p95
/// approximation). ERRORS: `errorRatePct` = `messages.errors / messages.total` (clamped at 100%), with
/// `errorRateTrendPct` the delta vs the prior comparable window (derived from `daily[]`). Series are the
/// per-day sparklines. `issues` rolls up cron failures + provider auth/quota + offline nodes + a degraded
/// gateway.
struct RedReport {
    let requests24h: Int
    let requests7d: Int
    let requestsWindow: Int
    let errorRatePct: Double
    let errorRateTrendPct: Double // signed delta vs prior window; >0 = worsening
    let errorsWindow: Int
    let latency: OpsLatencyLite?
    let requestsDaily: [OpsRatePoint]
    let errorRateDaily: [OpsRatePoint]
    let latencyDaily: [OpsLatencyPoint]
    let issues: [OpsHealthIssue]

    var hasLatency: Bool {
        guard let latency, (latency.count ?? 0) > 0 else { return false }
        return true
    }

    var avgMs: Double { self.latency?.avgMs ?? 0 }
    var p95Ms: Double { self.latency?.p95Ms ?? 0 }

    /// Count of issues that need attention, for the card badge + the screen's headline.
    var issueCount: Int { self.issues.count }

    /// Worst severity across the open issues, for the headline tint. `.ok` when nothing is wrong.
    var worstSeverity: OpsSeverity {
        if self.issues.contains(where: { $0.severity == .danger }) { return .danger }
        if self.issues.contains(where: { $0.severity == .warn }) { return .warn }
        return .ok
    }

    /// Error-rate severity for the RED error tile, by the shared thresholds.
    var errorSeverity: OpsSeverity {
        if self.errorRatePct >= OpsHealthThresholds.errorRateDanger { return .danger }
        if self.errorRatePct >= OpsHealthThresholds.errorRateWarn { return .warn }
        return .ok
    }

    /// True when the overview has any RED signal at all (some requests, some latency, or an open issue),
    /// so the screen can distinguish "healthy with traffic" from a genuinely empty account.
    var hasAnySignal: Bool {
        self.requestsWindow > 0
            || !self.requestsDaily.isEmpty
            || self.hasLatency
            || !self.issues.isEmpty
    }
}
