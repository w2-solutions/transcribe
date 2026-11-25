import Foundation

/// A tool call Claude made wrongly: returned as a result with `isError: true` so Claude can correct it.
public struct ToolError: Error, Sendable, Equatable {
    public let text: String
    public init(_ text: String) { self.text = text }

    static let badDate = ToolError("from_date and to_date must be YYYY-MM-DD or ISO 8601.")
    static let badListCursor = ToolError("That cursor isn't valid. Call list_recordings without a cursor to start again.")
    static let badRecordingID = ToolError("recording_id must be an id from list_recordings.")
    static let endBeforeStart = ToolError("end_seconds must be after start_seconds.")
    static let badTranscriptCursor = ToolError("That cursor isn't valid. Call get_transcript without a cursor to start again.")
    static let transcriptChanged = ToolError("The transcript changed since that part was read. Call get_transcript without a cursor to start again.")
    static func notFound(_ id: UUID) -> ToolError {
        ToolError("No finished recording has id \(id.uuidString). It may have been deleted or still be processing; use list_recordings.")
    }
}

/// list_recordings arguments. Unknown keys, and known keys of the wrong type, are ignored.
struct ListArguments: Equatable {
    static let defaultLimit = 20
    static let limits = 1...50

    var terms: [String] = []
    var speaker: String?
    var from: Date?          // inclusive
    var to: Date?            // exclusive: a bare to_date means "before the next local day"
    var offset = 0
    var limit = ListArguments.defaultLimit

    init(_ a: JSONValue?, timeZone: TimeZone) throws(ToolError) {
        if let query = a?["query"]?.string {
            terms = query.lowercased().split(whereSeparator: { $0.isWhitespace || $0.isNewline }).map(String.init)
        }
        if let speaker = a?["speaker"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !speaker.isEmpty {
            self.speaker = speaker
        }
        if let raw = a?["from_date"]?.string {
            guard let date = DateArgument.parse(raw, timeZone: timeZone, endOfRange: false) else { throw .badDate }
            from = date
        }
        if let raw = a?["to_date"]?.string {
            guard let date = DateArgument.parse(raw, timeZone: timeZone, endOfRange: true) else { throw .badDate }
            to = date
        }
        if let n = a?["limit"]?.int { limit = Int(min(max(n, Int64(Self.limits.lowerBound)), Int64(Self.limits.upperBound))) }
        if let cursor = a?["cursor"] {
            guard let token = cursor.string, let offset = Self.offset(token) else { throw .badListCursor }
            self.offset = offset
        }
    }

    var query: MCPRecordingQuery {
        MCPRecordingQuery(terms: terms, speaker: speaker, from: from, to: to, offset: offset, limit: limit)
    }

    static func cursor(offset: Int) -> String { "o\(offset)" }

    /// "o20" → 20: `o` then 1–6 digits.
    static func offset(_ token: String) -> Int? {
        guard token.first == "o" else { return nil }
        let digits = token.dropFirst()
        guard (1...6).contains(digits.count), digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return Int(digits)
    }
}

/// get_transcript arguments. Unknown keys are ignored; with a cursor, start_seconds and end_seconds are ignored.
struct TranscriptArguments: Equatable {
    var id: UUID
    var start: Double?
    var end: Double?
    var cursor: TranscriptCursor?

    init(_ a: JSONValue?) throws(ToolError) {
        guard let raw = a?["recording_id"]?.string,
              let id = UUID(uuidString: raw.trimmingCharacters(in: .whitespacesAndNewlines)) else { throw .badRecordingID }
        self.id = id
        if let c = a?["cursor"] {
            guard let token = c.string, let cursor = TranscriptCursor(token: token) else { throw .badTranscriptCursor }
            self.cursor = cursor
            return
        }
        start = a?["start_seconds"]?.double.map { max(0, $0) }
        end = a?["end_seconds"]?.double.map { max(0, $0) }
        if let end, end <= (start ?? 0) { throw .endBeforeStart }
    }

    /// The end of the range, from `end_seconds` or the cursor.
    var rangeEnd: Double? { cursor.map { $0.endMs.map { Double($0) / 1000 } } ?? end }
}

/// Dates for from_date / to_date, read in the user's time zone.
enum DateArgument {
    /// A bare date is the start of that local day (`endOfRange`: the start of the next day, so the whole day is in).
    /// A date-time is taken as given (`endOfRange`: one second later, so that second is in). nil when unreadable.
    static func parse(_ raw: String, timeZone: TimeZone, endOfRange: Bool) -> Date? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        if let day = bareDate(s, calendar: calendar) {
            return endOfRange ? calendar.date(byAdding: .day, value: 1, to: day) : day
        }
        guard let moment = dateTime(s, timeZone: timeZone) else { return nil }
        return endOfRange ? moment.addingTimeInterval(1) : moment
    }

    private static func bareDate(_ s: String, calendar: Calendar) -> Date? {
        let parts = s.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              parts.allSatisfy({ $0.allSatisfy { $0.isASCII && $0.isNumber } }),
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]),
              let date = calendar.date(from: DateComponents(year: y, month: m, day: d)) else { return nil }
        // Reject 2026-02-31 and the like, which the calendar would roll over.
        let back = calendar.dateComponents([.year, .month, .day], from: date)
        return back.year == y && back.month == m && back.day == d ? date : nil
    }

    private static func dateTime(_ s: String, timeZone: TimeZone) -> Date? {
        for options: ISO8601DateFormatter.Options in [[.withInternetDateTime], [.withInternetDateTime, .withFractionalSeconds]] {
            let f = ISO8601DateFormatter()
            f.formatOptions = options
            if let d = f.date(from: s) { return d }
        }
        // No offset: local time in the user's time zone.
        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd'T'HH:mm:ss.SSS"] {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.calendar = Calendar(identifier: .gregorian)
            f.timeZone = timeZone
            f.isLenient = false
            f.dateFormat = format
            if let d = f.date(from: s) { return d }
        }
        return nil
    }
}
