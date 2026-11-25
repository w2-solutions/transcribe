import Foundation
import TranscribeCore

/// One page of a get_transcript result (§3.4, D14): a header that every page repeats (title, speakers and how each
/// name was decided), then whole turns as "[start–end] Speaker: text" lines up to `lineBudget` characters. A turn too
/// long for a page on its own is split on word boundaries. Lengths are counted in UTF-16 units, which is never less
/// than the character count, so a page stays at or under `lineBudget + headerBudget` characters.
public enum TranscriptPager {
    public static let lineBudget = 32_000
    /// Everything that is not a transcript line: the header, the "Turns" line and the closing line.
    public static let headerBudget = 2_500
    /// Room kept inside `headerBudget` for the "Turns" line, the closing line and the blank lines between.
    static let footerReserve = 320
    static let titleLimit = 200

    static func page(_ t: MCPTranscript, args: TranscriptArguments, timeZone: TimeZone) throws(ToolError) -> String {
        let turns = t.document.turns
        let n = turns.count
        let speakers = Dictionary(t.summary.speakers.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        let longForm = max(t.summary.duration, turns.map(\.range.end).max() ?? 0) >= 3600
        let rangeEnd = args.rangeEnd

        var turnIndex = 0, wordIndex = 0
        if let c = args.cursor {
            guard c.turnCount == n else { throw .transcriptChanged }
            guard c.turn < n, c.word == 0 || c.word < turns[c.turn].words.count else { throw .badTranscriptCursor }
            turnIndex = c.turn; wordIndex = c.word
        }
        let start = args.cursor == nil ? args.start : nil
        func included(_ turn: Turn) -> Bool {
            if let start, turn.range.end <= start { return false }
            if let rangeEnd, turn.range.start >= rangeEnd { return false }
            return !turn.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        var lines: [String] = []
        var used = 0
        var firstLine: (turn: Int, time: Double)?
        var lastLine: (turn: Int, time: Double)?
        var next: (turn: Int, word: Int)?
        func add(_ line: Line, turn: Int) {
            lines.append(line.text)
            used += line.text.utf16.count + 1
            if firstLine == nil { firstLine = (turn, line.start) }
            lastLine = (turn, line.end)
        }

        while turnIndex < n {
            let turn = turns[turnIndex]
            guard included(turn) else { turnIndex += 1; wordIndex = 0; continue }
            let whole = Line(turn, from: wordIndex, to: turn.words.count, speakers: speakers, longForm: longForm)
            if used + whole.text.utf16.count + 1 <= lineBudget {
                add(whole, turn: turnIndex)
                turnIndex += 1; wordIndex = 0
                continue
            }
            if lines.isEmpty {
                // A single turn longer than a page: as many words as fit, then continue in this turn.
                let cut = fit(turn, from: wordIndex, speakers: speakers, longForm: longForm)
                add(Line(turn, from: wordIndex, to: cut, speakers: speakers, longForm: longForm), turn: turnIndex)
                if cut < turn.words.count {
                    next = (turnIndex, cut)
                } else if let later = turns.indices.dropFirst(turnIndex + 1).first(where: { included(turns[$0]) }) {
                    next = (later, 0)
                }
            } else {
                next = (turnIndex, wordIndex)
            }
            break
        }

        var out = header(t, speakers: t.summary.speakers, timeZone: timeZone)
        out.append("")
        if let firstLine, let lastLine {
            let span = "\(MCPTime.stamp(firstLine.time, longForm: longForm))–\(MCPTime.stamp(lastLine.time, longForm: longForm))"
            let numbers = firstLine.turn == lastLine.turn ? "Turn \(firstLine.turn + 1)" : "Turns \(firstLine.turn + 1)–\(lastLine.turn + 1)"
            out.append("\(numbers) of \(n) (\(span) of \(MCPTime.length(t.summary.duration))).")
            out.append("")
            out.append(contentsOf: lines)
        } else {
            out.append(rangeEnd != nil || start != nil ? "No turns in the requested range." : "This recording has no transcript text.")
        }
        out.append("")
        if let next {
            let endMs = rangeEnd.map { Int(min(($0 * 1000).rounded(), 999_999_999)) }
            let token = TranscriptCursor(turn: next.turn, word: next.word, turnCount: n, endMs: endMs).token
            out.append("next_cursor: \(token) (call get_transcript with this cursor and the same recording_id for the next part)")
        } else {
            out.append(rangeEnd != nil ? "End of the requested range." : "End of transcript.")
        }
        return out.joined(separator: "\n")
    }

    // MARK: Header

    /// Title, id, recorded line and the speakers, cut so the whole page outside the lines fits `headerBudget`.
    static func header(_ t: MCPTranscript, speakers: [MCPSpeaker], timeZone: TimeZone) -> [String] {
        var title = TranscriptText.oneLine(t.summary.title)
        if title.count > titleLimit { title = String(title.prefix(titleLimit)) + "…" }
        var head = [title, "id: \(t.summary.id.uuidString)",
                    "recorded: " + RecordingListFormatter.recordedFields(t.summary, timeZone: timeZone, folder: false)
                        .joined(separator: " · ")]
        let autoNote = speakers.contains { $0.status == .autoLabelled }
            ? "Names marked (auto) were recognised automatically and can be wrong." : nil
        guard !speakers.isEmpty else {
            head.append("speakers: none identified")
            return head
        }
        head.append("speakers:")
        let sorted = speakers.sorted { $0.ordinal < $1.ordinal }
        var used = head.reduce(0) { $0 + $1.utf16.count + 1 } + (autoNote.map { $0.utf16.count + 1 } ?? 0)
        let limit = headerBudget - footerReserve
        for (i, s) in sorted.enumerated() {
            let line = SpeakerLabelText.headerLine(s)
            let remaining = sorted.count - i - 1
            let moreRoom = remaining > 0 ? 32 : 0   // "- …and N more"
            guard used + line.utf16.count + 1 + moreRoom <= limit else {
                head.append("- …and \(sorted.count - i) more")
                break
            }
            head.append(line)
            used += line.utf16.count + 1
        }
        if let autoNote { head.append(autoNote) }
        return head
    }

    // MARK: Lines

    /// One transcript line: a whole turn, or the words `from..<to` of it.
    struct Line {
        var text: String
        var start: Double
        var end: Double

        init(_ turn: Turn, from: Int, to: Int, speakers: [SpeakerKey: MCPSpeaker], longForm: Bool) {
            let whole = from == 0 && to >= turn.words.count
            let body = whole ? turn.text : turn.words[from..<to].map(\.text).joined(separator: " ")
            if whole || to <= from {
                start = turn.range.start; end = turn.range.end
            } else {
                start = turn.words[from].range.start; end = turn.words[to - 1].range.end
            }
            text = "[\(MCPTime.stamp(start, longForm: longForm))–\(MCPTime.stamp(end, longForm: longForm))] "
                + TranscriptPager.label(turn, continued: from > 0, speakers: speakers) + TranscriptText.oneLine(body)
        }
    }

    /// "Liam: ", "Karan (auto) (overlapping speech): ", "Liam (continued): "; "" or "(continued) " with no speaker.
    static func label(_ turn: Turn, continued: Bool, speakers: [SpeakerKey: MCPSpeaker]) -> String {
        guard var name = TranscriptText.speakerName(turn, speakers) else { return continued ? "(continued) " : "" }
        if turn.hasOverlap { name += " (overlapping speech)" }
        if continued { name += " (continued)" }
        return name + ": "
    }

    /// The end index of the words from `from` that fit on an empty page; always at least one word.
    static func fit(_ turn: Turn, from: Int, speakers: [SpeakerKey: MCPSpeaker], longForm: Bool) -> Int {
        // The widest prefix this part could have: the latest time in the turn, on both sides.
        let latest = max(turn.range.end, turn.words.last?.range.end ?? 0)
        let stamp = MCPTime.stamp(latest, longForm: longForm)
        var length = "[\(stamp)–\(stamp)] ".utf16.count + label(turn, continued: from > 0, speakers: speakers).utf16.count + 1
        var end = from
        while end < turn.words.count {
            let word = turn.words[end].text.utf16.count + (end > from ? 1 : 0)
            guard length + word <= lineBudget else { break }
            length += word
            end += 1
        }
        return max(end, min(from + 1, turn.words.count))
    }
}
