import Foundation
import OpenClawChatUI
import OpenClawKit
import OpenClawProtocol
import SwiftUI

/// Lite decode mirrors + view models for the Run Explorer (tool-call trace) surface.
///
/// Two RPCs back this screen, and the split is deliberate:
///
/// - `sessions.usage` → `SessionUsageEntryLite[]` drives the RUN LIST (one row per session). It carries
///   per-session ROLLUPS only — message/tool counts, aggregate latency, token/cost totals — never a
///   per-tool-call sequence. Cost's own `SessionsUsageResultLite` (`CostModels.swift:69`) intentionally
///   drops `sessions[]` to keep its decode narrow; rather than widen that shared type, this file adds a
///   sibling `SessionsRunListResultLite` that decodes only `sessions[]`, so the Cost dashboard's decode
///   contract stays exactly as-is.
/// - `chat.history` → the raw transcript, decoded into the public `OpenClawChatMessage[]` and flattened
///   into `[RunSpan]` (see `RunTimelineViewModel`). This is the ONLY RPC that exposes structured tool
///   args/results, per-turn token usage, stop reasons, and timestamps.
///
/// HONESTY: the transcript arrives as a FLAT projected array — `chat.history` does not expose the
/// on-disk `parentId` chain. So the timeline is an ORDERED sequence with a shallow 2-level grouping
/// (assistant turn → its tool calls/results), NOT an arbitrary-depth trace tree, and inter-message
/// timestamp deltas are wall-clock spacing, NOT measured per-tool latency. Every label here says so.

// MARK: - sessions.usage per-session rollups (run list)

/// Decode mirror of the `sessions[]` array on `SessionsUsageResult` (`src/shared/usage-types.ts:76-87`),
/// narrowed to the per-row fields the run list renders. Sibling to Cost's `SessionsUsageResultLite`,
/// which omits `sessions[]` on purpose; we keep that type untouched and decode the rows here instead.
struct SessionsRunListResultLite: Decodable {
    let updatedAt: Int?
    let sessions: [SessionUsageEntryLite]?
}

/// One run row, mirroring `SessionUsageEntry` (`src/shared/usage-types.ts:15-52`). Every field is
/// optional so a partial/older payload still decodes. `usage` is the per-session `SessionCostSummary`
/// rollup (null for sessions with no recorded activity).
struct SessionUsageEntryLite: Decodable, Identifiable {
    let key: String
    let label: String?
    let sessionId: String?
    let currentSessionId: String?
    let scope: String?
    let updatedAt: Int?
    let agentId: String?
    let channel: String?
    let chatType: String?
    let model: String?
    let modelProvider: String?
    let usage: SessionCostSummaryLite?

    /// Stable identity for `ForEach` and the detail push: the gateway's row key.
    var id: String { self.key }

    /// The session key `chat.history` should be fetched against. `chat.history` resolves its argument
    /// through `resolveSessionStoreKey` (session-store-key.ts:74), which has NO index by `sessionId`: a
    /// bare UUID does not parse as an agent key and gets canonicalized to `agent:<default>:<uuid>` (the
    /// wrong/missing store entry, yielding an empty transcript). So prefer the row `key` — already the
    /// resolvable canonical/discovered store key the gateway builds (usage.ts:1177 named, 1194 unnamed) —
    /// and only fall back to the id forms if a row ever lacks a key.
    var historySessionKey: String {
        let candidates = [self.key, self.currentSessionId, self.sessionId]
        for candidate in candidates {
            let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let trimmed, !trimmed.isEmpty { return trimmed }
        }
        return self.key
    }

    /// Human title for the row: prefer the gateway label, then the model, then the key tail.
    var displayTitle: String {
        let trimmedLabel = self.label?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedLabel, !trimmedLabel.isEmpty { return trimmedLabel }
        if let model = self.modelLabel { return model }
        return self.shortKey
    }

    /// Short model label (provider stripped, "claude-"/"gpt-" prefixes trimmed) for the row pill.
    var modelLabel: String? {
        let trimmed = self.model?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmed.isEmpty { return CostFormatting.shortModelLabel(trimmed) }
        let provider = self.modelProvider?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return provider.isEmpty ? nil : provider
    }

    /// Last segment of a `scope:agent:base:thread` key, for a compact fallback title.
    var shortKey: String {
        let trimmed = self.key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let tail = trimmed.split(separator: ":").last.map(String.init), !tail.isEmpty else {
            return trimmed.isEmpty ? "Session" : trimmed
        }
        return tail
    }

    /// Newest-activity timestamp (ms) for sorting and the relative-time caption. Prefer the usage
    /// rollup's `lastActivity`, then the row `updatedAt`.
    var lastActivityMs: Double? {
        if let last = self.usage?.lastActivity { return Double(last) }
        if let updated = self.updatedAt { return Double(updated) }
        return nil
    }

    var toolCallCount: Int { self.usage?.toolUsage?.totalCalls ?? 0 }
    var totalTokens: Int { self.usage?.totalTokens ?? 0 }
    var totalCost: Double { self.usage?.totalCost ?? 0 }
}

/// Mirror of `SessionCostSummary` (`session-cost-usage.types.ts:160-177`), narrowed to the rollup
/// fields the run row + run header read. `SessionCostSummary` extends `CostUsageTotals`, so `totalTokens`
/// / `totalCost` are top-level here, not nested under `totals`.
struct SessionCostSummaryLite: Decodable {
    let totalTokens: Int?
    let totalCost: Double?
    let firstActivity: Int?
    let lastActivity: Int?
    let durationMs: Int?
    let messageCounts: SessionMessageCountsLite?
    let toolUsage: SessionToolUsageLite?
    let latency: SessionLatencyStatsLite?
}

/// Mirror of `SessionMessageCounts` (`session-cost-usage.types.ts:138-145`).
struct SessionMessageCountsLite: Decodable {
    let total: Int?
    let user: Int?
    let assistant: Int?
    let toolCalls: Int?
    let toolResults: Int?
    let errors: Int?
}

/// Mirror of `SessionToolUsage` (`session-cost-usage.types.ts:147-151`).
struct SessionToolUsageLite: Decodable {
    let totalCalls: Int?
    let uniqueTools: Int?
    let tools: [SessionToolCountLite]?
}

struct SessionToolCountLite: Decodable {
    let name: String?
    let count: Int?
}

/// Mirror of `SessionLatencyStats` (`session-cost-usage.types.ts:117-123`). These are per-MODEL-CALL
/// latency samples, not per-tool-call timings — labeled "model latency" everywhere it surfaces.
struct SessionLatencyStatsLite: Decodable {
    let count: Int?
    let avgMs: Double?
    let p95Ms: Double?
    let minMs: Double?
    let maxMs: Double?
}

extension SessionsRunListResultLite {
    /// Decode the `sessions.usage` object, then re-decode `sessions[]` per-element so one malformed row
    /// can't blank the whole list. Mirrors `SessionsUsageResultLite.decode` (`CostModels.swift:154`):
    /// fast whole-object path first, then a lenient `JSONSerialization` split that rebuilds the array
    /// element-by-element. We never decode a bare `[AnyCodable]` (that path is both lossy-unfriendly and
    /// a known Swift type-inference hazard on the top-level metatype).
    static func decode(from data: Data) -> SessionsRunListResultLite? {
        let decoder = JSONDecoder()
        if let direct = try? decoder.decode(SessionsRunListResultLite.self, from: data) {
            return direct
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return SessionsRunListResultLite(
            updatedAt: root["updatedAt"] as? Int,
            sessions: Self.decodeEntryList(root["sessions"]))
    }

    private static func decodeEntryList(_ raw: Any?) -> [SessionUsageEntryLite]? {
        guard let elements = raw as? [Any] else { return nil }
        let decoder = JSONDecoder()
        var out: [SessionUsageEntryLite] = []
        out.reserveCapacity(elements.count)
        for element in elements {
            guard JSONSerialization.isValidJSONObject(element),
                  let elementData = try? JSONSerialization.data(withJSONObject: element),
                  let decoded = try? decoder.decode(SessionUsageEntryLite.self, from: elementData)
            else {
                continue
            }
            out.append(decoded)
        }
        return out
    }
}

// MARK: - Run rows (derived list shape)

/// One row in the run list, derived from a `SessionUsageEntryLite`. Carries the small set of strings the
/// row renders plus the `historySessionKey` the detail screen fetches `chat.history` against.
struct RunRow: Identifiable, Equatable {
    let id: String
    let historySessionKey: String
    let title: String
    let modelLabel: String?
    let toolCallCount: Int
    let totalTokens: Int
    /// Run cost from the `sessions.usage` rollup (`SessionCostSummaryLite.totalCost`). chat.history emits
    /// per-message `cost` as a top-level sibling of `usage` that the decoded `OpenClawChatMessage` drops,
    /// so the rollup is the faithful run-cost source the header reads.
    let totalCost: Double
    let avgLatencyMs: Double?
    let lastActivityMs: Double?

    /// "N tool calls • M tokens • avg 1.2s model latency" — the row subtitle, built from the usage
    /// rollups. Latency is explicitly labeled "model latency" (it is per-model-call, not per-tool).
    var subtitle: String {
        var parts: [String] = []
        let callNoun = self.toolCallCount == 1 ? "tool call" : "tool calls"
        parts.append("\(self.toolCallCount) \(callNoun)")
        if self.totalTokens > 0 {
            parts.append("\(CostFormatting.compactNumber(self.totalTokens)) tokens")
        }
        if let avg = self.avgLatencyMs, avg > 0 {
            parts.append("avg \(TraceFormatting.duration(ms: avg)) model latency")
        }
        return parts.joined(separator: " • ")
    }

    /// Relative-time caption ("2h ago") for the trailing slot, or nil when no timestamp is known.
    var relativeActivity: String? {
        guard let ms = self.lastActivityMs, ms > 0 else { return nil }
        return TraceFormatting.relativeTime(forMilliseconds: ms)
    }

    init(entry: SessionUsageEntryLite) {
        self.id = entry.id
        self.historySessionKey = entry.historySessionKey
        self.title = entry.displayTitle
        self.modelLabel = entry.modelLabel
        self.toolCallCount = entry.toolCallCount
        self.totalTokens = entry.totalTokens
        self.totalCost = entry.totalCost
        self.avgLatencyMs = entry.usage?.latency?.avgMs
        self.lastActivityMs = entry.lastActivityMs
    }
}

// MARK: - Run spans (timeline shape)

/// One ordered step in a run's transcript. Produced from the public `OpenClawChatMessage[]` in
/// transcript order — a faithful timeline, since transcript order is real. The kinds mirror the chat
/// UI's own classification (`ChatMessageBody.toolCalls`/`inlineToolResults`, `ChatMessageViews.swift:341-356`),
/// re-implemented here over the PUBLIC content fields because those classifiers are `private`.
struct RunSpan: Identifiable {
    enum Kind {
        case userMessage(text: String)
        case assistantText(text: String)
        case toolCall(name: String, arguments: AnyCodable?, callId: String?)
        case toolResult(content: AnyCodable?, text: String?, callId: String?, isError: Bool)
        case error(message: String)
    }

    let id: String
    let kind: Kind
    /// Index of the parent assistant turn this span belongs to (turns start at a user/assistant message;
    /// tool calls/results inherit the most recent assistant turn). Drives the 2-level grouping.
    let turnIndex: Int
    let timestampMs: Double?
    let usage: OpenClawChatUsage?

    /// The tool-call id captured on this call/result span, when present. The timeline groups and renders
    /// strictly by `turnIndex` in transcript order — it does NOT pair results back to calls by this id —
    /// so this is exposed only as carried metadata, not a rendering key.
    var pairingCallId: String? {
        switch self.kind {
        case let .toolCall(_, _, callId): callId
        case let .toolResult(_, _, callId, _): callId
        default: nil
        }
    }

    var isToolCall: Bool {
        if case .toolCall = self.kind { return true }
        return false
    }

    var isError: Bool {
        switch self.kind {
        case .error: true
        case let .toolResult(_, _, _, isError): isError
        default: false
        }
    }
}

/// A 2-level group: one assistant turn (the parent) and the ordered spans that belong to it (its text,
/// its tool calls, and the tool results paired to those calls). This is the natural grouping the chat UI
/// already uses (one tool-trace bubble per assistant turn); it is NOT a deeper tree.
struct TurnGroup: Identifiable {
    let id: Int
    let spans: [RunSpan]

    /// Wall-clock start of the turn (first span timestamp), for the timeline rail label.
    var startMs: Double? {
        self.spans.compactMap(\.timestampMs).min()
    }

    /// True when any span in the turn is an error, so the group can tint its rail.
    var hasError: Bool {
        self.spans.contains(where: \.isError)
    }

    /// Summed per-turn token usage across assistant messages in this turn (each assistant message
    /// carries its own `usage`). Used for the turn header pill.
    var turnTokens: Int {
        self.spans.reduce(0) { running, span in
            running + (span.usage?.total ?? 0)
        }
    }
}

/// The fully assembled run-detail payload: the ordered span list, its turn grouping, the header rollup,
/// and an optional cumulative token/cost rail from `sessions.usage.timeseries`.
struct RunDetail {
    let sessionKey: String
    let title: String
    let spans: [RunSpan]
    let turns: [TurnGroup]
    let header: RunHeaderSummary
    let timeseries: [RunTimePoint]

    var hasSpans: Bool { !self.spans.isEmpty }
}

/// Header rollup for the run-detail screen. Tokens, tool-call count, duration, and the error flag are
/// derived from the transcript (authoritative for this run); `totalCost` is carried from the run row's
/// `sessions.usage` rollup (chat.history drops per-message cost), and model/title are carried too.
struct RunHeaderSummary {
    let title: String
    let modelLabel: String?
    let totalTokens: Int
    let totalCost: Double
    let toolCallCount: Int
    let messageCount: Int
    let durationMs: Double?
    let hasError: Bool
}

/// One point on the optional cumulative token/cost rail, mirroring `SessionUsageTimePoint`
/// (`src/shared/session-usage-timeseries-types.ts:2-21`). These are per-model-call usage samples, NOT
/// tool spans — surfaced only as a secondary header chart.
struct RunTimePoint: Identifiable, Decodable {
    let timestamp: Double
    let totalTokens: Double?
    let cost: Double?
    let cumulativeTokens: Double?
    let cumulativeCost: Double?

    var id: Double { self.timestamp }
}

/// Decode mirror of `SessionUsageTimeSeries` (`session-usage-timeseries-types.ts:23+`): `{ points: [] }`.
struct RunTimeSeriesLite: Decodable {
    let points: [RunTimePoint]?

    /// Per-element decode of `points[]` so one malformed sample can't fail the (optional) rail.
    static func decode(from data: Data) -> RunTimeSeriesLite? {
        let decoder = JSONDecoder()
        if let direct = try? decoder.decode(RunTimeSeriesLite.self, from: data) {
            return direct
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawPoints = root["points"] as? [Any]
        else {
            return nil
        }
        var out: [RunTimePoint] = []
        out.reserveCapacity(rawPoints.count)
        for element in rawPoints {
            guard JSONSerialization.isValidJSONObject(element),
                  let elementData = try? JSONSerialization.data(withJSONObject: element),
                  let decoded = try? decoder.decode(RunTimePoint.self, from: elementData)
            else {
                continue
            }
            out.append(decoded)
        }
        return RunTimeSeriesLite(points: out)
    }
}

// MARK: - Span builder (classify + order)

/// Flattens a decoded `OpenClawChatMessage[]` (transcript order) into an ordered `[RunSpan]` and the
/// 2-level `TurnGroup` grouping. Mirrors the chat UI's block classification (which lives in `private`
/// types in `OpenClawChatUI`), re-implemented over the PUBLIC `OpenClawChatMessage` /
/// `OpenClawChatMessageContent` fields. Grouping is by `turnIndex` in transcript order only — results are
/// NOT paired back to calls by id. Pure logic, no view dependency.
enum RunSpanBuilder {
    /// Content `type` values that mark a tool-call block, matching `ChatMessageBody.toolCalls`.
    private static let toolCallTypes: Set<String> = ["toolcall", "tool_call", "tooluse", "tool_use"]
    /// Content `type` values that mark a tool-result block, matching `ChatMessageBody.inlineToolResults`.
    private static let toolResultTypes: Set<String> = ["toolresult", "tool_result"]

    /// True when a content block is a tool call: an explicit tool-call type, OR a name+arguments pair
    /// (the chat UI's same fallback for blocks that omit `type`).
    private static func isToolCallBlock(_ block: OpenClawChatMessageContent) -> Bool {
        let kind = (block.type ?? "").lowercased()
        if self.toolCallTypes.contains(kind) { return true }
        return block.name != nil && block.arguments != nil
    }

    private static func isToolResultBlock(_ block: OpenClawChatMessageContent) -> Bool {
        let kind = (block.type ?? "").lowercased()
        return self.toolResultTypes.contains(kind)
    }

    /// Build the ordered span list. Each top-level message advances the turn index when it starts a new
    /// user/assistant turn; tool-result messages (role `toolResult`) inherit the current turn so a
    /// result groups with the assistant turn that called it.
    static func spans(from messages: [OpenClawChatMessage]) -> [RunSpan] {
        var spans: [RunSpan] = []
        var turnIndex = -1
        var spanCounter = 0

        for message in messages {
            let role = message.role.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let startsNewTurn = role == "user" || role == "assistant"
            if startsNewTurn {
                turnIndex += 1
            }
            let effectiveTurn = max(turnIndex, 0)

            switch role {
            case "user":
                Self.appendUserSpans(
                    message: message,
                    turn: effectiveTurn,
                    counter: &spanCounter,
                    into: &spans)
            case "assistant":
                Self.appendAssistantSpans(
                    message: message,
                    turn: effectiveTurn,
                    counter: &spanCounter,
                    into: &spans)
            case "toolresult", "tool_result", "tool":
                Self.appendResultMessageSpan(
                    message: message,
                    turn: effectiveTurn,
                    counter: &spanCounter,
                    into: &spans)
            default:
                continue
            }
        }
        return spans
    }

    /// Group the ordered spans by their `turnIndex` into `TurnGroup`s, preserving order.
    static func turns(from spans: [RunSpan]) -> [TurnGroup] {
        var byTurn: [Int: [RunSpan]] = [:]
        var order: [Int] = []
        for span in spans {
            if byTurn[span.turnIndex] == nil { order.append(span.turnIndex) }
            byTurn[span.turnIndex, default: []].append(span)
        }
        return order.map { TurnGroup(id: $0, spans: byTurn[$0] ?? []) }
    }

    private static func appendUserSpans(
        message: OpenClawChatMessage,
        turn: Int,
        counter: inout Int,
        into spans: inout [RunSpan])
    {
        let text = Self.joinedText(message.content)
        guard !text.isEmpty else { return }
        spans.append(RunSpan(
            id: "span-\(counter)",
            kind: .userMessage(text: text),
            turnIndex: turn,
            timestampMs: message.timestamp,
            usage: nil))
        counter += 1
    }

    private static func appendAssistantSpans(
        message: OpenClawChatMessage,
        turn: Int,
        counter: inout Int,
        into spans: inout [RunSpan])
    {
        // Error turn: surface the gateway's error text as its own span and skip the rest.
        if let errorText = OpenClawChatMessageErrorText.text(for: message) {
            spans.append(RunSpan(
                id: "span-\(counter)",
                kind: .error(message: errorText),
                turnIndex: turn,
                timestampMs: message.timestamp,
                usage: message.usage))
            counter += 1
            return
        }

        let text = Self.joinedAssistantText(message.content)
        if !text.isEmpty {
            spans.append(RunSpan(
                id: "span-\(counter)",
                kind: .assistantText(text: text),
                turnIndex: turn,
                timestampMs: message.timestamp,
                usage: message.usage))
            counter += 1
        }

        // Tool calls in this assistant turn, in block order.
        for block in message.content where Self.isToolCallBlock(block) {
            let name = block.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "tool"
            spans.append(RunSpan(
                id: "span-\(counter)",
                kind: .toolCall(name: name, arguments: block.arguments, callId: block.id),
                turnIndex: turn,
                timestampMs: message.timestamp,
                usage: nil))
            counter += 1
        }

        // Inline tool-result blocks carried on the same assistant message (some transcript formats).
        for block in message.content where Self.isToolResultBlock(block) {
            spans.append(Self.resultSpan(
                from: block,
                callId: block.id,
                turn: turn,
                timestampMs: message.timestamp,
                counter: &counter))
        }
    }

    private static func appendResultMessageSpan(
        message: OpenClawChatMessage,
        turn: Int,
        counter: inout Int,
        into spans: inout [RunSpan])
    {
        // A `toolResult`-role message: the structured result is on its first content block; the call id
        // is the message-level `toolCallId` (or the block id), matching the chat UI's merge contract.
        let block = message.content.first
        let callId = message.toolCallId ?? block?.id
        let isError = (message.stopReason?.lowercased() == "error")
            || ((block?.type ?? "").lowercased().contains("error"))
        let text = Self.joinedText(message.content)
        spans.append(RunSpan(
            id: "span-\(counter)",
            kind: .toolResult(content: block?.content, text: text.isEmpty ? nil : text, callId: callId, isError: isError),
            turnIndex: turn,
            timestampMs: message.timestamp,
            usage: nil))
        counter += 1
    }

    private static func resultSpan(
        from block: OpenClawChatMessageContent,
        callId: String?,
        turn: Int,
        timestampMs: Double?,
        counter: inout Int) -> RunSpan
    {
        let isError = (block.type ?? "").lowercased().contains("error")
        let text = block.text?.trimmingCharacters(in: .whitespacesAndNewlines)
        let span = RunSpan(
            id: "span-\(counter)",
            kind: .toolResult(
                content: block.content,
                text: (text?.isEmpty ?? true) ? nil : text,
                callId: callId,
                isError: isError),
            turnIndex: turn,
            timestampMs: timestampMs,
            usage: nil)
        counter += 1
        return span
    }

    /// Concatenate the plain `text` blocks of a message (skipping tool/thinking blocks) for a user span.
    private static func joinedText(_ content: [OpenClawChatMessageContent]) -> String {
        content
            .compactMap { block -> String? in
                let trimmed = block.text?.trimmingCharacters(in: .whitespacesAndNewlines)
                return (trimmed?.isEmpty ?? true) ? nil : trimmed
            }
            .joined(separator: "\n\n")
    }

    /// Assistant text only — same as `joinedText` but explicit about intent (thinking blocks have no
    /// `text`, tool blocks are handled separately, so a plain-text filter suffices).
    private static func joinedAssistantText(_ content: [OpenClawChatMessageContent]) -> String {
        content
            .filter { !Self.isToolCallBlock($0) && !Self.isToolResultBlock($0) }
            .compactMap { block -> String? in
                let trimmed = block.text?.trimmingCharacters(in: .whitespacesAndNewlines)
                return (trimmed?.isEmpty ?? true) ? nil : trimmed
            }
            .joined(separator: "\n\n")
    }
}

/// Bridges to the public error-display contract on `OpenClawChatMessage`. The static `errorDisplayText`
/// helper is internal to `OpenClawChatUI`, so we re-derive the same rule (assistant role + `error`
/// stop reason + non-empty `errorMessage`) over the PUBLIC fields.
enum OpenClawChatMessageErrorText {
    static func text(for message: OpenClawChatMessage) -> String? {
        let role = message.role.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let stop = message.stopReason?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard role == "assistant", stop == "error" else { return nil }
        let text = message.errorMessage?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let text, !text.isEmpty else { return nil }
        return text
    }
}
