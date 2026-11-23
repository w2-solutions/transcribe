import Foundation

/// One block of live text on the recording screen. `id` is its position from the start of the recording, so
/// it stays the same as later text arrives.
public struct LiveParagraph: Sendable, Equatable, Identifiable {
    public let id: Int
    public var confirmed: String
    public var volatile: String
    public init(id: Int, confirmed: String = "", volatile: String = "") {
        self.id = id; self.confirmed = confirmed; self.volatile = volatile
    }
}

/// Turns the running live text into short paragraphs and paces how fast new words are shown.
///
/// Live text has no speaker labels (speakers are separated after Stop), so without breaks it is one growing
/// wall of words. Paragraphs end at a sentence end once they are long enough. Breaks depend only on the words
/// before them, so text that is already on screen never re-flows when more arrives.
public enum LiveTextLayout {
    /// A paragraph ends at the first sentence end at or after this many characters.
    public static let softLimit = 110
    /// With no sentence end in sight, a paragraph ends at the first word boundary after this many characters.
    public static let hardLimit = 280

    public static func paragraphs(_ text: LiveText, softLimit: Int = softLimit,
                                  hardLimit: Int = hardLimit) -> [LiveParagraph] {
        let confirmed = words(text.confirmed), volatile = words(text.volatile)
        var result: [LiveParagraph] = []
        var current = LiveParagraph(id: 0)
        var length = 0
        for (index, word) in (confirmed + volatile).enumerated() {
            if index < confirmed.count {
                current.confirmed += current.confirmed.isEmpty ? word : " " + word
            } else {
                current.volatile += current.volatile.isEmpty ? word : " " + word
            }
            length += word.count + 1
            if (length >= softLimit && endsSentence(word)) || length >= hardLimit {
                result.append(current)
                current = LiveParagraph(id: result.count)
                length = 0
            }
        }
        if length > 0 { result.append(current) }
        return result
    }

    public static func wordCount(_ text: LiveText) -> Int { words(text.confirmed).count + words(text.volatile).count }

    /// The first `count` words of the text (confirmed words first).
    public static func revealing(_ text: LiveText, words count: Int) -> LiveText {
        let confirmed = words(text.confirmed), volatile = words(text.volatile)
        guard count < confirmed.count + volatile.count else { return text }
        let n = Swift.max(0, count)
        return LiveText(confirmed: confirmed.prefix(n).joined(separator: " "),
                        volatile: volatile.prefix(Swift.max(0, n - confirmed.count)).joined(separator: " "))
    }

    /// Seconds to wait before showing the next word when `backlog` words are waiting. New text arrives a few
    /// words at a time; this spreads them out at about speaking pace and speeds up when more is waiting, so
    /// the screen is never more than about `catchUp` seconds behind.
    public static func revealInterval(backlog: Int, catchUp: TimeInterval = 1.2) -> TimeInterval {
        guard backlog > 0 else { return slowestInterval }
        return Swift.min(slowestInterval, Swift.max(fastestInterval, catchUp / Double(backlog)))
    }
    public static let slowestInterval: TimeInterval = 0.18
    public static let fastestInterval: TimeInterval = 0.02

    static func words(_ s: String) -> [String] { s.split(whereSeparator: \.isWhitespace).map(String.init) }

    static func endsSentence(_ word: String) -> Bool {
        let trimmed = word.reversed().drop { closers.contains($0) }
        guard let last = trimmed.first else { return false }
        return terminators.contains(last)
    }
    private static let terminators: Set<Character> = [".", "?", "!", "…", "。", "？", "！"]
    private static let closers: Set<Character> = ["\"", "'", "”", "’", ")", "»"]
}
