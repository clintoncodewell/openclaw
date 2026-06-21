import Charts
import OpenClawKit
import SwiftUI

/// The RED / operational-health overview: three RED tiles (Requests, Error rate, Turn latency) with
/// per-day Swift Charts sparklines, a "What needs attention" rollup (cron failures, provider auth /
/// quota, offline nodes, degraded gateway), and a provider plan/quota section. Pushed inside Command
/// Center's existing NavigationStack so the system back button works for free.
///
/// REAL signals shown: request rate (daily messages + toolCalls), error count / rate (daily + window),
/// turn latency avg / p95 / min / max (window + per-day), cron failures, provider auth + plan quota,
/// node / gateway online state.
/// OMITTED (no gateway source, surfaced honestly in copy): TTFT — does not exist anywhere in the
/// protocol; the duration tile is labeled "turn latency", which is END-TO-END. Per-HOUR granularity —
/// the aggregates carry no sub-day buckets, so every series here is per-day (charts are labeled "per
/// day"). p95 is a max-of-session-p95 approximation, not a recomputed percentile.
struct OpsHealthScreen: View {
    @Environment(NodeAppModel.self) private var appModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var viewModel = OpsHealthViewModel()

    var body: some View {
        ZStack {
            OpenClawProBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    self.header
                    self.content
                }
                .padding(.top, 14)
                .padding(.bottom, 18)
            }
            .safeAreaPadding(.bottom, OpenClawProMetric.bottomScrollInset)
        }
        .navigationTitle("Health")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            await self.viewModel.load(appModel: self.appModel, force: true)
        }
        .task(id: self.scenePhase) {
            guard self.scenePhase == .active else { return }
            await self.viewModel.load(appModel: self.appModel, force: false)
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Health")
                .font(.system(size: 27, weight: .bold, design: .rounded))
            Text(self.headerDetail)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, OpenClawProMetric.pagePadding)
    }

    private var headerDetail: String {
        switch self.viewModel.state {
        case .idle, .loading:
            return "Loading request, error & latency signals"
        case .offline:
            return "Gateway offline"
        case .error:
            return "Operational signals unavailable"
        case .empty:
            return "No recorded activity yet"
        case let .loaded(report):
            let count = report.issueCount
            if count == 0 { return "All systems healthy" }
            return count == 1 ? "1 issue needs attention" : "\(count) issues need attention"
        }
    }

    // MARK: - Content router

    @ViewBuilder
    private var content: some View {
        switch self.viewModel.state {
        case .idle, .loading:
            self.loadingState
        case .offline:
            self.emptyState(
                icon: "wifi.slash",
                title: "Gateway offline",
                detail: "Connect to the gateway to see operational health.")
        case let .error(message):
            self.emptyState(
                icon: "exclamationmark.triangle.fill",
                title: "Health unavailable",
                detail: message)
        case .empty:
            self.emptyState(
                icon: "waveform.path.ecg",
                title: "No activity recorded",
                detail: "RED metrics appear once your agents start handling requests.")
        case let .loaded(report):
            self.loadedContent(report)
        }
    }

    @ViewBuilder
    private func loadedContent(_ report: RedReport) -> some View {
        self.redTiles(report)
        self.requestsChartSection(report)
        self.errorChartSection(report)
        self.latencyChartSection(report)
        self.attentionSection(report)
        self.providerSection(report)
        self.granularityNote
    }

    // MARK: - RED tiles

    /// The three RED headline tiles. Each value is a local string so the metric grid's builder stays
    /// simple (the Swift type-checker chokes on inline string interpolation inside large literals).
    private func redTiles(_ report: RedReport) -> some View {
        let requestsValue = OpsFormatting.count(report.requests24h)
        let requestsTitle = "Requests 24h · \(OpsFormatting.count(report.requests7d)) 7d"
        let errorValue = OpsFormatting.percent(report.errorRatePct)
        let errorTitle = "Error rate · \(OpsFormatting.trend(report.errorRateTrendPct))"
        let latencyValue = report.hasLatency ? OpsFormatting.latency(report.avgMs) : "—"
        let latencyTitle = report.hasLatency
            ? "Turn latency · p95 \(OpsFormatting.latency(report.p95Ms))"
            : "Turn latency"
        let metrics = [
            ProMetric(
                icon: "arrow.up.arrow.down.circle.fill",
                title: requestsTitle,
                value: requestsValue,
                color: OpenClawBrand.accent),
            ProMetric(
                icon: "exclamationmark.triangle.fill",
                title: errorTitle,
                value: errorValue,
                color: report.errorSeverity.color),
            ProMetric(
                icon: "timer",
                title: latencyTitle,
                value: latencyValue,
                color: OpenClawBrand.accentHot),
        ]
        return ProMetricGrid(metrics: metrics)
    }

    // MARK: - Requests sparkline

    @ViewBuilder
    private func requestsChartSection(_ report: RedReport) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ProSectionHeader(title: "Requests per day")
            CommandPanel(padding: 14) {
                if report.requestsDaily.isEmpty {
                    OpsInlineNote(icon: "chart.bar", text: "No request volume in this window yet.")
                } else {
                    OpsRateChart(points: report.requestsDaily, color: OpenClawBrand.accent, asBars: true)
                }
            }
            .padding(.horizontal, OpenClawProMetric.pagePadding)
        }
    }

    // MARK: - Error-rate sparkline

    @ViewBuilder
    private func errorChartSection(_ report: RedReport) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ProSectionHeader(title: "Error rate per day")
            CommandPanel(padding: 14) {
                if report.errorRateDaily.isEmpty {
                    OpsInlineNote(icon: "checkmark.seal", text: "No errors recorded in this window.")
                } else {
                    OpsRateChart(
                        points: report.errorRateDaily,
                        color: report.errorSeverity.color,
                        asBars: false,
                        valueSuffix: "%")
                }
            }
            .padding(.horizontal, OpenClawProMetric.pagePadding)
        }
    }

    // MARK: - Latency sparkline

    @ViewBuilder
    private func latencyChartSection(_ report: RedReport) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ProSectionHeader(title: "Turn latency per day")
            CommandPanel(padding: 14) {
                if report.latencyDaily.isEmpty {
                    OpsInlineNote(icon: "timer", text: "No latency samples in this window yet.")
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        OpsLatencyChart(points: report.latencyDaily)
                        OpsLatencyLegend()
                    }
                }
            }
            .padding(.horizontal, OpenClawProMetric.pagePadding)
        }
    }

    // MARK: - What needs attention

    @ViewBuilder
    private func attentionSection(_ report: RedReport) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ProSectionHeader(title: "What needs attention")
            if report.issues.isEmpty {
                CommandEmptyStateRow(
                    icon: "checkmark.seal.fill",
                    title: "All systems healthy",
                    detail: "No cron, provider, or node issues.")
                    .padding(.horizontal, OpenClawProMetric.pagePadding)
            } else {
                CommandPanel(padding: 8) {
                    VStack(spacing: 8) {
                        ForEach(report.issues) { issue in
                            OpsIssueRow(issue: issue)
                        }
                    }
                }
                .padding(.horizontal, OpenClawProMetric.pagePadding)
            }
        }
    }

    // MARK: - Provider plan / quota

    @ViewBuilder
    private func providerSection(_ report: RedReport) -> some View {
        let providers = self.providerSnapshots
        if !providers.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                ProSectionHeader(title: "Provider plans")
                CommandPanel(padding: 8) {
                    VStack(spacing: 8) {
                        ForEach(providers) { provider in
                            OpsProviderRow(provider: provider)
                        }
                    }
                }
                .padding(.horizontal, OpenClawProMetric.pagePadding)
            }
        }
    }

    /// Provider snapshots for the plan section. Held on the view model's loaded `usage.status` decode;
    /// nil while the call is absent (the section then hides rather than showing an empty panel).
    private var providerSnapshots: [OpsProviderSnapshotLite] {
        self.viewModel.providerSnapshots
    }

    // MARK: - Honest granularity / TTFT note

    private var granularityNote: some View {
        OpsInlineNote(
            icon: "info.circle",
            text: "All series are per day — the gateway exposes no per-hour or time-to-first-token data. Latency is end-to-end turn duration; p95 is approximate.")
            .padding(.horizontal, OpenClawProMetric.pagePadding)
    }

    // MARK: - Shared states

    private var loadingState: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text("Loading operational health")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, OpenClawProMetric.pagePadding)
    }

    private func emptyState(icon: String, title: String, detail: String) -> some View {
        CommandEmptyStateRow(icon: icon, title: title, detail: detail)
            .padding(.horizontal, OpenClawProMetric.pagePadding)
    }
}

// MARK: - RED rate chart

/// Per-day RED rate chart (requests or error-rate). Bars for request volume, an area+line for error-rate
/// so the two read differently at a glance. Ships with iOS 18; no SPM dependency. Kept as its own view so
/// the `Chart` builder stays simple (the Swift type-checker is fragile inside large view bodies).
private struct OpsRateChart: View {
    let points: [OpsRatePoint]
    let color: Color
    var asBars: Bool
    var valueSuffix: String = ""

    var body: some View {
        Chart {
            ForEach(self.points) { point in
                if self.asBars {
                    BarMark(
                        x: .value("Day", point.date, unit: .day),
                        y: .value("Value", point.value))
                        .foregroundStyle(self.color.gradient)
                        .cornerRadius(3)
                } else {
                    AreaMark(
                        x: .value("Day", point.date, unit: .day),
                        y: .value("Value", point.value))
                        .foregroundStyle(self.color.opacity(0.16).gradient)
                    LineMark(
                        x: .value("Day", point.date, unit: .day),
                        y: .value("Value", point.value))
                        .foregroundStyle(self.color)
                        .interpolationMethod(.monotone)
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let number = value.as(Double.self) {
                        Text(self.axisLabel(number))
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .day, count: self.xAxisStride)) { _ in
                AxisGridLine()
                AxisValueLabel(format: .dateTime.month(.abbreviated).day())
            }
        }
        .frame(height: 150)
    }

    private func axisLabel(_ value: Double) -> String {
        if self.valueSuffix == "%" {
            return OpsFormatting.percent(value)
        }
        return OpsFormatting.count(Int(value.rounded()))
    }

    /// Thin the x-axis so a 30-day window doesn't overprint date labels.
    private var xAxisStride: Int {
        self.points.count > 14 ? 5 : 2
    }
}

// MARK: - Latency chart

/// Per-day latency chart: two lines (avg + p95 turn duration, ms). p95 is the max-of-session-p95
/// approximation; the legend says so without overclaiming a recomputed percentile.
private struct OpsLatencyChart: View {
    let points: [OpsLatencyPoint]

    var body: some View {
        Chart {
            ForEach(self.points) { point in
                LineMark(
                    x: .value("Day", point.date, unit: .day),
                    y: .value("avg ms", point.avgMs),
                    series: .value("Series", "avg"))
                    .foregroundStyle(OpenClawBrand.accent)
                    .interpolationMethod(.monotone)
                LineMark(
                    x: .value("Day", point.date, unit: .day),
                    y: .value("p95 ms", point.p95Ms),
                    series: .value("Series", "p95"))
                    .foregroundStyle(OpenClawBrand.accentHot)
                    .lineStyle(StrokeStyle(lineWidth: 1.4, dash: [4, 3]))
                    .interpolationMethod(.monotone)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let ms = value.as(Double.self) {
                        Text(OpsFormatting.latency(ms))
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .day, count: self.xAxisStride)) { _ in
                AxisGridLine()
                AxisValueLabel(format: .dateTime.month(.abbreviated).day())
            }
        }
        .frame(height: 150)
    }

    private var xAxisStride: Int {
        self.points.count > 14 ? 5 : 2
    }
}

/// Legend for the two-line latency chart: solid accent = avg, dashed hot = p95 (approx).
private struct OpsLatencyLegend: View {
    var body: some View {
        HStack(spacing: 14) {
            self.swatch(color: OpenClawBrand.accent, label: "avg")
            self.swatch(color: OpenClawBrand.accentHot, label: "p95 (approx)")
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
    }

    private func swatch(color: Color, label: String) -> some View {
        HStack(spacing: 5) {
            Capsule()
                .fill(color)
                .frame(width: 14, height: 3)
            Text(label)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Attention issue row

/// One "what needs attention" row: severity-tinted icon badge, title + detail, and a status pill colored
/// by severity. Tappable surface (whole row) for parity with the rest of Command Center; the action is a
/// no-op placeholder today since each issue category lives on its own existing screen.
private struct OpsIssueRow: View {
    let issue: OpsHealthIssue

    var body: some View {
        ProStatusRow(
            icon: self.issue.icon,
            title: self.issue.title,
            detail: self.issue.detail,
            value: self.issue.pillValue,
            color: self.issue.severity.color)
    }
}

// MARK: - Provider plan row

/// One provider plan/quota row: name + plan caption, an auth-error or near-quota status pill, and a quota
/// progress bar sized by the worst window. Amber bar when at/over the quota threshold, red when the
/// provider reports an auth error.
private struct OpsProviderRow: View {
    @Environment(\.colorScheme) private var colorScheme
    let provider: OpsProviderSnapshotLite

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(self.provider.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
                if let plan = self.planLabel {
                    Text(plan)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                ProValuePill(value: self.statusValue, color: self.statusColor)
            }
            ProProgressBar(progress: self.barFraction, color: self.statusColor)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background {
            RoundedRectangle(cornerRadius: OpenClawProMetric.controlRadius, style: .continuous)
                .fill(self.rowFill)
                .overlay {
                    RoundedRectangle(cornerRadius: OpenClawProMetric.controlRadius, style: .continuous)
                        .strokeBorder(self.rowBorder, lineWidth: 1)
                }
        }
    }

    private var planLabel: String? {
        let trimmed = self.provider.plan?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private var hasError: Bool {
        guard let error = self.provider.error else { return false }
        return !error.isEmpty
    }

    /// Status pill: "auth" when the provider reports an error, otherwise the worst window's used %.
    private var statusValue: String {
        if self.hasError { return "auth" }
        return OpsFormatting.percent(self.provider.worstUsedPercent)
    }

    /// Red on auth failure, amber when at/over the quota threshold, ok otherwise.
    private var statusColor: Color {
        if self.hasError { return OpenClawBrand.danger }
        if self.provider.worstUsedPercent >= OpsHealthThresholds.providerQuotaWarn {
            return OpenClawBrand.warn
        }
        return OpenClawBrand.ok
    }

    private var barFraction: Double {
        max(0, min(self.provider.worstUsedPercent / 100, 1))
    }

    private var rowFill: Color {
        self.colorScheme == .dark ? Color.white.opacity(0.035) : Color(uiColor: .systemBackground)
    }

    private var rowBorder: Color {
        Color(uiColor: .separator).opacity(self.colorScheme == .dark ? 0.24 : 0.22)
    }
}

// MARK: - Inline note

/// A small inline note row for in-panel empty / informational states (lighter than a full empty card),
/// mirroring Cost's `CostInlineNote`.
private struct OpsInlineNote: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: self.icon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(self.text)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(3)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
    }
}
