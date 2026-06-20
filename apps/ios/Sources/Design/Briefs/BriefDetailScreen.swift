import OpenClawChatUI
import SwiftUI

/// Full reader view for a single brief / report. Renders the run's `summary` as markdown via the
/// shared `OpenClawProseView` wrapper. Pushed via NavigationLink, so the system back button is
/// inherited from Command Center's NavigationStack — no custom dismiss handling needed.
struct BriefDetailScreen: View {
    let run: BriefRun

    var body: some View {
        ZStack {
            CommandControlBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    self.headerCard
                    if let error = self.run.error, self.run.statusKind == .error {
                        self.errorCard(error)
                    }
                    self.bodyCard
                    self.footerCard
                }
                .padding(.top, 14)
                .padding(.horizontal, OpenClawProMetric.pagePadding)
                .padding(.bottom, 18)
            }
            .safeAreaPadding(.bottom, OpenClawProMetric.bottomScrollInset)
        }
        .navigationTitle(self.run.jobName)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var headerCard: some View {
        CommandPanel(isProminent: true, padding: 14) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 12) {
                    ProIconBadge(systemName: self.run.statusKind.icon, color: self.run.statusKind.color)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(self.run.jobName)
                            .font(.title3.weight(.semibold))
                            .lineLimit(2)
                            .minimumScaleFactor(0.82)
                        Text(self.run.date.formatted(date: .complete, time: .shortened))
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                }
                ProValuePill(value: self.run.statusLabel, color: self.run.statusKind.color)
            }
        }
    }

    private func errorCard(_ error: String) -> some View {
        ProCard(tint: OpenClawBrand.danger, padding: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Label("Error", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(OpenClawBrand.danger)
                Text(error)
                    .font(.callout)
                    .foregroundStyle(OpenClawBrand.danger)
                    .textSelection(.enabled)
            }
        }
    }

    private var bodyCard: some View {
        CommandPanel(padding: 14) {
            if self.run.summary.isEmpty {
                Text("This run produced no summary.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                OpenClawProseView(text: self.run.summary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var footerCard: some View {
        ProCard(padding: 14) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Run details")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                ForEach(self.footerRows, id: \.label) { row in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(row.label)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 84, alignment: .leading)
                        Text(row.value)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                }
            }
        }
    }

    private var footerRows: [(label: String, value: String)] {
        var rows: [(label: String, value: String)] = [
            (label: "Job", value: self.run.jobName),
            (label: "Time", value: self.run.date.formatted(date: .abbreviated, time: .standard)),
        ]
        if let provider = self.run.provider {
            let model = self.run.modelLabel
            let value = model.map { "\(provider) • \($0)" } ?? provider
            rows.append((label: "Model", value: value))
        } else if let model = self.run.modelLabel {
            rows.append((label: "Model", value: model))
        }
        if let durationLabel = self.run.durationLabel {
            rows.append((label: "Duration", value: durationLabel))
        }
        if let runId = self.run.runId {
            rows.append((label: "Run ID", value: runId))
        }
        return rows
    }
}
