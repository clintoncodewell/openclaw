import Foundation
import OpenClawKit
import OpenClawProtocol
import SwiftUI

/// Lite decode mirrors for the gateway cost/usage RPCs the Cost dashboard reads:
///
/// - `usage.cost` → `CostUsageSummaryLite` (defined in `AgentProModels.swift`, reused here) for the
///   per-day trend + grand totals. We only extend it with `CostUsageTotalsLite` so the screen can read
///   the full token/cost breakdown the existing two computed fields don't expose.
/// - `sessions.usage` → `SessionsUsageResultLite` for the per-model / per-agent / per-day-per-model
///   aggregates `usage.cost` does not return.
///
/// Both responses are JSON *objects*, so a plain `JSONDecoder` is safe — there is no bare top-level
/// array to split (unlike `exec.approval.list`). The only lossy split we apply is per-element on the
/// `aggregates.byModel` / `byAgent` arrays, mirroring `InboxApproval.decodeList`, so one malformed
/// breakdown row can never blank the whole screen. All numeric fields are coerced through
/// `AgentProValueReader` because the gateway emits ints and doubles interchangeably for token counts.

// MARK: - Totals

/// Full `CostUsageTotals` mirror (`src/infra/session-cost-usage.types.ts:40-53`). `totalCost` and the
/// per-bucket `*Cost` fields are USD dollars, not cents. Every field is optional so a partial payload
/// (older gateway, missing cost data) still decodes; readers default to 0 via the computed helpers.
struct CostUsageTotalsLite: Decodable {
    let input: Int?
    let output: Int?
    let cacheRead: Int?
    let cacheWrite: Int?
    let totalTokens: Int?
    let totalCost: Double?
    let inputCost: Double?
    let outputCost: Double?
    let cacheReadCost: Double?
    let cacheWriteCost: Double?
    let missingCostEntries: Int?

    /// Tokens read off cache vs. fresh input, used by the cache-efficiency caption on the screen.
    var totalTokensValue: Int { self.totalTokens ?? 0 }
    var totalCostValue: Double { self.totalCost ?? 0 }
    var cacheReadValue: Int { self.cacheRead ?? 0 }
    var cacheWriteValue: Int { self.cacheWrite ?? 0 }
    var inputValue: Int { self.input ?? 0 }
    var outputValue: Int { self.output ?? 0 }

    /// The gateway emits ints/doubles/strings interchangeably for token counts; route every field
    /// through `AgentProValueReader` rather than trusting the static `Decodable` synthesis. Used when
    /// we hand-decode a `[String: AnyCodable]` totals blob (e.g. from `CostUsageSummaryLite.totals`).
    init(reading totals: [String: AnyCodable]?) {
        self.input = AgentProValueReader.intValue(totals?["input"])
        self.output = AgentProValueReader.intValue(totals?["output"])
        self.cacheRead = AgentProValueReader.intValue(totals?["cacheRead"])
        self.cacheWrite = AgentProValueReader.intValue(totals?["cacheWrite"])
        self.totalTokens = AgentProValueReader.intValue(totals?["totalTokens"])
        self.totalCost = AgentProValueReader.doubleValue(totals?["totalCost"])
        self.inputCost = AgentProValueReader.doubleValue(totals?["inputCost"])
        self.outputCost = AgentProValueReader.doubleValue(totals?["outputCost"])
        self.cacheReadCost = AgentProValueReader.doubleValue(totals?["cacheReadCost"])
        self.cacheWriteCost = AgentProValueReader.doubleValue(totals?["cacheWriteCost"])
        self.missingCostEntries = AgentProValueReader.intValue(totals?["missingCostEntries"])
    }
}

// MARK: - sessions.usage

/// Decode mirror of `SessionsUsageResult` (`src/shared/usage-types.ts:75-87`). We only keep the
/// aggregate buckets the dashboard renders; `sessions[]`, `messages`, `tools`, and latency series are
/// intentionally dropped to keep the decode narrow.
struct SessionsUsageResultLite: Decodable {
    let updatedAt: Int?
    let startDate: String?
    let endDate: String?
    let totals: CostUsageTotalsLite?
    let aggregates: AggregatesLite?
    let cacheStatus: CostCacheStatusLite?
}

/// Mirror of `SessionsUsageAggregates` (`src/shared/usage-types.ts:54-74`), narrowed to the buckets the
/// screen uses: per-model, per-provider, per-agent, and the per-day-per-model series that drives the
/// derived model-mix days. The dashboard's daily trend comes from `usage.cost`'s own daily series, so
/// `aggregates.daily` is intentionally not decoded here.
struct AggregatesLite: Decodable {
    let byModel: [ModelUsageLite]?
    let byProvider: [ModelUsageLite]?
    let byAgent: [AgentTotalsLite]?
    let modelDaily: [DailyModelLite]?
}

/// Mirror of `SessionModelUsage` (`session-cost-usage.types.ts:153-158`). Arrives already sorted by
/// `totals.totalCost` desc from the gateway (`usage.ts:1593-1606`), so the screen renders in order.
struct ModelUsageLite: Decodable, Identifiable {
    let provider: String?
    let model: String?
    let count: Int?
    let totals: CostUsageTotalsLite?

    /// Stable identity for `ForEach`: provider+model is unique within a single aggregate list.
    var id: String { "\(self.provider ?? "?")/\(self.model ?? "?")" }

    var costValue: Double { self.totals?.totalCostValue ?? 0 }
    var tokensValue: Int { self.totals?.totalTokensValue ?? 0 }
    var callCount: Int { self.count ?? 0 }
}

/// Mirror of one `aggregates.byAgent` element (`{ agentId, totals }`, `usage-types.ts:60`). Sorted by
/// `totalCost` desc from the gateway (`usage.ts:1607-1609`).
struct AgentTotalsLite: Decodable, Identifiable {
    let agentId: String?
    let totals: CostUsageTotalsLite?

    var id: String { self.agentId ?? UUID().uuidString }
    var costValue: Double { self.totals?.totalCostValue ?? 0 }
    var tokensValue: Int { self.totals?.totalTokensValue ?? 0 }
}

/// Mirror of `SessionDailyModelUsage` (`session-cost-usage.types.ts:129-136`): one (date, model) usage
/// point. The model-fallback / model-mix signal is *derived* from these rows — the gateway emits no
/// explicit fallback event, so when more than one distinct (provider, model) appears on the same date
/// we treat that day as a model-mix day.
struct DailyModelLite: Decodable {
    let date: String
    let provider: String?
    let model: String?
    let tokens: Int?
    let cost: Double?
    let count: Int?
}

/// Mirror of `CostUsageSummary.cacheStatus` (`session-cost-usage.types.ts:64-70`). Surfaced as a small
/// freshness caption so the user knows when totals are still warming up after a cold start.
struct CostCacheStatusLite: Decodable {
    let status: String?
    let cachedFiles: Int?
    let pendingFiles: Int?
    let staleFiles: Int?
    let refreshedAt: Int?

    /// True while the gateway is still hydrating its usage cache, so the screen can show a "refreshing"
    /// hint instead of implying the (possibly low) numbers are final.
    var isSettling: Bool {
        switch self.status {
        case "refreshing", "stale", "partial": true
        default: (self.pendingFiles ?? 0) > 0
        }
    }
}

extension SessionsUsageResultLite {
    /// Decode the `sessions.usage` object, then re-decode `aggregates.byModel` / `byProvider` /
    /// `byAgent` / `modelDaily` per-element so one malformed breakdown row can't fail the whole
    /// response. The split mirrors `InboxApproval.decodeList`: pull the raw arrays out with
    /// `JSONSerialization`, then decode each element on its own. A plain decode of the top-level object
    /// is attempted first; the lenient pass only repairs the array fields if they were lossy.
    static func decode(from data: Data) -> SessionsUsageResultLite? {
        let decoder = JSONDecoder()
        // Fast path: the whole object decodes cleanly (the common case).
        if let direct = try? decoder.decode(SessionsUsageResultLite.self, from: data) {
            return direct
        }
        // Lenient path: rebuild the aggregate arrays element-by-element so a single bad row survives.
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let aggregatesRaw = root["aggregates"] as? [String: Any]
        let aggregates = AggregatesLite(
            byModel: Self.decodeModelList(aggregatesRaw?["byModel"]),
            byProvider: Self.decodeModelList(aggregatesRaw?["byProvider"]),
            byAgent: Self.decodeAgentList(aggregatesRaw?["byAgent"]),
            modelDaily: Self.decodeList(DailyModelLite.self, aggregatesRaw?["modelDaily"]))
        return SessionsUsageResultLite(
            updatedAt: root["updatedAt"] as? Int,
            startDate: root["startDate"] as? String,
            endDate: root["endDate"] as? String,
            totals: Self.decodeObject(CostUsageTotalsLite.self, root["totals"]),
            aggregates: aggregates,
            cacheStatus: Self.decodeObject(CostCacheStatusLite.self, root["cacheStatus"]))
    }

    private static func decodeModelList(_ raw: Any?) -> [ModelUsageLite]? {
        Self.decodeList(ModelUsageLite.self, raw)
    }

    private static func decodeAgentList(_ raw: Any?) -> [AgentTotalsLite]? {
        Self.decodeList(AgentTotalsLite.self, raw)
    }

    /// Per-element lossy decode of a JSON array into `[T]`, dropping any element that won't decode.
    private static func decodeList<T: Decodable>(_ type: T.Type, _ raw: Any?) -> [T]? {
        guard let elements = raw as? [Any] else { return nil }
        let decoder = JSONDecoder()
        var out: [T] = []
        out.reserveCapacity(elements.count)
        for element in elements {
            guard JSONSerialization.isValidJSONObject(element),
                  let elementData = try? JSONSerialization.data(withJSONObject: element),
                  let decoded = try? decoder.decode(T.self, from: elementData)
            else {
                continue
            }
            out.append(decoded)
        }
        return out
    }

    /// Decode a single nested JSON object into `T`, or `nil` if absent / malformed.
    private static func decodeObject<T: Decodable>(_ type: T.Type, _ raw: Any?) -> T? {
        guard JSONSerialization.isValidJSONObject(raw ?? NSNull()),
              let objectData = try? JSONSerialization.data(withJSONObject: raw as Any)
        else {
            return nil
        }
        return try? JSONDecoder().decode(T.self, from: objectData)
    }
}

// MARK: - Derived report shapes

/// One point on the daily-cost trend chart.
struct CostTrendPoint: Identifiable {
    let date: Date
    let dayKey: String // YYYY-MM-DD
    let cost: Double
    let tokens: Int

    var id: String { self.dayKey }
}

/// A derived model-mix day: more than one distinct (provider, model) ran on the same date, which we
/// surface as the closest available "fallback" signal. The gateway emits no explicit fallback event,
/// so this is a derived heuristic, not a server-confirmed switch.
struct ModelMixDay: Identifiable {
    let dayKey: String // YYYY-MM-DD
    let date: Date
    let models: [String] // short model labels, cost-desc

    var id: String { self.dayKey }

    /// "claude-x → gpt-y" style label: the day's top model, then the runner-up it mixed with.
    var transitionLabel: String {
        guard let primary = self.models.first else { return "Model mix" }
        guard self.models.count > 1 else { return primary }
        return "\(primary) → \(self.models[1])"
    }

    var detail: String {
        let count = self.models.count
        return "\(count) models ran this day"
    }
}

/// The fully assembled dashboard payload the screen renders. Combines the `usage.cost` 30-day summary
/// (top totals + trend) with the `sessions.usage` aggregates (per-model, per-agent, model-mix). The
/// today / 7d / 30d window totals each come from their OWN gateway-scoped `usage.cost` window sum
/// (`{"days":N,"mode":"gateway"}`), not a client-side slice of the sparse `daily` series — the series
/// has no zero-fill, so slicing it drifts whenever recent days have no spend. `todayUSD`/`todayTokens`
/// are optional: a failed today call leaves them `nil` ("unavailable") rather than a false `0` that
/// would silently clear an over-budget banner.
struct CostReport {
    let todayUSD: Double?
    let last7USD: Double
    let last30USD: Double
    let todayTokens: Int?
    let last7Tokens: Int
    let last30Tokens: Int
    let dailyTrend: [CostTrendPoint]
    let byModel: [ModelUsageLite]
    let byAgent: [AgentTotalsLite]
    let modelMixDays: [ModelMixDay]
    let cacheStatus: CostCacheStatusLite?

    var hasModelBreakdown: Bool { !self.byModel.isEmpty }
    var hasAgentBreakdown: Bool { !self.byAgent.isEmpty }

    /// Grand total cost across the per-model breakdown, used to size each model's share bar.
    var modelGrandCost: Double {
        self.byModel.reduce(0) { $0 + $1.costValue }
    }

    /// Grand total cost across the per-agent breakdown, used to size each agent's share bar.
    var agentGrandCost: Double {
        self.byAgent.reduce(0) { $0 + $1.costValue }
    }
}
