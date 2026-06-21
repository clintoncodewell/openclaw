import Foundation
import OpenClawKit
import OpenClawProtocol
import SwiftUI

/// Closed load state for the Crons dashboard so the view never juggles parallel nullable flags.
/// Mirrors `CostLoadState` / `BriefsLoadState`. `loaded` carries the decoded job definitions; the
/// last-run map and scheduler status are separate published fields so a failed run-log / status call
/// drops only its own section, not the whole list.
enum CronJobsLoadState: Equatable {
    case idle
    case loading
    case loaded([CronJob])
    case empty
    case offline
    case error(String)

    static func == (lhs: CronJobsLoadState, rhs: CronJobsLoadState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.loading, .loading), (.empty, .empty), (.offline, .offline):
            true
        case let (.error(l), .error(r)):
            l == r
        case let (.loaded(l), .loaded(r)):
            // Identity by the cheap (id, updatedAtMs, enabled) tuple; the screen re-renders fully on any
            // reload, so this only needs to detect "the set of jobs changed" cheaply.
            l.count == r.count
                && zip(l, r).allSatisfy {
                    $0.id == $1.id && $0.updatedatms == $1.updatedatms && $0.enabled == $1.enabled
                }
        default:
            false
        }
    }
}

/// Drives the Crons dashboard: the cron JOB-DEFINITION list (`cron.list`, distinct from the Briefs
/// run-LOG), the scheduler status (`cron.status`), and a per-job last-run map derived from one
/// `cron.runs` page (reusing the Briefs `CronRunLogEntry` -> `BriefRun` decode). Structure mirrors
/// `CostInsightsViewModel`: a closed load-state enum, a `connected(appModel:)` gate copied verbatim, and
/// a load that preserves the prior list on a transient failure so the screen never blanks mid-refresh.
///
/// WRITE feasibility is honest: cron.add / cron.update / cron.remove / cron.run are `operator.admin`; the
/// editor + run/delete/enable controls gate on `hasAdmin` (read locally from `LocalDeviceScopes`, no RPC).
/// A read-only device still lists jobs + views runs (`operator.read`); its mutating controls disable.
@MainActor
@Observable
final class CronJobsViewModel {
    private(set) var state: CronJobsLoadState = .idle

    /// Scheduler on/off + job count + next wake, from `cron.status`. `nil` until first load / offline.
    private(set) var status: CronStatusLite?

    /// jobId -> its most recent run, derived from one `cron.runs` page. Drives each row's last-run badge.
    /// Separate from `state` so a failed run-log call leaves the job list intact (only the badges drop).
    private(set) var lastRuns: [String: BriefRun] = [:]

    /// This device's operator scopes, read locally from the paired operator token. `hasAdmin` gates every
    /// mutating control; a narrowed (read-only) device shows the list but disables create/edit/run/delete.
    /// Captured on each load so a re-pair with broader scope takes effect on the next refresh.
    private(set) var hasAdmin = false

    /// Per-job busy ids for the run/enable/delete spinners (mirrors `AgentProTab.cronActionBusyIDs`).
    private(set) var busyJobIDs: Set<String> = []

    /// Transient status / error line shown under the header after a mutation (mirrors
    /// `AgentProTab.cronActionStatusText`). Cleared on the next mutation.
    private(set) var actionStatusText: String?

    /// How many jobs to request in one page. `cron.list` clamps `limit` to 1...200.
    private static let pageLimit = 200
    /// How many run-log entries to scan for the per-job last-run map.
    private static let runsLimit = 200

    var jobs: [CronJob] {
        if case let .loaded(jobs) = self.state { return jobs }
        return []
    }

    /// Jobs sorted by soonest next run, then name — matching `AgentProTab.sortedCronJobs`.
    var sortedJobs: [CronJob] {
        self.jobs.sorted { lhs, rhs in
            let lhsNext = CronJobFieldReader.nextRunAtMs(lhs)
            let rhsNext = CronJobFieldReader.nextRunAtMs(rhs)
            switch (lhsNext, rhsNext) {
            case let (l?, r?): return l < r
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
        }
    }

    // MARK: - Load

    func load(appModel: NodeAppModel, force: Bool) async {
        guard self.connected(appModel: appModel) else {
            self.state = .offline
            return
        }
        if case .loading = self.state, !force { return }
        // Preserve already-loaded content while refetching so the list never blanks to a spinner — covers
        // pull-to-refresh (force) and the scenePhase foreground refresh (force == false).
        if case .loaded = self.state {} else {
            self.state = .loading
        }

        // This device's scopes are local — no RPC — so gating renders even if every RPC below fails.
        self.hasAdmin = LocalDeviceScopes(deviceId: DeviceIdentityStore.loadOrCreate().deviceId).hasAdmin

        // Three concurrent reads: the job-definition page (primary), the scheduler status, and one
        // run-log page for the last-run map. Each is independent — a nil from status/runs drops only that
        // section; the list comes from `cron.list`.
        async let listData = Self.requestData(
            appModel: appModel,
            method: "cron.list",
            paramsJSON: Self.listParamsJSON())
        async let statusData = Self.requestData(
            appModel: appModel,
            method: "cron.status",
            paramsJSON: "{}")
        async let runsData = Self.requestData(
            appModel: appModel,
            method: "cron.runs",
            paramsJSON: Self.runsParamsJSON())

        let list = await listData
        let status = await statusData
        let runs = await runsData

        // `cron.list` is the primary source; if it failed entirely, keep any prior list and only surface
        // an error when the screen is otherwise empty (mirrors the reference VMs).
        guard let listData = list, let jobs = Self.decodeJobs(from: listData) else {
            if case .loaded = self.state { return }
            self.state = .error("Could not load scheduled jobs.")
            return
        }

        self.status = status.flatMap { try? JSONDecoder().decode(CronStatusLite.self, from: $0) } ?? self.status
        if let runs { self.lastRuns = Self.decodeLastRuns(from: runs) }
        self.state = jobs.isEmpty ? .empty : .loaded(jobs)
    }

    // MARK: - Mutations (operator.admin; gated on hasAdmin by the caller)

    /// Create a job via `cron.add`. Optimistic only via the post-success re-fetch (a created job's
    /// server-owned `id`/`state` are unknown client-side, so we can't insert a real row pre-response;
    /// instead we re-fetch on success). Returns nil on success or an error message to show inline.
    func createJob(appModel: NodeAppModel, request: CronRequestPayload) async -> String? {
        guard self.hasAdmin else { return Self.adminRequiredMessage }
        let params = CronAddParams(
            name: request.name,
            agentid: request.agentId.map { AnyCodable($0) },
            sessionkey: nil,
            description: nil,
            enabled: request.enabled,
            deleteafterrun: nil,
            schedule: request.schedule,
            sessiontarget: request.sessionTarget,
            wakemode: request.wakeMode,
            payload: request.payload,
            delivery: nil,
            failurealert: nil)
        do {
            _ = try await Self.request(appModel: appModel, method: "cron.add", params: params, timeoutSeconds: 20)
            self.actionStatusText = "Created \(request.name)."
            await self.load(appModel: appModel, force: true)
            return nil
        } catch {
            return Self.mutationMessage(error)
        }
    }

    /// Update a job via `cron.update`. Optimistic: we re-fetch on success (the patch result is the full
    /// updated job, but the simpler contract is to reconcile via the list re-fetch). Returns nil on
    /// success or an error message.
    func updateJob(
        appModel: NodeAppModel,
        jobId: String,
        request: CronRequestPayload) async -> String?
    {
        guard self.hasAdmin else { return Self.adminRequiredMessage }
        // Omit `schedule` / `wakeMode` from the patch unless the operator changed them: re-sending an
        // unchanged interval resets its phase (`anchorMs` backfill, `service/ops.ts:526-541`) and
        // re-sending `wakeMode` clobbers a `now` job (`applyJobPatch`, `service/jobs.ts:850`). `editChanges`
        // is always non-nil on the edit path (set by `CronFormValidator` whenever a seed exists).
        let changes = request.editChanges
        let patch = CronEditPatch(
            name: request.name,
            description: nil,
            enabled: request.enabled,
            agentId: request.agentId.map { AnyCodable($0) },
            schedule: (changes?.scheduleChanged ?? true) ? request.schedule : nil,
            sessionTarget: request.sessionTarget,
            wakeMode: (changes?.wakeModeChanged ?? true) ? request.wakeMode : nil,
            payload: request.payload)
        let params = CronEditUpdateParams(id: jobId, patch: patch)
        do {
            _ = try await Self.request(appModel: appModel, method: "cron.update", params: params, timeoutSeconds: 20)
            self.actionStatusText = "Updated \(request.name)."
            await self.load(appModel: appModel, force: true)
            return nil
        } catch {
            return Self.mutationMessage(error)
        }
    }

    /// Enable/disable a job via a `{enabled}` patch — the same path the Agent Pro pause/enable button
    /// uses. Optimistic: flip the row in place, re-fetch on success, ROLL BACK to the prior list on error.
    func setEnabled(appModel: NodeAppModel, job: CronJob, enabled: Bool) async {
        guard self.hasAdmin, !self.busyJobIDs.contains(job.id) else { return }
        let previous = self.jobs
        self.busyJobIDs.insert(job.id)
        self.actionStatusText = nil
        defer { self.busyJobIDs.remove(job.id) }

        self.applyOptimisticEnabled(jobId: job.id, enabled: enabled)
        let patch = CronEditPatch(enabled: enabled)
        let params = CronEditUpdateParams(id: job.id, patch: patch)
        do {
            _ = try await Self.request(appModel: appModel, method: "cron.update", params: params, timeoutSeconds: 20)
            self.actionStatusText = enabled ? "Enabled \(job.name)." : "Paused \(job.name)."
            await self.load(appModel: appModel, force: true)
        } catch {
            self.state = .loaded(previous)
            self.actionStatusText = Self.mutationMessage(error)
        }
    }

    /// Run a job now via `cron.run` (`mode: force`). Surfaces the `{ran:false, reason}` disposition.
    func runNow(appModel: NodeAppModel, job: CronJob) async {
        guard self.hasAdmin, !self.busyJobIDs.contains(job.id) else { return }
        self.busyJobIDs.insert(job.id)
        self.actionStatusText = nil
        defer { self.busyJobIDs.remove(job.id) }

        let params = CronRunParams(id: job.id, mode: "force")
        do {
            let data = try await Self.request(appModel: appModel, method: "cron.run", params: params, timeoutSeconds: 30)
            let disposition = CronManualRunResult.decode(from: data)
            self.actionStatusText = "\(job.name): \(disposition.statusText)"
            await self.load(appModel: appModel, force: true)
        } catch {
            self.actionStatusText = Self.mutationMessage(error)
        }
    }

    /// Delete a job via `cron.remove`. Optimistic: drop the row immediately, re-fetch on success, ROLL
    /// BACK to the prior list on error (the handler 400s when `removed == false`).
    func deleteJob(appModel: NodeAppModel, job: CronJob) async {
        guard self.hasAdmin, !self.busyJobIDs.contains(job.id) else { return }
        let previous = self.jobs
        self.busyJobIDs.insert(job.id)
        self.actionStatusText = nil
        defer { self.busyJobIDs.remove(job.id) }

        let remaining = previous.filter { $0.id != job.id }
        self.state = remaining.isEmpty ? .empty : .loaded(remaining)
        let params = CronRemoveParams(id: job.id)
        do {
            _ = try await Self.request(appModel: appModel, method: "cron.remove", params: params, timeoutSeconds: 20)
            self.actionStatusText = "Removed \(job.name)."
            await self.load(appModel: appModel, force: true)
        } catch {
            self.state = .loaded(previous)
            self.actionStatusText = Self.mutationMessage(error)
        }
    }

    /// Flip a single job's `enabled` in the loaded list without re-fetching, for the optimistic toggle.
    private func applyOptimisticEnabled(jobId: String, enabled: Bool) {
        guard case let .loaded(jobs) = self.state else { return }
        let updated = jobs.map { job -> CronJob in
            guard job.id == jobId else { return job }
            return CronJob(
                id: job.id,
                agentid: job.agentid,
                sessionkey: job.sessionkey,
                name: job.name,
                description: job.description,
                enabled: enabled,
                deleteafterrun: job.deleteafterrun,
                createdatms: job.createdatms,
                updatedatms: job.updatedatms,
                schedule: job.schedule,
                sessiontarget: job.sessiontarget,
                wakemode: job.wakemode,
                payload: job.payload,
                delivery: job.delivery,
                failurealert: job.failurealert,
                state: job.state)
        }
        self.state = .loaded(updated)
    }

    // MARK: - Params

    /// `cron.list` params: all jobs (`includeDisabled: true`) sorted by soonest next run, full page. Built
    /// through the shared `CronListParams` model so key casing (`includeDisabled`, `sortBy`, …) matches
    /// the strict TypeBox validator (`additionalProperties: false`). `compact: false` so we get full jobs.
    private static func listParamsJSON() -> String {
        let params = CronListParams(
            includedisabled: true,
            limit: Self.pageLimit,
            offset: nil,
            query: nil,
            enabled: AnyCodable("all"),
            schedulekind: nil,
            lastrunstatus: nil,
            sortby: AnyCodable("nextRunAtMs"),
            sortdir: AnyCodable("asc"),
            agentid: nil,
            compact: false)
        guard let data = try? JSONEncoder().encode(params),
              let json = String(data: data, encoding: .utf8)
        else {
            return "{\"includeDisabled\":true,\"limit\":\(Self.pageLimit),\"sortBy\":\"nextRunAtMs\",\"sortDir\":\"asc\"}"
        }
        return json
    }

    /// `cron.runs` params: newest-first across all jobs, for the per-job last-run map. Built through the
    /// shared `CronRunsParams` model (same path Briefs uses) so casing matches the strict validator.
    private static func runsParamsJSON() -> String {
        let params = CronRunsParams(
            scope: AnyCodable("all"),
            id: nil,
            jobid: nil,
            runid: nil,
            limit: Self.runsLimit,
            offset: nil,
            statuses: nil,
            status: nil,
            deliverystatuses: nil,
            deliverystatus: nil,
            query: nil,
            sortdir: AnyCodable("desc"))
        guard let data = try? JSONEncoder().encode(params),
              let json = String(data: data, encoding: .utf8)
        else {
            return "{\"scope\":\"all\",\"limit\":\(Self.runsLimit),\"sortDir\":\"desc\"}"
        }
        return json
    }

    // MARK: - Decode (lossy: never decode bare [AnyCodable])

    /// Lossy job decode: parse the `cron.list` page envelope's `jobs` array as opaque JSON values, then
    /// decode each element individually so one malformed job never blanks the whole list. Mirrors the
    /// Briefs `decodeRuns` contract — never `decode([AnyCodable].self)` on a typed model.
    private static func decodeJobs(from data: Data) -> [CronJob]? {
        struct Envelope: Decodable {
            let jobs: [AnyCodable]?
        }
        let decoder = JSONDecoder()
        guard let envelope = try? decoder.decode(Envelope.self, from: data) else { return nil }
        guard let rawJobs = envelope.jobs else { return [] }
        var jobs: [CronJob] = []
        jobs.reserveCapacity(rawJobs.count)
        for raw in rawJobs {
            guard let jobData = try? JSONEncoder().encode(raw),
                  let job = try? decoder.decode(CronJob.self, from: jobData)
            else {
                continue
            }
            jobs.append(job)
        }
        return jobs
    }

    /// Build the jobId -> latest run map from a `cron.runs` page, reusing the Briefs lossy decode + the
    /// `BriefRun` flattening. Runs arrive newest-first (`sortDir: desc`); we keep the first run seen per
    /// job, which is therefore the most recent.
    private static func decodeLastRuns(from data: Data) -> [String: BriefRun] {
        struct Envelope: Decodable {
            let entries: [AnyCodable]?
        }
        let decoder = JSONDecoder()
        guard let envelope = try? decoder.decode(Envelope.self, from: data),
              let rawEntries = envelope.entries
        else {
            return [:]
        }
        var map: [String: BriefRun] = [:]
        for raw in rawEntries {
            guard let entryData = try? JSONEncoder().encode(raw),
                  let entry = try? decoder.decode(CronRunLogEntry.self, from: entryData),
                  let run = BriefRun(entry: entry)
            else {
                continue
            }
            // First seen per job == most recent (newest-first page). Don't overwrite with older runs.
            if map[run.jobId] == nil { map[run.jobId] = run }
        }
        return map
    }

    // MARK: - Request helpers

    private static func requestData(
        appModel: NodeAppModel,
        method: String,
        paramsJSON: String) async -> Data?
    {
        do {
            return try await appModel.operatorSession.request(
                method: method,
                paramsJSON: paramsJSON,
                timeoutSeconds: 12)
        } catch {
            return nil
        }
    }

    /// Encode a typed param model and call the gateway. Mirrors `AgentProTab.requestGateway` (encode ->
    /// JSON string -> `operatorSession.request`). Throws on encode failure or gateway error so the caller
    /// maps the error via `mutationMessage`.
    private static func request(
        appModel: NodeAppModel,
        method: String,
        params: some Encodable,
        timeoutSeconds: Int) async throws -> Data
    {
        let data = try JSONEncoder().encode(params)
        guard let json = String(data: data, encoding: .utf8) else {
            throw CronMutationError.encodeFailed
        }
        return try await appModel.operatorSession.request(
            method: method,
            paramsJSON: json,
            timeoutSeconds: timeoutSeconds)
    }

    // MARK: - Connection gate (copied verbatim from CostInsightsViewModel)

    private func connected(appModel: NodeAppModel) -> Bool {
        guard !appModel.isLocalGatewayFixtureEnabled else { return false }
        guard appModel.isOperatorGatewayConnected else { return false }
        return GatewayStatusBuilder.build(appModel: appModel) == .connected
    }

    // MARK: - Error mapping

    static let adminRequiredMessage =
        "This gateway connection cannot edit jobs yet. Reconnect with admin scope."

    /// Map a gateway error to operator-facing copy, reusing the exact admin-scope message the shipped
    /// skill-mutation path uses (`AgentProTab.skillMutationMessage`). Kept local so the Crons surface does
    /// not depend on `AgentProTab`.
    static func mutationMessage(_ error: Error) -> String {
        if let gatewayError = error as? GatewayResponseError {
            let lower = gatewayError.message.lowercased()
            if lower.contains("operator.admin") || lower.contains("unauthorized") {
                return Self.adminRequiredMessage
            }
            return gatewayError.message
        }
        return error.localizedDescription
    }
}

/// Closed encode-failure error for the request helper (mirrors `SkillMutationError`).
enum CronMutationError: LocalizedError {
    case encodeFailed

    var errorDescription: String? {
        switch self {
        case .encodeFailed: "Could not encode the cron request."
        }
    }
}
