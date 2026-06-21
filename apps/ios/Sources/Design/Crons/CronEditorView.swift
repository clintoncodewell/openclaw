import OpenClawProtocol
import SwiftUI

/// The cron job editor sheet, driven by `.sheet(item: $form)` (`CronEditorForm` is `Identifiable`):
/// a `nil` `jobId` is CREATE (`cron.add`), a set `jobId` is EDIT (`cron.update` patch). Built from the
/// same primitives the skill editor sheet uses — `NavigationStack { OpenClawProBackground + ScrollView of
/// ProCards }`, `TextField` / `TextEditor` / `Picker(.segmented)` / a custom switch row — so no new design
/// system work. Save validates client-side first (`CronFormValidator`) to avoid round-trips, then calls
/// the admin-scoped create/update RPC on the shared `CronJobsViewModel`; errors surface inline (including
/// the "Reconnect with admin scope" mapping).
struct CronEditorView: View {
    @Environment(NodeAppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss

    /// The view model owning the list — Save commits through it (re-fetch on success).
    let viewModel: CronJobsViewModel
    /// Working copy of the form; edits stay local until Save.
    @State private var form: CronEditorForm
    /// Inline validation / gateway error under the Save button. `nil` == no error.
    @State private var errorText: String?
    /// True while the create/update RPC is in flight, to disable Save + show a spinner.
    @State private var isSaving = false

    init(viewModel: CronJobsViewModel, form: CronEditorForm) {
        self.viewModel = viewModel
        self._form = State(initialValue: form)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                OpenClawProBackground()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        self.detailsCard
                        self.scheduleCard
                        self.targetCard
                        self.saveCard
                    }
                    .padding(.vertical, 18)
                }
            }
            .navigationTitle(self.form.isEditing ? "Edit job" : "New job")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { self.dismiss() }
                }
            }
        }
    }

    // MARK: - Details (name + prompt)

    private var detailsCard: some View {
        ProCard(radius: OpenClawProMetric.cardRadius) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Details")
                    .font(.headline)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Name")
                        .font(.subheadline.weight(.semibold))
                    TextField("Daily brief", text: self.$form.name)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(self.promptLabel)
                        .font(.subheadline.weight(.semibold))
                    TextEditor(text: self.$form.prompt)
                        .frame(minHeight: 96)
                        .padding(6)
                        .background {
                            RoundedRectangle(cornerRadius: OpenClawProMetric.controlRadius, style: .continuous)
                                .fill(Color(uiColor: .secondarySystemGroupedBackground))
                                .overlay {
                                    RoundedRectangle(
                                        cornerRadius: OpenClawProMetric.controlRadius,
                                        style: .continuous)
                                        .strokeBorder(Color(uiColor: .separator).opacity(0.30), lineWidth: 1)
                                }
                        }
                    Text(self.promptHelp)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, OpenClawProMetric.pagePadding)
    }

    /// Prompt field label/help depend on the session target: main jobs post a system event, isolated /
    /// current jobs run an agent turn. This mirrors the gateway's payload-kind-per-target constraint.
    private var promptLabel: String {
        switch self.form.sessionTarget.payloadKind {
        case .systemEvent: "System event text"
        case .agentTurn: "Prompt"
        }
    }

    private var promptHelp: String {
        switch self.form.sessionTarget.payloadKind {
        case .systemEvent: "Posted into the main session at run time."
        case .agentTurn: "Sent to the agent as a turn at run time."
        }
    }

    // MARK: - Schedule

    private var scheduleCard: some View {
        ProCard(radius: OpenClawProMetric.cardRadius) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Schedule")
                    .font(.headline)
                Picker("Schedule kind", selection: self.$form.scheduleKind) {
                    ForEach(CronScheduleKind.allCases) { kind in
                        Text(kind.label).tag(kind)
                    }
                }
                .pickerStyle(.segmented)

                self.scheduleField

                Text(self.form.scheduleKind.help)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, OpenClawProMetric.pagePadding)
    }

    /// The schedule input switches on the selected kind: cron expression, interval minutes, or ISO date.
    @ViewBuilder
    private var scheduleField: some View {
        switch self.form.scheduleKind {
        case .cron:
            TextField("0 9 * * *", text: self.$form.cronExpr)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
        case .every:
            HStack(spacing: 8) {
                TextField("60", text: self.$form.everyMinutes)
                    .textFieldStyle(.roundedBorder)
                    .keyboardType(.numberPad)
                    .frame(maxWidth: 120)
                Text("minutes")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        case .at:
            TextField("2026-07-01T09:00:00Z", text: self.$form.atISO)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
        }
    }

    // MARK: - Target (session target + agent + enabled)

    private var targetCard: some View {
        ProCard(radius: OpenClawProMetric.cardRadius) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Target")
                    .font(.headline)
                Picker("Session target", selection: self.$form.sessionTarget) {
                    ForEach(CronSessionTarget.allCases) { target in
                        Text(target.label).tag(target)
                    }
                }
                .pickerStyle(.segmented)

                self.agentPicker

                // Custom switch row (native Toggle row-taps are flaky on iOS 26 in these sheets — reuse
                // the same explicit-Button switch the skill editor uses).
                self.enabledRow
            }
        }
        .padding(.horizontal, OpenClawProMetric.pagePadding)
    }

    /// Agent picker sourced from `appModel.gatewayAgents`. "Default" (nil) inherits the gateway's default
    /// agent. Only shown when the gateway reported an agent list.
    @ViewBuilder
    private var agentPicker: some View {
        if !self.appModel.gatewayAgents.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Agent")
                    .font(.subheadline.weight(.semibold))
                Picker("Agent", selection: self.$form.agentId) {
                    Text("Default agent").tag(String?.none)
                    ForEach(self.appModel.gatewayAgents, id: \.id) { agent in
                        Text(self.agentLabel(agent)).tag(String?.some(agent.id))
                    }
                }
                .pickerStyle(.menu)
            }
        }
    }

    private func agentLabel(_ agent: AgentSummary) -> String {
        let name = agent.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? agent.id : name
    }

    private var enabledRow: some View {
        Button {
            self.form.enabled.toggle()
        } label: {
            HStack {
                Text("Enabled")
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 8)
                self.switchIndicator(isOn: self.form.enabled)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Enabled")
        .accessibilityValue(self.form.enabled ? "On" : "Off")
    }

    /// Capsule switch indicator, matching `AgentProTab.skillEditorSwitchIndicator`.
    private func switchIndicator(isOn: Bool) -> some View {
        Capsule()
            .fill(isOn ? Color.accentColor : Color.secondary.opacity(0.35))
            .frame(width: 52, height: 32)
            .overlay(alignment: isOn ? .trailing : .leading) {
                Circle()
                    .fill(Color.white)
                    .frame(width: 28, height: 28)
                    .padding(2)
                    .shadow(color: Color.black.opacity(0.14), radius: 1, x: 0, y: 1)
            }
    }

    // MARK: - Save

    private var saveCard: some View {
        ProCard(radius: OpenClawProMetric.cardRadius) {
            VStack(alignment: .leading, spacing: 10) {
                Button {
                    // Flip isSaving SYNCHRONOUSLY (and guard) so a rapid second tap can't spawn a second
                    // save Task before the async path reaches its own guard — that would double cron.add.
                    guard !self.isSaving else { return }
                    self.isSaving = true
                    Task { await self.save() }
                } label: {
                    HStack(spacing: 8) {
                        if self.isSaving {
                            ProgressView().controlSize(.small)
                        }
                        Text(self.form.isEditing ? "Save changes" : "Create job")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(self.isSaving)

                if let errorText {
                    Text(errorText)
                        .font(.caption)
                        .foregroundStyle(OpenClawBrand.warn)
                }
            }
        }
        .padding(.horizontal, OpenClawProMetric.pagePadding)
    }

    /// Validate, then create or update via the view model. On success the sheet dismisses (the VM has
    /// already re-fetched the list); on failure the inline error shows and the sheet stays open.
    private func save() async {
        // isSaving was set synchronously by the button tap; always clear it (covers the invalid path too).
        defer { self.isSaving = false }
        self.errorText = nil
        switch CronFormValidator.validate(self.form) {
        case let .invalid(message):
            self.errorText = message
        case let .valid(request):
            let failure: String?
            if let jobId = self.form.jobId {
                failure = await self.viewModel.updateJob(appModel: self.appModel, jobId: jobId, request: request)
            } else {
                failure = await self.viewModel.createJob(appModel: self.appModel, request: request)
            }
            if let failure {
                self.errorText = failure
            } else {
                self.dismiss()
            }
        }
    }
}
