import Foundation
import OpenClawKit
import OpenClawProtocol
import SwiftUI

// Local models + param builders for the Crons surface. The READ side reuses the shared-protocol
// `CronJob` / `CronListParams` / `CronRunsParams` / `CronRunLogEntry` decoders verbatim; this file adds
// only what the WRITE side needs that the shared protocol does not already expose:
//   - a fuller `cron.update` patch (the shared `CronUpdatePatch` in AgentProModels carries only
//     `{enabled}` for the Agent Pro pause/enable button),
//   - a `cron.remove` param shape,
//   - the closed schedule/payload/sessionTarget enums the editor drives,
//   - the `AnyCodable` dictionary builders that match the gateway's TypeBox cron schema exactly
//     (`packages/gateway-protocol/src/schema/cron.ts`), so the editor never hand-interpolates value JSON.
//
// HONEST scope: cron.add / cron.update / cron.remove / cron.run are `operator.admin`; cron.list /
// cron.get / cron.status / cron.runs are `operator.read`. The editor + run/delete controls gate on the
// device's `hasAdmin` grant (read locally from `LocalDeviceScopes`); a read-only device still lists jobs
// and views run history. See `CronJobsViewModel`.

// MARK: - Write params

/// Fuller `cron.update` patch than the `{enabled}`-only `CronUpdatePatch` in `AgentProModels`. Every
/// field is optional so the editor sends only what actually changed; `schedule` / `payload` /
/// `sessionTarget` / `wakeMode` are pre-built `AnyCodable` dictionaries matching the gateway's
/// `CronJobPatchSchema` (`cron.ts:493-511`). Omitted (`nil`) keys are dropped by the encoder.
///
/// Sending an unchanged field is NOT harmless for two patch keys, so `updateJob` must leave them `nil`
/// when untouched:
///   - `wakeMode`: `applyJobPatch` (`service/jobs.ts:850`) only writes `job.wakeMode` when the patch
///     carries it, so re-sending a default `next-heartbeat` would silently clobber a `now` job created
///     elsewhere (CronWakeModeSchema allows both, `cron.ts:59`).
///   - `schedule` (kind `every`): `update` (`service/ops.ts:526-541`) backfills `anchorMs = now` whenever
///     `patch.schedule?.kind === "every"` has no anchor, resetting the interval phase. The phone never
///     authors `anchorMs`, so re-sending an unchanged interval would drift its phase to "now".
struct CronEditPatch: Encodable {
    var name: String?
    var description: String?
    var enabled: Bool?
    var agentId: AnyCodable?
    var schedule: AnyCodable?
    var sessionTarget: AnyCodable?
    var wakeMode: AnyCodable?
    var payload: AnyCodable?
}

/// `cron.update` request: `{ id, patch }`. The handler accepts `id` OR `jobId`; we send `id` to match
/// the existing `CronUpdateParams` in `AgentProModels` and the Agent Pro pause/enable path.
struct CronEditUpdateParams: Encodable {
    let id: String
    let patch: CronEditPatch
}

/// `cron.remove` request: `{ id }`. Handler accepts `id` OR `jobId`; returns `{ ok, removed }` and 400s
/// with `INVALID_REQUEST` when `removed == false` (`cron.ts:608-623`), surfaced as a mutation error.
struct CronRemoveParams: Encodable {
    let id: String
}

// MARK: - Editor form state

/// Schedule kind the editor offers, 1:1 with `CronScheduleSchema` (`cron.ts:196-221`).
enum CronScheduleKind: String, CaseIterable, Identifiable {
    case cron
    case every
    case at

    var id: String { self.rawValue }

    var label: String {
        switch self {
        case .cron: "Cron"
        case .every: "Interval"
        case .at: "Once"
        }
    }

    /// One-line help shown under the schedule field so the operator knows the expected input format.
    var help: String {
        switch self {
        case .cron: "Five-field cron expression, e.g. 0 9 * * * (every day at 09:00)."
        case .every: "Run every N minutes (minimum 1)."
        case .at: "Run once at an ISO-8601 instant, e.g. 2026-07-01T09:00:00Z."
        }
    }
}

/// Where a cron job's payload runs, 1:1 with `CronSessionTargetSchema` (`cron.ts:51-56`). The editor
/// exposes the three fixed targets; `session:<id>` is an advanced form the phone editor does not author.
/// The gateway enforces a hard payload-kind constraint per target (`cron.ts:250-251`): `main` requires a
/// `systemEvent` payload, `isolated`/`current` require an `agentTurn` payload. `payloadKind` encodes that.
enum CronSessionTarget: String, CaseIterable, Identifiable {
    case main
    case isolated
    case current

    var id: String { self.rawValue }

    var label: String {
        switch self {
        case .main: "Main session"
        case .isolated: "Isolated run"
        case .current: "Current session"
        }
    }

    /// The only payload kind the gateway accepts for this target (`cron.ts:250-251`).
    var payloadKind: CronPayloadKind {
        switch self {
        case .main: .systemEvent
        case .isolated, .current: .agentTurn
        }
    }
}

/// The payload kinds the editor builds. `command` payloads exist in the schema but are an advanced argv
/// form the phone editor does not author; the prompt field maps to `systemEvent.text` (main) or
/// `agentTurn.message` (isolated/current), chosen by the session target.
enum CronPayloadKind {
    case systemEvent
    case agentTurn
}

/// Mutable form backing the editor sheet. `Identifiable` selection drives `.sheet(item:)`: a `nil`
/// `jobId` means CREATE, a set `jobId` means EDIT (the existing job's fields are loaded in first). Kept a
/// value type so the sheet edits a working copy and the screen only commits to the view model on Save.
struct CronEditorForm: Identifiable {
    /// Stable identity for `.sheet(item:)`. For create we mint a fresh UUID so a brand-new sheet always
    /// presents; for edit we key on the job id so re-tapping the same row reuses the same sheet identity.
    let id: String
    /// `nil` for create, the job id for edit. Distinct from `id` so the create sheet's transient UUID is
    /// never mistaken for a real job id when building the update request.
    let jobId: String?
    var name: String
    var prompt: String
    var scheduleKind: CronScheduleKind
    var cronExpr: String
    var everyMinutes: String
    var atISO: String
    var sessionTarget: CronSessionTarget
    var agentId: String?
    var enabled: Bool

    /// Snapshot of the stored job as first loaded into an edit sheet (`nil` for create). Used to detect
    /// which patch fields actually changed so `updateJob` omits untouched `schedule` / `wakeMode` —
    /// re-sending those silently mutates a job (interval phase reset / `wakeMode` clobber). See
    /// `CronEditPatch` and `CronFormValidator.editChanges`.
    let seed: CronEditSeed?

    var isEditing: Bool { self.jobId != nil }

    /// A blank create form. Defaults: a daily 09:00 cron, isolated agent-turn run (the most common
    /// "scheduled brief" shape), enabled, no explicit agent (inherits the gateway default agent).
    static func create() -> CronEditorForm {
        CronEditorForm(
            id: "create-\(UUID().uuidString)",
            jobId: nil,
            name: "",
            prompt: "",
            scheduleKind: .cron,
            cronExpr: "0 9 * * *",
            everyMinutes: "60",
            atISO: "",
            sessionTarget: .isolated,
            agentId: nil,
            enabled: true,
            seed: nil)
    }

    /// An edit form seeded from a decoded `CronJob`. Schedule/payload/sessionTarget are `AnyCodable`
    /// dictionaries on the wire, so we read them back through `CronJobFieldReader`. Unknown / advanced
    /// shapes (e.g. `command` payloads, `session:<id>` targets) fall back to safe editor defaults rather
    /// than blocking the edit — the operator can still rename/enable/reschedule without clobbering them
    /// because untouched fields are not sent in the patch (`seed` drives that change detection).
    static func edit(job: CronJob) -> CronEditorForm {
        let schedule = CronJobFieldReader.schedule(job)
        let payloadText = CronJobFieldReader.payloadText(job)
        let target = CronJobFieldReader.sessionTarget(job)
        return CronEditorForm(
            id: job.id,
            jobId: job.id,
            name: job.name,
            prompt: payloadText,
            scheduleKind: schedule.kind,
            cronExpr: schedule.expr,
            everyMinutes: schedule.everyMinutes,
            atISO: schedule.atISO,
            sessionTarget: target,
            agentId: CronJobFieldReader.agentId(job),
            enabled: job.enabled,
            seed: CronEditSeed(
                scheduleKind: schedule.kind,
                cronExpr: schedule.expr,
                everyMinutes: schedule.everyMinutes,
                atISO: schedule.atISO,
                wakeMode: CronJobFieldReader.wakeMode(job),
                payloadIsCommand: CronJobFieldReader.payloadIsCommand(job),
                sessionTarget: target,
                prompt: payloadText))
    }
}

/// The subset of a stored job's fields the editor must compare against on Save to avoid re-sending
/// unchanged-but-destructive patch keys. Captured once at `edit(job:)`; the editor's mutable fields are
/// diffed against this to decide whether `schedule` / `wakeMode` belong in the `cron.update` patch.
struct CronEditSeed {
    let scheduleKind: CronScheduleKind
    let cronExpr: String
    let everyMinutes: String
    let atISO: String
    /// The job's stored `wakeMode` (`next-heartbeat` / `now`), so we re-send it only when the operator
    /// changes it (the phone editor has no wakeMode control today, so this stays equal and is omitted).
    let wakeMode: String
    /// True when the stored payload is a `command` payload the phone cannot author. Save is refused for
    /// these rather than silently rewriting them to an `agentTurn` / `systemEvent` payload.
    let payloadIsCommand: Bool
    /// The session target the form was seeded with (a `session:<id>` original is displayed as its safe
    /// fallback). Compared against the live form so `sessionTarget` is only sent in the patch when the
    /// operator actually changes the picker — otherwise an unrepresentable original is preserved, not
    /// overwritten with the fallback.
    let sessionTarget: CronSessionTarget
    /// The prompt/instruction text the form was seeded with, so `payload` is only re-sent when edited
    /// (re-sending rebuilds the payload from the form and would rewrite a job whose payload the editor
    /// can't faithfully represent).
    let prompt: String
}

// MARK: - Validation

/// Closed validation outcome so the editor maps to an inline message + Save-enablement without juggling
/// parallel bool/string fields. `valid` carries the built request so the call site never re-derives it.
enum CronFormValidation {
    case valid(CronRequestPayload)
    case invalid(String)
}

/// The fully-built, schema-shaped request payload for a save. `schedule` / `payload` / `sessionTarget` /
/// `wakeMode` are `AnyCodable` dictionaries matching the gateway cron schema exactly. Shared by create
/// (`cron.add`) and edit (`cron.update` patch) so both paths build identical, validated shapes.
///
/// `editChanges` is `nil` for create (everything is sent) and, for edit, names which optional patch keys
/// the operator actually changed so `updateJob` can omit untouched `schedule` / `wakeMode` (re-sending
/// either silently mutates the stored job).
struct CronRequestPayload {
    let name: String
    let schedule: AnyCodable
    let payload: AnyCodable
    let sessionTarget: AnyCodable
    let wakeMode: AnyCodable
    let agentId: String?
    let enabled: Bool
    let editChanges: CronEditChanges?
}

/// Which optional `cron.update` patch keys actually changed vs the seeded job. Lets `updateJob` send a
/// true partial patch for the two keys where re-sending an unchanged value is destructive.
struct CronEditChanges {
    let scheduleChanged: Bool
    let wakeModeChanged: Bool
    let sessionTargetChanged: Bool
    let payloadChanged: Bool
}

/// Build + validate the request from a form, client-side, before any round-trip. Mirrors the gateway's
/// own constraints so the common errors (empty name/prompt/expr, bad interval) surface instantly instead
/// of as a 400: non-empty name, non-empty prompt, and a schedule-kind-specific check. The payload kind is
/// derived from the session target (`main` => systemEvent.text, isolated/current => agentTurn.message),
/// exactly matching `cron.ts:250-251`, so a valid form can never violate that server constraint.
enum CronFormValidator {
    static func validate(_ form: CronEditorForm) -> CronFormValidation {
        let name = form.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            return .invalid("Name is required.")
        }

        // The phone cannot author `command` payloads; saving would rewrite the stored argv to an
        // `agentTurn` / `systemEvent` payload (`mergeCronPayload`, `service/jobs.ts:900`), losing it. Refuse
        // rather than silently clobber — the operator edits these from the CLI / macOS UI.
        if form.seed?.payloadIsCommand == true {
            return .invalid("This job runs a command. Edit it from the CLI or desktop app.")
        }

        let prompt = form.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else {
            return .invalid("A prompt or instruction is required.")
        }

        let scheduleResult = Self.buildSchedule(form)
        guard case let .success(schedule) = scheduleResult else {
            if case let .failure(error) = scheduleResult { return .invalid(error.message) }
            return .invalid("Invalid schedule.")
        }

        let target = form.sessionTarget
        let payload = Self.buildPayload(kind: target.payloadKind, text: prompt)

        let agentId = form.agentId?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedAgentId = (agentId?.isEmpty ?? true) ? nil : agentId

        // `next-heartbeat` is the conservative default for CREATE (waits for the next heartbeat tick
        // rather than forcing an immediate wake), matching the macOS editor default. For EDIT we re-emit
        // the job's stored wakeMode so an existing `now` job is preserved (see `editChanges`).
        let wakeMode = form.seed?.wakeMode ?? "next-heartbeat"

        let request = CronRequestPayload(
            name: name,
            schedule: schedule,
            payload: payload,
            sessionTarget: AnyCodable(target.rawValue),
            wakeMode: AnyCodable(wakeMode),
            agentId: resolvedAgentId,
            enabled: form.enabled,
            editChanges: form.seed.map { Self.editChanges(form: form, seed: $0) })
        return .valid(request)
    }

    /// Compute which destructive-to-resend patch keys the operator changed vs the seeded job. Schedule is
    /// compared field-by-field (trimmed) for the active kind. The phone has no wakeMode control, so
    /// `wakeModeChanged` is always false — the patch therefore omits `wakeMode` and the stored value
    /// (`next-heartbeat` or `now`) is preserved by `applyJobPatch`.
    private static func editChanges(form: CronEditorForm, seed: CronEditSeed) -> CronEditChanges {
        func trimmed(_ value: String) -> String {
            value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let scheduleChanged =
            form.scheduleKind != seed.scheduleKind
                || trimmed(form.cronExpr) != trimmed(seed.cronExpr)
                || trimmed(form.everyMinutes) != trimmed(seed.everyMinutes)
                || trimmed(form.atISO) != trimmed(seed.atISO)
        // sessionTarget / payload are sent ONLY when the operator changed them: re-sending the form's
        // fallback rendering of a `session:<id>` target (or rebuilding the payload from a command job the
        // editor can't represent) would overwrite the stored value. The phone has no wakeMode control.
        let sessionTargetChanged = form.sessionTarget != seed.sessionTarget
        let payloadChanged = trimmed(form.prompt) != trimmed(seed.prompt)
        return CronEditChanges(
            scheduleChanged: scheduleChanged,
            wakeModeChanged: false,
            sessionTargetChanged: sessionTargetChanged,
            payloadChanged: payloadChanged)
    }

    /// A human-readable validation failure for schedule building. `Result.Failure` must conform to
    /// `Error`, so the message is wrapped rather than thrown as a bare `String`.
    private struct CronFieldError: Error { let message: String }

    /// Build the schedule `AnyCodable` dictionary for the chosen kind, or a human error. Dictionaries are
    /// `[String: Any]` and encode through `AnyCodable`'s `[String: Any]` case, producing the exact wire
    /// shapes `{kind:"cron",expr}` / `{kind:"every",everyMs}` / `{kind:"at",at}` from `cron.ts:196-221`.
    private static func buildSchedule(_ form: CronEditorForm) -> Result<AnyCodable, CronFieldError> {
        switch form.scheduleKind {
        case .cron:
            let expr = form.cronExpr.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !expr.isEmpty else {
                return .failure(CronFieldError(message: "Cron expression is required."))
            }
            // Reject obviously-malformed expressions client-side rather than letting the mutation RPC
            // create/update a job with an unrunnable spec: standard cron is 5 fields (6 with seconds).
            let fieldCount = expr.split(whereSeparator: \.isWhitespace).count
            guard (5...6).contains(fieldCount) else {
                return .failure(CronFieldError(message: "Cron expression must have 5 fields (e.g. \"0 9 * * *\")."))
            }
            return .success(AnyCodable(["kind": "cron", "expr": expr]))
        case .every:
            let raw = form.everyMinutes.trimmingCharacters(in: .whitespacesAndNewlines)
            // Upper bound guards against an `Int` overflow trap on `minutes * 60_000` for a huge but
            // otherwise-valid integer input — that would crash the editor mid-validation.
            guard let minutes = Int(raw), minutes >= 1, minutes <= Int.max / 60_000 else {
                return .failure(CronFieldError(message: "Interval must be a whole number of minutes (1 to 35 million)."))
            }
            // Schema is `everyMs` (`>= 1`); convert minutes to ms once here so the field stays operator-
            // friendly while the wire value matches `CronScheduleSchema`.
            return .success(AnyCodable(["kind": "every", "everyMs": minutes * 60_000]))
        case .at:
            let at = form.atISO.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !at.isEmpty else {
                return .failure(CronFieldError(message: "A run time is required (ISO-8601)."))
            }
            // Parse to reject a malformed/non-ISO instant before it reaches the mutation RPC.
            guard ISO8601DateFormatter().date(from: at) != nil else {
                return .failure(CronFieldError(message: "Run time must be an ISO-8601 instant (e.g. 2026-06-22T09:00:00Z)."))
            }
            return .success(AnyCodable(["kind": "at", "at": at]))
        }
    }

    /// Build the payload `AnyCodable` for the kind: `{kind:"systemEvent",text}` for main-session jobs,
    /// `{kind:"agentTurn",message}` for isolated/current jobs (`CronPayloadSchema`, `cron.ts:224-240`).
    private static func buildPayload(kind: CronPayloadKind, text: String) -> AnyCodable {
        switch kind {
        case .systemEvent:
            AnyCodable(["kind": "systemEvent", "text": text])
        case .agentTurn:
            AnyCodable(["kind": "agentTurn", "message": text])
        }
    }
}

// MARK: - CronJob field reader (decode the AnyCodable wire fields for display + edit-seed)

/// Read the loosely-typed (`AnyCodable`) cron fields back out for display + edit-seeding. The gateway
/// stores `schedule` / `payload` / `sessionTarget` / `agentId` as opaque JSON; we read them once here so
/// the row and the editor never re-walk the dictionaries per render. Mirrors the macOS cron settings
/// reader and `AgentProTab+Cron.cronScheduleSummary`.
enum CronJobFieldReader {
    struct Schedule {
        let kind: CronScheduleKind
        let expr: String
        let everyMinutes: String
        let atISO: String
    }

    /// A human-readable one-line schedule label for the list row, matching `cronScheduleSummary`'s style.
    static func scheduleSummary(_ job: CronJob) -> String {
        guard let dict = job.schedule.value as? [String: AnyCodable] else {
            return "Schedule configured"
        }
        if let expr = Self.string(dict["expr"]) {
            return "Cron \(expr)"
        }
        if let everyMs = AgentProValueReader.intValue(dict["everyMs"]) {
            return "Every \(Self.durationLabel(milliseconds: everyMs))"
        }
        if let at = Self.string(dict["at"]) {
            return "Once at \(at)"
        }
        if let kind = Self.string(dict["kind"]) {
            return kind
        }
        return "Schedule configured"
    }

    /// Decode the schedule into editor fields. Unknown / unsupported shapes fall back to a daily cron so
    /// the edit sheet always opens with a usable schedule. The same `everyMinutes` value seeds both the
    /// form field and `CronEditSeed`, so an untouched interval compares equal and the patch omits
    /// `schedule` (`CronFormValidator.editChanges`) — the stored `everyMs`/`anchorMs` are preserved
    /// untouched. An operator who edits the minutes field DOES normalize the interval to whole minutes
    /// (a sub-minute or non-multiple `everyMs` rounds down here), which is the intended editor precision.
    static func schedule(_ job: CronJob) -> Schedule {
        guard let dict = job.schedule.value as? [String: AnyCodable] else {
            return Schedule(kind: .cron, expr: "0 9 * * *", everyMinutes: "60", atISO: "")
        }
        if let expr = Self.string(dict["expr"]) {
            return Schedule(kind: .cron, expr: expr, everyMinutes: "60", atISO: "")
        }
        if let everyMs = AgentProValueReader.intValue(dict["everyMs"]) {
            let minutes = max(1, everyMs / 60_000)
            return Schedule(kind: .every, expr: "0 9 * * *", everyMinutes: "\(minutes)", atISO: "")
        }
        if let at = Self.string(dict["at"]) {
            return Schedule(kind: .at, expr: "0 9 * * *", everyMinutes: "60", atISO: at)
        }
        return Schedule(kind: .cron, expr: "0 9 * * *", everyMinutes: "60", atISO: "")
    }

    /// The prompt text for the editor: `systemEvent.text` or `agentTurn.message`. Empty for advanced
    /// `command` payloads (which the phone editor does not author).
    static func payloadText(_ job: CronJob) -> String {
        guard let dict = job.payload.value as? [String: AnyCodable] else { return "" }
        if let text = Self.string(dict["text"]) { return text }
        if let message = Self.string(dict["message"]) { return message }
        return ""
    }

    /// True when the stored payload is a `command` payload (`CronPayloadSchema`, `cron.ts:38`). The phone
    /// editor cannot author argv, so the editor refuses to save these rather than rewriting them.
    static func payloadIsCommand(_ job: CronJob) -> Bool {
        guard let dict = job.payload.value as? [String: AnyCodable] else { return false }
        return Self.string(dict["kind"]) == "command"
    }

    /// The job's stored `wakeMode` (`next-heartbeat` / `now`, `CronWakeModeSchema`, `cron.ts:59`). Read so
    /// the edit path re-emits the existing value instead of clobbering a `now` job back to `next-heartbeat`.
    static func wakeMode(_ job: CronJob) -> String {
        Self.string(job.wakemode) ?? "next-heartbeat"
    }

    /// The session target for the editor. `session:<id>` and any unknown value fall back to `isolated`
    /// (the safe agent-turn default); the operator only overrides it deliberately.
    static func sessionTarget(_ job: CronJob) -> CronSessionTarget {
        let raw = Self.string(job.sessiontarget) ?? "isolated"
        return CronSessionTarget(rawValue: raw) ?? .isolated
    }

    /// The job's bound agent id, if any. `agentId` is a top-level string column on the job (not inside an
    /// AnyCodable dict), so read it directly.
    static func agentId(_ job: CronJob) -> String? {
        let trimmed = job.agentid?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The `nextRunAtMs` (ms epoch) from the server-owned state blob, for the row's "next run" label.
    static func nextRunAtMs(_ job: CronJob) -> Int? {
        AgentProValueReader.intValue(job.state["nextRunAtMs"])
    }

    private static func string(_ value: AnyCodable?) -> String? {
        guard let string = value?.value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Compact duration label (mirrors `BriefRun.duration` / `AgentProTab.duration`) for interval jobs.
    private static func durationLabel(milliseconds: Int) -> String {
        let seconds = max(0, milliseconds / 1000)
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h" }
        return "\(hours / 24)d"
    }
}

// MARK: - Manual-run disposition

/// Closed disposition for a `cron.run` result so the row maps the gateway's two response shapes to a
/// status line without re-stringly inspecting them. `cron.run` calls `enqueueRun` (`server-methods/cron.ts`):
/// a successful queue returns `{ok:true, enqueued:true, runId}` (NO `ran` key); a pre-flight skip returns
/// `{ok:true, ran:false, reason}` (`service/ops.ts`). So a missing `ran` means "queued", which is why the
/// decode below defaults `ran` to true.
enum CronManualRunResult {
    case ran
    case skipped(reason: String)

    /// Decode the `cron.run` response. A queued run (`enqueued:true`, no `ran`) or a missing/garbled body
    /// is treated as `ran` (the work was accepted / the list re-fetch reconciles real state); only an
    /// explicit `{ran:false, reason}` skip surfaces as skipped.
    static func decode(from data: Data) -> CronManualRunResult {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .ran
        }
        let ran = (root["ran"] as? Bool) ?? true
        if ran { return .ran }
        let reason = (root["reason"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return .skipped(reason: reason.isEmpty ? "not-due" : reason)
    }

    var statusText: String {
        switch self {
        case .ran:
            return "Queued."
        case let .skipped(reason):
            return "Not run (\(reason))."
        }
    }
}
