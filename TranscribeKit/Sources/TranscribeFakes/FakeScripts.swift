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
    /// Per-span overrides for `embedVoice`: the first entry whose range contains a span's midpoint wins.
    public var spanVectors: [(range: TimeRange, vector: VoiceVector)] = []
    /// Speakers heard through Mac audio (the far side of a call). In a fake Both recording the system stem holds
    /// exactly their segments and the microphone stem the rest (`FakeLiveRecording`).
    public var remoteSpeakers: Set<SpeakerKey> = []

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
                       liveTimeline: liveTimeline(for: turns, duration: duration), behaviour: behaviour)
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
        case .longTalk:
            return make(SeedContent.longTalk, SeedContent.longTalkDuration, newVoicesVectors, .normal)
        }
    }

    /// Seconds between live text updates, as with the real engine's live windows.
    public static let liveStep: TimeInterval = 2.0

    /// Cumulative live text as the real engine produces it: every `liveStep` seconds the words spoken so far
    /// arrive, the newest step's words volatile and everything before them confirmed.
    public static func liveTimeline(for turns: [ScriptTurn], duration: TimeInterval) -> [(at: TimeInterval, text: LiveText)] {
        let words = SeedContent.allWords(turns)
        func text(_ slice: [TimedWord]) -> String { slice.map(\.text).joined(separator: " ") }
        var timeline: [(at: TimeInterval, text: LiveText)] = []
        var t = liveStep
        while t < duration + liveStep {
            let confirmed = words.filter { $0.range.end <= t - liveStep }
            let volatile = words.filter { $0.range.end > t - liveStep && $0.range.end <= t }
            let entry = LiveText(confirmed: text(confirmed), volatile: text(volatile))
            if !entry.isEmpty, entry != timeline.last?.text { timeline.append((at: t, text: entry)) }
            t += liveStep
        }
        return timeline
    }

    /// The latest timeline entry at or before `t`.
    public func liveText(at t: TimeInterval) -> LiveText? {
        liveTimeline.last(where: { $0.at <= t })?.text
    }
}
