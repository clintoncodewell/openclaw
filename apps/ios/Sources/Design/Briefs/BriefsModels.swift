import Foundation
import OpenClawProtocol
import SwiftUI

/// UI-ready flattening of a single `cron.runs` entry. The gateway returns `CronRunLogEntry`
/// with several loosely-typed (`AnyCodable`) fields; we normalize them once here so the views
/// never re-derive status strings, durations, or model labels per render.
struct BriefRun: Identifiable, Hashable {
    let id: String
    let jobId: String
    let jobName: String
    let date: Date
    let statusLabel: String
    let statusKind: BriefStatusKind
    let summary: String
    let summaryPreview: String
    let error: String?
    let durationLabel: String?
    let modelLabel: String?
    let provider: String?
    let runId: String?

    init?(entry: CronRunLogEntry) {
        // ts is a stable wall-clock ms key; pair with jobId for a collision-free identity
        // (a single job can finish only once per ms).
        self.id = "\(entry.jobid)-\(entry.ts)"
        self.jobId = entry.jobid
        self.jobName = Self.normalized(entry.jobname) ?? entry.jobid
        self.date = Date(timeIntervalSince1970: Double(entry.ts) / 1000)

        let statusString = Self.stringValue(entry.status)
        let hasError = (Self.normalized(entry.error) != nil)
        self.statusKind = BriefStatusKind(statusString: statusString, hasError: hasError)
        self.statusLabel = statusString ?? (hasError ? "error" : "ok")

        let summaryText = Self.normalized(entry.summary) ?? ""
        self.summary = summaryText
        self.summaryPreview = Self.previewLine(from: summaryText)
        self.error = Self.normalized(entry.error)

        if let ms = entry.durationms {
            self.durationLabel = Self.duration(milliseconds: ms)
        } else {
            self.durationLabel = nil
        }
        self.modelLabel = Self.normalized(entry.model).map(Self.shortModelLabel)
        self.provider = Self.normalized(entry.provider)
        self.runId = Self.normalized(entry.runid)
    }

    /// Free-text haystack for the (optional) client-side fallback filter. Server-side `query`
    /// is preferred; this only backs instant local narrowing while a reload is in flight.
    var searchHaystack: String {
        [self.jobName, self.summary, self.error ?? "", self.jobId]
            .joined(separator: " ")
            .lowercased()
    }

    private static func normalized(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func stringValue(_ value: AnyCodable?) -> String? {
        guard let string = value?.value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// First non-empty line of the summary, stripped of leading markdown heading/list/quote
    /// markers so the inbox row reads as prose rather than raw `#`/`-`/`>` syntax.
    private static func previewLine(from summary: String) -> String {
        for rawLine in summary.split(whereSeparator: \.isNewline) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            while let first = line.first, "#>-*•".contains(first) {
                line.removeFirst()
                line = line.trimmingCharacters(in: .whitespaces)
            }
            if !line.isEmpty { return line }
        }
        return summary.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // Mirrors AgentProTab.shortModelLabel / .duration so footers match the rest of Agent Pro.
    private static func shortModelLabel(_ model: String) -> String {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "default" }
        let leaf = trimmed.split(separator: "/").last.map(String.init) ?? trimmed
        return leaf
            .replacingOccurrences(of: "claude-", with: "")
            .replacingOccurrences(of: "gpt-", with: "")
    }

    private static func duration(milliseconds: Int) -> String {
        let seconds = max(0, milliseconds / 1000)
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h" }
        return "\(hours / 24)d"
    }
}

/// Closed status outcome so views map to colors without restringly inspecting raw status text.
enum BriefStatusKind: Hashable {
    case ok
    case error
    case unknown

    init(statusString: String?, hasError: Bool) {
        let lowered = statusString?.lowercased()
        if lowered == "ok" || lowered == "success" || lowered == "succeeded" {
            self = .ok
        } else if hasError || lowered == "error" || lowered == "failed" || lowered == "failure" {
            self = .error
        } else {
            self = .unknown
        }
    }

    var color: Color {
        switch self {
        case .ok: OpenClawBrand.ok
        case .error: OpenClawBrand.danger
        case .unknown: .secondary
        }
    }

    var icon: String {
        switch self {
        case .ok: "checkmark.seal.fill"
        case .error: "exclamationmark.triangle.fill"
        case .unknown: "clock.fill"
        }
    }
}

/// Status filter chip selection for the inbox toolbar.
enum BriefStatusFilter: String, CaseIterable, Identifiable {
    case all
    case ok
    case error

    var id: String { self.rawValue }

    var label: String {
        switch self {
        case .all: "All"
        case .ok: "Done"
        case .error: "Failed"
        }
    }

    /// Gateway `statuses` array for this filter, or nil when no server-side narrowing applies.
    var gatewayStatuses: [String]? {
        switch self {
        case .all: nil
        case .ok: ["ok", "success", "succeeded"]
        case .error: ["error", "failed", "failure"]
        }
    }

    func matches(_ run: BriefRun) -> Bool {
        switch self {
        case .all: true
        case .ok: run.statusKind == .ok
        case .error: run.statusKind == .error
        }
    }
}

/// A dated bucket of runs ("Today" / "Yesterday" / explicit date), newest bucket first.
struct BriefsDateSection: Identifiable {
    let id: Date
    let title: String
    let runs: [BriefRun]

    /// Group runs by calendar day (descending), runs within a day already arrive newest-first
    /// from the gateway (`sortDir: desc`) but we re-sort defensively after the merge.
    static func sections(from runs: [BriefRun], calendar: Calendar = .current) -> [BriefsDateSection] {
        let grouped = Dictionary(grouping: runs) { calendar.startOfDay(for: $0.date) }
        return grouped
            .map { day, dayRuns in
                BriefsDateSection(
                    id: day,
                    title: Self.title(for: day, calendar: calendar),
                    runs: dayRuns.sorted { $0.date > $1.date })
            }
            .sorted { $0.id > $1.id }
    }

    private static func title(for day: Date, calendar: Calendar) -> String {
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        let now = Date()
        // Drop the year for same-year dates to keep headers compact.
        if calendar.component(.year, from: day) == calendar.component(.year, from: now) {
            return day.formatted(.dateTime.weekday(.abbreviated).month().day())
        }
        return day.formatted(.dateTime.month().day().year())
    }
}
