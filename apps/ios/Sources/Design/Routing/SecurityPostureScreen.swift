import OpenClawKit
import SwiftUI

/// The Security Posture surface — an HONEST security view, NOT an audit log. It surfaces only what the
/// gateway actually exposes to an operator session:
/// (a) THIS device's granted operator scopes + role (local, from `DeviceAuthStore`),
/// (b) the PAIRED-DEVICE roster via `device.pair.list` (role + active scopes; the full approved-scope
///     set is redacted server-side),
/// (c) the current exec-approval POLICY via `exec.approvals.get` ("what requires approval right now"),
/// (d) a LIVE pending-approvals + session-local resolved feed from the `exec.approval.requested` /
///     `exec.approval.resolved` broadcast.
///
/// EXPLICITLY NOT a historical security-event log: those records ARE emitted internally
/// (`diagnostic-events.ts:1223`) but kept off the public diagnostic stream and have no query RPC, so the
/// app cannot read them. The screen states the feed is "live session only".
///
/// Lives under Settings (admin/config-shaped). Pushed via `NavigationLink`, so it always supplies its
/// own `ZStack`/`ScrollView`/`navigationTitle` chrome.
struct SecurityPostureScreen: View {
    @Environment(NodeAppModel.self) private var appModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var viewModel = SecurityPostureViewModel()

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
        .navigationTitle("Security")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            await self.viewModel.load(appModel: self.appModel, force: true)
        }
        .task(id: self.scenePhase) {
            guard self.scenePhase == .active else { return }
            await self.viewModel.load(appModel: self.appModel, force: false)
        }
        .task {
            // Live, push-driven pending feed while foregrounded (session-local; resets on relaunch).
            await self.viewModel.observeApprovalEvents(appModel: self.appModel)
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Security")
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
            return "Loading security posture"
        case .offline:
            return "Gateway offline"
        case .error:
            return "Security posture unavailable"
        case .empty:
            return "No posture data available"
        case let .loaded(report):
            // `device.pair.list` requires operator.admin (which subsumes the pairing scope the app never
            // requests), so a non-admin device is denied the call outright — the roster is unavailable,
            // not "this device only." Frame that honestly rather than implying a self-only roster.
            if !report.localScopes.hasAdmin {
                return "Device roster needs admin · live approval feed"
            }
            let deviceCount = report.devices.count
            return deviceCount == 1
                ? "1 paired device · live approval feed"
                : "\(deviceCount) paired devices · live approval feed"
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
                detail: "Connect to the gateway to see security posture.")
        case let .error(message):
            self.emptyState(
                icon: "exclamationmark.triangle.fill",
                title: "Security posture unavailable",
                detail: message)
        case .empty:
            self.emptyState(
                icon: "lock.shield",
                title: "No posture data",
                detail: "Scopes, devices, and approval policy appear once connected.")
        case let .loaded(report):
            self.loadedContent(report)
        }
    }

    @ViewBuilder
    private func loadedContent(_ report: SecurityPostureReport) -> some View {
        self.thisDeviceSection(report.localScopes)
        self.policySection(report)
        self.devicesSection(report.devices)
        self.approvalFeedSection(report.localScopes)
        self.honestyNote
    }

    // MARK: - (a) This device's scopes

    private func thisDeviceSection(_ scopes: LocalDeviceScopes) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ProSectionHeader(title: "This device")
            ProCard(padding: 12) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        ProIconBadge(
                            systemName: scopes.hasAdmin ? "checkmark.shield.fill" : "lock.shield",
                            color: scopes.hasAdmin ? OpenClawBrand.ok : OpenClawBrand.warn)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(scopes.role.map { "Role · \($0)" } ?? "Operator session")
                                .font(.subheadline.weight(.semibold))
                            Text(scopes.isNarrowed
                                ? "Grant lacks operator.admin — admin writes are unavailable"
                                : "Full operator grant, including admin")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 6)
                    }
                    if scopes.scopes.isEmpty {
                        Text("No operator token stored for this device (shared-secret session).")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    } else {
                        FlowLayout(spacing: 6) {
                            ForEach(scopes.sortedScopes, id: \.self) { scope in
                                ScopeChip(scope: scope, granted: true)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, OpenClawProMetric.pagePadding)
        }
    }

    // MARK: - (c) Approval policy

    private func policySection(_ report: SecurityPostureReport) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ProSectionHeader(title: "Approval policy")
            ProCard(padding: 12) {
                if let policy = report.policy {
                    self.policyContent(policy)
                } else if report.policyNeedsAdmin {
                    self.policyUnavailable(
                        "Reading the approval policy needs operator.admin. This device's grant is narrower.")
                } else {
                    self.policyUnavailable("The gateway didn't return an approval policy.")
                }
            }
            .padding(.horizontal, OpenClawProMetric.pagePadding)
        }
    }

    private func policyContent(_ policy: ApprovalPolicyLite) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                ProIconBadge(systemName: "hand.raised.fill", color: policy.posture.color)
                VStack(alignment: .leading, spacing: 2) {
                    Text(policy.posture.label)
                        .font(.subheadline.weight(.semibold))
                    Text(policy.posture.detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 6)
            }
            HStack(spacing: 8) {
                if let security = policy.security {
                    ProCapsule(title: "security: \(security)", color: policy.posture.color)
                }
                if let ask = policy.ask {
                    ProCapsule(title: "ask: \(ask)", color: .secondary)
                }
                Spacer(minLength: 0)
            }
            if policy.agentOverrideCount > 0 {
                Text("\(policy.agentOverrideCount) agent-specific override(s) configured.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func policyUnavailable(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            ProIconBadge(systemName: "lock.slash", color: .secondary)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    // MARK: - (b) Paired devices

    @ViewBuilder
    private func devicesSection(_ devices: [PairedDeviceLite]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ProSectionHeader(title: "Paired devices")
            if devices.isEmpty {
                CommandEmptyStateRow(
                    icon: "laptopcomputer.and.iphone",
                    title: "Device roster unavailable",
                    detail: "Listing paired devices needs operator.admin on this device.")
                    .padding(.horizontal, OpenClawProMetric.pagePadding)
            } else {
                CommandPanel(padding: 8) {
                    VStack(spacing: 8) {
                        ForEach(devices) { device in
                            PairedDeviceRow(device: device)
                        }
                    }
                }
                .padding(.horizontal, OpenClawProMetric.pagePadding)
            }
        }
    }

    // MARK: - (d) Live approval feed

    @ViewBuilder
    private func approvalFeedSection(_ scopes: LocalDeviceScopes) -> some View {
        // The seed (`exec.approval.list`) needs operator.approvals, and the live broadcast is gated by
        // the same scope; operator.admin subsumes both. A device with neither gets an empty seed and zero
        // events, so an empty feed there means "can't see approvals", NOT "nothing happening" — say so
        // rather than show the generic "no approvals" copy.
        let canSeeApprovals = scopes.hasApprovals || scopes.hasAdmin
        VStack(alignment: .leading, spacing: 8) {
            ProSectionHeader(title: "Live approvals (session)")
            if self.viewModel.approvalFeed.isEmpty {
                if canSeeApprovals {
                    CommandEmptyStateRow(
                        icon: "checkmark.circle",
                        title: "No approvals this session",
                        detail: "Pending requests and resolutions appear here live.")
                        .padding(.horizontal, OpenClawProMetric.pagePadding)
                } else {
                    CommandEmptyStateRow(
                        icon: "lock.slash",
                        title: "Approvals not visible",
                        detail: "This device's grant lacks operator.approvals, so approval requests can't be shown here. Re-pair with approvals scope to see them.")
                        .padding(.horizontal, OpenClawProMetric.pagePadding)
                }
            } else {
                CommandPanel(padding: 8) {
                    VStack(spacing: 8) {
                        ForEach(self.viewModel.approvalFeed) { entry in
                            ApprovalFeedRow(entry: entry)
                        }
                    }
                }
                .padding(.horizontal, OpenClawProMetric.pagePadding)
            }
        }
    }

    // MARK: - Honesty note

    private var honestyNote: some View {
        SecurityInlineNote(
            icon: "info.circle",
            text: "This is a live posture view, not an audit log. The gateway emits security events internally but exposes no history/query RPC, so resolutions shown here are only those observed while this screen was open.")
            .padding(.horizontal, OpenClawProMetric.pagePadding)
    }

    // MARK: - Shared states

    private var loadingState: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text("Loading security posture")
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

// MARK: - Scope chip

/// One operator-scope chip with a granted/absent dot. Used for both this device's scopes and a paired
/// device's active scopes.
private struct ScopeChip: View {
    let scope: String
    let granted: Bool

    var body: some View {
        HStack(spacing: 5) {
            ProStatusDot(color: self.granted ? OpenClawBrand.ok : .secondary)
            Text(self.shortScope)
                .font(.caption2.weight(.semibold))
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background {
            Capsule().fill(Color.primary.opacity(0.06))
        }
    }

    /// Strip the `operator.` prefix so chips read `admin` / `read` / `write` compactly.
    private var shortScope: String {
        self.scope.hasPrefix("operator.")
            ? String(self.scope.dropFirst("operator.".count))
            : self.scope
    }
}

// MARK: - Paired device row

/// One paired-device row: name + platform, role pill, and active scopes. The full approved-scope set is
/// redacted server-side (`redactPairedDevice`), so the caption is explicit that these are active scopes.
private struct PairedDeviceRow: View {
    let device: PairedDeviceLite

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                ProIconBadge(
                    systemName: self.device.isAdmin ? "checkmark.shield.fill" : "iphone",
                    color: self.device.isAdmin ? OpenClawBrand.ok : OpenClawBrand.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(self.device.name)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text(self.subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                ProValuePill(value: self.device.roleLabel, color: self.device.isAdmin ? OpenClawBrand.ok : .secondary)
            }
            if !self.device.scopes.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(self.device.scopes.sorted(), id: \.self) { scope in
                        ScopeChip(scope: scope, granted: true)
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
    }

    private var subtitle: String {
        let parts = [self.device.platform, self.lastSeenText].compactMap(\.self)
        return parts.isEmpty ? self.device.deviceId : parts.joined(separator: " • ")
    }

    private var lastSeenText: String? {
        guard let lastSeen = self.device.lastSeenAtMs, lastSeen > 0 else { return nil }
        let date = Date(timeIntervalSince1970: Double(lastSeen) / 1000)
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return "seen \(formatter.localizedString(for: date, relativeTo: .now))"
    }
}

// MARK: - Approval feed row

/// One live-feed row: status dot/icon, command + origin, and a status pill. Pending rows are amber;
/// resolved rows are green/red by decision.
private struct ApprovalFeedRow: View {
    let entry: ApprovalFeedEntry

    var body: some View {
        ProStatusRow(
            icon: self.entry.icon,
            title: self.entry.command,
            detail: self.entry.origin,
            value: self.entry.statusLabel,
            color: self.entry.statusColor)
    }
}

// MARK: - Inline note

/// A small inline note row, mirroring `OpsInlineNote`.
private struct SecurityInlineNote: View {
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
