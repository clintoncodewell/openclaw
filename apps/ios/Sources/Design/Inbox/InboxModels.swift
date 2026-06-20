import Foundation
import OpenClawKit
import OpenClawProtocol
import SwiftUI

/// One pending exec-approval row in the Agent Inbox, decoded from `exec.approval.list`.
///
/// The list endpoint returns a bare JSON array whose elements nest the request under `request`
/// (`request.command`, `request.allowedDecisions`, …) — this is a different shape from
/// `exec.approval.get`, which flattens to `commandText`. `InboxApproval` decodes the list shape and
/// is intentionally a superset of `NodeAppModel.ExecApprovalPrompt` so future detail screens can be
/// driven straight from the row without a second fetch.
///
/// The inbox is built interrupt-source-agnostic on purpose: v1 hosts only exec "Review" interrupts
/// (the only resolve contract the gateway exposes — `{id, decision}`, no edit/reason field), but the
/// row/risk model is generic enough to later host `plugin.approval.*` Question/Respond interrupts.
struct InboxApproval: Identifiable, Equatable {
    let id: String
    let command: String
    let commandPreview: String?
    let allowedDecisions: [String]
    let host: String?
    let nodeId: String?
    let agentId: String?
    let security: String?
    let ask: String?
    let warningText: String?
    let createdAtMs: Int
    let expiresAtMs: Int?

    /// Mirrors `NodeAppModel.ExecApprovalPrompt.allowsAllowAlways` so the row only offers the
    /// "Always" affordance when the gateway's `allowedDecisions` actually permits it.
    var allowsAllowAlways: Bool {
        self.allowedDecisions.contains("allow-always")
    }

    /// One-line command text for the row: prefer the full command, fall back to the gateway preview.
    var displayCommand: String {
        let trimmed = self.command.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return self.commandPreview?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// Short "node · agent" subtitle, dropping whichever side is missing.
    var originText: String {
        let parts = [self.nodeId, self.host, self.agentId]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        // Prefer node|host (one location label) + agent, never repeat the same string twice.
        var seen = Set<String>()
        let unique = parts.filter { seen.insert($0).inserted }
        return unique.isEmpty ? "Unknown source" : unique.prefix(2).joined(separator: " · ")
    }

    /// Risk classification for the badge / chip color, derived from the gateway's exec-policy
    /// contract: `security` is exactly `deny | allowlist | full` and `ask` is `off | on-miss | always`
    /// (`src/infra/exec-approvals.ts`). `deny` or a `warningText` means the command tripped a hard
    /// block / explicit warning (danger); `full` (broadest access) or an `always`-ask policy means
    /// elevated-but-not-blocked (caution). Drives `OpenClawBrand.danger/.warn/.ok`.
    var riskKind: InboxRiskKind {
        let security = self.security?.lowercased() ?? ""
        let ask = self.ask?.lowercased() ?? ""
        let hasWarning = !(self.warningText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        if security == "deny" || hasWarning {
            return .danger
        }
        if security == "full" || ask == "always" {
            return .caution
        }
        return .normal
    }

    /// Short risk label for the pill (falls back to `ask` when present, else the risk word).
    var riskLabel: String {
        if let ask = self.ask?.trimmingCharacters(in: .whitespacesAndNewlines), !ask.isEmpty {
            return ask
        }
        return self.riskKind.label
    }

    /// Human "expires in …" caption. Reuses the threshold logic from `ExecApprovalPromptDialog`.
    var relativeExpiry: String? {
        guard let expiresAtMs = self.expiresAtMs else { return nil }
        let remainingSeconds = Int((Double(expiresAtMs) / 1000.0) - Date().timeIntervalSince1970)
        if remainingSeconds <= 0 { return "Expired" }
        if remainingSeconds < 60 { return "Expires in under a minute" }
        if remainingSeconds < 3600 {
            let minutes = Int(ceil(Double(remainingSeconds) / 60.0))
            return minutes == 1 ? "Expires in 1 minute" : "Expires in \(minutes) minutes"
        }
        let hours = Int(ceil(Double(remainingSeconds) / 3600.0))
        return hours == 1 ? "Expires in 1 hour" : "Expires in \(hours) hours"
    }
}

/// Closed risk classification so the row never juggles parallel security booleans.
enum InboxRiskKind {
    case normal
    case caution
    case danger

    var color: Color {
        switch self {
        case .normal: OpenClawBrand.ok
        case .caution: OpenClawBrand.warn
        case .danger: OpenClawBrand.danger
        }
    }

    var icon: String {
        switch self {
        case .normal: "terminal.fill"
        case .caution: "exclamationmark.triangle.fill"
        case .danger: "exclamationmark.octagon.fill"
        }
    }

    var label: String {
        switch self {
        case .normal: "Review"
        case .caution: "Caution"
        case .danger: "Dangerous"
        }
    }
}

extension InboxApproval {
    /// Lossy per-element decode of the bare `exec.approval.list` array: the top-level array is split
    /// with `JSONSerialization` and each element decoded on its own so one malformed pending record
    /// never blanks the whole inbox. (Splitting via `JSONSerialization` rather than decoding a bare
    /// `[AnyCodable]` both keeps the decode lossy and avoids a Swift type-inference crash on the
    /// top-level array metatype.) Mirrors the lossy contract of `BriefsInboxViewModel.decodeRuns`.
    static func decodeList(from data: Data) -> [InboxApproval] {
        guard let rawElements = try? JSONSerialization.jsonObject(with: data) as? [Any] else {
            return []
        }
        let decoder = JSONDecoder()
        var approvals: [InboxApproval] = []
        approvals.reserveCapacity(rawElements.count)
        for element in rawElements {
            guard JSONSerialization.isValidJSONObject(element),
                  let entryData = try? JSONSerialization.data(withJSONObject: element),
                  let entry = try? decoder.decode(ListEntry.self, from: entryData),
                  let approval = InboxApproval(entry: entry)
            else {
                continue
            }
            approvals.append(approval)
        }
        return approvals
    }

    /// Decodable mirror of a single `exec.approval.list` element (`{ id, request, createdAtMs,
    /// expiresAtMs }`). `request` carries the full `ExecApprovalRequestPayload`; we read only the
    /// fields the inbox renders.
    private struct ListEntry: Decodable {
        let id: String
        let request: Request
        let createdAtMs: Int?
        let expiresAtMs: Int?

        struct Request: Decodable {
            let command: String?
            let commandPreview: String?
            let allowedDecisions: [String]?
            let host: String?
            let nodeId: String?
            let agentId: String?
            let security: String?
            let ask: String?
            let warningText: String?
        }
    }

    private init?(entry: ListEntry) {
        let id = entry.id.trimmingCharacters(in: .whitespacesAndNewlines)
        let command = (entry.request.command ?? entry.request.commandPreview ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // A row with no id or no command text is unrenderable; drop it rather than show a blank card.
        guard !id.isEmpty, !command.isEmpty else { return nil }
        self.id = id
        self.command = command
        self.commandPreview = entry.request.commandPreview?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.allowedDecisions = (entry.request.allowedDecisions ?? []).compactMap { decision in
            let trimmed = decision.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        self.host = entry.request.host?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.nodeId = entry.request.nodeId?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.agentId = entry.request.agentId?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.security = entry.request.security?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.ask = entry.request.ask?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.warningText = entry.request.warningText?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.createdAtMs = entry.createdAtMs ?? 0
        self.expiresAtMs = entry.expiresAtMs
    }
}
