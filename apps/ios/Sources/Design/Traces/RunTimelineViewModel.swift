import Foundation
import OpenClawChatUI
import OpenClawKit
import OpenClawProtocol
import SwiftUI

/// Closed load state for a single run's timeline. Mirrors `TraceListLoadState`.
enum RunTimelineLoadState: Equatable {
    case idle
    case loading
    case loaded(RunDetail)
    case empty
    case offline
    case error(String)

    static func == (lhs: RunTimelineLoadState, rhs: RunTimelineLoadState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.loading, .loading), (.empty, .empty), (.offline, .offline):
            true
        case let (.error(l), .error(r)):
            l == r
        case let (.loaded(l), .loaded(r)):
            // Cheap identity by session key + span count; the screen re-renders fully on any reload.
            l.sessionKey == r.sessionKey && l.spans.count == r.spans.count
        default:
            false
        }
    }
}

/// Drives one run's detail timeline. ONE `chat.history` call ({ sessionKey, limit:1000 }) yields the raw
/// transcript, decoded per-element into the public `OpenClawChatMessage[]` and flattened into an ORDERED
/// `[RunSpan]` with a 2-level turn grouping. A second, best-effort `sessions.usage.timeseries` call backs
/// the optional cumulative token/cost rail in the header. Structure mirrors `CostInsightsViewModel`:
/// closed load state, verbatim `connected(appModel:)` gate, preserve-on-refetch.
@MainActor
@Observable
final class RunTimelineViewModel {
    private(set) var state: RunTimelineLoadState = .idle

    /// Carried from the run row so the header has a title/model even before the transcript decodes.
    let sessionKey: String
    let title: String
    let modelLabel: String?
    /// Run cost from the `sessions.usage` rollup. chat.history emits per-message `cost` as a top-level
    /// sibling of `usage` that the decoded `OpenClawChatMessage` drops, so the transcript cannot sum run
    /// cost; the rollup row carries the faithful number and we surface it in the header instead.
    let runCost: Double

    private static let historyLimit = 1000

    init(sessionKey: String, title: String, modelLabel: String?, runCost: Double) {
        self.sessionKey = sessionKey
        self.title = title
        self.modelLabel = modelLabel
        self.runCost = runCost
    }

    var detail: RunDetail? {
        if case let .loaded(detail) = self.state { return detail }
        return nil
    }

    func load(appModel: NodeAppModel, force: Bool) async {
        guard self.connected(appModel: appModel) else {
            self.state = .offline
            return
        }
        if case .loading = self.state, !force { return }
        if case .loaded = self.state {} else {
            self.state = .loading
        }

        // The transcript is the primary source; the timeseries rail is optional. Both fetches are
        // @MainActor-isolated, so this interleaves them at their inner await points (not true parallelism)
        // and starts the optional rail without blocking the transcript. Only the transcript fails the screen.
        async let historyTask = self.fetchHistory(appModel: appModel)
        async let timeseriesTask = self.fetchTimeseries(appModel: appModel)
        let history = await historyTask
        let timeseries = await timeseriesTask

        guard let messages = history else {
            if case .loaded = self.state { return }
            self.state = .error("Could not load this run's timeline.")
            return
        }

        let spans = RunSpanBuilder.spans(from: messages)
        guard !spans.isEmpty else {
            self.state = .empty
            return
        }
        let turns = RunSpanBuilder.turns(from: spans)
        let header = Self.buildHeader(
            title: self.title,
            modelLabel: self.modelLabel,
            runCost: self.runCost,
            messages: messages,
            spans: spans)
        let detail = RunDetail(
            sessionKey: self.sessionKey,
            title: self.title,
            spans: spans,
            turns: turns,
            header: header,
            timeseries: timeseries)
        self.state = .loaded(detail)
    }

    // MARK: - Fetch + decode

    /// Fetch `chat.history` and decode the `messages` array per-element into `OpenClawChatMessage`,
    /// skipping any malformed entry. The payload's `messages` is `[AnyCodable]`; we re-encode each element
    /// and decode it on its own (mirroring `ChatViewModel.decodeMessages`, which is internal to
    /// `OpenClawChatUI`) rather than decoding a bare `[OpenClawChatMessage]` so one bad message can't drop
    /// the whole transcript.
    private func fetchHistory(appModel: NodeAppModel) async -> [OpenClawChatMessage]? {
        let payload: OpenClawChatHistoryPayload
        do {
            let transport = appModel.makeChatTransport()
            payload = try await transport.requestHistory(sessionKey: self.sessionKey)
        } catch {
            return nil
        }
        let raw = payload.messages ?? []
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        var messages: [OpenClawChatMessage] = []
        messages.reserveCapacity(raw.count)
        for element in raw {
            guard let elementData = try? encoder.encode(element),
                  let decoded = try? decoder.decode(OpenClawChatMessage.self, from: elementData)
            else {
                continue
            }
            messages.append(decoded)
        }
        return messages
    }

    /// Best-effort `sessions.usage.timeseries` fetch for the header rail. Params: `key` (required). A
    /// failure just yields an empty rail; it never fails the screen.
    private func fetchTimeseries(appModel: NodeAppModel) async -> [RunTimePoint] {
        let json = Self.timeseriesParamsJSON(key: self.sessionKey)
        guard let data = try? await appModel.operatorSession.request(
            method: "sessions.usage.timeseries",
            paramsJSON: json,
            timeoutSeconds: 12),
            let series = RunTimeSeriesLite.decode(from: data)
        else {
            return []
        }
        return series.points ?? []
    }

    /// `sessions.usage.timeseries` params: `key` is required (`usage.ts:1625`). Encoded as a literal
    /// object so the casing is exact; the key is JSON-escaped through `JSONEncoder`.
    private static func timeseriesParamsJSON(key: String) -> String {
        guard let keyData = try? JSONEncoder().encode(key),
              let keyJSON = String(data: keyData, encoding: .utf8)
        else {
            return "{}"
        }
        return "{\"key\":\(keyJSON)}"
    }

    // MARK: - Header assembly

    /// Build the run-header rollup. Tokens, tool-call count, wall-clock duration, and the error flag come
    /// from the transcript (authoritative for this run). Cost comes from the `sessions.usage` rollup
    /// (`runCost`): chat.history emits per-message `cost` as a top-level sibling of `usage` that the
    /// decoded `OpenClawChatMessage` drops, so the transcript cannot sum run cost.
    private static func buildHeader(
        title: String,
        modelLabel: String?,
        runCost: Double,
        messages: [OpenClawChatMessage],
        spans: [RunSpan]) -> RunHeaderSummary
    {
        var totalTokens = 0
        for message in messages {
            if let usage = message.usage {
                totalTokens += usage.total ?? 0
            }
        }
        let toolCallCount = spans.filter(\.isToolCall).count
        let hasError = spans.contains(where: \.isError)
        let timestamps = messages.compactMap(\.timestamp).filter { $0 > 0 }
        let durationMs: Double? = {
            guard let first = timestamps.min(), let last = timestamps.max(), last > first else { return nil }
            return last - first
        }()
        return RunHeaderSummary(
            title: title,
            modelLabel: modelLabel,
            totalTokens: totalTokens,
            totalCost: runCost,
            toolCallCount: toolCallCount,
            messageCount: messages.count,
            durationMs: durationMs,
            hasError: hasError)
    }

    // MARK: - Connection gate (copied verbatim from AgentInboxViewModel)

    private func connected(appModel: NodeAppModel) -> Bool {
        guard !appModel.isLocalGatewayFixtureEnabled else { return false }
        guard appModel.isOperatorGatewayConnected else { return false }
        return GatewayStatusBuilder.build(appModel: appModel) == .connected
    }
}
