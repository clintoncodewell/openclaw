import Foundation
import OpenClawKit

/// Formatting helpers for the Run Explorer: durations, relative time, and a pretty-printed JSON renderer
/// for span args/results that redacts secret-looking keys. The secret-key list mirrors
/// `ToolArgumentsFormatter.isSensitiveKey` (`ChatMessageViews.swift:737`), which is `private` to
/// `OpenClawChatUI`; we re-list it here for the full-JSON span detail (that formatter only emits a
/// collapsed single line, so it can't be reused for the expanded view anyway).
enum TraceFormatting {
    // Keys whose values are likely secrets — rendered as "***" in expanded span JSON.
    private static let sensitiveKeyFragments = [
        "token", "secret", "password", "passwd", "apikey", "api_key", "authorization", "bearer", "credential",
    ]

    private static func isSensitiveKey(_ key: String) -> Bool {
        let lowered = key.lowercased()
        return self.sensitiveKeyFragments.contains { lowered.contains($0) }
    }

    /// Compact duration label: "820ms", "1.2s", "3m 04s". Used for both wall-clock deltas (labeled as
    /// such at the call site) and the model-latency rollup.
    static func duration(ms: Double) -> String {
        guard ms.isFinite, ms >= 0 else { return "—" }
        if ms < 1000 {
            return "\(Int(ms.rounded()))ms"
        }
        let seconds = ms / 1000
        if seconds < 60 {
            return String(format: "%.1fs", seconds)
        }
        let minutes = Int(seconds) / 60
        let remainder = Int(seconds) % 60
        return String(format: "%dm %02ds", minutes, remainder)
    }

    /// Relative-time caption ("2h ago") from epoch milliseconds.
    static func relativeTime(forMilliseconds milliseconds: Double) -> String {
        let date = Date(timeIntervalSince1970: milliseconds / 1000)
        let formatter = RelativeDateTimeFormatter()
        formatter.dateTimeStyle = .numeric
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: .now)
    }

    /// Absolute wall-clock time ("3:14:09 PM") from epoch milliseconds, for the timeline rail.
    static func clockTime(forMilliseconds milliseconds: Double) -> String {
        let date = Date(timeIntervalSince1970: milliseconds / 1000)
        return date.formatted(date: .omitted, time: .standard)
    }

    /// Pretty-printed JSON for an `AnyCodable` payload (tool args or structured result), with
    /// secret-looking keys redacted to "***". Returns nil when the payload is empty/absent. The redaction
    /// walks the value tree first, then hands a sanitized object to `JSONSerialization` so no secret ever
    /// reaches the rendered string.
    static func prettyJSON(_ value: AnyCodable?) -> String? {
        guard let raw = value?.value else { return nil }
        let sanitized = self.redact(raw)
        // Scalars don't round-trip through `JSONSerialization` (which needs a top-level array/object);
        // render them directly so a bare string/number result still shows something.
        guard JSONSerialization.isValidJSONObject(sanitized) else {
            return self.scalarString(sanitized)
        }
        guard let data = try? JSONSerialization.data(
            withJSONObject: sanitized,
            options: [.prettyPrinted, .sortedKeys]),
            let json = String(data: data, encoding: .utf8)
        else {
            return nil
        }
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "{}", trimmed != "[]" else { return nil }
        return trimmed
    }

    /// Recursively replace sensitive values with "***" and unwrap `AnyCodable` so the result is a plain
    /// Foundation tree `JSONSerialization` accepts.
    private static func redact(_ value: Any) -> Any {
        switch value {
        case let wrapped as AnyCodable:
            return self.redact(wrapped.value)
        case let dict as [String: AnyCodable]:
            var out: [String: Any] = [:]
            for (key, val) in dict {
                out[key] = self.isSensitiveKey(key) ? "***" : self.redact(val.value)
            }
            return out
        case let dict as [String: Any]:
            var out: [String: Any] = [:]
            for (key, val) in dict {
                out[key] = self.isSensitiveKey(key) ? "***" : self.redact(val)
            }
            return out
        case let array as [AnyCodable]:
            return array.map { self.redact($0.value) }
        case let array as [Any]:
            return array.map { self.redact($0) }
        default:
            return value
        }
    }

    private static func scalarString(_ value: Any) -> String? {
        switch value {
        case let string as String:
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case let bool as Bool:
            return bool ? "true" : "false"
        case let int as Int:
            return String(int)
        case let double as Double:
            return String(double)
        case is NSNull:
            return nil
        default:
            let described = String(describing: value).trimmingCharacters(in: .whitespacesAndNewlines)
            return described.isEmpty ? nil : described
        }
    }
}
