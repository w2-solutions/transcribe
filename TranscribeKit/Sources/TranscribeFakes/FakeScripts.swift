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
    /// Which stream each speaker is heard on when the script is recorded with the microphone and Mac audio (Both):
    /// `.system` speakers are on the system stem only, `.mixed` ones on the microphone and, for the first half of each
    /// of their segments, on the system stem too, everyone else on the microphone only. Empty for every script but
    /// `callVoices`. `stemSegments` turns this into stems (`SyntheticAudio.writeStems`, and `FakeLiveRecording` in Both mode), so the real
    /// attribution (`SourceAttribution`) runs on them.
    public var speakerSources: [SpeakerKey: SpeakerSource] = [:]

    /// The segments that sound on one stem of a Both recording, with the person speaking each.
    public func stemSegments(_ stream: CaptureStream) -> [(TimeRange, SyntheticPerson)] {
        segments.compactMap { segment in
            let person = persons[segment.speakerKey] ?? .stranger
            switch (stream, speakerSources[segment.speakerKey] ?? .mic) {
            case (.mic, .system): return nil
            case (.mic, _): return (segment.range, person)
            case (.system, .mic): return nil
            case (.system, .system): return (segment.range, person)
            case (.system, .mixed):
                return (TimeRange(start: segment.range.start, end: segment.range.start + segment.range.duration / 2), person)
            }
        }
    }

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
        case .callVoices:
            // Liam in the room, Karan through Mac audio, and S3 heard on both: a blend of the two (never learned).
            var script = FakeScript(name: name, duration: SeedContent.callConversationDuration,
                                    turns: SeedContent.callConversation,
                                    words: SeedContent.allWords(SeedContent.callConversation),
                                    segments: SeedContent.segments(SeedContent.callConversation), vectors: [
                                        "S1": SyntheticVoices.vector(near: .liam, cosine: 0.90, variant: 28),
                                        "S2": SyntheticVoices.vector(near: .karan, cosine: 0.90, variant: 29),
                                        "S3": SyntheticVoices.mix([(.liam, 0.6), (.karan, 0.6)], variant: 64),
                                    ],
                                    persons: ["S1": .liam, "S2": .karan, "S3": .stranger],
                                    liveTimeline: liveTimeline(for: SeedContent.callConversation,
                                                               duration: SeedContent.callConversationDuration),
                                    behaviour: .normal)
            script.speakerSources = ["S1": .mic, "S2": .system, "S3": .mixed]
            return script
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

    /// What the fake engine transcribes for a dictation file (`DictationFiles.prefix`), whatever the script: one
    /// sentence, 7 words over 0.2–2.4 s.
    public static let dictationSentence = "Let's move the stand-up to ten tomorrow."
    public static let dictationWords: [TimedWord] = dictationSentence.split(separator: " ").enumerated().map { i, word in
        let start = 0.2 + Double(i) * 0.32
        return TimedWord(text: String(word), range: TimeRange(start: start, end: start + 0.28))
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
