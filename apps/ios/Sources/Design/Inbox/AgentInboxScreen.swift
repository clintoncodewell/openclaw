import OpenClawKit
import SwiftUI

/// The Agent Inbox: a push-driven, multi-item list of pending exec-approval "Review" interrupts
/// (`exec.approval.list`), newest first, each an actionable card. Approve / Always / Ignore reuse the
/// existing canonical resolve path on `NodeAppModel` (the same one the notification & watch surfaces
/// use) rather than reimplementing the RPC. Pushed inside Command Center's existing NavigationStack so
/// the system back button works for free.
struct AgentInboxScreen: View {
    @Environment(NodeAppModel.self) private var appModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var viewModel = AgentInboxViewModel()

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
        .navigationTitle("Inbox")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            await self.viewModel.load(appModel: self.appModel, force: true)
        }
        .task(id: self.scenePhase) {
            guard self.scenePhase == .active else { return }
            await self.viewModel.load(appModel: self.appModel, force: false)
        }
        .task {
            // Live, push-driven freshness while foregrounded: the gateway broadcasts
            // `exec.approval.requested` / `exec.approval.resolved` to approvals-scoped clients, so a
            // request raised (or resolved) on another surface refreshes this list immediately.
            await self.observeApprovalEvents()
        }
    }

    private func observeApprovalEvents() async {
        let stream = await self.appModel.operatorSession.subscribeServerEvents(bufferingNewest: 200)
        for await event in stream {
            if Task.isCancelled { return }
            switch event.event {
            case "exec.approval.requested", "exec.approval.resolved":
                await self.viewModel.load(appModel: self.appModel, force: true)
            default:
                continue
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Inbox")
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
            return "Loading approvals"
        case .offline:
            return "Gateway offline"
        case .error:
            return "Inbox unavailable"
        case .empty:
            return "Inbox zero — nothing waiting"
        case .loaded:
            let count = self.viewModel.pendingCount
            return count == 1 ? "1 decision needs you" : "\(count) decisions need you"
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
                detail: "Connect to the gateway to review pending approvals.")
        case let .error(message):
            self.emptyState(
                icon: "exclamationmark.triangle.fill",
                title: "Inbox unavailable",
                detail: message)
        case .empty:
            self.inboxZeroState
        case .loaded:
            self.approvalsSection
        }
    }

    private var approvalsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            ProSectionHeader(title: "Pending")
            CommandPanel(padding: 8) {
                VStack(spacing: 8) {
                    ForEach(self.viewModel.approvals) { approval in
                        InboxApprovalRow(
                            approval: approval,
                            isResolving: self.viewModel.resolvingIDs.contains(approval.id),
                            errorText: self.viewModel.rowErrors[approval.id])
                        { decision in
                            Task {
                                await self.viewModel.resolve(
                                    approval,
                                    decision: decision,
                                    appModel: self.appModel)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, OpenClawProMetric.pagePadding)
        }
    }

    /// Calm, positive "Inbox zero" empty state — there is nothing to act on.
    private var inboxZeroState: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 44, weight: .semibold))
                .foregroundStyle(OpenClawBrand.ok)
            VStack(spacing: 4) {
                Text("Inbox zero")
                    .font(.title3.weight(.bold))
                Text("No agents are waiting on you. New approval requests will appear here.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
        .padding(.horizontal, OpenClawProMetric.pagePadding)
    }

    private var loadingState: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text("Loading approvals")
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

/// A single pending approval rendered as an actionable card: risk badge, origin + command, a risk
/// pill and expiry caption, and the resolve actions. Approve maps to `allow-once`, Always to
/// `allow-always` (only when the request permits it), Ignore to `deny` — the research action
/// vocabulary surfaced over the exec-approval Review contract.
private struct InboxApprovalRow: View {
    @Environment(\.colorScheme) private var colorScheme
    let approval: InboxApproval
    let isResolving: Bool
    let errorText: String?
    /// Resolve callback carrying the gateway decision token (`allow-once` / `allow-always` / `deny`).
    let onResolve: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                ProIconBadge(systemName: self.approval.riskKind.icon, color: self.approval.riskKind.color)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(self.approval.originText)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.82)
                        Spacer(minLength: 6)
                        if let expiry = self.approval.relativeExpiry {
                            Text(expiry)
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Text(self.approval.displayCommand)
                        .font(.system(size: 13, weight: .regular, design: .monospaced))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: 8) {
                        ProValuePill(value: self.approval.riskLabel, color: self.approval.riskKind.color)
                        Spacer(minLength: 0)
                    }
                }
            }

            if let errorText, !errorText.isEmpty {
                Text(errorText)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(OpenClawBrand.danger)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

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
        .contentShape(Rectangle())
    }

    private var actionRow: some View {
        HStack(spacing: 8) {
            Button {
                self.onResolve("allow-once")
            } label: {
                Label("Approve", systemImage: "checkmark")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)

            if self.approval.allowsAllowAlways {
                Button {
                    self.onResolve("allow-always")
                } label: {
                    Text("Always")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }

            Button(role: .destructive) {
                self.onResolve("deny")
            } label: {
                Label("Ignore", systemImage: "xmark")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
        .controlSize(.small)
        .disabled(self.isResolving)
        .overlay(alignment: .center) {
            if self.isResolving {
                ProgressView().controlSize(.small)
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
