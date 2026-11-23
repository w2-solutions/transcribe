import Foundation
import Testing
@testable import TranscribeCore

fileprivate func word(_ text: String, _ start: Double, _ end: Double) -> TimedWord {
    TimedWord(text: text, range: TimeRange(start: start, end: end))
}

fileprivate func seg(_ key: SpeakerKey, _ start: Double, _ end: Double) -> SpeakerSegment {
    SpeakerSegment(speakerKey: key, range: TimeRange(start: start, end: end))
}

/// Conversation B as built by the fake script (`SeedContent.words(for:)`): words evenly timed from
/// segment start + 0.1 to segment end − 0.1, each lasting 90% of its slot.
enum ConversationBFixture {
    static let turns: [(key: SpeakerKey, start: Double, end: Double, text: String)] = [
        ("S1", 0.50, 6.90, "Hey, Karan. Um, I just want to test out if this transcription app works. Can you say something?"),
        ("S2", 6.95, 14.60, "Uh yes, testing the transcription app. This is the first take that we're taking. Okay, I got the spelling wrong, but it's alright."),
        ("S1", 14.70, 19.70, "Awesome. Alright, I think that'll do. Thanks."),
        ("S2", 19.75, 24.00, "Oh yeah, uh thanks. You're welcome."),
    ]

    static func words(_ t: (key: SpeakerKey, start: Double, end: Double, text: String)) -> [TimedWord] {
        let tokens = t.text.split(separator: " ").map(String.init)
        let start = t.start + 0.1, end = t.end - 0.1
        let slice = (end - start) / Double(tokens.count)
        return tokens.enumerated().map { i, token in
            let a = start + Double(i) * slice
            return TimedWord(text: token, range: TimeRange(start: a, end: a + slice * 0.9))
        }
    }

    static var allWords: [TimedWord] { turns.flatMap(words) }
    static var segments: [SpeakerSegment] {
        turns.map { SpeakerSegment(speakerKey: $0.key, range: TimeRange(start: $0.start, end: $0.end)) }
    }
}

@Suite("TurnBuilder.speakerTurns")
struct TurnBuilderTests {
    func keys(_ turns: [Turn]) -> [SpeakerKey?] { turns.map(\.speakerKey) }

    @Test func takesSpeakerWithMostOverlap() {
        let turns = TurnBuilder.speakerTurns(words: [word("hello", 1.0, 2.0)],
                                             segments: [seg("S1", 0.0, 1.4), seg("S2", 1.4, 3.0)])
        #expect(keys(turns) == ["S2"])
    }

    @Test func overlapIsAUnionPerSpeaker() {
        // S1 has two touching pieces totalling 0.6; S2 one piece of 0.5.
        let turns = TurnBuilder.speakerTurns(words: [word("a", 0.0, 1.0)],
                                             segments: [seg("S1", 0.0, 0.3), seg("S1", 0.2, 0.6), seg("S2", 0.5, 1.0)])
        #expect(keys(turns) == ["S1"])
    }

    @Test func tieGoesToSpeakerContainingMidpoint() {
        // Both overlap 0.5 s; only S2 contains the midpoint 1.5 (ranges are half-open).
        let turns = TurnBuilder.speakerTurns(words: [word("x", 1.0, 2.0)],
                                             segments: [seg("S1", 0.5, 1.5), seg("S2", 1.5, 2.5)])
        #expect(keys(turns) == ["S2"])
    }

    @Test func tieWithBothContainingMidpointGoesToLowerKey() {
        let turns = TurnBuilder.speakerTurns(words: [word("x", 1.0, 2.0)],
                                             segments: [seg("S2", 1.4, 3.0), seg("S1", 0.0, 1.6)])
        #expect(keys(turns) == ["S1"])
    }

    @Test func tieWithNoMidpointGoesToLowerKeyInNaturalOrder() {
        // S2 and S10 each cover 0.4 s, neither covers the midpoint 1.5.
        let segments = [seg("S10", 1.0, 1.2), seg("S10", 1.8, 2.0), seg("S2", 1.2, 1.4), seg("S2", 1.6, 1.8)]
        let turns = TurnBuilder.speakerTurns(words: [word("x", 1.0, 2.0)], segments: segments)
        #expect(keys(turns) == ["S2"])
    }

    @Test(arguments: [
        (4.6, 5.9, "S1"),   // 0.4 s before vs 0.6 s after
        (4.4, 5.75, "S2"),  // 0.6 s before vs 0.45 s after
        (4.5, 5.8, "S1"),   // exactly 0.5 s each side: lower key
    ])
    func nearestSegmentWithinTolerance(s1End: Double, s2Start: Double, expected: String) {
        let turns = TurnBuilder.speakerTurns(words: [word("x", 5.0, 5.3)],
                                             segments: [seg("S1", 0.0, s1End), seg("S2", s2Start, 8.0)])
        #expect(keys(turns) == [expected])
    }

    @Test func carriesPreviousSpeakerForwardWhenNothingIsNear() {
        let words = [word("one", 0.5, 1.0), word("two", 1.2, 1.6), word("three", 2.5, 2.9)]
        let turns = TurnBuilder.speakerTurns(words: words, segments: [seg("S1", 0.0, 1.7), seg("S2", 5.0, 6.0)])
        #expect(keys(turns) == ["S1"])
        #expect(turns[0].words.count == 3)
    }

    @Test func firstWordTakesNextWordsSpeaker() {
        let words = [word("early", 0.0, 0.3), word("later", 5.1, 5.5)]
        // "early" is 4.7 s from the only segment; it takes "later"'s speaker. The 4.8 s gap still splits turns.
        let turns = TurnBuilder.speakerTurns(words: words, segments: [seg("S2", 5.0, 6.0)])
        #expect(keys(turns) == ["S2", "S2"])
    }

    @Test(arguments: [(0.7, true), (0.71, false)])
    func flagsWordWhenSecondSpeakerCoversThirtyPercent(s2Start: Double, flagged: Bool) {
        let words = [word("mine", 0.0, 1.0), word("more", 1.1, 1.5)]
        let turns = TurnBuilder.speakerTurns(words: words, segments: [seg("S1", 0.0, 1.6), seg("S2", s2Start, 1.05)])
        #expect(keys(turns) == ["S1"])
        #expect(turns[0].words[0].isOverlap == flagged)
        #expect(turns[0].words[1].isOverlap == false)
        #expect(turns[0].hasOverlap == flagged)
    }

    @Test func absorbsOneShortWordIsland() {
        let words = [word("a", 0.5, 1.0), word("b", 1.2, 1.8), word("c", 2.0, 2.3), word("d", 2.4, 3.0)]
        let segments = [seg("S1", 0.0, 2.0), seg("S2", 2.0, 2.3), seg("S1", 2.3, 5.0)]
        let turns = TurnBuilder.speakerTurns(words: words, segments: segments)
        #expect(keys(turns) == ["S1"])
        #expect(turns[0].words.map(\.text) == ["a", "b", "c", "d"])
        #expect(turns[0].words[2].isOverlap, "the absorbed word is another speaker's audio")
    }

    @Test func keepsIslandThatIsTooLong() {
        let words = [word("a", 0.5, 1.0), word("b", 1.2, 1.8), word("c", 2.0, 2.4), word("d", 2.5, 3.0)]
        let segments = [seg("S1", 0.0, 2.0), seg("S2", 2.0, 2.4), seg("S1", 2.4, 5.0)]
        #expect(keys(TurnBuilder.speakerTurns(words: words, segments: segments)) == ["S1", "S2", "S1"])
    }

    @Test func keepsIslandOfTwoWords() {
        let words = [word("a", 0.5, 1.0), word("b", 2.0, 2.1), word("c", 2.15, 2.3), word("d", 2.5, 3.0)]
        let segments = [seg("S1", 0.0, 2.0), seg("S2", 2.0, 2.3), seg("S1", 2.3, 5.0)]
        #expect(keys(TurnBuilder.speakerTurns(words: words, segments: segments)) == ["S1", "S2", "S1"])
    }

    @Test func keepsIslandBetweenDifferentSpeakers() {
        let words = [word("a", 0.5, 1.0), word("c", 2.0, 2.3), word("d", 2.5, 3.0)]
        let segments = [seg("S1", 0.0, 2.0), seg("S2", 2.0, 2.3), seg("S3", 2.3, 5.0)]
        #expect(keys(TurnBuilder.speakerTurns(words: words, segments: segments)) == ["S1", "S2", "S3"])
    }

    @Test(arguments: [(4.0, 2), (3.9, 1)])
    func splitsSameSpeakerOnThreeSecondGap(secondStart: Double, turnCount: Int) {
        let words = [word("first", 0.0, 1.0), word("second", secondStart, secondStart + 0.5)]
        let turns = TurnBuilder.speakerTurns(words: words, segments: [seg("S1", 0.0, 10.0)])
        #expect(turns.count == turnCount)
        #expect(turns.allSatisfy { $0.speakerKey == "S1" })
    }

    @Test func noSegmentsGivesNilKeys() {
        let words = [word("a", 0.0, 0.5), word("b", 0.6, 1.0), word("c", 5.0, 5.5)]
        let turns = TurnBuilder.speakerTurns(words: words, segments: [])
        #expect(keys(turns) == [nil, nil])
        #expect(!turns.contains { $0.hasOverlap })
    }

    @Test func zeroWordsGivesNoTurns() {
        #expect(TurnBuilder.speakerTurns(words: [], segments: [seg("S1", 0, 1)]).isEmpty)
        #expect(TurnBuilder.paragraphs(words: []).isEmpty)
    }

    @Test func unsortedInputGivesTheSameTurns() {
        let words = ConversationBFixture.allWords, segments = ConversationBFixture.segments
        let expected = TurnBuilder.speakerTurns(words: words, segments: segments)
        var rng = ShuffleRNG(seed: 42)
        for _ in 0..<5 {
            let turns = TurnBuilder.speakerTurns(words: words.shuffled(using: &rng), segments: segments.shuffled(using: &rng))
            #expect(turns == expected)
        }
    }

    @Test func idsAreStableAndRangesSpanWords() {
        let turns = TurnBuilder.speakerTurns(words: ConversationBFixture.allWords, segments: ConversationBFixture.segments)
        #expect(turns.map(\.id) == turns.indices.map { Turn.stableID(index: $0) })
        for turn in turns {
            #expect(turn.range.start == turn.words.first?.range.start)
            #expect(turn.range.end == turn.words.last?.range.end)
        }
        #expect(TurnBuilder.speakerTurns(words: ConversationBFixture.allWords, segments: ConversationBFixture.segments) == turns)
    }

    @Test func conversationBReproducesTheFourMockupTurns() {
        let turns = TurnBuilder.speakerTurns(words: ConversationBFixture.allWords, segments: ConversationBFixture.segments)
        #expect(keys(turns) == ["S1", "S2", "S1", "S2"])
        #expect(turns.map(\.text) == ConversationBFixture.turns.map(\.text))
        #expect(!turns.contains { $0.hasOverlap })
        // Mockup times 0:01, 0:07, 0:15, 0:20 are the starts rounded to the nearest second;
        // DisplayFormat.duration (rounding down) gives 0:00, 0:07, 0:14, 0:19 (skeleton deviation 12).
        #expect(turns.map { DisplayFormat.duration($0.range.start.rounded()) } == ["0:01", "0:07", "0:15", "0:20"])
        #expect(turns.map { DisplayFormat.duration($0.range.start) } == ["0:00", "0:07", "0:14", "0:19"])
    }

    @Test func oneHourOfWordsBuildsQuickly() {
        // 36k words over an hour, alternating speakers every ~10 s with slightly overlapping segments.
        var words: [TimedWord] = [], segments: [SpeakerSegment] = []
        words.reserveCapacity(36_000)
        for i in 0..<36_000 {
            let t = Double(i) * 0.1
            words.append(word("w\(i)", t, t + 0.08))
        }
        var t = 0.0, k = 0
        while t < 3600 {
            let length = 6 + Double(k % 7)
            segments.append(seg(k % 3 == 0 ? "S1" : (k % 3 == 1 ? "S2" : "S3"), t, t + length + 0.3))
            t += length; k += 1
        }
        let clock = ContinuousClock()
        var turns: [Turn] = []
        let elapsed = clock.measure { turns = TurnBuilder.speakerTurns(words: words, segments: segments) }
        #expect(turns.reduce(0) { $0 + $1.words.count } == 36_000)
        #if DEBUG
        let limit = Duration.seconds(5)     // unoptimised build; the 0.5 s target is checked with -c release
        #else
        let limit = Duration.milliseconds(500)
        #endif
        #expect(elapsed < limit, "built in \(elapsed)")
    }
}

@Suite("TurnBuilder.paragraphs")
struct ParagraphTests {
    @Test(arguments: [(1.51, 2), (1.5, 1)])
    func splitsOnGapLongerThanOneAndAHalfSeconds(gap: Double, count: Int) {
        let words = [word("Hello", 0, 1), word("again", 1 + gap, 2 + gap)]
        let paragraphs = TurnBuilder.paragraphs(words: words)
        #expect(paragraphs.count == count)
        #expect(paragraphs.allSatisfy { $0.speakerKey == nil })
        #expect(paragraphs.map(\.id) == paragraphs.indices.map { Turn.stableID(index: $0) })
    }

    @Test func splitsLongParagraphAtSentenceEnd() {
        // Words every 0.5 s; "end." at 30.0–30.4 makes the paragraph ≥ 30 s long and ends a sentence.
        var words = (0..<60).map { word("w\($0)", Double($0) * 0.5, Double($0) * 0.5 + 0.4) }
        words.append(word("end.", 30.0, 30.4))
        words.append(word("next", 30.5, 30.9))
        let paragraphs = TurnBuilder.paragraphs(words: words)
        #expect(paragraphs.count == 2)
        #expect(paragraphs[0].words.last?.text == "end.")
        #expect(paragraphs[1].words.map(\.text) == ["next"])
    }

    @Test func doesNotSplitLongParagraphWithoutSentenceEnd() {
        let words = (0..<100).map { word("w\($0)", Double($0) * 0.5, Double($0) * 0.5 + 0.4) }
        #expect(TurnBuilder.paragraphs(words: words).count == 1)
    }

    @Test func doesNotSplitShortParagraphAtSentenceEnd() {
        let words = [word("One.", 0, 0.4), word("Two.", 0.5, 0.9), word("Three.", 1.0, 1.4)]
        #expect(TurnBuilder.paragraphs(words: words).count == 1)
    }

    @Test func sentenceEndIgnoresClosingQuotes() {
        #expect(TurnBuilder.endsSentence("said.\""))
        #expect(TurnBuilder.endsSentence("really?)"))
        #expect(!TurnBuilder.endsSentence("Karan,"))
        #expect(!TurnBuilder.endsSentence(""))
    }
}

/// Deterministic generator for shuffle tests.
fileprivate struct ShuffleRNG: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
