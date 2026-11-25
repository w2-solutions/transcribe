import Foundation

/// Where the next get_transcript page starts: `v1.t<turnIndex>.w<wordIndex>.n<turnCount>`, plus `.e<endMs>` when the
/// first call gave an `end_seconds`. `turnCount` detects a transcript that changed between pages.
struct TranscriptCursor: Equatable {
    var turn: Int
    var word: Int
    var turnCount: Int
    var endMs: Int?

    init(turn: Int, word: Int, turnCount: Int, endMs: Int? = nil) {
        self.turn = turn; self.word = word; self.turnCount = turnCount; self.endMs = endMs
    }

    var token: String {
        "v1.t\(turn).w\(word).n\(turnCount)" + (endMs.map { ".e\($0)" } ?? "")
    }

    init?(token: String) {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 || parts.count == 5, parts[0] == "v1",
              let t = Self.number(parts[1], "t"), let w = Self.number(parts[2], "w"), let n = Self.number(parts[3], "n")
        else { return nil }
        var e: Int?
        if parts.count == 5 {
            guard let end = Self.number(parts[4], "e") else { return nil }
            e = end
        }
        self.init(turn: t, word: w, turnCount: n, endMs: e)
    }

    /// "t58" → 58: the prefix, then 1–9 ASCII digits.
    private static func number(_ part: Substring, _ prefix: Character) -> Int? {
        guard part.first == prefix else { return nil }
        let digits = part.dropFirst()
        guard (1...9).contains(digits.count), digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return Int(digits)
    }
}
