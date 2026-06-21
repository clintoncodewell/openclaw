import OpenClawKit
import SwiftUI

/// The Provider Auth health surface: per-provider OAuth / credential health from `models.authStatus`
/// (the RICH per-profile endpoint), with "re-auth needed" cards (status + reasonCode + expiry
/// countdown), quota bars for providers that report usage windows, and an admin "Clear dead credential"
/// action behind a confirm dialog. Pushed inside Command Center's existing NavigationStack so the
/// system back button works for free.
///
/// This is the surface that would have caught the OpenAI OAuth outage early: a dead single-session OAuth
/// shows here as provider/profile `status: expired|missing` with a `reasonCode` and an expiry label.
///
/// RE-AUTH IS HOST-SIDE: there is NO gateway RPC to trigger a provider OAuth re-login from the app
/// (`web.login.*` is channel web/QR login, not provider OAuth). The card SURFACES the re-auth need and
/// can clear the dead credential via `models.authLogout` (admin) so the next host-side login is clean —
/// it cannot complete a re-login in-app. The copy frames it as "re-login on the gateway host".
struct AuthHealthScreen: View {
    @Environment(NodeAppModel.self) private var appModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var viewModel = AuthHealthViewModel()
    /// The provider staged for the "Clear dead credential" confirm dialog; non-nil drives the dialog.
    @State private var logoutContext: LogoutContext?
    /// Transient banner for the last logout outcome, cleared on the next load.
    @State private var actionNoticeText: String?

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
        .navigationTitle("Provider Auth")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            await self.viewModel.load(appModel: self.appModel, force: true)
        }
        .task(id: self.scenePhase) {
            guard self.scenePhase == .active else { return }
            await self.viewModel.load(appModel: self.appModel, force: false)
        }
        .confirmationDialog(
            "Clear dead credential",
            isPresented: self.logoutPresented,
            titleVisibility: .visible,
            presenting: self.logoutContext)
        { context in
            Button("Clear \(context.providerName) credential", role: .destructive) {
                self.confirmLogout(context)
            }
            Button("Cancel", role: .cancel) {}
        } message: { context in
            Text("Removes the dead credential and aborts in-flight runs for \(context.providerName). You must re-login on the gateway host — this does not re-authenticate from the app.")
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Provider Auth")
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
            return "Loading provider credential health"
        case .offline:
            return "Gateway offline"
        case .error:
            return "Auth status unavailable"
        case .empty:
            return "No providers configured"
        case let .loaded(report):
            if report.reauthCount > 0 {
                return report.reauthCount == 1
                    ? "1 provider needs re-auth"
                    : "\(report.reauthCount) providers need re-auth"
            }
            if report.expiringCount > 0 {
                return report.expiringCount == 1
                    ? "1 credential expiring soon"
                    : "\(report.expiringCount) credentials expiring soon"
            }
            return "All provider credentials healthy"
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
                detail: "Connect to the gateway to see provider auth.")
        case let .error(message):
            self.emptyState(
                icon: "exclamationmark.triangle.fill",
                title: "Auth status unavailable",
                detail: message)
        case .empty:
            self.emptyState(
                icon: "key.horizontal",
                title: "No providers configured",
                detail: "Provider auth health appears once a model provider is configured.")
        case let .loaded(report):
            self.loadedContent(report)
        }
    }

    @ViewBuilder
    private func loadedContent(_ report: AuthHealthReport) -> some View {
        if let notice = self.actionNoticeText {
            AuthInlineNote(icon: "info.circle", text: notice)
                .padding(.horizontal, OpenClawProMetric.pagePadding)
        }
        if self.viewModel.adminActionUnavailable {
            self.adminNotice
        }
        self.providersSection(report)
        self.reauthNote
    }

    // MARK: - Providers

    private func providersSection(_ report: AuthHealthReport) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ProSectionHeader(title: "Providers")
            VStack(spacing: 10) {
                ForEach(report.providers) { provider in
                    AuthProviderCard(
                        provider: provider,
                        isWorking: self.viewModel.loggingOutProvider == provider.provider,
                        canClear: !self.viewModel.adminActionUnavailable,
                        onClear: { self.presentLogout(provider) })
                }
            }
            .padding(.horizontal, OpenClawProMetric.pagePadding)
        }
    }

    // MARK: - Notices

    private var adminNotice: some View {
        AuthInlineNote(
            icon: "lock.shield",
            text: "This device's grant lacks operator.admin, so clearing credentials is disabled. Re-login still happens on the gateway host.")
            .padding(.horizontal, OpenClawProMetric.pagePadding)
    }

    private var reauthNote: some View {
        AuthInlineNote(
            icon: "info.circle",
            text: "Re-auth happens on the gateway host (run openclaw onboard / auth there). The app surfaces the need and can clear a dead credential, but cannot complete an OAuth re-login in-app.")
            .padding(.horizontal, OpenClawProMetric.pagePadding)
    }

    // MARK: - Logout action

    private var logoutPresented: Binding<Bool> {
        Binding(
            get: { self.logoutContext != nil },
            set: { if !$0 { self.logoutContext = nil } })
    }

    private func presentLogout(_ provider: AuthProviderLite) {
        self.logoutContext = LogoutContext(provider: provider.provider, providerName: provider.name)
    }

    private func confirmLogout(_ context: LogoutContext) {
        Task {
            let outcome = await self.viewModel.clearDeadCredential(
                appModel: self.appModel,
                provider: context.provider)
            switch outcome {
            case let .cleared(removed, aborted):
                self.actionNoticeText = "Cleared \(context.providerName): \(removed) profile(s) removed, \(aborted) run(s) aborted. Re-login on the host."
            case .missingScope:
                self.actionNoticeText = "Clear blocked — this device lacks operator.admin."
            case let .failed(message):
                self.actionNoticeText = "Could not clear: \(message)"
            }
        }
    }

    // MARK: - Shared states

    private var loadingState: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text("Loading provider auth")
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

/// The staged logout context: a provider to clear.
private struct LogoutContext: Identifiable {
    let provider: String
    let providerName: String

    var id: String { self.provider }
}

// MARK: - Provider card

/// One provider auth card: name + plan + status pill, a re-auth callout (reasonCode + expiry countdown)
/// when a re-login is needed, quota bars for any usage windows, per-profile rows, and an admin "Clear
/// dead credential" action. Healthy providers render compact (no callout).
private struct AuthProviderCard: View {
    let provider: AuthProviderLite
    let isWorking: Bool
    let canClear: Bool
    let onClear: () -> Void

    var body: some View {
        ProCard(tint: self.cardTint, isProminent: self.provider.needsReauth, padding: 12) {
            VStack(alignment: .leading, spacing: 10) {
                self.cardHeader
                if self.provider.needsReauth || self.provider.isExpiringSoon {
                    self.reauthCallout
                }
                if !self.provider.windows.isEmpty {
                    self.quotaSection
                }
                if !self.provider.profiles.isEmpty {
                    self.profilesSection
                }
            }
        }
    }

    private var cardTint: Color? {
        if self.provider.needsReauth { return OpenClawBrand.danger }
        if self.provider.isExpiringSoon { return OpenClawBrand.warn }
        return nil
    }

    private var cardHeader: some View {
        HStack(alignment: .center, spacing: 10) {
            ProIconBadge(systemName: self.headerIcon, color: self.provider.status.color)
            VStack(alignment: .leading, spacing: 2) {
                Text(self.provider.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                if let plan = self.planLabel {
                    Text(plan)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            ProValuePill(value: self.provider.status.label, color: self.provider.status.color)
        }
    }

    private var headerIcon: String {
        if self.provider.needsReauth { return "key.slash.fill" }
        if self.provider.isExpiringSoon { return "clock.badge.exclamationmark.fill" }
        return "key.fill"
    }

    private var planLabel: String? {
        let trimmed = self.provider.plan?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: Re-auth callout

    private var reauthCallout: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(self.provider.status.color)
                VStack(alignment: .leading, spacing: 2) {
                    Text(self.calloutTitle)
                        .font(.caption.weight(.semibold))
                    Text(self.calloutDetail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            if let expiry = self.provider.leadProfile?.expiry ?? self.provider.expiry {
                self.expiryCountdown(expiry)
            }
            if self.canClear {
                self.clearButton
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: OpenClawProMetric.controlRadius, style: .continuous)
                .fill(self.provider.status.color.opacity(0.08))
        }
    }

    private var calloutTitle: String {
        if self.provider.needsReauth {
            return "Provider auth expired — re-login on the gateway host"
        }
        return "Credential expiring soon — plan a host-side re-login"
    }

    private var calloutDetail: String {
        let profile = self.provider.leadProfile
        let typePart = profile.map { "\($0.typeLabel)" } ?? "Credential"
        if let reason = profile?.reasonText {
            return "\(typePart): \(reason)"
        }
        return "\(typePart) needs re-authentication on the host (openclaw onboard / auth)."
    }

    private func expiryCountdown(_ expiry: AuthExpiryLite) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "timer")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(self.provider.status.color)
                Text(self.expiryLabel(expiry))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(self.provider.status.color)
                Spacer(minLength: 0)
            }
            ProProgressBar(progress: expiry.countdownFraction, color: self.provider.status.color)
        }
    }

    private func expiryLabel(_ expiry: AuthExpiryLite) -> String {
        if expiry.isExpired { return "Expired" }
        if let label = expiry.label { return "Expires in \(label)" }
        return "Expiry imminent"
    }

    private var clearButton: some View {
        Button(role: .destructive, action: self.onClear) {
            if self.isWorking {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Clearing…")
                }
            } else {
                Label("Clear dead credential", systemImage: "trash")
            }
        }
        .font(.caption.weight(.semibold))
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(self.isWorking)
    }

    // MARK: Quota

    private var quotaSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("Quota")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Spacer(minLength: 0)
                if let window = self.provider.worstWindow {
                    Text("\(Int(self.provider.worstUsedPercent.rounded()))% · \(window.label)")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }
            ProProgressBar(progress: self.quotaFraction, color: self.quotaColor)
        }
    }

    private var quotaFraction: Double {
        max(0, min(self.provider.worstUsedPercent / 100, 1))
    }

    private var quotaColor: Color {
        self.provider.worstUsedPercent >= OpsHealthThresholds.providerQuotaWarn
            ? OpenClawBrand.warn
            : OpenClawBrand.accentHot
    }

    // MARK: Profiles

    private var profilesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Profiles")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            VStack(spacing: 6) {
                ForEach(self.provider.profiles) { profile in
                    AuthProfileRow(profile: profile)
                }
            }
        }
    }
}

// MARK: - Profile row

/// One credential-profile row: status dot, profile id + type, expiry label, and a status pill. The
/// granular per-profile view behind the provider's rolled-up status.
private struct AuthProfileRow: View {
    @Environment(\.colorScheme) private var colorScheme
    let profile: AuthProfileLite

    var body: some View {
        HStack(spacing: 10) {
            ProStatusDot(color: self.profile.status.color)
            VStack(alignment: .leading, spacing: 1) {
                Text(self.profile.profileId)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Text(self.detailText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            Text(self.profile.status.label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(self.profile.status.color)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background {
            RoundedRectangle(cornerRadius: OpenClawProMetric.controlRadius, style: .continuous)
                .fill(self.rowFill)
                .overlay {
                    RoundedRectangle(cornerRadius: OpenClawProMetric.controlRadius, style: .continuous)
                        .strokeBorder(self.rowBorder, lineWidth: 1)
                }
        }
    }

    private var detailText: String {
        if let expiry = self.profile.expiry {
            if expiry.isExpired { return "\(self.profile.typeLabel) · expired" }
            if let label = expiry.label { return "\(self.profile.typeLabel) · \(label) left" }
        }
        if let reason = self.profile.reasonText { return "\(self.profile.typeLabel) · \(reason)" }
        return self.profile.typeLabel
    }

    private var rowFill: Color {
        self.colorScheme == .dark ? Color.white.opacity(0.035) : Color(uiColor: .systemBackground)
    }

    private var rowBorder: Color {
        Color(uiColor: .separator).opacity(self.colorScheme == .dark ? 0.24 : 0.22)
    }
}

// MARK: - Inline note

/// A small inline note row for informational states, mirroring `OpsInlineNote`.
private struct AuthInlineNote: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: self.icon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(self.text)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .proPanelSurface(radius: OpenClawProMetric.cardRadius)
    }
}
