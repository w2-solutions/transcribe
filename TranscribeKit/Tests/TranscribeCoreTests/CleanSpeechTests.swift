import Foundation
import Testing
@testable import TranscribeCore

fileprivate func seg(_ key: SpeakerKey, _ start: Double, _ end: Double) -> SpeakerSegment {
    SpeakerSegment(speakerKey: key, range: TimeRange(start: start, end: end))
}

fileprivate func close(_ a: Double, _ b: Double, _ tolerance: Double = 1e-9) -> Bool { abs(a - b) <= tolerance }

fileprivate func same(_ spans: [TimeRange], _ expected: [(Double, Double)]) -> Bool {
    spans.count == expected.count && zip(spans, expected).allSatisfy { close($0.start, $1.0) && close($0.end, $1.1) }
}

/// A turn whose words are spread evenly over [start, end], each lasting 90% of its slot.
fileprivate func turn(_ index: Int, _ key: SpeakerKey?, _ start: Double, _ end: Double, _ text: String,
                      overlapWords: Set<Int> = [], override: SpeakerKey? = nil) -> Turn {
    let tokens = text.split(separator: " ").map(String.init)
    let slice = (end - start) / Double(tokens.count)
    let words = tokens.enumerated().map { i, token in
        TimedWord(text: token, range: TimeRange(start: start + Double(i) * slice, end: start + Double(i) * slice + slice * 0.9),
                  isOverlap: overlapWords.contains(i))
    }
    return Turn(id: Turn.stableID(index: index), speakerKey: key, range: TimeRange(start: start, end: words.last!.range.end),
                words: words, hasOverlap: !overlapWords.isEmpty, speakerKeyOverride: override)
}

@Suite("CleanSpeech")
struct CleanSpeechTests {
    @Test func subtractsOtherSpeakersAndTrimsEdges() {
        let spans = CleanSpeech.spans(for: "S1", in: [seg("S1", 0, 10), seg("S2", 4, 6), seg("S3", 5.5, 7)])
        #expect(same(spans, [(0.1, 3.9), (7.1, 9.9)]))
        #expect(close(CleanSpeech.seconds(spans), 3.8 + 2.8))
    }

    @Test func mergesTheSpeakersOwnOverlappingSegments() {
        let spans = CleanSpeech.spans(for: "S1", in: [seg("S1", 0, 3), seg("S1", 2, 5), seg("S1", 5, 6)])
        #expect(same(spans, [(0.1, 5.9)]))
    }

    @Test(arguments: [(1.2, 1), (1.19, 0)])
    func keepsPiecesOfAtLeastOneSecondAfterTrimming(end: Double, count: Int) {
        #expect(CleanSpeech.spans(for: "S1", in: [seg("S1", 0, end)]).count == count)
    }

    @Test func otherSpeakerCoveringEverythingLeavesNothing() {
        #expect(CleanSpeech.spans(for: "S1", in: [seg("S1", 2, 4), seg("S2", 0, 10)]).isEmpty)
        #expect(CleanSpeech.spans(for: "S9", in: [seg("S1", 0, 10)]).isEmpty)
    }

    @Test func conversationBCleanSeconds() {
        let segments = ConversationBFixture.segments
        #expect(close(CleanSpeech.seconds(CleanSpeech.spans(for: "S1", in: segments)), 11.0, 1e-6))
        #expect(close(CleanSpeech.seconds(CleanSpeech.spans(for: "S2", in: segments)), 11.5, 1e-6))
    }

    @Test func embeddingSpansTakeLongestFirstUntilSixtySeconds() {
        let spans = [TimeRange(start: 0, end: 10), TimeRange(start: 20, end: 50), TimeRange(start: 60, end: 85),
                     TimeRange(start: 100, end: 120)]
        // 30 + 25 = 55 < 60, so the 20 s span is added too (75 s); the 10 s span is not needed.
        let chosen = CleanSpeech.embeddingSpans(spans)
        #expect(chosen == [TimeRange(start: 20, end: 50), TimeRange(start: 60, end: 85), TimeRange(start: 100, end: 120)])
    }

    @Test func embeddingSpansStopExactlyAtSixty() {
        let spans = [TimeRange(start: 40, end: 70), TimeRange(start: 0, end: 30), TimeRange(start: 80, end: 85)]
        #expect(CleanSpeech.embeddingSpans(spans) == [TimeRange(start: 0, end: 30), TimeRange(start: 40, end: 70)])
    }

    @Test func embeddingSpansKeepEverythingUnderTheCap() {
        let spans = [TimeRange(start: 5, end: 8), TimeRange(start: 0, end: 2)]
        #expect(CleanSpeech.embeddingSpans(spans) == [TimeRange(start: 0, end: 2), TimeRange(start: 5, end: 8)])
        #expect(CleanSpeech.embeddingSpans([]).isEmpty)
    }

    @Test func totalSecondsIsTheUnionOfTheSpeakersSegments() {
        let segments = [seg("S1", 0, 3), seg("S1", 2, 5), seg("S1", 10, 11), seg("S2", 0, 20)]
        #expect(close(CleanSpeech.totalSeconds(for: "S1", in: segments), 6))
        #expect(close(CleanSpeech.totalSeconds(for: "S2", in: segments), 20))
        #expect(CleanSpeech.totalSeconds(for: "S3", in: segments) == 0)
    }

    // MARK: listenClips

    @Test func clipsCutToFirstSentenceInTimeOrder() {
        let turns = TurnBuilder.speakerTurns(words: ConversationBFixture.allWords, segments: ConversationBFixture.segments)
        let clips = CleanSpeech.listenClips(for: "S2", turns: turns)
        #expect(clips.map(\.quote) == ["Uh yes, testing the transcription app.", "Oh yeah, uh thanks."])
        #expect(clips[0].range.start == turns[1].words[0].range.start)
        #expect(clips[0].range.end == turns[1].words[5].range.end)
        #expect(clips.allSatisfy { $0.range.duration >= 1.5 && $0.range.duration <= 8 })
    }

    @Test func picksTheLongestTurns() {
        let turns = [
            turn(0, "S1", 0, 2, "Short one here."),
            turn(1, "S1", 3, 9, "This is the longest turn of all."),
            turn(2, "S1", 10, 14, "Middle length turn here."),
        ]
        let clips = CleanSpeech.listenClips(for: "S1", turns: turns)
        #expect(clips.map(\.quote) == ["This is the longest turn of all.", "Middle length turn here."])
        #expect(CleanSpeech.listenClips(for: "S1", turns: turns, max: 1).map(\.quote) == ["This is the longest turn of all."])
        #expect(CleanSpeech.listenClips(for: "S1", turns: turns, max: 0).isEmpty)
    }

    @Test func shortSentenceExtendsWithinItsTurn() {
        // "Hi." lasts 0.45 s; following words are added until the clip is at least 1.5 s.
        let t = turn(0, "S1", 0, 5, "Hi. Can you hear me okay over there?")   // 8 words, 0.625 s slots
        let clip = try! #require(CleanSpeech.listenClips(for: "S1", turns: [t]).first)
        #expect(clip.quote == "Hi. Can you")
        #expect(close(clip.range.duration, 2 * 0.625 + 0.5625))
    }

    @Test func veryShortTurnIsPaddedToTheMinimum() {
        let clip = try! #require(CleanSpeech.listenClips(for: "S1", turns: [turn(0, "S1", 4, 4.8, "Yes.")]).first)
        #expect(clip.quote == "Yes.")
        #expect(close(clip.range.start, 4) && close(clip.range.duration, 1.5))
    }

    @Test func longSentenceIsCutAtTheMaximum() {
        let text = (1...24).map { "word\($0)" }.joined(separator: " ") + "."
        let clip = try! #require(CleanSpeech.listenClips(for: "S1", turns: [turn(0, "S1", 0, 12, text)]).first)
        #expect(close(clip.range.start, 0) && close(clip.range.duration, 8))
        #expect(clip.quote.hasSuffix("…"))
        #expect(clip.quote.hasPrefix("word1 word2"))
        #expect(!clip.quote.contains("word17"))
    }

    @Test func prefersNonOverlapTurnsAndFallsBackToOverlapOnes() {
        let turns = [
            turn(0, "S1", 0, 10, "A long turn with someone talking over it.", overlapWords: [0, 1]),
            turn(1, "S1", 12, 15, "A clean turn."),
        ]
        let one = CleanSpeech.listenClips(for: "S1", turns: turns, max: 1)
        #expect(one.map(\.quote) == ["A clean turn."])
        let two = CleanSpeech.listenClips(for: "S1", turns: turns, max: 2)
        #expect(two.map(\.quote) == ["turn with someone talking over it.", "A clean turn."])
        #expect(two[0].range.start == turns[0].words[2].range.start)
    }

    @Test func clipsFollowTheEffectiveKey() {
        let turns = [
            turn(0, "S1", 0, 6, "This turn was moved to someone else.", override: "S2"),
            turn(1, "S1", 7, 9, "This one stays."),
        ]
        #expect(CleanSpeech.listenClips(for: "S1", turns: turns).map(\.quote) == ["This one stays."])
        #expect(CleanSpeech.listenClips(for: "S2", turns: turns).map(\.quote) == ["This turn was moved to someone else."])
        #expect(CleanSpeech.listenClips(for: "S3", turns: turns).isEmpty)
    }
}
