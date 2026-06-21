import Foundation
import OpenClawKit
import OpenClawProtocol
import SwiftUI

/// Lite decode mirrors + derived view models for the Fleet dashboard. The screen reads three gateway
/// RPCs and folds them into one fleet view:
///
/// - `node.list` (scope `operator.read`, `nodes.ts:980-1003`) → `FleetNode`. Returns one row PER KNOWN
///   NODE — the union of paired devices, approved node records, pending requests, and live websocket
///   sessions (`node-catalog.ts:266-293`) — so it includes Mac / iPhone nodes that are currently OFFLINE,
///   not just the live beacons `system-presence` carries. `NodeListNode` (`node-list-types.ts:2-26`) had
///   no Swift model; this is the net-new fuller decoder, extended from the narrow `OpsNodeLite` lossy
///   pattern (`Ops/OpsModels.swift:316-338`).
/// - `agents.list` (scope `operator.read`) → reuses `AgentRoutingLite.decodeList` (`Routing/RoutingModels`)
///   for the read-only per-agent rows (name + primary model).
/// - `system-presence` (scope `operator.read`) → `[PresenceEntry]` (already typed in
///   `GatewayModels.swift:250`); a complementary transient beacon stream folded in for the live-presence
///   count, NOT the inventory source.
///
/// There is deliberately NO `role` field: `NodeListNode` has none (`node-catalog.ts` never sets one), so
/// the screen derives device class from `deviceFamily` / `platform` instead of inventing a role.

// MARK: - node.list (full fleet node)

/// One `node.list` `nodes[]` element, decoded lossily (one malformed node can't blank the fleet). Every
/// field here is REAL on `NodeListNode` (`node-list-types.ts:2-26`, populated in `node-catalog.ts:198-247`).
/// `commands` is the per-node action surface: the node-declared, gateway-allowlisted command ids that
/// `node.invoke` will accept (`nodes.ts:1252-1271`). Action buttons gate on membership in this list so an
/// affordance never renders for a command the target can't run.
struct FleetNode: Identifiable {
    let nodeId: String
    let displayName: String?
    let platform: String?
    let deviceFamily: String?
    let version: String?
    let coreVersion: String?
    let remoteIp: String?
    /// Live caps (or approved caps when offline) — `node-catalog.ts:224`. Display-only context.
    let caps: [String]
    /// Node-declared + allowlisted command ids — the per-node action surface (`node-catalog.ts:225-227`).
    let commands: [String]
    let approvalState: String?
    let connected: Bool
    let paired: Bool
    let connectedAtMs: Int?
    let lastSeenAtMs: Int?
    let lastSeenReason: String?

    var id: String { self.nodeId }

    /// Display label: prefer the human name, fall back to the node id (mirrors `OpsNodeLite.name`).
    var name: String {
        let trimmed = self.displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? self.nodeId : trimmed
    }

    /// Closed connection status so the screen maps a node to a dot color / sort weight / label without
    /// re-inspecting the raw `connected` / `paired` / `approvalState` triple at the call site.
    var status: FleetNodeStatus {
        if self.connected { return .online }
        let state = self.approvalState ?? ""
        if state == "pending-approval" || state == "pending-reapproval" { return .pending }
        if state == "unapproved" { return .unapproved }
        // A paired node the gateway reports disconnected is the offline case; anything else is "known but
        // never expected to hold a connection", which we still show as offline rather than inventing a state.
        return .offline
    }

    /// SF Symbol for the node's device class. Derived from `deviceFamily` first (the catalog's
    /// `iphone`/`ipad`/`mac`/`android` value), then `platform` — same precedence as the presence-row
    /// `presenceIcon` mapping (`AgentProNodesDestination.swift:336-342`), extended for Android.
    var icon: String {
        let family = (self.deviceFamily ?? "").lowercased()
        let platform = (self.platform ?? "").lowercased()
        let blob = family + " " + platform
        if blob.contains("phone") || blob.contains("ios") { return "iphone" }
        if blob.contains("pad") || blob.contains("tablet") { return "ipad" }
        if blob.contains("mac") || blob.contains("desktop") { return "desktopcomputer" }
        if blob.contains("android") { return "candybarphone" }
        if blob.contains("windows") || blob.contains("win") { return "pc" }
        return "display"
    }

    /// macOS / Windows nodes can serve a still `screen.snapshot` out-of-the-box (`node-command-policy.ts`
    /// defaults); iOS screen capture is foreground-restricted and NOT a default, so the snapshot affordance
    /// is platform-gated on top of the per-node `commands` membership check.
    var isDesktopClass: Bool {
        let blob = ((self.deviceFamily ?? "") + " " + (self.platform ?? "")).lowercased()
        return blob.contains("mac") || blob.contains("desktop") || blob.contains("windows") || blob.contains("win")
    }

    /// Relative "last seen" label from `lastSeenAtMs` (max of connect / pairing timestamps,
    /// `node-catalog.ts:159-184`). Reuses the same `.relative` presentation as the presence rows
    /// (`AgentProNodesDestination.swift:353-356`). `nil` when the gateway reported no timestamp.
    var lastSeenLabel: String? {
        guard let lastSeenAtMs = self.lastSeenAtMs, lastSeenAtMs > 0 else { return nil }
        return FleetFormatting.relativeTime(fromMilliseconds: lastSeenAtMs)
    }

    /// Relative "connected" label from `connectedAtMs` (live sessions only, `node-catalog.ts:241`).
    var connectedLabel: String? {
        guard let connectedAtMs = self.connectedAtMs, connectedAtMs > 0 else { return nil }
        return FleetFormatting.relativeTime(fromMilliseconds: connectedAtMs)
    }

    init(reading raw: [String: Any]) {
        self.nodeId = (raw["nodeId"] as? String) ?? "node"
        self.displayName = raw["displayName"] as? String
        self.platform = raw["platform"] as? String
        self.deviceFamily = raw["deviceFamily"] as? String
        self.version = raw["version"] as? String
        self.coreVersion = raw["coreVersion"] as? String
        self.remoteIp = raw["remoteIp"] as? String
        self.caps = Self.stringArray(raw["caps"])
        self.commands = Self.stringArray(raw["commands"])
        self.approvalState = raw["approvalState"] as? String
        self.connected = (raw["connected"] as? Bool) ?? false
        self.paired = (raw["paired"] as? Bool) ?? false
        self.connectedAtMs = AgentProValueReader.intValue(Self.wrap(raw["connectedAtMs"]))
        self.lastSeenAtMs = AgentProValueReader.intValue(Self.wrap(raw["lastSeenAtMs"]))
        self.lastSeenReason = raw["lastSeenReason"] as? String
    }

    /// Read a `[String]` straight off the `JSONSerialization` dict. The serialized values are raw `String`
    /// (not re-wrapped `AnyCodable`, unlike a decoded `AnyCodable` array), so a plain `as? [String]` is the
    /// correct unwrap here — distinct from `AgentRoutingLite.stringArrayField`, which reads decoded
    /// `AnyCodable` elements. Non-string / empty entries are dropped.
    private static func stringArray(_ value: Any?) -> [String] {
        guard let array = value as? [Any] else { return [] }
        return array.compactMap { element in
            guard let string = element as? String else { return nil }
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
    }

    private static func wrap(_ value: Any?) -> AnyCodable? {
        guard let value, !(value is NSNull) else { return nil }
        return AnyCodable(value)
    }

    /// Lossy per-`nodes[]`-element decode of the `node.list` envelope (`{ts, nodes:[...]}`,
    /// `nodes.ts:1001`). Mirrors `OpsNodeLite.decodeList` exactly: `JSONSerialization` on the root, then
    /// map each `[String: Any]` element via `init(reading:)`. We never decode `[AnyCodable].self` — one
    /// malformed node element must not blank the whole fleet.
    static func decodeList(from data: Data) -> [FleetNode] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let nodesRaw = root["nodes"] as? [[String: Any]]
        else {
            return []
        }
        // Dedupe by nodeId (the `Identifiable` id + ForEach key): node.list is a union of paired /
        // approved / pending / live sources (node-catalog) and, while the catalog normally emits one row
        // per node, a duplicate id in a ForEach is a hard SwiftUI crash — keep the first occurrence.
        var seen = Set<String>()
        return nodesRaw
            .map(FleetNode.init(reading:))
            .filter { seen.insert($0.id).inserted }
    }
}

// MARK: - Node status (closed enum)

/// Closed connection status for a fleet node → dot color, sort weight, and short label. Closed so the
/// screen never re-derives status from the raw `connected` / `approvalState` fields at each call site.
enum FleetNodeStatus {
    /// Live websocket session (`connected == true`).
    case online
    /// Paired but the gateway reports no live session.
    case offline
    /// Pairing request awaiting approval / re-approval.
    case pending
    /// Known to the gateway but never approved.
    case unapproved

    var color: Color {
        switch self {
        case .online: OpenClawBrand.ok
        case .offline: OpenClawBrand.warn
        case .pending: OpenClawBrand.accent
        case .unapproved: .secondary
        }
    }

    var label: String {
        switch self {
        case .online: "online"
        case .offline: "offline"
        case .pending: "pending"
        case .unapproved: "unapproved"
        }
    }

    /// Sort weight so the fleet list renders online nodes first, then offline, then pending / unapproved.
    var sortRank: Int {
        switch self {
        case .online: 0
        case .offline: 1
        case .pending: 2
        case .unapproved: 3
        }
    }
}

// MARK: - Node actions (closed, scope-reachable only)

/// The status-read node actions the fleet dashboard can invoke. EVERY case here is a command that is
/// (a) `operator.write`-reachable — the iOS operator session always holds `operator.write`
/// (`NodeAppModel.swift:2811`) — and (b) in a platform DEFAULT allowlist (`node-command-policy.ts:82-129`),
/// so `node.invoke` accepts it the moment the target node DECLARES it. Buttons additionally gate on
/// `node.commands.contains(command)`, so an affordance only renders when the specific node declared the
/// command — an unreachable action never appears.
///
/// INVASIVE-CAPTURE commands (`camera.snap` / `camera.clip` / `screen.record` / `*.add` / `sms.*`) are
/// DELIBERATELY EXCLUDED here: they are in `DEFAULT_DANGEROUS_NODE_COMMANDS` (`node-command-policy.ts:71-79`),
/// NOT in any platform default, and require a server-side `gateway.nodes.allowCommands` grant the app
/// cannot make. They surface only via `FleetNodeDetail`'s separate "declared dangerous command" path —
/// behind both a `node.commands` membership check (so they appear iff an operator already enabled them)
/// AND a confirmation dialog — never as a silent-fail default affordance.
enum FleetAction: Identifiable, CaseIterable {
    case locationGet
    case deviceInfo
    case deviceStatus
    case cameraList
    case photosLatest
    case notify
    case screenSnapshot

    var id: String { self.command }

    /// The wire command id passed to `node.invoke` (`command` param, `nodes.ts:124-132`).
    var command: String {
        switch self {
        case .locationGet: "location.get"
        case .deviceInfo: "device.info"
        case .deviceStatus: "device.status"
        case .cameraList: "camera.list"
        case .photosLatest: "photos.latest"
        case .notify: "system.notify"
        case .screenSnapshot: "screen.snapshot"
        }
    }

    var title: String {
        switch self {
        case .locationGet: "Where is this device"
        case .deviceInfo: "Device info"
        case .deviceStatus: "Device status"
        case .cameraList: "List cameras"
        case .photosLatest: "Latest photo metadata"
        case .notify: "Send notification"
        case .screenSnapshot: "Screen snapshot"
        }
    }

    var subtitle: String {
        switch self {
        case .locationGet: "Read the device's current location"
        case .deviceInfo: "Read model, OS, and identity"
        case .deviceStatus: "Read battery, storage, and uptime"
        case .cameraList: "List cameras (does not capture)"
        case .photosLatest: "Read the newest photo's metadata"
        case .notify: "Push a local notification to the device"
        case .screenSnapshot: "Capture a still screen grab"
        }
    }

    var icon: String {
        switch self {
        case .locationGet: "location.fill"
        case .deviceInfo: "info.circle.fill"
        case .deviceStatus: "gauge.with.dots.needle.50percent"
        case .cameraList: "camera.fill"
        case .photosLatest: "photo.fill"
        case .notify: "bell.badge.fill"
        case .screenSnapshot: "rectangle.on.rectangle"
        }
    }

    /// All actions here are non-dangerous status reads (none are in `DEFAULT_DANGEROUS_NODE_COMMANDS`), so
    /// none require a confirm dialog. Kept as a field so `FleetNodeDetail` can branch uniformly across the
    /// default actions and any declared dangerous command without special-casing.
    var isInvasive: Bool { false }

    /// `screen.snapshot` is a macOS / Windows platform default ONLY — iOS screen capture is
    /// foreground-restricted and not allowlisted (`nodes.ts:290-297`). The detail screen shows this action
    /// for desktop-class nodes only, on top of the per-node `commands` membership check.
    var isDesktopOnly: Bool {
        if case .screenSnapshot = self { return true }
        return false
    }
}

// MARK: - Invoke result (closed)

/// Closed outcome of a `node.invoke` call → the inline status the detail screen shows under the button.
/// Mapped from the success payload and the gateway error codes: `node.invoke` returns
/// `{ ok:true, payload, payloadJSON }` on success (`nodes.ts:1330`), or a `GatewayResponseError` carrying
/// `UNAVAILABLE` with a nested `details.code` of `NOT_CONNECTED` (`nodes.ts:1240`) or
/// `QUEUED_UNTIL_FOREGROUND` (`nodes.ts:1378`). Closed so the view renders one state without juggling
/// parallel optionals.
enum FleetActionResult: Equatable {
    /// Command ran; `summary` is a short human-readable digest of the payload.
    case ok(summary: String)
    /// iOS foreground-only command (`camera.*` / `screen.*` / `talk.*`) queued because the target iPhone
    /// is backgrounded; it runs when the device next foregrounds (`nodes.ts:299-320`). NOT an error.
    case queuedUntilForeground
    /// Target node is disconnected and the APNs wake / wait window elapsed without it connecting.
    case notConnected
    /// The command is not in the node's allowlist+declared set, or the operator lacks the scope. Carries
    /// the gateway's reason when present.
    case notAllowed(reason: String)
    /// Any other failure (decode, timeout, transport).
    case error(String)

    var iconName: String {
        switch self {
        case .ok: "checkmark.circle.fill"
        case .queuedUntilForeground: "clock.badge.fill"
        case .notConnected: "wifi.slash"
        case .notAllowed: "hand.raised.fill"
        case .error: "exclamationmark.triangle.fill"
        }
    }

    var color: Color {
        switch self {
        case .ok: OpenClawBrand.ok
        case .queuedUntilForeground: OpenClawBrand.accent
        case .notConnected, .notAllowed, .error: OpenClawBrand.warn
        }
    }

    var message: String {
        switch self {
        case let .ok(summary): summary
        case .queuedUntilForeground: "Queued until the device returns to foreground."
        case .notConnected: "Device is offline — it did not reconnect in time."
        case let .notAllowed(reason): reason.isEmpty ? "Command not permitted on this node." : reason
        case let .error(message): message
        }
    }
}

// MARK: - Formatting

/// Number / time formatting for the Fleet screen, kept local so the screen doesn't depend on Ops's or
/// Cost's formatters. `relativeTime` mirrors `AgentProNodesDestination.relativeTime` (`:353-356`) exactly
/// so a node's "last seen" reads identically to a presence row's.
enum FleetFormatting {
    static func relativeTime(fromMilliseconds milliseconds: Int) -> String {
        let date = Date(timeIntervalSince1970: Double(milliseconds) / 1000)
        return date.formatted(.relative(presentation: .named, unitsStyle: .abbreviated))
    }
}
