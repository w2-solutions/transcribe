import Foundation
import TranscribeCore

/// The `match:` line of list_recordings: the first turn that contains the first search term, about 160 characters
/// around the hit, with ellipses where it was cut.
public enum Snippet {
    static let width = 160

    /// nil when no turn contains the term (the match was in the title or a speaker name).
    public static func first(in doc: TranscriptDocument, terms: [String], speakers: [SpeakerKey: MCPSpeaker]) -> MCPSnippet? {
        guard let term = terms.first, !term.isEmpty else { return nil }
        for turn in doc.turns {
            let text = TranscriptText.oneLine(turn.text)
            guard text.lowercased().contains(term) else { continue }
            return MCPSnippet(start: turn.range.start, speaker: TranscriptText.speakerName(turn, speakers),
                              text: window(text, around: term))
        }
        return nil
    }

    /// `width` characters centred on the first hit, trimmed to whole words.
    static func window(_ text: String, around term: String) -> String {
        guard text.count > width else { return text }
        let chars = Array(text)
        let hit = text.range(of: term, options: .caseInsensitive)
        let hitStart = hit.map { text.distance(from: text.startIndex, to: $0.lowerBound) } ?? 0
        let hitEnd = hit.map { text.distance(from: text.startIndex, to: $0.upperBound) } ?? 0
        var lower = max(0, hitStart - max(0, width - (hitEnd - hitStart)) / 2)
        let upperBound = min(chars.count, lower + width)
        lower = max(0, upperBound - width)
        var upper = upperBound
        // Drop the partial words at either cut, as long as the hit stays inside.
        if lower > 0, lower < hitStart, let space = chars[lower..<hitStart].firstIndex(where: \.isWhitespace) {
            lower = space + 1
        }
        if upper < chars.count, hitEnd < upper, let space = chars[hitEnd..<upper].lastIndex(where: \.isWhitespace) {
            upper = space
        }
        let body = String(chars[lower..<upper]).trimmingCharacters(in: .whitespaces)
        return (lower > 0 ? "…" : "") + body + (upper < chars.count ? "…" : "")
    }
}

/// Turn text and speaker names as tool lines show them.
enum TranscriptText {
    /// Newlines and tabs become spaces, so one turn is always one line.
    static func oneLine(_ s: String) -> String {
        guard s.contains(where: { $0.isNewline || $0 == "\t" }) else { return s }
        return String(s.map { $0.isNewline || $0 == "\t" ? " " : $0 })
    }

    /// The label of a turn: its effective speaker's line name, "Unknown speaker" for a key with no speaker, nil when
    /// the turn has no key.
    static func speakerName(_ turn: Turn, _ speakers: [SpeakerKey: MCPSpeaker]) -> String? {
        guard let key = turn.effectiveSpeakerKey else { return nil }
        return speakers[key].map(SpeakerLabelText.lineName) ?? "Unknown speaker"
    }
}
