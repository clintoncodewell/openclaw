import Foundation
import OpenClawKit
import OpenClawProtocol
import SwiftUI

/// Lite decoders + derived models for the Security Posture surface. HONEST scope: this is a POSTURE
/// surface, NOT an audit log. There is NO operator-action log, NO queryable security-event RPC, and NO
/// exec-approval HISTORY exposed to an operator session — security.event records ARE emitted internally
/// (`diagnostic-events.ts:1223`) but kept off the public diagnostic stream and have no `security.events
/// .list` / `audit.list` method. What IS real and surfaced here:
///
/// (a) THIS device's granted operator scopes + role — read LOCALLY from `DeviceAuthStore` (the paired
///     "operator" token's `scopes`), no RPC.
/// (b) PAIRED DEVICES roster via `device.pair.list` (scope `operator.pairing`). NOTE: the handler
///     `redactPairedDevice` (`devices.ts:58`) STRIPS `approvedScopes` from the wire — only the
///     token-active `scopes` survive in `...rest`, alongside role/roles + token lifecycle metadata. So
///     the roster shows role + active scopes per device, and we are explicit that the full approved-
///     scope set is redacted server-side.
/// (c) The current exec-approval POLICY via `exec.approvals.get` (scope `operator.admin`) — "what
///     requires approval right now" (the global `defaults.security` + `defaults.ask` posture + any
///     per-agent overrides). This is posture, not history.
/// (d) A LIVE pending-approvals feed seeded from `exec.approval.list` and appended/cleared from the
///     `exec.approval.requested` / `exec.approval.resolved` broadcast — SESSION-LOCAL, resets on
///     relaunch. There is NO historical resolution endpoint, so resolved rows are only those resolved
///     while this screen was open.

// MARK: - (a) This device's scopes (local)

/// This session's own granted operator scopes + role, read from `DeviceAuthStore` for the paired
/// "operator" token. Local — no RPC. Empty `scopes` means the device isn't paired with an operator
/// token (e.g. shared-secret only), which the screen states plainly.
struct LocalDeviceScopes {
    let deviceId: String
    let role: String?
    let scopes: [String]

    /// Read the stored operator token's scopes for this device id. The stored entry is written at
    /// pairing time with the approver's granted scope subset (`devices.ts`); reading it locally needs
    /// no round-trip and reflects exactly what this session can call.
    init(deviceId: String) {
        self.deviceId = deviceId
        let entry = DeviceAuthStore.loadToken(deviceId: deviceId, role: "operator")
        self.role = entry?.role
        self.scopes = entry?.scopes ?? []
    }

    var hasAdmin: Bool { self.scopes.contains("operator.admin") }
    var hasApprovals: Bool { self.scopes.contains("operator.approvals") }
    var hasPairing: Bool { self.scopes.contains("operator.pairing") }

    /// True when the operator token grant is narrower than the full default operator scope set — the
    /// signal the routing/auth write surfaces use to fall back to read-only. A device with no stored
    /// operator token (empty scopes) is treated as narrowed.
    var isNarrowed: Bool {
        !self.hasAdmin
    }

    /// Sorted scope list for stable display, longest-suffix-first so `admin` reads before `read`.
    var sortedScopes: [String] {
        self.scopes.sorted()
    }
}

// MARK: - (b) device.pair.list roster

/// One paired device from `device.pair.list`, narrowed to the fields that survive `redactPairedDevice`.
/// `approvedScopes` is intentionally absent — the handler strips it before sending; only the token-
/// active `scopes` survive (alongside role/roles + lifecycle timestamps), so this is the active-scope
/// view, not the full approved grant.
struct PairedDeviceLite: Identifiable {
    let deviceId: String
    let displayName: String?
    let platform: String?
    let role: String?
    let roles: [String]
    let scopes: [String]
    let createdAtMs: Int?
    let approvedAtMs: Int?
    let lastSeenAtMs: Int?

    var id: String { self.deviceId }

    var name: String {
        let trimmed = self.displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? self.deviceId : trimmed
    }

    /// Effective role label: prefer the singular `role`, fall back to the first of `roles`, else
    /// "operator" (the default operator-device role).
    var roleLabel: String {
        if let role = self.role?.trimmingCharacters(in: .whitespacesAndNewlines), !role.isEmpty {
            return role
        }
        return self.roles.first ?? "operator"
    }

    var isAdmin: Bool {
        self.scopes.contains("operator.admin") || self.roleLabel == "admin"
    }

    init(reading raw: [String: Any]) {
        self.deviceId = (raw["deviceId"] as? String) ?? "device"
        self.displayName = raw["displayName"] as? String
        self.platform = raw["platform"] as? String
        self.role = raw["role"] as? String
        self.roles = (raw["roles"] as? [Any])?.compactMap { $0 as? String } ?? []
        self.scopes = (raw["scopes"] as? [Any])?.compactMap { $0 as? String } ?? []
        self.createdAtMs = AgentProValueReader.intValue(Self.wrap(raw["createdAtMs"]))
        self.approvedAtMs = AgentProValueReader.intValue(Self.wrap(raw["approvedAtMs"]))
        self.lastSeenAtMs = AgentProValueReader.intValue(Self.wrap(raw["lastSeenAtMs"]))
    }

    private static func wrap(_ value: Any?) -> AnyCodable? {
        guard let value, !(value is NSNull) else { return nil }
        return AnyCodable(value)
    }

    /// Lossy decode of the `device.pair.list` envelope (`{ pending: [...], paired: [...] }`). We surface
    /// only the `paired` roster (pending pairings are a separate, transient pairing-approval flow); each
    /// element is rebuilt on its own so one malformed device can't blank the roster.
    static func decodePairedList(from data: Data) -> [PairedDeviceLite] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pairedRaw = root["paired"] as? [[String: Any]]
        else {
            return []
        }
        return pairedRaw.map(PairedDeviceLite.init(reading:))
    }
}

// MARK: - (c) exec.approvals.get policy

/// The current exec-approval POLICY posture from `exec.approvals.get`, narrowed to the global default
/// (`file.defaults.security` + `defaults.ask`) + a count of per-agent overrides. The payload is
/// `{ path, exists, hash, file: { version, defaults?, agents? } }` (`exec-approvals.ts:86`). This is
/// "what requires approval right now", not a history of decisions.
struct ApprovalPolicyLite {
    let exists: Bool
    let security: String?
    let ask: String?
    let agentOverrideCount: Int

    /// Closed posture verdict from `security` + `ask`, mirroring the gateway's mode resolution
    /// (`resolveExecModeFromPolicy`, `exec-approvals.ts:117`): deny / allowlist / ask / full.
    var posture: ApprovalPosture {
        ApprovalPosture(security: self.security, ask: self.ask)
    }

    static func decode(from data: Data) -> ApprovalPolicyLite? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let exists = (root["exists"] as? Bool) ?? false
        let file = root["file"] as? [String: Any]
        let defaults = file?["defaults"] as? [String: Any]
        let security = (defaults?["security"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let ask = (defaults?["ask"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let agents = file?["agents"] as? [String: Any]
        return ApprovalPolicyLite(
            exists: exists,
            security: (security?.isEmpty ?? true) ? nil : security,
            ask: (ask?.isEmpty ?? true) ? nil : ask,
            agentOverrideCount: agents?.count ?? 0)
    }
}

/// Closed approval-posture verdict so the card maps to a label/color without re-deriving the
/// security/ask combination. Mirrors `ExecMode` (`exec-approvals.ts:40`).
enum ApprovalPosture {
    case deny
    case allowlist
    case ask
    case full
    case unknown

    /// Derive the posture from the policy's `security` + `ask`, matching `resolveExecModeFromPolicy`:
    /// `deny` security ⇒ deny; `allowlist` + `ask:off` ⇒ allowlist; `full` + `ask:!=always` ⇒ full;
    /// everything else ⇒ ask.
    init(security: String?, ask: String?) {
        let security = security?.lowercased()
        let ask = ask?.lowercased()
        switch security {
        case "deny":
            self = .deny
        case "allowlist":
            self = ask == "off" ? .allowlist : .ask
        case "full":
            self = ask == "always" ? .ask : .full
        case nil:
            self = .unknown
        default:
            self = .ask
        }
    }

    var label: String {
        switch self {
        case .deny: "Deny all"
        case .allowlist: "Allowlist only"
        case .ask: "Ask on miss"
        case .full: "Full access"
        case .unknown: "Unknown"
        }
    }

    var detail: String {
        switch self {
        case .deny: "Every command requires approval — nothing runs unprompted."
        case .allowlist: "Only allowlisted commands run; others are blocked, no prompt."
        case .ask: "Allowlisted commands run; anything else prompts for approval."
        case .full: "Commands run without approval (broadest access)."
        case .unknown: "No default policy reported by the gateway."
        }
    }

    /// Color by how permissive the posture is: deny/allowlist are tight (ok), ask is moderate (accent),
    /// full is the broadest (warn).
    var color: Color {
        switch self {
        case .deny, .allowlist: OpenClawBrand.ok
        case .ask: OpenClawBrand.accent
        case .full: OpenClawBrand.warn
        case .unknown: .secondary
        }
    }
}

// MARK: - (d) Live pending-approval feed (session-local)

/// One entry in the SESSION-LOCAL approvals feed: a pending request, or a resolution observed live.
/// Closed `kind` so the row maps to color/label without re-deriving. There is NO historical-resolution
/// endpoint, so `resolved` rows exist only for approvals resolved while this screen was open.
struct ApprovalFeedEntry: Identifiable {
    enum Kind: Equatable {
        case pending
        case resolved(decision: String?)
    }

    let id: String
    let command: String
    let origin: String
    let kind: Kind
    let timestamp: Date

    var isPending: Bool {
        if case .pending = self.kind { return true }
        return false
    }

    /// Build a pending entry from a decoded `InboxApproval` (the same `exec.approval.list` row the Inbox
    /// uses), so the feed reuses the existing decode contract instead of a second source of truth.
    init(pending approval: InboxApproval) {
        self.id = approval.id
        self.command = approval.displayCommand
        self.origin = approval.originText
        self.kind = .pending
        self.timestamp = Date(timeIntervalSince1970: Double(approval.createdAtMs) / 1000)
    }

    /// Build a resolved entry from a live `exec.approval.resolved` broadcast payload. The broadcast
    /// carries the id + decision; command/origin may be sparse, so they fall back to the prior pending
    /// row's text (passed in) when available.
    init(resolvedId id: String, decision: String?, command: String, origin: String) {
        self.id = id
        self.command = command
        self.origin = origin
        self.kind = .resolved(decision: decision)
        self.timestamp = Date()
    }

    var statusColor: Color {
        switch self.kind {
        case .pending: OpenClawBrand.warn
        case let .resolved(decision):
            switch decision?.lowercased() {
            case "deny", "denied", "reject", "rejected": OpenClawBrand.danger
            default: OpenClawBrand.ok
            }
        }
    }

    var statusLabel: String {
        switch self.kind {
        case .pending: return "pending"
        case let .resolved(decision):
            let trimmed = decision?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? "resolved" : trimmed
        }
    }

    var icon: String {
        switch self.kind {
        case .pending: "hourglass"
        case .resolved: "checkmark.circle.fill"
        }
    }
}
