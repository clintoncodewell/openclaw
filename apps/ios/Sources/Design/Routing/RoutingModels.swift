import Foundation
import OpenClawKit
import OpenClawProtocol
import SwiftUI

/// Lite decode mirrors + derived view models for the Model Routing surface. The screen reads two
/// gateway RPCs and folds them into per-agent routing rows:
///
/// - `agents.list` (scope `operator.read`) → `AgentsListResult` / `AgentSummary` (already in
///   `GatewayModels.swift`). Each agent's `model` dict carries BOTH the primary AND the resolved
///   fallback chain on the wire — built by `resolveGatewayAgentModel` (`session-utils.ts:1235-1250`)
///   as `{ primary?: string, fallbacks?: string[] }`. The existing roster line
///   (`AgentProTab+GatewayData.swift modelLabel`) only reads `model["primary"]` and drops the
///   fallbacks; `AgentRoutingLite` reads both, so the chain is finally surfaced.
/// - `models.list` `{"view":"all"}` (scope `operator.read`) → `ModelsListResult` / `ModelChoice`
///   (already typed). The `all` view returns the full catalog annotated with a per-entry
///   `available` flag (provider-auth availability, `models-list-result.ts:195-223`). We cross-
///   reference each agent's primary/fallback model ids against this catalog to tag each step
///   available / unavailable.
///
/// READ-ONLY by design. The gateway exposes no non-destructive routing setter. The one writable RPC
/// (`agents.update`) takes only a bare `model` string, and the handler writes it straight over the
/// agent's whole `model` config object via `applyAgentConfig`, replacing `{primary, fallbacks}`. A bare
/// string then reads back as an explicit `fallbacks: []` override (`resolveSelectedModelFallbacksOverride`
/// in `agent-scope.ts`), wiping the agent's chain AND disabling global default fallbacks — so even a
/// "primary only" write is destructive. The non-destructive `setAgentEffectiveModelPrimary` helper exists
/// server-side but is wired to no RPC. The surface is therefore a pure derived view with no setter.

// MARK: - agents.list (per-agent routing)

/// One agent's resolved routing, read from `AgentSummary.model` (`[String: AnyCodable]?`). The dict
/// carries `primary` (string) and `fallbacks` (string array) already resolved by the gateway
/// (`session-utils.ts:1248`); we read both. `runtimeId` is the resolved provider/runtime label off
/// `agentRuntime.id` for the row caption. Kept a plain value so the screen re-renders fully on reload.
struct AgentRoutingLite: Identifiable {
    let id: String
    let name: String
    let workspace: String?
    let isDefault: Bool
    let primary: String?
    let fallbacks: [String]
    let runtimeId: String?

    /// Build from a decoded `AgentSummary` + the gateway's default-agent id. Reads the primary and the
    /// already-on-the-wire fallback chain out of the `model` dict, deduping the primary out of the
    /// fallback list so a model that is both primary and listed as a fallback isn't shown twice.
    init(agent: AgentSummary, defaultAgentId: String?) {
        self.id = agent.id
        self.name = Self.normalized(agent.name) ?? agent.id
        self.workspace = Self.normalized(agent.workspace)
        self.isDefault = defaultAgentId.map { $0 == agent.id } ?? false

        let model = agent.model
        self.primary = Self.stringField(model?["primary"])
            ?? Self.stringField(model?["name"])
            ?? Self.stringField(model?["id"])
            ?? Self.stringField(model?["model"])

        let rawFallbacks = Self.stringArrayField(model?["fallbacks"])
        // Drop any fallback equal to the primary: the gateway dedupes via `normalizeFallbackList`
        // (`session-utils.ts:1217`), but a defensive client-side dedupe keeps the chain clean even if a
        // future resolver leaves the primary in the list.
        let primaryValue = self.primary
        self.fallbacks = rawFallbacks.filter { $0 != primaryValue }

        if let runtime = agent.agentruntime, let runtimeId = Self.stringField(runtime["id"]) {
            self.runtimeId = runtimeId
        } else {
            self.runtimeId = nil
        }
    }

    /// True when this agent has a fallback chain to render. Drives the "primary only" vs "chain" copy.
    var hasFallbacks: Bool { !self.fallbacks.isEmpty }

    private static func stringField(_ value: AnyCodable?) -> String? {
        guard let string = value?.value as? String else { return nil }
        return Self.normalized(string)
    }

    /// Read a `[String]` field from an `AnyCodable`. A decoded `AnyCodable` array holds `[AnyCodable]`
    /// elements (each value re-wrapped), so we unwrap `element.value as? String` per item — a plain
    /// `as? [String]` / `element as? String` would fail because the elements are `AnyCodable`, not raw
    /// strings. Non-string / empty entries are dropped.
    private static func stringArrayField(_ value: AnyCodable?) -> [String] {
        if let wrapped = value?.value as? [AnyCodable] {
            return wrapped.compactMap { Self.normalized($0.value as? String) }
        }
        // Fallback for a raw `[String]` / `[Any]` (e.g. built locally via `AnyCodable(["a","b"])`).
        if let rawArray = value?.value as? [Any] {
            return rawArray.compactMap { Self.normalized($0 as? String) }
        }
        return []
    }

    private static func normalized(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}

extension AgentRoutingLite {
    /// Lossy per-`agents[]`-element decode of the `agents.list` envelope. A plain `JSONDecoder` of
    /// `AgentsListResult` is attempted first; the lenient path rebuilds each `AgentSummary` from a
    /// `JSONSerialization` element so one malformed agent row can't blank the whole roster. Mirrors the
    /// lossy fast-path / lenient-rebuild pattern in `OpsUsageResultLite.decode` /
    /// `InboxApproval.decodeList`. Returns the rows plus the resolved default-agent id for the badge.
    static func decodeList(from data: Data) -> (agents: [AgentRoutingLite], defaultId: String?) {
        let decoder = JSONDecoder()
        if let result = try? decoder.decode(AgentsListResult.self, from: data) {
            let rows = result.agents.map { AgentRoutingLite(agent: $0, defaultAgentId: result.defaultid) }
            return (rows, result.defaultid)
        }

        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ([], nil)
        }
        let defaultId = (root["defaultId"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawAgents = (root["agents"] as? [Any]) ?? []
        var rows: [AgentRoutingLite] = []
        rows.reserveCapacity(rawAgents.count)
        for element in rawAgents {
            guard JSONSerialization.isValidJSONObject(element),
                  let entryData = try? JSONSerialization.data(withJSONObject: element),
                  let agent = try? decoder.decode(AgentSummary.self, from: entryData)
            else {
                continue
            }
            rows.append(AgentRoutingLite(agent: agent, defaultAgentId: defaultId))
        }
        return (rows, defaultId.flatMap { $0.isEmpty ? nil : $0 })
    }
}

// MARK: - models.list (catalog)

/// One catalog model with its provider-auth availability, decoded from `models.list` `{"view":"all"}`.
/// A thin wrapper over `ModelChoice` (already typed in `GatewayModels.swift`) so the routing screen can
/// group + cross-reference without re-reading the protocol type. `available == nil` means the gateway
/// didn't annotate availability (the non-`all` view), which we treat as "assume available".
struct RoutingCatalogModel: Identifiable {
    let id: String
    let name: String
    let provider: String
    let alias: String?
    let available: Bool
    let reasoning: Bool

    init(choice: ModelChoice) {
        self.id = choice.id
        self.name = choice.name.isEmpty ? choice.id : choice.name
        self.provider = choice.provider
        self.alias = choice.alias
        // `available` is only set in the `all` view; absence means "not annotated", which we read as
        // available so a missing flag never paints a working model red.
        self.available = choice.available ?? true
        self.reasoning = choice.reasoning ?? false
    }
}

extension RoutingCatalogModel {
    /// Lossy decode of the `models.list` envelope (`{ models: [...] }`). Fast-path decodes
    /// `ModelsListResult`; the lenient path rebuilds each `ModelChoice` element on its own so one
    /// malformed catalog row can't blank the section.
    static func decodeList(from data: Data) -> [RoutingCatalogModel] {
        let decoder = JSONDecoder()
        if let result = try? decoder.decode(ModelsListResult.self, from: data) {
            return result.models.map(RoutingCatalogModel.init(choice:))
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawModels = root["models"] as? [Any]
        else {
            return []
        }
        var models: [RoutingCatalogModel] = []
        models.reserveCapacity(rawModels.count)
        for element in rawModels {
            guard JSONSerialization.isValidJSONObject(element),
                  let entryData = try? JSONSerialization.data(withJSONObject: element),
                  let choice = try? decoder.decode(ModelChoice.self, from: entryData)
            else {
                continue
            }
            models.append(RoutingCatalogModel(choice: choice))
        }
        return models
    }
}

// MARK: - Catalog index + per-step availability

/// An index over the catalog so each routing step (primary / fallback) can be resolved to a catalog
/// entry by model id OR alias in one lookup, instead of scanning the array per step. Built once per
/// load. `byProvider` backs the grouped catalog section.
struct RoutingCatalog {
    let models: [RoutingCatalogModel]
    private let byKey: [String: RoutingCatalogModel]

    init(models: [RoutingCatalogModel]) {
        self.models = models
        var index: [String: RoutingCatalogModel] = [:]
        index.reserveCapacity(models.count * 2)
        for model in models {
            // Index by id first; only fill an alias slot if it isn't already taken by a real id, so a
            // model whose id collides with another's alias still resolves to itself.
            if index[model.id] == nil { index[model.id] = model }
            if let alias = model.alias, !alias.isEmpty, index[alias] == nil {
                index[alias] = model
            }
        }
        self.byKey = index
    }

    var isEmpty: Bool { self.models.isEmpty }

    /// Resolve a routing step's model ref to a catalog entry by id or alias. `nil` when the agent
    /// points at a model the catalog doesn't list (e.g. a provider that isn't configured) — the row
    /// then renders it as "not in catalog" rather than claiming availability it can't verify.
    func model(forRef ref: String) -> RoutingCatalogModel? {
        self.byKey[ref]
    }

    /// Catalog grouped by provider, providers alphabetized, models name-sorted within each — the shape
    /// the screen's catalog section renders.
    var byProvider: [RoutingCatalogProviderGroup] {
        var grouped: [String: [RoutingCatalogModel]] = [:]
        for model in self.models {
            grouped[model.provider, default: []].append(model)
        }
        return grouped
            .map { provider, models in
                RoutingCatalogProviderGroup(
                    provider: provider,
                    models: models.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending })
            }
            .sorted { $0.provider.localizedCaseInsensitiveCompare($1.provider) == .orderedAscending }
    }
}

/// One provider's catalog group for the grouped catalog section.
struct RoutingCatalogProviderGroup: Identifiable {
    let provider: String
    let models: [RoutingCatalogModel]

    var id: String { self.provider }

    /// Count of unavailable (provider-auth-failing) models in the group, for the group header pill.
    var unavailableCount: Int {
        self.models.reduce(0) { $0 + ($1.available ? 0 : 1) }
    }
}

/// One resolved routing step (primary or a fallback) for an agent, tagged with catalog availability.
/// Closed `kind` so the row maps to a label/color without re-deriving which slot it is.
struct RoutingStep: Identifiable {
    enum Kind {
        case primary
        case fallback(order: Int)
    }

    let kind: Kind
    let modelRef: String
    /// Availability verdict against the catalog. `.available` / `.unavailable` come from the catalog's
    /// `available` flag; `.unknown` means the ref isn't in the catalog at all (can't verify).
    let availability: RoutingAvailability
    /// Short display label for the step, leaf of the model ref with provider prefixes stripped.
    let displayLabel: String

    var id: String {
        switch self.kind {
        case .primary: "primary:\(self.modelRef)"
        case let .fallback(order): "fallback:\(order):\(self.modelRef)"
        }
    }

    /// Build a step from a model ref + the catalog index. The label is the leaf name with `claude-` /
    /// `gpt-` stripped, matching the existing `shortModelLabel` shortening used across Cost / Agent Pro.
    init(kind: Kind, modelRef: String, catalog: RoutingCatalog) {
        self.kind = kind
        self.modelRef = modelRef
        self.displayLabel = RoutingFormatting.shortModelLabel(modelRef)
        if let model = catalog.model(forRef: modelRef) {
            self.availability = model.available ? .available : .unavailable
        } else {
            // Ref not in the catalog (provider not configured, or the catalog failed to load): we can't
            // verify availability, so render it neutral rather than claim a verdict either way.
            self.availability = .unknown
        }
    }

    var slotLabel: String {
        switch self.kind {
        case .primary: "Primary"
        case let .fallback(order): "Fallback \(order)"
        }
    }
}

/// Closed availability verdict for a routing step → status dot color. `.unknown` (ref not in catalog)
/// is a neutral/secondary state, distinct from a catalog model the provider can't authenticate.
enum RoutingAvailability {
    case available
    case unavailable
    case unknown

    var color: Color {
        switch self {
        case .available: OpenClawBrand.ok
        case .unavailable: OpenClawBrand.warn
        case .unknown: .secondary
        }
    }

    var label: String {
        switch self {
        case .available: "available"
        case .unavailable: "unavailable"
        case .unknown: "not in catalog"
        }
    }
}

/// The fully assembled routing row the screen renders: the agent's identity plus its ordered routing
/// chain (primary first, then fallbacks in order), each tagged with catalog availability.
struct AgentRoutingRow: Identifiable {
    let agent: AgentRoutingLite
    let steps: [RoutingStep]

    var id: String { self.agent.id }

    /// Build the ordered routing chain by resolving the agent's primary + fallbacks against the catalog.
    /// A `nil` primary (agent on the gateway default) yields no primary step — the row then reads
    /// "Gateway default".
    init(agent: AgentRoutingLite, catalog: RoutingCatalog) {
        self.agent = agent
        var steps: [RoutingStep] = []
        if let primary = agent.primary {
            steps.append(RoutingStep(kind: .primary, modelRef: primary, catalog: catalog))
        }
        for (offset, fallback) in agent.fallbacks.enumerated() {
            steps.append(RoutingStep(
                kind: .fallback(order: offset + 1),
                modelRef: fallback,
                catalog: catalog))
        }
        self.steps = steps
    }

    var primaryStep: RoutingStep? {
        self.steps.first { step in
            if case .primary = step.kind { return true }
            return false
        }
    }

    var fallbackSteps: [RoutingStep] {
        self.steps.filter { step in
            if case .fallback = step.kind { return true }
            return false
        }
    }

    /// True when at least one step in the chain is provider-auth unavailable — the row badge that flags
    /// a routing chain whose primary or a fallback can't currently authenticate.
    var hasUnavailableStep: Bool {
        self.steps.contains { $0.availability == .unavailable }
    }
}

/// Number / label formatting for the Routing screen, kept local so the screen doesn't depend on Cost's
/// or Ops's formatters. `shortModelLabel` mirrors `CostFormatting.shortModelLabel` /
/// `AgentProTab.shortModelLabel` exactly so the same model renders identically across surfaces.
enum RoutingFormatting {
    static func shortModelLabel(_ model: String) -> String {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "default" }
        let leaf = trimmed.split(separator: "/").last.map(String.init) ?? trimmed
        return leaf
            .replacingOccurrences(of: "claude-", with: "")
            .replacingOccurrences(of: "gpt-", with: "")
    }
}
