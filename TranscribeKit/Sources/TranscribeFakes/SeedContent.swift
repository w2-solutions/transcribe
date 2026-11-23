import Foundation
import TranscribeCore

/// One scripted turn: who spoke, when (the diarizer segment), and what they said.
public struct ScriptTurn: Sendable, Equatable {
    public var key: SpeakerKey
    public var segment: TimeRange
    public var text: String
    public init(key: SpeakerKey, segment: TimeRange, text: String) { self.key = key; self.segment = segment; self.text = text }
}

/// Text content shared by the fake scripts and the seeds (mockup copy; invented meeting lines).
public enum SeedContent {
    /// Conversation B: the mockup's 0:24 "Hey, Karan" recording.
    public static let conversationB: [ScriptTurn] = [
        ScriptTurn(key: "S1", segment: TimeRange(start: 0.50, end: 6.90),
                   text: "Hey, Karan. Um, I just want to test out if this transcription app works. Can you say something?"),
        ScriptTurn(key: "S2", segment: TimeRange(start: 6.95, end: 14.60),
                   text: "Uh yes, testing the transcription app. This is the first take that we're taking. Okay, I got the spelling wrong, but it's alright."),
        ScriptTurn(key: "S1", segment: TimeRange(start: 14.70, end: 19.70),
                   text: "Awesome. Alright, I think that'll do. Thanks."),
        ScriptTurn(key: "S2", segment: TimeRange(start: 19.75, end: 24.00),
                   text: "Oh yeah, uh thanks. You're welcome."),
    ]
    public static let conversationBDuration: TimeInterval = 24.0

    /// Conversation A: the mockup's 0:20 "Just checking" recording.
    public static let conversationA: [ScriptTurn] = [
        ScriptTurn(key: "S1", segment: TimeRange(start: 0.50, end: 10.60),
                   text: "Just checking if it remembers who is speaking, like if it'll auto-detect that I'm Liam and auto-detect if this is Karan."),
        ScriptTurn(key: "S2", segment: TimeRange(start: 10.70, end: 15.50),
                   text: "And now this is me starting to speak, which is a second attempt at testing the app."),
        ScriptTurn(key: "S1", segment: TimeRange(start: 15.60, end: 20.00),
                   text: "Let's see if it works. Thanks, Karan. Appreciate that."),
    ]
    public static let conversationADuration: TimeInterval = 20.0

    /// Recording C opener (S1, 1.0–5.8).
    public static let meetingOpener = "Morning. Before we start, can we go through what's left on the list from last week?"

    /// Eight short, invented, plain-business-English lines about a project list (recording C).
    public static let meetingLines: [String] = [
        "Sure. The supplier quotes came back on Friday, so that item is done.",
        "Good. What about the site photos for the client report?",
        "They're uploaded, but two of them need captions before we send it.",
        "Okay, I'll add the captions this afternoon and send the report tomorrow.",
        "The budget sheet still needs the new rates from the finance team.",
        "I'll chase finance today. Can we move the review meeting to Thursday?",
        "Thursday works for me. Let's keep it to thirty minutes.",
        "Great. That leaves the safety checklist, which I can finish by Wednesday.",
    ]
    public static let conversationCDuration: TimeInterval = 768

    /// Recording C: S1 opener at 1.0–5.8, then alternating S2 / S1 turns starting about every 20 s.
    public static let conversationC: [ScriptTurn] = {
        var turns = [ScriptTurn(key: "S1", segment: TimeRange(start: 1.0, end: 5.8), text: meetingOpener)]
        var start: TimeInterval = 8.0
        var k = 0
        while start < conversationCDuration - 6 {
            let line = meetingLines[k % meetingLines.count]
            let words = line.split(separator: " ").count
            let length = Swift.min(Double(words) * 0.42 + 0.6, conversationCDuration - start)
            turns.append(ScriptTurn(key: k % 2 == 0 ? "S2" : "S1", segment: TimeRange(start: start, end: start + length), text: line))
            k += 1
            start += 20
        }
        return turns
    }()

    /// Long talk: the meeting lines back to back for 90 s, alternating speakers, with no gaps to speak of.
    public static let longTalkDuration: TimeInterval = 90
    public static let longTalk: [ScriptTurn] = {
        var turns: [ScriptTurn] = []
        var start: TimeInterval = 0.5
        var k = 0
        while true {
            let line = k == 0 ? meetingOpener : meetingLines[(k - 1) % meetingLines.count]
            let length = Double(line.split(separator: " ").count) * 0.36 + 0.4
            guard start + length <= longTalkDuration - 0.5 else { break }
            turns.append(ScriptTurn(key: k % 2 == 0 ? "S1" : "S2", segment: TimeRange(start: start, end: start + length), text: line))
            k += 1
            start += length + 0.15
        }
        return turns
    }()

    // MARK: Builders

    /// Words timed evenly from segment start + 0.1 to segment end − 0.1.
    public static func words(for turn: ScriptTurn) -> [TimedWord] {
        let tokens = turn.text.split(separator: " ").map(String.init)
        guard !tokens.isEmpty else { return [] }
        let start = turn.segment.start + 0.1, end = Swift.max(start, turn.segment.end - 0.1)
        let slice = (end - start) / Double(tokens.count)
        return tokens.enumerated().map { i, token in
            let a = start + Double(i) * slice
            return TimedWord(text: token, range: TimeRange(start: a, end: a + slice * 0.9))
        }
    }

    public static func allWords(_ turns: [ScriptTurn]) -> [TimedWord] { turns.flatMap(words(for:)) }

    /// One speaker turn per script turn (ids from Turn.stableID).
    public static func speakerTurns(_ turns: [ScriptTurn]) -> [Turn] {
        turns.enumerated().map { i, t in
            let w = words(for: t)
            let range = TimeRange(start: w.first?.range.start ?? t.segment.start, end: w.last?.range.end ?? t.segment.end)
            return Turn(id: Turn.stableID(index: i), speakerKey: t.key, range: range, words: w)
        }
    }

    /// One speaker-less paragraph per script turn.
    public static func paragraphs(_ turns: [ScriptTurn]) -> [Turn] {
        speakerTurns(turns).map { var t = $0; t.speakerKey = nil; return t }
    }

    public static func segments(_ turns: [ScriptTurn]) -> [SpeakerSegment] {
        turns.map { SpeakerSegment(speakerKey: $0.key, range: $0.segment) }
    }
}
