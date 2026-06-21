import OpenClawKit
import OpenClawProtocol
import SwiftUI
import UIKit

/// One node's full detail: identity, capabilities, declared commands, and one-tap STATUS-READ actions.
///
/// Action policy (verified against `node-command-policy.ts` + `nodes.ts`):
/// - The default action buttons are the status reads in `FleetAction` — each rendered ONLY when the node
///   DECLARED the command (`node.commands.contains`). `operator.write` is always held, and these are in a
///   platform default allowlist, so a declared one is genuinely invokable.
/// - `screen.snapshot` additionally requires a desktop-class node (macOS / Windows default only).
/// - INVASIVE-CAPTURE commands (`camera.snap` / `camera.clip` / `screen.record` / `*.add` / `sms.*`) are
///   NOT in any platform default and need a server-side `gateway.nodes.allowCommands` grant the app can't
///   make. We surface them ONLY when the node already declares them (so an operator enabled them server-
///   side) AND behind a `.confirmationDialog`, so the app never paints a silently-failing affordance.
/// - When the node is offline, actions are disabled with a note: `node.invoke` would attempt an APNs wake
///   and may return `NOT_CONNECTED`; for iOS foreground-only commands a backgrounded device returns
///   `QUEUED_UNTIL_FOREGROUND`, which we render as "queued", not an error.
struct FleetNodeDetail: View {
    let node: FleetNode
    @Bindable var viewModel: FleetViewModel

    /// The dangerous command currently awaiting confirmation, or nil. Drives the `.confirmationDialog`.
    @State private var pendingDangerousCommand: String?

    @Environment(NodeAppModel.self) private var appModel

    /// Dangerous commands that, IF the node declares them (operator already granted them server-side), we
    /// surface behind a confirm dialog. These mirror `DEFAULT_DANGEROUS_NODE_COMMANDS`
    /// (`node-command-policy.ts:71-79`). They are never invoked without confirmation.
    private static let dangerousCommands: [(command: String, title: String, icon: String)] = [
        (command: "camera.snap", title: "Take a photo", icon: "camera.aperture"),
        (command: "camera.clip", title: "Record a clip", icon: "video.fill"),
        (command: "screen.record", title: "Record the screen", icon: "rectangle.dashed.badge.record"),
        (command: "sms.send", title: "Send an SMS", icon: "message.fill"),
    ]

    var body: some View {
        ZStack {
            OpenClawProBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    self.headerCard
                    self.identityCard
                    self.actionsSection
                    self.capabilitiesCard
                    self.commandsCard
                }
                .padding(.vertical, 18)
            }
            .safeAreaPadding(.bottom, OpenClawProMetric.bottomScrollInset)
        }
        .navigationTitle(self.node.name)
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            self.confirmTitle,
            isPresented: self.confirmBinding,
            titleVisibility: .visible)
        {
            if let command = self.pendingDangerousCommand {
                Button("Run \(command)", role: .destructive) {
                    Task { await self.viewModel.invokeCommand(command, on: self.node, appModel: self.appModel) }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This is an invasive command an operator enabled server-side. It runs on the device immediately.")
        }
    }

    // MARK: - Header

    private var headerCard: some View {
        ProCard {
            HStack(spacing: 12) {
                ProIconBadge(systemName: self.node.icon, color: self.node.status.color)
                VStack(alignment: .leading, spacing: 3) {
                    Text(self.node.name)
                        .font(.headline)
                    Text(self.headerDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                ProValuePill(value: self.node.status.label, color: self.node.status.color)
            }
        }
        .padding(.horizontal, OpenClawProMetric.pagePadding)
    }

    private var headerDetail: String {
        let parts = [
            Self.normalized(self.node.platform),
            Self.normalized(self.node.version).map { "v\($0)" },
        ].compactMap(\.self)
        return parts.isEmpty ? "Node \(self.node.nodeId)" : parts.joined(separator: " • ")
    }

    // MARK: - Identity

    private var identityCard: some View {
        ProCard {
            VStack(spacing: 0) {
                self.detailRow("Node ID", value: self.node.nodeId)
                Divider()
                self.detailRow("Platform", value: self.node.platform)
                Divider()
                self.detailRow("Device", value: self.node.deviceFamily)
                Divider()
                self.detailRow("Version", value: self.node.version)
                Divider()
                self.detailRow("Core", value: self.node.coreVersion)
                Divider()
                self.detailRow("IP", value: self.node.remoteIp)
                Divider()
                self.detailRow("Approval", value: self.node.approvalState)
                Divider()
                self.detailRow("Connected", value: self.node.connectedLabel)
                Divider()
                self.detailRow("Last seen", value: self.node.lastSeenLabel)
            }
        }
        .padding(.horizontal, OpenClawProMetric.pagePadding)
    }

    /// Copy-to-clipboard identity row, mirroring `AgentProNodesDestination.nodeDetailRow` (`:218-238`).
    private func detailRow(_ title: String, value: String?) -> some View {
        let normalized = Self.normalized(value) ?? "n/a"
        return HStack(spacing: 10) {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(normalized)
                .lineLimit(1)
                .truncationMode(.middle)
            Button {
                UIPasteboard.general.string = normalized
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.plain)
            .disabled(normalized == "n/a")
            .accessibilityLabel("Copy \(title)")
        }
        .font(.subheadline)
        .padding(.vertical, 10)
    }

    // MARK: - Actions

    @ViewBuilder
    private var actionsSection: some View {
        let actions = self.availableActions
        let dangerous = self.availableDangerousCommands
        if actions.isEmpty, dangerous.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                ProSectionHeader(title: "Actions")
                ProCard {
                    Text("This node declares no operator-invokable commands.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, OpenClawProMetric.pagePadding)
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ProSectionHeader(title: "Actions")
                if !self.node.connected {
                    self.offlineActionNote
                }
                ProCard(padding: 8) {
                    VStack(spacing: 8) {
                        ForEach(actions) { action in
                            self.statusActionRow(action)
                        }
                        ForEach(dangerous, id: \.command) { entry in
                            self.dangerousActionRow(command: entry.command, title: entry.title, icon: entry.icon)
                        }
                    }
                }
                .padding(.horizontal, OpenClawProMetric.pagePadding)
            }
        }
    }

    /// Status-read actions the node declares (and, for `screen.snapshot`, that are platform-appropriate).
    private var availableActions: [FleetAction] {
        FleetAction.allCases.filter { action in
            guard self.node.commands.contains(action.command) else { return false }
            if action.isDesktopOnly { return self.node.isDesktopClass }
            return true
        }
    }

    /// Dangerous commands the node ALREADY declares (operator-enabled server-side). Empty in the common
    /// case — only populated when `gateway.nodes.allowCommands` granted one on the node.
    private var availableDangerousCommands: [(command: String, title: String, icon: String)] {
        Self.dangerousCommands.filter { self.node.commands.contains($0.command) }
    }

    private var offlineActionNote: some View {
        HStack(spacing: 8) {
            Image(systemName: "wifi.slash")
                .font(.caption.weight(.semibold))
                .foregroundStyle(OpenClawBrand.warn)
            Text("Device offline — an action will attempt to wake it, or queue until it returns to foreground.")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(3)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, OpenClawProMetric.pagePadding)
    }

    private func statusActionRow(_ action: FleetAction) -> some View {
        let inFlight = self.viewModel.isInFlight(nodeId: self.node.nodeId, command: action.command)
        let result = self.viewModel.result(nodeId: self.node.nodeId, command: action.command)
        return VStack(alignment: .leading, spacing: 6) {
            Button {
                Task { await self.viewModel.invoke(action, on: self.node, appModel: self.appModel) }
            } label: {
                self.actionRowLabel(icon: action.icon, title: action.title, subtitle: action.subtitle, inFlight: inFlight)
            }
            .buttonStyle(.plain)
            .disabled(inFlight)
            if let result {
                self.resultRow(result)
            }
        }
    }

    private func dangerousActionRow(command: String, title: String, icon: String) -> some View {
        let inFlight = self.viewModel.isInFlight(nodeId: self.node.nodeId, command: command)
        let result = self.viewModel.result(nodeId: self.node.nodeId, command: command)
        return VStack(alignment: .leading, spacing: 6) {
            Button {
                self.pendingDangerousCommand = command
            } label: {
                self.actionRowLabel(
                    icon: icon,
                    title: title,
                    subtitle: "Invasive — operator-enabled, requires confirmation",
                    inFlight: inFlight,
                    tint: OpenClawBrand.danger)
            }
            .buttonStyle(.plain)
            .disabled(inFlight)
            if let result {
                self.resultRow(result)
            }
        }
    }

    private func actionRowLabel(
        icon: String,
        title: String,
        subtitle: String,
        inFlight: Bool,
        tint: Color = OpenClawBrand.accent) -> some View
    {
        HStack(alignment: .center, spacing: 12) {
            ProIconBadge(systemName: icon, color: tint)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            if inFlight {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
    }

    /// Inline outcome under a tapped action, colored + iconed by the closed `FleetActionResult`.
    private func resultRow(_ result: FleetActionResult) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: result.iconName)
                .font(.caption.weight(.semibold))
                .foregroundStyle(result.color)
            Text(result.message)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(4)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .padding(.bottom, 4)
    }

    // MARK: - Capabilities + commands

    private var capabilitiesCard: some View {
        self.listCard(title: "Capabilities", values: self.node.caps)
    }

    private var commandsCard: some View {
        self.listCard(title: "Declared commands", values: self.node.commands)
    }

    /// Monospaced list card, mirroring `AgentProNodesDestination.nodeListCard` (`:240-262`).
    private func listCard(title: String, values: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ProSectionHeader(title: title)
            ProCard {
                if values.isEmpty {
                    Text("None reported.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(values, id: \.self) { value in
                            Text(value)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
            .padding(.horizontal, OpenClawProMetric.pagePadding)
        }
    }

    // MARK: - Confirm dialog plumbing

    private var confirmBinding: Binding<Bool> {
        Binding(
            get: { self.pendingDangerousCommand != nil },
            set: { isPresented in
                if !isPresented { self.pendingDangerousCommand = nil }
            })
    }

    private var confirmTitle: String {
        guard let command = self.pendingDangerousCommand else { return "Run command" }
        return "Run \(command) on \(self.node.name)?"
    }

    private static func normalized(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}
