import Foundation
import Testing
@testable import TranscribeCore

@Suite("FillerWordFilter")
struct FillerWordFilterTests {
    @Test(arguments: ["um", "Um,", "UH.", "erm", "er", "ah!", "hmm", "mm", "(uh)", "Hmm?"])
    func recognisesFillers(_ word: String) {
        #expect(FillerWordFilter.isFiller(word))
    }

    @Test(arguments: ["umbrella", "her", "ahead", "summer", "yes", "", ",", "uh-huh"])
    func ignoresOtherWords(_ word: String) {
        #expect(!FillerWordFilter.isFiller(word))
    }

    @Test(arguments: [
        ("Uh yes, testing", "Yes, testing"),
        ("Uh yes, testing the transcription app.", "Yes, testing the transcription app."),
        ("Hey, Karan. Um, I just want to test", "Hey, Karan. I just want to test"),
        ("Oh yeah, uh thanks. You're welcome.", "Oh yeah, thanks. You're welcome."),
        ("Thanks, um.", "Thanks."),
        ("Is that right, uh?", "Is that right?"),
        ("Okay. Um. Right.", "Okay. Right."),
        ("so   um  we   start", "so we start"),
        ("Done. hmm and then", "Done. And then"),
        ("Um, iPhone first", "iPhone first"),
        ("um uh", ""),
        ("No fillers here.", "No fillers here."),
        ("Line one, um.\nUh line two", "Line one.\nLine two"),
    ])
    func filtersAndRepairs(_ input: String, _ expected: String) {
        #expect(FillerWordFilter.filter(input) == expected)
    }
}

@Suite("TranscriptFormatter")
struct TranscriptFormatterTests {
    func t(_ i: Int, _ key: SpeakerKey?, _ start: Double, _ text: String, override: SpeakerKey? = nil) -> Turn {
        let words = text.split(separator: " ").enumerated().map { j, w in
            TimedWord(text: String(w), range: TimeRange(start: start + Double(j) * 0.3, end: start + Double(j) * 0.3 + 0.25))
        }
        return Turn(id: Turn.stableID(index: i), speakerKey: key,
                    range: TimeRange(start: start, end: words.last?.range.end ?? start), words: words,
                    speakerKeyOverride: override)
    }

    var document: TranscriptDocument {
        let turns = [
            t(0, "S1", 1.2, "Hey, Karan. Um, I just want to test out if this transcription app works."),
            t(1, "S2", 7.05, "Uh yes, testing the transcription app."),
            t(2, "S1", 75.5, "Awesome."),
        ]
        return TranscriptDocument(words: turns.flatMap(\.words), turns: turns, asrModelID: "test")
    }

    func name(_ key: SpeakerKey) -> String { ["S1": "Liam", "S2": "Karan", "U1": "Priya"][key] ?? key }

    @Test func textOnlySeparatesTurnsWithBlankLines() {
        let text = TranscriptFormatter.plainText(document, format: .textOnly, removeFillers: false, speakerName: name)
        #expect(text == """
        Hey, Karan. Um, I just want to test out if this transcription app works.

        Uh yes, testing the transcription app.

        Awesome.
        """)
    }

    @Test func withSpeakersHeadsEachTurnWithNameAndTime() {
        let text = TranscriptFormatter.plainText(document, format: .withSpeakers, removeFillers: false, speakerName: name)
        #expect(text == """
        Liam · 0:01
        Hey, Karan. Um, I just want to test out if this transcription app works.

        Karan · 0:07
        Uh yes, testing the transcription app.

        Liam · 1:15
        Awesome.
        """)
    }

    @Test func removesFillersInCopy() {
        let text = TranscriptFormatter.plainText(document, format: .withSpeakers, removeFillers: true, speakerName: name)
        #expect(text == """
        Liam · 0:01
        Hey, Karan. I just want to test out if this transcription app works.

        Karan · 0:07
        Yes, testing the transcription app.

        Liam · 1:15
        Awesome.
        """)
        let plain = TranscriptFormatter.plainText(document, format: .textOnly, removeFillers: true, speakerName: name)
        #expect(plain.hasPrefix("Hey, Karan. I just want"))
        #expect(plain.contains("\n\nYes, testing the transcription app.\n\n"))
    }

    @Test func paragraphsWithoutSpeakersShowJustTheTime() {
        let turns = [t(0, nil, 1.0, "First paragraph."), t(1, nil, 3725, "Much later.")]
        let doc = TranscriptDocument(words: turns.flatMap(\.words), turns: turns, asrModelID: "test")
        let text = TranscriptFormatter.plainText(doc, format: .withSpeakers, removeFillers: false, speakerName: name)
        #expect(text == "0:01\nFirst paragraph.\n\n1:02:05\nMuch later.")
    }

    @Test func usesTheOverrideAndSkipsEmptyTurns() {
        let turns = [t(0, "S1", 0, "Um uh"), t(1, "S1", 2, "Over to you.", override: "U1"), t(2, "S2", 4, "Thanks.")]
        let doc = TranscriptDocument(words: turns.flatMap(\.words), turns: turns, asrModelID: "test")
        let text = TranscriptFormatter.plainText(doc, format: .withSpeakers, removeFillers: true, speakerName: name)
        #expect(text == "Priya · 0:02\nOver to you.\n\nKaran · 0:04\nThanks.")
    }

    @Test func offFormatsWithSpeakersAndEmptyDocumentIsEmpty() {
        let off = TranscriptFormatter.plainText(document, format: .off, removeFillers: false, speakerName: name)
        #expect(off == TranscriptFormatter.plainText(document, format: .withSpeakers, removeFillers: false, speakerName: name))
        let empty = TranscriptDocument(words: [], turns: [], asrModelID: "test")
        #expect(TranscriptFormatter.plainText(empty, format: .withSpeakers, removeFillers: true, speakerName: name) == "")
    }
}
