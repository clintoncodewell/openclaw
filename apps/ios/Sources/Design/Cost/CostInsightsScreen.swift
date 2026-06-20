import Charts
import OpenClawKit
import SwiftUI

/// The Cost & Usage dashboard: total spend (today / 7d / 30d) with tokens, a Swift Charts daily-cost
/// trend, per-model and per-agent breakdowns, derived model-mix days, and client-side budget
/// guardrails. Pushed inside Command Center's existing NavigationStack so the system back button works
/// for free. Reuses the same `usage.cost` summary the Agent Pro overview fetches, plus one
/// `sessions.usage` call for the breakdown aggregates the overview path does not fetch.
struct CostInsightsScreen: View {
    @Environment(NodeAppModel.self) private var appModel
    @Environment(\.scenePhase) private var scenePhase
    /// Shared store injected by the owning `CommandCenterTab` so an edit here updates the card's budget
    /// pill live. Falls back to `fallbackBudget` only when used standalone (previews) with no owner.
    @Environment(\.costBudgetStore) private var sharedBudget
    @State private var viewModel = CostInsightsViewModel()
    @State private var fallbackBudget = CostBudgetStore()
    @State private var showingBudgetSheet = false

    private var budget: CostBudgetStore {
        self.sharedBudget ?? self.fallbackBudget
    }

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
        .navigationTitle("Cost")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            await self.viewModel.load(appModel: self.appModel, force: true)
        }
        .task(id: self.scenePhase) {
            guard self.scenePhase == .active else { return }
            await self.viewModel.load(appModel: self.appModel, force: false)
        }
        .sheet(isPresented: self.$showingBudgetSheet) {
            CostBudgetEditSheet(budget: self.budget)
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Cost")
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
            return "Loading spend & usage"
        case .offline:
            return "Gateway offline"
        case .error:
            return "Usage unavailable"
        case .empty:
            return "No recorded spend yet"
        case .loaded:
            let spend = self.viewModel.spend(for: self.viewModel.range)
            return "\(CostFormatting.currency(spend)) in the last \(self.viewModel.range.label.lowercased())"
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
                detail: "Connect to the gateway to see spend & usage.")
        case let .error(message):
            self.emptyState(
                icon: "exclamationmark.triangle.fill",
                title: "Usage unavailable",
                detail: message)
        case .empty:
            self.emptyState(
                icon: "dollarsign.circle",
                title: "No spend recorded",
                detail: "Cost analytics appear once your agents run.")
        case let .loaded(report):
            self.loadedContent(report)
        }
    }

    @ViewBuilder
    private func loadedContent(_ report: CostReport) -> some View {
        self.rangePicker
        self.totalsStrip(report)
        CostBudgetCard(
            report: report,
            budget: self.budget,
            onEdit: { self.showingBudgetSheet = true })
        self.trendSection(report)
        self.modelSection(report)
        self.agentSection(report)
        self.modelMixSection(report)
        if let cacheStatus = report.cacheStatus, cacheStatus.isSettling {
            self.settlingNote
        }
    }

    // MARK: - Range picker

    private var rangePicker: some View {
        Picker("Range", selection: self.$viewModel.range) {
            ForEach(CostRange.allCases) { range in
                Text(range.label).tag(range)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, OpenClawProMetric.pagePadding)
    }

    // MARK: - Totals strip

    private func totalsStrip(_ report: CostReport) -> some View {
        let spend = self.viewModel.spend(for: self.viewModel.range)
        let tokens = self.viewModel.range == .today ? report.todayTokens : report.last30Tokens
        let metrics = [
            ProMetric(
                icon: "dollarsign.circle.fill",
                title: "\(self.viewModel.range.label) spend",
                value: CostFormatting.currency(spend),
                color: OpenClawBrand.accent),
            ProMetric(
                icon: "number",
                title: "Tokens",
                value: CostFormatting.compactNumber(tokens),
                color: OpenClawBrand.accentHot),
            ProMetric(
                icon: "calendar",
                title: "30-day total",
                value: CostFormatting.currency(report.last30USD),
                color: OpenClawBrand.ok),
        ]
        return ProMetricGrid(metrics: metrics)
    }

    // MARK: - Trend chart

    @ViewBuilder
    private func trendSection(_ report: CostReport) -> some View {
        let points = self.trendWindow(report)
        VStack(alignment: .leading, spacing: 8) {
            ProSectionHeader(title: "Daily spend")
            CommandPanel(padding: 14) {
                if points.isEmpty {
                    CostInlineNote(
                        icon: "chart.bar",
                        text: "No daily spend in this window yet.")
                } else {
                    CostTrendChart(
                        points: points,
                        dailyCap: self.budget.dailyEnabled ? self.budget.dailyUSD : nil)
                }
            }
            .padding(.horizontal, OpenClawProMetric.pagePadding)
        }
    }

    /// Slice the 30-day trend down to the selected range so the chart matches the totals strip. The
    /// gateway's daily series is sparse (no zero-fill), so `suffix(n)` would reach further back than n
    /// calendar days when usage is scattered. Anchor the window on the newest point and keep points
    /// whose day key is on/after the cutoff, mirroring the totals-strip window math in the view model.
    private func trendWindow(_ report: CostReport) -> [CostTrendPoint] {
        let trailing = self.viewModel.range.trailingDays
        guard trailing > 0, let newest = report.dailyTrend.last else { return report.dailyTrend }
        let cutoffDate = newest.date.addingTimeInterval(-Double(trailing - 1) * 86_400)
        return report.dailyTrend.filter { $0.date >= cutoffDate }
    }

    // MARK: - Per-model breakdown

    @ViewBuilder
    private func modelSection(_ report: CostReport) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ProSectionHeader(title: "By model")
            CommandPanel(padding: 8) {
                if report.hasModelBreakdown {
                    VStack(spacing: 8) {
                        ForEach(report.byModel) { model in
                            CostBreakdownRow(
                                title: CostFormatting.label(for: model),
                                cost: model.costValue,
                                tokens: model.tokensValue,
                                share: report.modelGrandCost > 0 ? model.costValue / report.modelGrandCost : 0,
                                color: OpenClawBrand.accent)
                        }
                    }
                } else {
                    CostInlineNote(
                        icon: "cpu",
                        text: "No per-model usage in this window.")
                }
            }
            .padding(.horizontal, OpenClawProMetric.pagePadding)
        }
    }

    // MARK: - Per-agent breakdown

    @ViewBuilder
    private func agentSection(_ report: CostReport) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ProSectionHeader(title: "By agent")
            CommandPanel(padding: 8) {
                if report.hasAgentBreakdown {
                    VStack(spacing: 8) {
                        ForEach(report.byAgent) { agent in
                            CostBreakdownRow(
                                title: agent.agentId ?? "unknown",
                                cost: agent.costValue,
                                tokens: agent.tokensValue,
                                share: report.agentGrandCost > 0 ? agent.costValue / report.agentGrandCost : 0,
                                color: OpenClawBrand.accentHot)
                        }
                    }
                } else {
                    CostInlineNote(
                        icon: "person.2",
                        text: "No per-agent usage in this window.")
                }
            }
            .padding(.horizontal, OpenClawProMetric.pagePadding)
        }
    }

    // MARK: - Model-mix / fallback days

    @ViewBuilder
    private func modelMixSection(_ report: CostReport) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ProSectionHeader(title: "Model mix")
            if report.modelMixDays.isEmpty {
                CommandEmptyStateRow(
                    icon: "arrow.triangle.branch",
                    title: "No fallbacks",
                    detail: "All runs stayed on the primary model.")
                    .padding(.horizontal, OpenClawProMetric.pagePadding)
            } else {
                CommandPanel(padding: 8) {
                    VStack(spacing: 8) {
                        ForEach(report.modelMixDays) { day in
                            CostModelMixRow(day: day)
                        }
                    }
                }
                .padding(.horizontal, OpenClawProMetric.pagePadding)
            }
        }
    }

    // MARK: - Shared states

    private var settlingNote: some View {
        CostInlineNote(
            icon: "arrow.triangle.2.circlepath",
            text: "Usage cache is still refreshing — totals may rise.")
            .padding(.horizontal, OpenClawProMetric.pagePadding)
    }

    private var loadingState: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text("Loading cost analytics")
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

// MARK: - Trend chart

/// Swift Charts daily-cost bar chart with an optional dashed rule at the daily budget cap. Ships with
/// iOS 18; no SPM dependency. Kept as its own view so the chart body's builder stays simple.
private struct CostTrendChart: View {
    let points: [CostTrendPoint]
    let dailyCap: Double?

    var body: some View {
        Chart {
            ForEach(self.points) { point in
                BarMark(
                    x: .value("Day", point.date, unit: .day),
                    y: .value("Cost", point.cost))
                    .foregroundStyle(OpenClawBrand.accent.gradient)
                    .cornerRadius(3)
            }
            if let dailyCap, dailyCap > 0 {
                RuleMark(y: .value("Daily cap", dailyCap))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .foregroundStyle(OpenClawBrand.warn)
                    .annotation(position: .top, alignment: .trailing) {
                        Text("Cap \(CostFormatting.currency(dailyCap))")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(OpenClawBrand.warn)
                    }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let cost = value.as(Double.self) {
                        Text(CostFormatting.currency(cost))
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
        .frame(height: 168)
    }

    /// Thin the x-axis so a 30-day window doesn't overprint date labels.
    private var xAxisStride: Int {
        self.points.count > 14 ? 5 : 2
    }
}

// MARK: - Budget guardrail card

/// The budget guardrail card: one progress row per enabled cap (daily, monthly), an over-budget
/// banner, and a "Set budgets" affordance. All client-side via `CostBudgetStore`.
private struct CostBudgetCard: View {
    let report: CostReport
    let budget: CostBudgetStore
    let onEdit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ProSectionHeader(
                title: "Budget",
                actionTitle: self.budget.anyBudgetSet ? "Edit" : "Set budgets",
                action: self.onEdit)
            CommandPanel(padding: 12) {
                if self.budget.anyBudgetSet {
                    VStack(alignment: .leading, spacing: 12) {
                        if self.budget.dailyEnabled {
                            CostBudgetRow(
                                label: "Daily",
                                spend: self.report.todayUSD,
                                cap: self.budget.dailyUSD,
                                status: self.budget.dailyStatus(spend: self.report.todayUSD))
                        }
                        if self.budget.monthlyEnabled {
                            CostBudgetRow(
                                label: "30-day",
                                spend: self.report.last30USD,
                                cap: self.budget.monthlyUSD,
                                status: self.budget.monthlyStatus(spend: self.report.last30USD))
                        }
                        if self.budget.alertsEnabled, let banner = self.overBudgetText {
                            CostBudgetBanner(text: banner)
                        }
                    }
                } else {
                    self.noBudgetPrompt
                }
            }
            .padding(.horizontal, OpenClawProMetric.pagePadding)
        }
    }

    /// Banner copy for the worst over-budget cap, or nil when neither cap is exceeded. Daily takes
    /// precedence over the 30-day cap because it is the more immediate signal.
    private var overBudgetText: String? {
        let daily = self.budget.dailyStatus(spend: self.report.todayUSD)
        if case let .over(_, overBy) = daily {
            return "Over the daily budget by \(CostFormatting.currency(overBy))."
        }
        let monthly = self.budget.monthlyStatus(spend: self.report.last30USD)
        if case let .over(_, overBy) = monthly {
            return "Over the 30-day budget by \(CostFormatting.currency(overBy))."
        }
        return nil
    }

    private var noBudgetPrompt: some View {
        Button(action: self.onEdit) {
            HStack(spacing: 12) {
                ProIconBadge(systemName: "target", color: OpenClawBrand.accent)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Set a spend budget")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text("Get a heads-up before costs run away.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.tertiary)
            }
        }
        .buttonStyle(.plain)
    }
}

/// One budget progress row: label, spent / cap pill, and a status-colored progress bar.
private struct CostBudgetRow: View {
    let label: String
    let spend: Double
    let cap: Double
    let status: BudgetStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(self.label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                ProValuePill(value: self.pillText, color: self.status.color)
            }
            ProProgressBar(progress: self.status.barFraction, color: self.status.color)
        }
    }

    private var pillText: String {
        "\(CostFormatting.currency(self.spend)) / \(CostFormatting.currency(self.cap))"
    }
}

/// Over-budget alert banner. Danger-colored, full width.
private struct CostBudgetBanner: View {
    let text: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption.weight(.bold))
                .foregroundStyle(OpenClawBrand.danger)
            Text(self.text)
                .font(.caption.weight(.semibold))
                .foregroundStyle(OpenClawBrand.danger)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background {
            RoundedRectangle(cornerRadius: OpenClawProMetric.controlRadius, style: .continuous)
                .fill(OpenClawBrand.danger.opacity(0.10))
                .overlay {
                    RoundedRectangle(cornerRadius: OpenClawProMetric.controlRadius, style: .continuous)
                        .strokeBorder(OpenClawBrand.danger.opacity(0.30), lineWidth: 1)
                }
        }
    }
}

// MARK: - Breakdown rows

/// A per-model or per-agent breakdown row: title, cost, token count, and a cost-share bar.
private struct CostBreakdownRow: View {
    @Environment(\.colorScheme) private var colorScheme
    let title: String
    let cost: Double
    let tokens: Int
    let share: Double
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(self.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
                Spacer(minLength: 6)
                Text(CostFormatting.currency(self.cost))
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(self.color)
            }
            HStack(spacing: 8) {
                ProProgressBar(progress: self.share, color: self.color)
                Text("\(CostFormatting.compactNumber(self.tokens)) tok")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 72, alignment: .trailing)
            }
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

    private var rowFill: Color {
        self.colorScheme == .dark ? Color.white.opacity(0.035) : Color(uiColor: .systemBackground)
    }

    private var rowBorder: Color {
        Color(uiColor: .separator).opacity(self.colorScheme == .dark ? 0.24 : 0.22)
    }
}

/// One derived model-mix day row: branch icon, the date, and the "model A → model B" transition.
private struct CostModelMixRow: View {
    let day: ModelMixDay

    var body: some View {
        ProStatusRow(
            icon: "arrow.triangle.branch",
            title: self.day.transitionLabel,
            detail: self.day.detail,
            value: self.day.date.formatted(.dateTime.month(.abbreviated).day()),
            color: OpenClawBrand.warn)
    }
}

/// A small inline note row for in-panel empty / informational states (lighter than a full empty card).
private struct CostInlineNote: View {
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
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
    }
}

// MARK: - Budget edit sheet

/// Sheet for setting the daily / monthly spend caps and toggling alerts. Writes straight through the
/// `CostBudgetStore`, which persists each cap to `UserDefaults` in its `didSet`. Entering 0 (or
/// clearing) turns a cap off.
private struct CostBudgetEditSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var budget: CostBudgetStore
    @State private var dailyText = ""
    @State private var monthlyText = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    self.capField(
                        title: "Daily budget",
                        text: self.$dailyText,
                        prompt: "Off")
                    self.capField(
                        title: "30-day budget",
                        text: self.$monthlyText,
                        prompt: "Off")
                } header: {
                    Text("Spend caps (USD)")
                } footer: {
                    Text("Budgets are stored on this device only — the gateway has no spend limit. Leave a field blank or 0 to turn it off.")
                }

                Section {
                    Toggle("Over-budget alerts", isOn: self.$budget.alertsEnabled)
                } footer: {
                    Text("Show a banner and a Command Center badge when spend nears or passes a cap.")
                }
            }
            .navigationTitle("Budget")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { self.dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        self.commit()
                        self.dismiss()
                    }
                }
            }
            .onAppear(perform: self.seedFields)
        }
        .presentationDetents([.medium])
    }

    private func capField(title: String, text: Binding<String>, prompt: String) -> some View {
        HStack {
            Text(title)
            Spacer(minLength: 12)
            TextField(prompt, text: text)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 120)
        }
    }

    /// Seed the text fields from the persisted caps; a 0 cap shows as empty ("Off").
    private func seedFields() {
        self.dailyText = self.budget.dailyUSD > 0 ? Self.format(self.budget.dailyUSD) : ""
        self.monthlyText = self.budget.monthlyUSD > 0 ? Self.format(self.budget.monthlyUSD) : ""
    }

    /// Parse the fields back into caps; an empty / unparseable / negative value turns the cap off (0).
    private func commit() {
        self.budget.dailyUSD = Self.parse(self.dailyText)
        self.budget.monthlyUSD = Self.parse(self.monthlyText)
    }

    private static func parse(_ text: String) -> Double {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let value = Double(trimmed), value > 0 else { return 0 }
        return value
    }

    private static func format(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...2)))
    }
}
