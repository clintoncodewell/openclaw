import OpenClawProtocol
import SwiftUI

/// The Crons / Jobs dashboard: the cron JOB-DEFINITION list (`cron.list`), the scheduler status
/// (`cron.status`), and a per-job last-run badge (from one `cron.runs` page, reusing the Briefs
/// `BriefRun` decode). Pushed inside Command Center's existing NavigationStack so the system back button
/// works for free. Reuses the same screen scaffold as `BriefsInboxScreen` / `CostInsightsScreen`.
///
/// AUTHORING (honest scope): list + run-history are `operator.read` (always available when connected);
/// create / edit / run-now / pause / delete are `operator.admin`. When the device lacks admin
/// (`viewModel.hasAdmin == false`) the mutating controls disable and an inline note explains how to
/// regain them — mirroring the shipped skill-mutation + AuthHealth gating exactly. No dead buttons.
struct CronJobsScreen: View {
    @Environment(NodeAppModel.self) private var appModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var viewModel = CronJobsViewModel()
    /// Drives the editor sheet: `nil` == closed, set == create (nil jobId) or edit (job id).
    @State private var editorForm: CronEditorForm?
    /// Job awaiting delete confirmation, driving the `.confirmationDialog`.
    @State private var pendingDelete: CronJob?

    var body: some View {
        ZStack {
            CommandControlBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    self.header
                    self.statusCard
                    self.adminNote
                    self.content
                    self.briefsLink
                }
                .padding(.top, 14)
                .padding(.bottom, 18)
            }
            .safeAreaPadding(.bottom, OpenClawProMetric.bottomScrollInset)
        }
        .navigationTitle("Jobs")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    self.editorForm = CronEditorForm.create()
                } label: {
                    Label("New job", systemImage: "plus")
                }
                // Create is admin-only; disable when narrowed or offline so the control is never dead.
                .disabled(!self.viewModel.hasAdmin || !self.gatewayConnected)
            }
        }
        .sheet(item: self.$editorForm) { form in
            CronEditorView(viewModel: self.viewModel, form: form)
        }
        .confirmationDialog(
            "Delete this job?",
            isPresented: self.deleteDialogBinding,
            titleVisibility: .visible,
            presenting: self.pendingDelete)
        { job in
            Button("Delete \(job.name)", role: .destructive) {
                Task { await self.viewModel.deleteJob(appModel: self.appModel, job: job) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { job in
            Text("\(job.name) will be removed from the scheduler. This can't be undone.")
        }
        .refreshable {
            await self.viewModel.load(appModel: self.appModel, force: true)
        }
        .task(id: self.scenePhase) {
            guard self.scenePhase == .active else { return }
            await self.viewModel.load(appModel: self.appModel, force: false)
        }
    }

    private var gatewayConnected: Bool {
        GatewayStatusBuilder.build(appModel: self.appModel) == .connected
    }

    /// Binding bridge for `.confirmationDialog(isPresented:)` driven by the `pendingDelete` item.
    private var deleteDialogBinding: Binding<Bool> {
        Binding(
            get: { self.pendingDelete != nil },
            set: { if !$0 { self.pendingDelete = nil } })
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Jobs")
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
            return "Loading scheduled jobs"
        case .offline:
            return "Gateway offline"
        case .error:
            return "Jobs unavailable"
        case .empty:
            return "No scheduled jobs yet"
        case let .loaded(jobs):
            return jobs.count == 1 ? "1 scheduled job" : "\(jobs.count) scheduled jobs"
        }
    }

    // MARK: - Scheduler status card

    private var statusCard: some View {
        ProCard(radius: OpenClawProMetric.cardRadius) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Scheduler")
                        .font(.headline)
                    Spacer()
                    ProValuePill(value: self.schedulerOn ? "on" : "off", color: self.schedulerColor)
                }
                HStack(spacing: 10) {
                    self.metric(label: "Jobs", value: "\(self.viewModel.status?.jobs ?? self.viewModel.jobs.count)")
                    self.metric(label: "Next", value: self.nextRunLabel)
                }
                if let actionStatusText = self.viewModel.actionStatusText {
                    Text(actionStatusText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
        .padding(.horizontal, OpenClawProMetric.pagePadding)
    }

    private var schedulerOn: Bool {
        self.viewModel.status?.enabled ?? false
    }

    private var schedulerColor: Color {
        self.schedulerOn ? OpenClawBrand.ok : .secondary
    }

    private var nextRunLabel: String {
        guard let ms = self.viewModel.status?.nextwakeatms else { return "none" }
        return CronTimeFormat.relative(fromMilliseconds: ms)
    }

    private func metric(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            Text(value)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Admin note (read-only gating)

    /// Inline note shown only when connected but the device lacks admin scope, explaining why the
    /// mutating controls are disabled. Reuses the shipped "Reconnect with admin scope" copy.
    @ViewBuilder
    private var adminNote: some View {
        if self.gatewayConnected, !self.viewModel.hasAdmin {
            ProCard(radius: OpenClawProMetric.cardRadius) {
                HStack(spacing: 10) {
                    Image(systemName: "lock.fill")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(OpenClawBrand.warn)
                    Text("Read-only: this device can view jobs and run history. Reconnect with admin scope to create, edit, run, or delete jobs.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, OpenClawProMetric.pagePadding)
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
                detail: "Connect to the gateway to see scheduled jobs.")
        case let .error(message):
            self.emptyState(
                icon: "exclamationmark.triangle.fill",
                title: "Jobs unavailable",
                detail: message)
        case .empty:
            self.emptyState(
                icon: "clock.badge.questionmark",
                title: "No scheduled jobs",
                detail: self.viewModel.hasAdmin
                    ? "Tap + to schedule your first job."
                    : "Scheduled jobs will appear here.")
        case .loaded:
            self.jobsList
        }
    }

    private var jobsList: some View {
        VStack(alignment: .leading, spacing: 8) {
            ProSectionHeader(title: "Scheduled")
            VStack(spacing: 8) {
                ForEach(self.viewModel.sortedJobs, id: \.id) { job in
                    CronJobRow(
                        job: job,
                        lastRun: self.viewModel.lastRuns[job.id],
                        busy: self.viewModel.busyJobIDs.contains(job.id),
                        canMutate: self.viewModel.hasAdmin && self.gatewayConnected,
                        onTap: { self.editorForm = CronEditorForm.edit(job: job) },
                        onRun: { Task { await self.viewModel.runNow(appModel: self.appModel, job: job) } },
                        onToggle: {
                            Task {
                                await self.viewModel.setEnabled(appModel: self.appModel, job: job, enabled: !job.enabled)
                            }
                        },
                        onDelete: { self.pendingDelete = job })
                }
            }
            .padding(.horizontal, OpenClawProMetric.pagePadding)
        }
    }

    // MARK: - Briefs link (run history)

    private var briefsLink: some View {
        NavigationLink {
            BriefsInboxScreen()
        } label: {
            CommandPanel(padding: 12) {
                HStack(alignment: .center, spacing: 12) {
                    ProIconBadge(systemName: "doc.text.magnifyingglass", color: OpenClawBrand.accent)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Run history")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                        Text("Every job's past runs and reports")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, OpenClawProMetric.pagePadding)
    }

    // MARK: - States

    private var loadingState: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text("Loading jobs")
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

/// One cron job row: status badge, name, schedule summary, enabled badge, last-run status, and the
/// Run / Pause-Enable / Edit / Delete controls. Layout follows `AgentProTab.cronJobDetailRow` + the
/// Briefs row. Delete routes through the screen's `.confirmationDialog`. Mutating controls disable when
/// `canMutate == false` (read-only device or offline) so a narrowed device shows the row but never a
/// dead button. (Rows live in a `VStack`, not a `List`, so there is no swipe action — the inline Delete
/// button is the single delete affordance.)
private struct CronJobRow: View {
    @Environment(\.colorScheme) private var colorScheme
    let job: CronJob
    let lastRun: BriefRun?
    let busy: Bool
    let canMutate: Bool
    let onTap: () -> Void
    let onRun: () -> Void
    let onToggle: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Tapping the row body opens the editor (edit); the action buttons below are separate hit
            // targets so a Run/Pause tap never also opens the sheet.
            Button(action: self.onTap) {
                self.rowContent
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!self.canMutate)

            self.actionRow
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

    private var rowContent: some View {
        HStack(alignment: .top, spacing: 12) {
            ProIconBadge(
                systemName: self.job.enabled ? "clock.arrow.circlepath" : "pause.circle",
                color: self.job.enabled ? OpenClawBrand.accent : .secondary)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(self.job.name)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)
                    Spacer(minLength: 6)
                    ProValuePill(
                        value: self.job.enabled ? "enabled" : "paused",
                        color: self.job.enabled ? OpenClawBrand.ok : .secondary)
                }
                Text(CronJobFieldReader.scheduleSummary(self.job))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                self.lastRunLine
            }
            if self.busy {
                ProgressView().controlSize(.small)
            } else if self.canMutate {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    /// Last-run summary line, reusing the Briefs `BriefRun` status kind/label/colors. Absent until a run
    /// exists for this job.
    @ViewBuilder
    private var lastRunLine: some View {
        if let lastRun = self.lastRun {
            HStack(spacing: 6) {
                Image(systemName: lastRun.statusKind.icon)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(lastRun.statusKind.color)
                Text("Last run \(lastRun.statusLabel)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(lastRun.date.formatted(.relative(presentation: .named)))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        } else {
            Text("No runs yet")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private var actionRow: some View {
        HStack(spacing: 8) {
            Button(action: self.onRun) {
                Label("Run", systemImage: "play.fill")
            }
            .disabled(self.busy || !self.canMutate)

            Button(action: self.onToggle) {
                Label(
                    self.job.enabled ? "Pause" : "Enable",
                    systemImage: self.job.enabled ? "pause.fill" : "checkmark")
            }
            .disabled(self.busy || !self.canMutate)

            Spacer(minLength: 0)

            Button(role: .destructive, action: self.onDelete) {
                Label("Delete", systemImage: "trash")
            }
            .disabled(self.busy || !self.canMutate)
        }
        .buttonStyle(.bordered)
        .controlSize(.mini)
        .padding(.top, 8)
        .padding(.leading, 42)
    }

    private var rowFill: Color {
        self.colorScheme == .dark ? Color.white.opacity(0.035) : Color(uiColor: .systemBackground)
    }

    private var rowBorder: Color {
        Color(uiColor: .separator).opacity(self.colorScheme == .dark ? 0.24 : 0.22)
    }
}

/// Relative-time formatting for the scheduler "next run" label. Mirrors `AgentProTab.relativeTime`
/// (ms epoch -> "in 5m" / "2h ago"). Kept local so the Crons surface does not depend on `AgentProTab`.
enum CronTimeFormat {
    static func relative(fromMilliseconds ms: Int) -> String {
        let date = Date(timeIntervalSince1970: Double(ms) / 1000)
        return date.formatted(.relative(presentation: .named))
    }
}
