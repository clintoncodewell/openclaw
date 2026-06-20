import Foundation
import OpenClawKit
import OpenClawProtocol
import SwiftUI

/// Closed load state for the Briefs inbox so the view never juggles parallel nullable flags.
enum BriefsLoadState: Equatable {
    case idle
    case loading
    case loaded([BriefRun])
    case empty
    case offline
    case error(String)
}

@MainActor
@Observable
final class BriefsInboxViewModel {
    private(set) var state: BriefsLoadState = .idle
    var searchText: String = ""
    var statusFilter: BriefStatusFilter = .all
    var jobFilter: String? // jobId; nil == all jobs

    /// How many aggregated run-log entries to pull in one page. cron.runs clamps to 1...200.
    private static let pageLimit = 120

    private var lastSearchToken = UUID()

    /// The full set of jobs seen on the most recent unfiltered page, in id->name form. Captured
    /// only when `jobFilter == nil` so a job-filtered page (which returns just one job's entries)
    /// never collapses the chip row to the single selected job and traps the user on it.
    private var knownJobs: [(id: String, name: String)] = []

    /// All distinct jobs available for the filter chips. Derived from the last unfiltered page
    /// (`knownJobs`) so every job chip stays visible even while a single job is selected. Hidden
    /// unless we have content on screen, matching the rest of the filter row.
    var availableJobs: [(id: String, name: String)] {
        guard case .loaded = self.state else { return [] }
        return self.knownJobs
    }

    /// Sections after applying the local job/status/text narrowing on top of the loaded page.
    /// Status + text are also pushed to the gateway on reload; this keeps the UI responsive
    /// between a filter tap and the refreshed page arriving.
    var sections: [BriefsDateSection] {
        guard case let .loaded(runs) = self.state else { return [] }
        let needle = self.searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let filtered = runs.filter { run in
            if let jobFilter = self.jobFilter, run.jobId != jobFilter { return false }
            if !self.statusFilter.matches(run) { return false }
            if !needle.isEmpty, !run.searchHaystack.contains(needle) { return false }
            return true
        }
        return BriefsDateSection.sections(from: filtered)
    }

    func load(appModel: NodeAppModel, force: Bool) async {
        guard self.connected(appModel: appModel) else {
            self.state = .offline
            return
        }
        if case .loading = self.state, !force { return }
        // Preserve already-loaded content while we refetch in the background so the list never
        // blanks to a spinner — this covers both pull-to-refresh (force) and the scenePhase
        // foreground refresh (force == false), which is the common path.
        if case .loaded = self.state {} else {
            self.state = .loading
        }

        let params = self.makeParams()
        do {
            let data = try await appModel.operatorSession.request(
                method: "cron.runs",
                paramsJSON: params,
                timeoutSeconds: 12)
            let runs = Self.decodeRuns(from: data)
            // Refresh the job-chip catalog only from an unfiltered page; a job-filtered page is a
            // subset and would otherwise shrink the chip row to the single selected job.
            if self.jobFilter == nil {
                self.knownJobs = Self.distinctJobs(from: runs)
            }
            self.state = runs.isEmpty ? .empty : .loaded(runs)
        } catch {
            // Keep prior runs visible on a transient refresh failure; only surface an error
            // when we have nothing to show.
            if case .loaded = self.state {
                return
            }
            self.state = .error(Self.errorText(error))
        }
    }

    /// Debounced reload driven by the search field: server-side `query` does the real filtering.
    func searchChanged(appModel: NodeAppModel) {
        let token = UUID()
        self.lastSearchToken = token
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard let self, self.lastSearchToken == token else { return }
            await self.load(appModel: appModel, force: true)
        }
    }

    private func makeParams() -> String {
        let trimmedQuery = self.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let params = CronRunsParams(
            scope: AnyCodable("all"),
            id: nil,
            jobid: self.jobFilter,
            runid: nil,
            limit: Self.pageLimit,
            offset: nil,
            statuses: self.statusFilter.gatewayStatuses?.map { AnyCodable($0) },
            status: nil,
            deliverystatuses: nil,
            deliverystatus: nil,
            query: trimmedQuery.isEmpty ? nil : trimmedQuery,
            sortdir: AnyCodable("desc"))
        guard let data = try? JSONEncoder().encode(params),
              let json = String(data: data, encoding: .utf8)
        else {
            return "{\"scope\":\"all\",\"limit\":\(Self.pageLimit),\"sortDir\":\"desc\"}"
        }
        return json
    }

    /// Lossy entry decode: parse the envelope's `entries` as opaque JSON values, then decode each
    /// element individually so one malformed run-log entry never blanks the whole inbox. Mirrors
    /// the macOS `LossyCronRunsResponse` contract.
    private static func decodeRuns(from data: Data) -> [BriefRun] {
        struct Envelope: Decodable {
            let entries: [AnyCodable]?
        }
        let decoder = JSONDecoder()
        guard let envelope = try? decoder.decode(Envelope.self, from: data),
              let rawEntries = envelope.entries
        else {
            return []
        }
        var runs: [BriefRun] = []
        runs.reserveCapacity(rawEntries.count)
        for raw in rawEntries {
            guard let entryData = try? JSONEncoder().encode(raw),
                  let entry = try? decoder.decode(CronRunLogEntry.self, from: entryData),
                  let run = BriefRun(entry: entry)
            else {
                continue
            }
            runs.append(run)
        }
        return runs
    }

    /// Distinct jobs in load order, sorted by display name, for the filter chip row.
    private static func distinctJobs(from runs: [BriefRun]) -> [(id: String, name: String)] {
        var seen = Set<String>()
        var jobs: [(id: String, name: String)] = []
        for run in runs where !seen.contains(run.jobId) {
            seen.insert(run.jobId)
            jobs.append((id: run.jobId, name: run.jobName))
        }
        return jobs.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func connected(appModel: NodeAppModel) -> Bool {
        guard !appModel.isLocalGatewayFixtureEnabled else { return false }
        guard appModel.isOperatorGatewayConnected else { return false }
        return GatewayStatusBuilder.build(appModel: appModel) == .connected
    }

    private static func errorText(_ error: Error) -> String {
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Could not load briefs." : trimmed
    }
}
