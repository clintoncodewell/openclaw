import Charts
import OpenClawChatUI
import OpenClawKit
import SwiftUI

/// One run's ORDERED tool-call timeline. The header summarizes the run (model, tokens, cost, tool-call
/// count, wall-clock duration) and optionally charts cumulative tokens from `sessions.usage.timeseries`.
/// Below it, the transcript renders as an ordered span list with a 2-level grouping (assistant turn → its
/// tool calls/results), each span expandable to its structured JSON args/result.
///
/// HONESTY: this is an ordered timeline, not a trace tree. `chat.history` does not expose the on-disk
/// `parentId` chain, so there is no arbitrary-depth parent/child hierarchy — only the assistant-turn
/// grouping the chat UI already uses. Inter-span time labels are WALL-CLOCK spacing from message
/// timestamps, not measured tool latency. The view layout mirrors `BriefDetailScreen`.
struct RunTimelineScreen: View {
    @Environment(NodeAppModel.self) private var appModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var viewModel: RunTimelineViewModel
    /// Grouped-by-turn (default) vs. one flat ordered rail — both back the same ordered span data; the
    /// toggle is honest that there is no deeper tree to expand into.
    @State private var layout: TimelineLayout = .grouped

    enum TimelineLayout: String, CaseIterable, Identifiable {
        case grouped
        case flat

        var id: String { self.rawValue }

        var label: String {
            switch self {
            case .grouped: "Grouped by turn"
            case .flat: "Flat timeline"
            }
        }
    }

    init(sessionKey: String, title: String, modelLabel: String?, runCost: Double) {
        self._viewModel = State(wrappedValue: RunTimelineViewModel(
            sessionKey: sessionKey,
            title: title,
            modelLabel: modelLabel,
            runCost: runCost))
    }

    var body: some View {
        ZStack {
            CommandControlBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    self.content
                }
                .padding(.top, 14)
                .padding(.horizontal, OpenClawProMetric.pagePadding)
                .padding(.bottom, 18)
            }
            .safeAreaPadding(.bottom, OpenClawProMetric.bottomScrollInset)
        }
        .navigationTitle(self.viewModel.title)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            await self.viewModel.load(appModel: self.appModel, force: true)
        }
        .task(id: self.scenePhase) {
            guard self.scenePhase == .active else { return }
            await self.viewModel.load(appModel: self.appModel, force: false)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch self.viewModel.state {
        case .idle, .loading:
            self.loadingCard
        case .offline:
            self.messageCard(
                icon: "wifi.slash",
                title: "Gateway offline",
                detail: "Connect to the gateway to view this run's timeline.")
        case let .error(message):
            self.messageCard(
                icon: "exclamationmark.triangle.fill",
                title: "Timeline unavailable",
                detail: message)
        case .empty:
            self.messageCard(
                icon: "point.3.connected.trianglepath.dotted",
                title: "No transcript",
                detail: "This run has no recorded messages to show.")
        case let .loaded(detail):
            RunHeaderCard(header: detail.header, timeseries: detail.timeseries)
            self.layoutPicker
            self.honestyNote
            switch self.layout {
            case .grouped:
                ForEach(detail.turns) { turn in
                    TurnGroupCard(turn: turn)
                }
            case .flat:
                FlatTimelineCard(spans: detail.spans)
            }
        }
    }

    private var layoutPicker: some View {
        Picker("Layout", selection: self.$layout) {
            ForEach(TimelineLayout.allCases) { option in
                Text(option.label).tag(option)
            }
        }
        .pickerStyle(.segmented)
        .padding(.vertical, 2)
    }

    /// Sets reader expectations: ordered, not a tree; deltas are wall-clock.
    private var honestyNote: some View {
        Text("Ordered run timeline. Spans are grouped by assistant turn; time labels are wall-clock spacing between messages, not measured tool latency.")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var loadingCard: some View {
        CommandPanel(padding: 14) {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Loading run timeline")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
        }
    }

    private func messageCard(icon: String, title: String, detail: String) -> some View {
        CommandPanel(padding: 14) {
            HStack(alignment: .top, spacing: 12) {
                ProIconBadge(systemName: icon, color: OpenClawBrand.accent)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
        }
    }
}

// MARK: - Header

/// Run-header card: title, model, and a metric strip (tokens, cost, tool calls, wall-clock duration),
/// plus an optional cumulative-token rail from the timeseries samples. Mirrors `BriefDetailScreen`'s
/// prominent header card.
private struct RunHeaderCard: View {
    let header: RunHeaderSummary
    let timeseries: [RunTimePoint]

    var body: some View {
        CommandPanel(isProminent: true, padding: 14) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    ProIconBadge(
                        systemName: self.header.hasError ? "exclamationmark.octagon.fill" : "point.3.connected.trianglepath.dotted",
                        color: self.header.hasError ? OpenClawBrand.danger : OpenClawBrand.accent)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(self.header.title)
                            .font(.title3.weight(.semibold))
                            .lineLimit(2)
                            .minimumScaleFactor(0.82)
                        if let model = self.header.modelLabel {
                            Text(model)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 8)
                }

                HStack(spacing: 8) {
                    ForEach(self.metricPills, id: \.label) { pill in
                        ProValuePill(value: pill.value, color: pill.color)
                    }
                    Spacer(minLength: 0)
                }

                self.cumulativeChart
            }
        }
    }

    private var metricPills: [(label: String, value: String, color: Color)] {
        var pills: [(label: String, value: String, color: Color)] = []
        let callNoun = self.header.toolCallCount == 1 ? "call" : "calls"
        pills.append((label: "calls", value: "\(self.header.toolCallCount) tool \(callNoun)", color: OpenClawBrand.accent))
        if self.header.totalTokens > 0 {
            pills.append((label: "tokens", value: "\(CostFormatting.compactNumber(self.header.totalTokens)) tokens", color: OpenClawBrand.accentHot))
        }
        if self.header.totalCost > 0 {
            pills.append((label: "cost", value: CostFormatting.currency(self.header.totalCost), color: OpenClawBrand.ok))
        }
        if let duration = self.header.durationMs {
            pills.append((label: "duration", value: TraceFormatting.duration(ms: duration), color: .secondary))
        }
        return pills
    }

    /// Cumulative-token rail from the timeseries samples. Secondary, optional, and clearly a token series
    /// (not a tool-span chart) — only shown when there are at least two points to draw a line.
    @ViewBuilder
    private var cumulativeChart: some View {
        let points = self.timeseries.filter { ($0.cumulativeTokens ?? 0) > 0 }
        if points.count >= 2 {
            VStack(alignment: .leading, spacing: 4) {
                Text("Cumulative tokens")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Chart(points) { point in
                    AreaMark(
                        x: .value("Time", Date(timeIntervalSince1970: point.timestamp / 1000)),
                        y: .value("Tokens", point.cumulativeTokens ?? 0))
                        .foregroundStyle(OpenClawBrand.accent.opacity(0.18))
                    LineMark(
                        x: .value("Time", Date(timeIntervalSince1970: point.timestamp / 1000)),
                        y: .value("Tokens", point.cumulativeTokens ?? 0))
                        .foregroundStyle(OpenClawBrand.accent)
                        .interpolationMethod(.monotone)
                }
                .chartXAxis(.hidden)
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 3))
                }
                .frame(height: 80)
            }
        }
    }
}

// MARK: - Grouped layout

/// One assistant turn rendered as a card with a leading timeline rail (a dot + connecting line per span)
/// and the ordered spans. The rail's time labels are wall-clock starts; the inter-span delta is shown on
/// each span row, labeled as wall-clock spacing.
private struct TurnGroupCard: View {
    let turn: TurnGroup

    var body: some View {
        CommandPanel(padding: 12) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text("Turn \(self.turn.id + 1)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                    Spacer(minLength: 8)
                    if let start = self.turn.startMs {
                        Text(TraceFormatting.clockTime(forMilliseconds: start))
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.tertiary)
                    }
                    if self.turn.turnTokens > 0 {
                        ProValuePill(
                            value: "\(CostFormatting.compactNumber(self.turn.turnTokens)) tok",
                            color: OpenClawBrand.accentHot)
                    }
                }
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(self.turn.spans.enumerated()), id: \.element.id) { index, span in
                        SpanRailRow(
                            span: span,
                            previousTimestamp: index > 0 ? self.turn.spans[index - 1].timestampMs : nil,
                            isLast: index == self.turn.spans.count - 1)
                    }
                }
            }
        }
    }
}

// MARK: - Flat layout

/// All spans in one ordered rail, ignoring turn boundaries — the same ordered data, no grouping. Honest
/// alternative to the grouped view, useful for scanning the raw sequence.
private struct FlatTimelineCard: View {
    let spans: [RunSpan]

    var body: some View {
        CommandPanel(padding: 12) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(self.spans.enumerated()), id: \.element.id) { index, span in
                    SpanRailRow(
                        span: span,
                        previousTimestamp: index > 0 ? self.spans[index - 1].timestampMs : nil,
                        isLast: index == self.spans.count - 1)
                }
            }
        }
    }
}

// MARK: - Span row (rail + expandable card)

/// A single span on the timeline rail: a leading dot + connecting line, an inter-span wall-clock delta
/// caption, and an expandable card body. Tool-call spans reuse `ToolDisplayRegistry` for their icon +
/// title (exactly as the chat header does) and expand to pretty-printed, secret-redacted JSON args and
/// the structured/text result.
private struct SpanRailRow: View {
    let span: RunSpan
    let previousTimestamp: Double?
    let isLast: Bool
    @State private var expanded = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            self.rail
            VStack(alignment: .leading, spacing: 4) {
                if let delta = self.wallClockDelta {
                    Text(delta)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.tertiary)
                }
                self.spanBody
            }
            .padding(.bottom, self.isLast ? 0 : 10)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The leading rail: a status-tinted dot and (unless last) a connecting line down to the next span.
    private var rail: some View {
        VStack(spacing: 0) {
            Circle()
                .fill(self.accent)
                .frame(width: 9, height: 9)
                .padding(.top, 5)
            if !self.isLast {
                Rectangle()
                    .fill(Color.secondary.opacity(0.18))
                    .frame(width: 2)
                    .frame(maxHeight: .infinity)
            }
        }
        .frame(width: 9)
    }

    @ViewBuilder
    private var spanBody: some View {
        switch self.span.kind {
        case let .userMessage(text):
            self.textSpan(role: "You", text: text, icon: "person.fill", tint: .secondary, isMarkdown: false)
        case let .assistantText(text):
            self.textSpan(role: "Assistant", text: text, icon: "sparkles", tint: OpenClawBrand.accent, isMarkdown: true)
        case let .toolCall(name, arguments, _):
            self.toolCallSpan(name: name, arguments: arguments)
        case let .toolResult(content, text, _, isError):
            self.toolResultSpan(content: content, text: text, isError: isError)
        case let .error(message):
            self.errorSpan(message: message)
        }
    }

    // MARK: span bodies

    private func textSpan(role: String, text: String, icon: String, tint: Color, isMarkdown: Bool) -> some View {
        Button {
            withAnimation(.snappy) { self.expanded.toggle() }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: icon)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(tint)
                    Text(role)
                        .font(.footnote.weight(.semibold))
                    Spacer(minLength: 6)
                    if let tokens = self.tokensLabel {
                        Text(tokens)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                }
                if self.expanded {
                    if isMarkdown {
                        OpenClawProseView(text: text)
                            .textSelection(.enabled)
                    } else {
                        Text(text)
                            .font(.callout)
                            .foregroundStyle(.primary)
                            .textSelection(.enabled)
                    }
                } else {
                    Text(text)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(self.cardBackground)
        }
        .buttonStyle(.plain)
    }

    private func toolCallSpan(name: String, arguments: AnyCodable?) -> some View {
        let display = ToolDisplayRegistry.resolve(name: name, args: arguments)
        let prettyArgs = TraceFormatting.prettyJSON(arguments)
        return Button {
            withAnimation(.snappy) { self.expanded.toggle() }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(display.emoji)
                        .font(.footnote)
                    Text(display.title)
                        .font(.footnote.weight(.semibold))
                    Spacer(minLength: 6)
                    if prettyArgs != nil {
                        Image(systemName: self.expanded ? "chevron.up" : "chevron.down")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.tertiary)
                    }
                }
                if let detail = display.detail, !detail.isEmpty, !self.expanded {
                    Text(detail)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if self.expanded, let prettyArgs {
                    self.jsonBlock(prettyArgs, caption: "Arguments")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(self.cardBackground)
        }
        .buttonStyle(.plain)
    }

    private func toolResultSpan(content: AnyCodable?, text: String?, isError: Bool) -> some View {
        let prettyResult = TraceFormatting.prettyJSON(content)
        let bodyText = self.resultText(content: content, text: text)
        let tint = isError ? OpenClawBrand.danger : OpenClawBrand.ok
        return Button {
            withAnimation(.snappy) { self.expanded.toggle() }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: isError ? "xmark.octagon.fill" : "arrow.turn.down.right")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(tint)
                    Text(isError ? "Tool error" : "Result")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(isError ? OpenClawBrand.danger : .primary)
                    Spacer(minLength: 6)
                    if prettyResult != nil || (bodyText.map { $0.count > 120 } ?? false) {
                        Image(systemName: self.expanded ? "chevron.up" : "chevron.down")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.tertiary)
                    }
                }
                if let prettyResult, self.expanded {
                    self.jsonBlock(prettyResult, caption: "Result")
                } else if let bodyText, !bodyText.isEmpty {
                    OpenClawProseView(text: bodyText)
                        .textSelection(.enabled)
                        .lineLimit(self.expanded ? nil : 4)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(self.cardBackground(tint: isError ? OpenClawBrand.danger : nil))
        }
        .buttonStyle(.plain)
    }

    private func errorSpan(message: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Error", systemImage: "exclamationmark.triangle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(OpenClawBrand.danger)
            Text(message)
                .font(.callout)
                .foregroundStyle(OpenClawBrand.danger)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(self.cardBackground(tint: OpenClawBrand.danger))
    }

    // MARK: building blocks

    private func jsonBlock(_ json: String, caption: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(caption)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.tertiary)
                .textCase(.uppercase)
            ScrollView(.horizontal, showsIndicators: false) {
                Text(json)
                    .font(.caption.monospaced())
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        }
    }

    private var cardBackground: some View {
        self.cardBackground(tint: nil)
    }

    private func cardBackground(tint: Color?) -> some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill((tint ?? Color.primary).opacity(tint == nil ? 0.04 : 0.07))
    }

    /// Best-effort textual rendering of a result: prefer the plain `text`, else a compact string from the
    /// structured content (so a text-only render path still shows something before expansion).
    private func resultText(content: AnyCodable?, text: String?) -> String? {
        if let text, !text.isEmpty { return text }
        return TraceFormatting.prettyJSON(content)
    }

    private var tokensLabel: String? {
        guard let total = self.span.usage?.total, total > 0 else { return nil }
        return "\(CostFormatting.compactNumber(total)) tok"
    }

    /// Tinted dot color per span kind.
    private var accent: Color {
        switch self.span.kind {
        case .userMessage: .secondary
        case .assistantText: OpenClawBrand.accent
        case .toolCall: OpenClawBrand.accentHot
        case let .toolResult(_, _, _, isError): isError ? OpenClawBrand.danger : OpenClawBrand.ok
        case .error: OpenClawBrand.danger
        }
    }

    /// Inter-span wall-clock delta caption ("+1.2s"), shown only when both timestamps are known and the
    /// gap is positive. Labeled as wall-clock spacing, never tool latency.
    private var wallClockDelta: String? {
        guard let current = self.span.timestampMs, let previous = self.previousTimestamp else { return nil }
        let delta = current - previous
        guard delta > 0 else { return nil }
        return "+\(TraceFormatting.duration(ms: delta))"
    }
}
