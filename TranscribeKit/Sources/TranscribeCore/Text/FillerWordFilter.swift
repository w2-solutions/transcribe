import Foundation

public enum FillerWordFilter {
    public static let english: Set<String> = ["um", "uh", "erm", "er", "ah", "hmm", "mm"]

    /// True when `word`, lower-cased and stripped of surrounding punctuation, is an English filler.
    public static func isFiller(_ word: String) -> Bool {
        let core = word.trimmingCharacters(in: .punctuationCharacters.union(.symbols).union(.whitespacesAndNewlines))
        return !core.isEmpty && english.contains(core.lowercased())
    }

    /// Removes filler words, then repairs the result:
    /// - spacing is collapsed to single spaces (line breaks are kept);
    /// - a word that now starts a sentence is capitalised ("Uh yes, testing" → "Yes, testing");
    /// - a filler's sentence-ending punctuation moves to the previous word ("thanks, um." → "thanks.").
    public static func filter(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { filterLine(String($0)) }
            .joined(separator: "\n")
    }

    private static func filterLine(_ line: String) -> String {
        let tokens = line.split(whereSeparator: \.isWhitespace).map(String.init)
        var kept: [String] = []
        var capitaliseNext = false
        for token in tokens {
            if isFiller(token) {
                let startsSentence = kept.last.map(TurnBuilder.endsSentence) ?? true
                if startsSentence { capitaliseNext = true }
                if let terminal = terminalPunctuation(token), var previous = kept.last, !TurnBuilder.endsSentence(previous) {
                    while let c = previous.last, c == "," || c == ";" || c == ":" { previous.removeLast() }
                    kept[kept.count - 1] = previous + terminal
                    capitaliseNext = true
                }
                continue
            }
            if capitaliseNext {
                kept.append(capitalisingFirstLetter(token))
                capitaliseNext = false
            } else {
                kept.append(token)
            }
        }
        return kept.joined(separator: " ")
    }

    /// The sentence-ending punctuation a token ends with ("." / "?" / "!" / "…"), if any.
    private static func terminalPunctuation(_ token: String) -> String? {
        guard let last = token.last, ".?!…".contains(last) else { return nil }
        let run = token.reversed().prefix { ".?!…".contains($0) }
        return String(run.reversed())
    }

    /// Upper-cases the first letter unless the word already has deliberate inner capitals ("iPhone").
    private static func capitalisingFirstLetter(_ word: String) -> String {
        guard let i = word.firstIndex(where: \.isLetter) else { return word }
        let letter = word[i]
        guard letter.isLowercase, !word[word.index(after: i)...].contains(where: \.isUppercase) else { return word }
        return word.replacingCharacters(in: i...i, with: letter.uppercased())
    }
}
