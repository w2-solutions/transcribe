import Foundation

/// The text of a list_recordings result (§3.4).
enum RecordingListFormatter {
    static let empty = "No finished recordings match."

    static func text(_ page: MCPRecordingPage, args: ListArguments, timeZone: TimeZone) -> String {
        guard page.total > 0 else { return empty }
        guard !page.items.isEmpty else {
            return "No recordings at this cursor; \(page.total) match in all. Call list_recordings without a cursor to start again."
        }
        let first = args.offset + 1, last = args.offset + page.items.count
        let noun = page.total == 1 ? "recording" : "recordings"
        let shown = first == last ? "\(first) shown" : "\(first)–\(last) shown"
        var lines = ["\(page.total) \(noun) (\(shown)). Times are in the user's time zone."]
        for (i, r) in page.items.enumerated() {
            lines.append("")
            lines.append("\(first + i). \(TranscriptText.oneLine(r.title))")
            lines.append("   id: \(r.id.uuidString)")
            lines.append("   recorded: " + recordedFields(r, timeZone: timeZone, folder: true).joined(separator: " · "))
            if !r.speakers.isEmpty {
                lines.append("   speakers: " + r.speakers.map(SpeakerLabelText.bracket).joined(separator: " · "))
            }
            if !args.terms.isEmpty, let s = r.snippet {
                let who = s.speaker.map { "\($0): " } ?? ""
                lines.append("   match: [\(MCPTime.stamp(s.start, longForm: r.duration >= 3600))] \(who)\"\(s.text)\"")
            }
        }
        if last < page.total {
            lines.append("")
            lines.append("next_cursor: \(ListArguments.cursor(offset: last)) (call list_recordings again with this cursor)")
        }
        return lines.joined(separator: "\n")
    }

    /// "2026-11-18T14:31:00+11:00", "length 12:48", "on Mac", "folder: Work", "language: en"; missing ones left out.
    static func recordedFields(_ r: MCPRecordingSummary, timeZone: TimeZone, folder: Bool) -> [String] {
        var fields = [MCPTime.iso(r.createdAt, timeZone: timeZone), "length \(MCPTime.length(r.duration))"]
        if let device = r.device { fields.append("on \(device)") }
        if folder, let name = r.folder { fields.append("folder: \(TranscriptText.oneLine(name))") }
        if let language = r.language { fields.append("language: \(language)") }
        return fields
    }
}
