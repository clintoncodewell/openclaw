import SwiftUI

/// The Briefs / Reports inbox: every cron job's run-log entries aggregated (`cron.runs`,
/// `scope: "all"`), grouped into dated sections, newest first. Pushed inside Command Center's
/// existing NavigationStack so the system back button works for free.
struct BriefsInboxScreen: View {
    @Environment(NodeAppModel.self) private var appModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var viewModel = BriefsInboxViewModel()

    var body: some View {
        ZStack {
            CommandControlBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    self.header
                    self.searchField
                    self.filterChips
                    self.content
                }
                .padding(.top, 14)
                .padding(.bottom, 18)
            }
            .safeAreaPadding(.bottom, OpenClawProMetric.bottomScrollInset)
        }
        .navigationTitle("Briefs")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(for: BriefRun.self) { run in
            BriefDetailScreen(run: run)
        }
        .refreshable {
            await self.viewModel.load(appModel: self.appModel, force: true)
        }
        .task(id: self.scenePhase) {
            guard self.scenePhase == .active else { return }
            await self.viewModel.load(appModel: self.appModel, force: false)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Briefs")
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
            return "Loading scheduled reports"
        case .offline:
            return "Gateway offline"
        case .error:
            return "Reports unavailable"
        case .empty:
            return "No reports yet"
        case .loaded:
            let count = self.viewModel.sections.reduce(0) { $0 + $1.runs.count }
            return count == 1 ? "1 report" : "\(count) reports"
        }
    }

    private var searchField: some View {
        BriefsSearchField(viewModel: self.viewModel) {
            self.viewModel.searchChanged(appModel: self.appModel)
        }
        .padding(.horizontal, OpenClawProMetric.pagePadding)
    }

    private var filterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(BriefStatusFilter.allCases) { filter in
                    BriefFilterChip(
                        title: filter.label,
                        isSelected: self.viewModel.statusFilter == filter)
                    {
                        guard self.viewModel.statusFilter != filter else { return }
                        self.viewModel.statusFilter = filter
                        Task { await self.viewModel.load(appModel: self.appModel, force: true) }
                    }
                }

                if !self.viewModel.availableJobs.isEmpty {
                    Divider().frame(height: 22)
                    BriefFilterChip(
                        title: "All jobs",
                        isSelected: self.viewModel.jobFilter == nil)
                    {
                        guard self.viewModel.jobFilter != nil else { return }
                        self.viewModel.jobFilter = nil
                        Task { await self.viewModel.load(appModel: self.appModel, force: true) }
                    }
                    ForEach(self.viewModel.availableJobs, id: \.id) { job in
                        BriefFilterChip(
                            title: job.name,
                            isSelected: self.viewModel.jobFilter == job.id)
                        {
                            let next = self.viewModel.jobFilter == job.id ? nil : job.id
                            self.viewModel.jobFilter = next
                            Task { await self.viewModel.load(appModel: self.appModel, force: true) }
                        }
                    }
                }
            }
            .padding(.horizontal, OpenClawProMetric.pagePadding)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch self.viewModel.state {
        case .idle, .loading:
            self.loadingState
        case .offline:
            self.emptyState(
                icon: "wifi.slash",
                title: "Gateway offline",
                detail: "Connect to the gateway to see scheduled reports.")
        case let .error(message):
            self.emptyState(
                icon: "exclamationmark.triangle.fill",
                title: "Briefs unavailable",
                detail: message)
        case .empty:
            self.emptyState(
                icon: "tray",
                title: "No briefs yet",
                detail: "Scheduled jobs will post their reports here.")
        case .loaded:
            let sections = self.viewModel.sections
            if sections.isEmpty {
                self.emptyState(
                    icon: "line.3.horizontal.decrease.circle",
                    title: "No matching briefs",
                    detail: "Try a different filter or search term.")
            } else {
                ForEach(sections) { section in
                    self.sectionView(section)
                }
            }
        }
    }

    private func sectionView(_ section: BriefsDateSection) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ProSectionHeader(title: section.title)
            CommandPanel(padding: 8) {
                VStack(spacing: 8) {
                    ForEach(section.runs) { run in
                        NavigationLink(value: run) {
                            BriefRowView(run: run)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, OpenClawProMetric.pagePadding)
        }
    }

    private var loadingState: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text("Loading briefs")
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

/// Search bar bound to the inbox view model. Kept as its own view so `@Bindable` can project a
/// two-way binding from the `@Observable` view model held as `@State` by the parent screen.
private struct BriefsSearchField: View {
    @Environment(\.colorScheme) private var colorScheme
    @Bindable var viewModel: BriefsInboxViewModel
    let onChange: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            TextField("Search briefs", text: self.$viewModel.searchText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .onChange(of: self.viewModel.searchText) {
                    self.onChange()
                }
            if !self.viewModel.searchText.isEmpty {
                Button {
                    self.viewModel.searchText = ""
                    self.onChange()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background {
            RoundedRectangle(cornerRadius: OpenClawProMetric.controlRadius, style: .continuous)
                .fill(Color(uiColor: .secondarySystemGroupedBackground))
                .overlay {
                    RoundedRectangle(cornerRadius: OpenClawProMetric.controlRadius, style: .continuous)
                        .strokeBorder(Color(uiColor: .separator).opacity(0.30), lineWidth: 1)
                }
        }
    }
}

/// A single run-log entry row: status badge, job name, timestamp, and a one-line preview.
/// Layout mirrors the macOS cron run row (`CronSettings+Rows.runRow`).
private struct BriefRowView: View {
    @Environment(\.colorScheme) private var colorScheme
    let run: BriefRun

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ProIconBadge(systemName: self.run.statusKind.icon, color: self.run.statusKind.color)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(self.run.jobName)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)
                    Spacer(minLength: 6)
                    Text(self.run.date.formatted(date: .omitted, time: .shortened))
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                Text(self.previewText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 8) {
                    ProValuePill(value: self.run.statusLabel, color: self.run.statusKind.color)
                    if let durationLabel = self.run.durationLabel {
                        Text(durationLabel)
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.tertiary)
                }
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
        .contentShape(Rectangle())
    }

    private var previewText: String {
        if let error = self.run.error, self.run.statusKind == .error {
            return error
        }
        return self.run.summaryPreview.isEmpty ? "No summary." : self.run.summaryPreview
    }

    private var rowFill: Color {
        self.colorScheme == .dark ? Color.white.opacity(0.035) : Color(uiColor: .systemBackground)
    }

    private var rowBorder: Color {
        Color(uiColor: .separator).opacity(self.colorScheme == .dark ? 0.24 : 0.22)
    }
}

/// Small selectable pill for the status / job filter row.
private struct BriefFilterChip: View {
    @Environment(\.colorScheme) private var colorScheme
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: self.action) {
            Text(self.title)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .foregroundStyle(self.isSelected ? Color.white : Color.primary)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background {
                    Capsule()
                        .fill(self.isSelected ? OpenClawBrand.accent : self.unselectedFill)
                        .overlay {
                            Capsule()
                                .strokeBorder(
                                    self.isSelected ? Color.clear : Color(uiColor: .separator).opacity(0.30),
                                    lineWidth: 1)
                        }
                }
        }
        .buttonStyle(.plain)
    }

    private var unselectedFill: Color {
        self.colorScheme == .dark ? Color.white.opacity(0.05) : Color(uiColor: .secondarySystemGroupedBackground)
    }
}
