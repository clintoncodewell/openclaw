import OpenClawKit
import SwiftUI

/// The Run Explorer list: recent agent runs (sessions), newest first, each a card with its key metrics
/// (model, tool-call count, tokens, when, and aggregate model latency) drawn from the `sessions.usage`
/// rollups. Tapping a run pushes `RunTimelineScreen` for that session's ordered tool-call timeline.
/// Pushed inside Command Center's existing NavigationStack so the system back button works for free.
struct TraceListScreen: View {
    @Environment(NodeAppModel.self) private var appModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var viewModel = TraceExplorerViewModel()

    var body: some View {
        ZStack {
            CommandControlBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    self.header
                    self.content
                }
                .padding(.top, 14)
                .padding(.bottom, 18)
            }
            .safeAreaPadding(.bottom, OpenClawProMetric.bottomScrollInset)
        }
        .navigationTitle("Runs")
        .navigationBarTitleDisplayMode(.inline)
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
            Text("Runs")
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
            return "Loading recent runs"
        case .offline:
            return "Gateway offline"
        case .error:
            return "Runs unavailable"
        case .empty:
            return "No recent runs"
        case let .loaded(rows):
            return rows.count == 1 ? "1 run" : "\(rows.count) runs"
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
                detail: "Connect to the gateway to inspect recent runs.")
        case let .error(message):
            self.emptyState(
                icon: "exclamationmark.triangle.fill",
                title: "Runs unavailable",
                detail: message)
        case .empty:
            self.emptyState(
                icon: "point.3.connected.trianglepath.dotted",
                title: "No recent runs",
                detail: "Agent runs with recorded activity will appear here.")
        case let .loaded(rows):
            self.runsSection(rows)
        }
    }

    private func runsSection(_ rows: [RunRow]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ProSectionHeader(title: "Recent runs")
            VStack(spacing: 8) {
                ForEach(rows) { row in
                    NavigationLink {
                        RunTimelineScreen(
                            sessionKey: row.historySessionKey,
                            title: row.title,
                            modelLabel: row.modelLabel,
                            runCost: row.totalCost)
                    } label: {
                        RunListRow(row: row)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, OpenClawProMetric.pagePadding)
        }
    }

    private var loadingState: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text("Loading recent runs")
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

/// One run row card: a status/icon badge, the run title + a metric subtitle from the usage rollups, a
/// model pill, and a relative-time caption.
private struct RunListRow: View {
    let row: RunRow

    var body: some View {
        CommandPanel(padding: 12) {
            HStack(alignment: .center, spacing: 12) {
                ProIconBadge(systemName: "point.3.connected.trianglepath.dotted", color: OpenClawBrand.accent)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(self.row.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.82)
                        Spacer(minLength: 6)
                        if let when = self.row.relativeActivity {
                            Text(when)
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Text(self.row.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if let model = self.row.modelLabel {
                        HStack(spacing: 8) {
                            ProValuePill(value: model, color: OpenClawBrand.accent)
                            Spacer(minLength: 0)
                        }
                    }
                }
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.tertiary)
            }
        }
    }
}
