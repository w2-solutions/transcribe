import Foundation
import TranscribeCore

/// What the fake engine "hears" and returns for one recording (§7.2).
public struct FakeScript: Sendable {
    public enum Behaviour: Sendable, Equatable { case normal, noSpeech, failSeparation, holdAtSeparating }

    public var name: FakeScriptName
    public var duration: TimeInterval
    public var turns: [ScriptTurn]
    public var words: [TimedWord]
    public var segments: [SpeakerSegment]
    public var vectors: [SpeakerKey: VoiceVector]
    public var persons: [SpeakerKey: SyntheticPerson]       // voice used for SyntheticAudio
    public var liveTimeline: [(at: TimeInterval, text: LiveText)]
    public var behaviour: Behaviour

    /// Segments with the synthetic person speaking each one (for SyntheticAudio).
    public var audioSegments: [(TimeRange, SyntheticPerson)] {
        segments.map { ($0.range, persons[$0.speakerKey] ?? .stranger) }
    }

    public static func named(_ name: FakeScriptName) -> FakeScript {
        let b = SeedContent.conversationB, a = SeedContent.conversationA
        let bPersons: [SpeakerKey: SyntheticPerson] = ["S1": .liam, "S2": .karan]
        func make(_ turns: [ScriptTurn], _ duration: TimeInterval, _ vectors: [SpeakerKey: VoiceVector],
                  _ behaviour: Behaviour) -> FakeScript {
            FakeScript(name: name, duration: duration, turns: turns, words: SeedContent.allWords(turns),
                       segments: SeedContent.segments(turns), vectors: vectors, persons: bPersons,
                       liveTimeline: liveTimeline, behaviour: behaviour)
        }
        let newVoicesVectors: [SpeakerKey: VoiceVector] = [
            "S1": SyntheticVoices.vector(near: .liam, cosine: 0.90, variant: 1),
            "S2": SyntheticVoices.vector(near: .karan, cosine: 0.90, variant: 2),
        ]
        switch name {
        case .newVoices:
            return make(b, SeedContent.conversationBDuration, newVoicesVectors, .normal)
        case .knownVoices:
            return make(a, SeedContent.conversationADuration, [
                "S1": SyntheticVoices.vector(near: .liam, cosine: 0.82, variant: 3),
                "S2": SyntheticVoices.vector(near: .karan, cosine: 0.71, variant: 4),
            ], .normal)
        case .askKaran:
            return make(b, SeedContent.conversationBDuration, [
                "S1": SyntheticVoices.vector(near: .liam, cosine: 0.82, variant: 5),
                "S2": SyntheticVoices.vector(near: .karan, cosine: 0.47, variant: 6),
            ], .normal)
        case .noSpeech:
            return FakeScript(name: name, duration: 8, turns: [], words: [], segments: [], vectors: [:], persons: [:],
                              liveTimeline: [], behaviour: .noSpeech)
        case .failSeparation:
            return make(b, SeedContent.conversationBDuration, [:], .failSeparation)
        case .holdAtSeparating:
            return make(b, SeedContent.conversationBDuration, newVoicesVectors, .holdAtSeparating)
        }
    }

    /// Cumulative live text following the Recording mockup.
    public static let liveTimeline: [(at: TimeInterval, text: LiveText)] = {
        let first = SeedContent.conversationB[0].text
        return [
            (at: 1.0, text: LiveText(confirmed: "", volatile: "Hey, Karan.")),
            (at: 3.0, text: LiveText(confirmed: first, volatile: "")),
            (at: 8.0, text: LiveText(confirmed: first + " Uh yes, testing the transcription app. This is the first take",
                                     volatile: "that we're taking. Okay, I got the")),
        ]
    }()

    /// The latest timeline entry at or before `t`.
    public func liveText(at t: TimeInterval) -> LiveText? {
        liveTimeline.last(where: { $0.at <= t })?.text
    }
}
