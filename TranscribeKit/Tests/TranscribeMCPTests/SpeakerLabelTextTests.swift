import Foundation
import Testing
@testable import TranscribeMCP

@Suite("MCP: speaker label text")
struct SpeakerLabelTextTests {
    @Test func namedUser() {
        let liam = MCPSpeaker(key: "S1", ordinal: 1, name: "Liam", status: .named, isUser: true)
        #expect(SpeakerLabelText.lineName(liam) == "Liam")
        #expect(SpeakerLabelText.bracket(liam) == "Liam [the user, named]")
        #expect(SpeakerLabelText.headerLine(liam) == "- Liam: the user; named by the user")
        let priya = MCPSpeaker(key: "S2", ordinal: 2, name: "Priya", status: .named)
        #expect(SpeakerLabelText.bracket(priya) == "Priya [named]")
        #expect(SpeakerLabelText.headerLine(priya) == "- Priya: named by the user")
    }

    @Test func autoLabelledSaysNotConfirmedAndAuto() {
        let karan = MCPSpeaker(key: "S2", ordinal: 2, name: "Karan", status: .autoLabelled)
        #expect(SpeakerLabelText.lineName(karan) == "Karan (auto)")
        #expect(SpeakerLabelText.bracket(karan) == "Karan [recognised automatically, not confirmed]")
        #expect(SpeakerLabelText.headerLine(karan) == "- Karan (auto): recognised automatically by voice; not confirmed by the user")
        let liam = MCPSpeaker(key: "S1", ordinal: 1, name: "Liam", status: .autoLabelled, isUser: true)
        #expect(SpeakerLabelText.headerLine(liam) == "- Liam (auto): the user; recognised automatically by voice; not confirmed")
        #expect(SpeakerLabelText.bracket(liam) == "Liam [the user, recognised automatically, not confirmed]")
    }

    @Test func suggestedShowsGuessButKeepsSpeakerN() {
        let s = MCPSpeaker(key: "S2", ordinal: 2, name: "Speaker 2", status: .suggested, suggestedName: "Priya")
        #expect(SpeakerLabelText.lineName(s) == "Speaker 2")
        #expect(SpeakerLabelText.bracket(s) == "Speaker 2 [unnamed, Transcribe guesses Priya]")
        #expect(SpeakerLabelText.headerLine(s) == "- Speaker 2: unnamed; Transcribe's guess is Priya, not confirmed")
        // Even if a name was carried on the speaker, a suggestion never shows as the name.
        var carried = s
        carried.name = "Priya"
        #expect(SpeakerLabelText.lineName(carried) == "Speaker 2")
    }

    @Test func suggestedWithoutName() {
        let s = MCPSpeaker(key: "S2", ordinal: 2, name: "Speaker 2", status: .suggested)
        #expect(SpeakerLabelText.bracket(s) == "Speaker 2 [unnamed]")
        #expect(SpeakerLabelText.headerLine(s) == "- Speaker 2: unnamed")
    }

    @Test func unnamed() {
        let s = MCPSpeaker(key: "S3", ordinal: 3, name: "Speaker 3", status: .unnamed)
        #expect(SpeakerLabelText.lineName(s) == "Speaker 3")
        #expect(SpeakerLabelText.bracket(s) == "Speaker 3 [unnamed]")
        #expect(SpeakerLabelText.headerLine(s) == "- Speaker 3: unnamed")
    }
}
