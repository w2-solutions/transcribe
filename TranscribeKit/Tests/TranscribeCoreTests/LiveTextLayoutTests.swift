import Foundation
import Testing
@testable import TranscribeCore

@Suite("LiveTextLayout")
struct LiveTextLayoutTests {
    static let speech = "Morning. Before we start, can we go through what's left on the list from last week? "
        + "Sure. The supplier quotes came back on Friday, so that item is done. Good. What about the site photos "
        + "for the client report? They're uploaded, but two of them need captions before we send it. Okay, I'll add "
        + "the captions this afternoon and send the report tomorrow."

    @Test func emptyTextHasNoParagraphs() {
        #expect(LiveTextLayout.paragraphs(LiveText()).isEmpty)
        #expect(LiveTextLayout.paragraphs(LiveText(confirmed: "  \n ", volatile: "")).isEmpty)
    }

    @Test func shortTextIsOneParagraph() {
        let p = LiveTextLayout.paragraphs(LiveText(confirmed: "Hey, Karan.", volatile: "Um, I just"))
        #expect(p == [LiveParagraph(id: 0, confirmed: "Hey, Karan.", volatile: "Um, I just")])
    }

    @Test func breaksAtSentenceEndsOnceLongEnough() {
        let p = LiveTextLayout.paragraphs(LiveText(confirmed: Self.speech))
        #expect(p.count == 3)
        #expect(p.map(\.id) == [0, 1, 2])
        for paragraph in p.dropLast() {
            #expect(paragraph.confirmed.count >= LiveTextLayout.softLimit - 1)
            #expect(LiveTextLayout.endsSentence(String(paragraph.confirmed.split(separator: " ").last ?? "")))
        }
        #expect(p.map(\.confirmed).joined(separator: " ") == Self.speech)
    }

    @Test func textWithoutPunctuationBreaksAtTheHardLimit() {
        let p = LiveTextLayout.paragraphs(LiveText(confirmed: Array(repeating: "word", count: 200).joined(separator: " ")))
        #expect(p.count > 1)
        #expect(p.allSatisfy { $0.confirmed.count <= LiveTextLayout.hardLimit + 5 })
    }

    @Test func theConfirmedVolatileSplitCanFallInsideAParagraph() {
        let words = Self.speech.split(separator: " ").map(String.init)
        let text = LiveText(confirmed: words.prefix(30).joined(separator: " "), volatile: words.dropFirst(30).joined(separator: " "))
        let p = LiveTextLayout.paragraphs(text)
        #expect(p == LiveTextLayout.paragraphs(LiveText(confirmed: Self.speech)).map { whole in
            // Same breaks; only the colour split differs.
            p[whole.id]
        })
        #expect(p.map { [$0.confirmed, $0.volatile].filter { !$0.isEmpty }.joined(separator: " ") }.joined(separator: " ") == Self.speech)
        #expect(p.last?.confirmed.isEmpty == true)
        #expect(p.first?.volatile.isEmpty == true)
    }

    /// Text on screen must not re-flow as words arrive: every earlier paragraph stays exactly as it was.
    @Test func earlierParagraphsNeverChangeAsWordsArrive() {
        let all = LiveText(confirmed: Self.speech)
        let total = LiveTextLayout.wordCount(all)
        var previous: [LiveParagraph] = []
        for n in 0...total {
            let now = LiveTextLayout.paragraphs(LiveTextLayout.revealing(all, words: n))
            #expect(now.count >= previous.count)
            #expect(Array(now.prefix(Swift.max(0, previous.count - 1))) == Array(previous.dropLast()))
            previous = now
        }
        #expect(previous == LiveTextLayout.paragraphs(all))
    }

    @Test func revealingTakesConfirmedWordsFirst() {
        let text = LiveText(confirmed: "one two three", volatile: "four five")
        #expect(LiveTextLayout.wordCount(text) == 5)
        #expect(LiveTextLayout.revealing(text, words: 0) == LiveText())
        #expect(LiveTextLayout.revealing(text, words: 2) == LiveText(confirmed: "one two"))
        #expect(LiveTextLayout.revealing(text, words: 4) == LiveText(confirmed: "one two three", volatile: "four"))
        #expect(LiveTextLayout.revealing(text, words: 5) == text)
        #expect(LiveTextLayout.revealing(text, words: 99) == text)
        #expect(LiveTextLayout.revealing(text, words: -1) == LiveText())
    }

    @Test(arguments: ["done.", "week?", "Thanks!", "right.\"", "so…", "ok.)"])
    func recognisesSentenceEnds(_ word: String) { #expect(LiveTextLayout.endsSentence(word)) }

    @Test(arguments: ["done", "Karan,", "3.5", "\"", ""])
    func ignoresOtherWords(_ word: String) { #expect(!LiveTextLayout.endsSentence(word)) }

    @Test func wordsAppearFasterWhenMoreAreWaiting() {
        #expect(LiveTextLayout.revealInterval(backlog: 1) == LiveTextLayout.slowestInterval)
        #expect(abs(LiveTextLayout.revealInterval(backlog: 12) - 0.1) < 0.0001)
        #expect(LiveTextLayout.revealInterval(backlog: 10_000) == LiveTextLayout.fastestInterval)
        #expect(LiveTextLayout.revealInterval(backlog: 0) == LiveTextLayout.slowestInterval)
        // Whatever is waiting is on screen within about the catch-up time.
        for backlog in [3, 8, 20, 40] {
            #expect(Double(backlog) * LiveTextLayout.revealInterval(backlog: backlog) <= 1.2 + 0.001)
        }
    }
}
