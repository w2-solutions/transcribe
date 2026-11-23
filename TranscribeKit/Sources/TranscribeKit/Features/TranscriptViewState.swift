import Foundation
import TranscribeCore

/// One speaker of a recording as the transcript shows it (a value copy of `RecordingSpeaker`).
public struct TranscriptSpeaker: Sendable, Equatable, Identifiable {
    public enum ChipStyle: Sendable, Equatable { case unnamed, suggested, filled(recognised: Bool) }

    public var key: SpeakerKey
    public var ordinal: Int
    public var slot: Int
    public var label: SpeakerLabelState
    /// profile name → snapshot → "Speaker N"
    public var name: String
    public var profileID: UUID?
    public var suggestedProfileID: UUID?
    /// Name of the suggested profile ("Karan" in "Is this Karan?").
    public var suggestedName: String?
    public var cleanSeconds: Double
    public var totalSeconds: Double
    public var id: SpeakerKey { key }

    public init(key: SpeakerKey, ordinal: Int, slot: Int, label: SpeakerLabelState, name: String,
                profileID: UUID? = nil, suggestedProfileID: UUID? = nil, suggestedName: String? = nil,
                cleanSeconds: Double = 0, totalSeconds: Double = 0) {
        self.key = key; self.ordinal = ordinal; self.slot = slot; self.label = label; self.name = name
        self.profileID = profileID; self.suggestedProfileID = suggestedProfileID; self.suggestedName = suggestedName
        self.cleanSeconds = cleanSeconds; self.totalSeconds = totalSeconds
    }

    @MainActor public init(_ speaker: RecordingSpeaker, suggestedName: String?) {
        self.init(key: speaker.key, ordinal: speaker.ordinal, slot: speaker.colourSlot, label: speaker.label,
                  name: speaker.displayName, profileID: speaker.profile?.id,
                  suggestedProfileID: speaker.suggestedProfileID, suggestedName: suggestedName,
                  cleanSeconds: speaker.cleanSeconds, totalSeconds: speaker.totalSeconds)
    }

    /// Same rule as `Recording.speakersNeedingName`.
    public var needsName: Bool {
        (label == .unnamed || label == .suggested) && cleanSeconds >= MatchPolicy.default.minIdentifySeconds
    }

    /// A suggestion that can be asked about ("Is this Karan?").
    public var isAskable: Bool { label == .suggested && suggestedProfileID != nil && suggestedName != nil }

    public var chipStyle: ChipStyle {
        switch label {
        case .unnamed: .unnamed
        case .suggested: suggestedName == nil ? .unnamed : .suggested
        case .autoLabelled: .filled(recognised: true)
        case .named: .filled(recognised: false)
        }
    }

    /// Text on the chip: "Speaker 2", "Karan" (suggested chips add the "?" themselves), "Liam".
    public var chipName: String { label == .suggested ? (suggestedName ?? name) : name }

    /// Named or auto-labelled: "Wrong speaker? Change" applies.
    public var isLabelled: Bool { label == .named || label == .autoLabelled }
}

/// Everything `TranscriptView` derives from a recording: phase, banner, turn texts, now-playing range and search (§6.3–§6.6).
public struct TranscriptViewState: Sendable, Equatable {
    public enum Phase: Sendable, Equatable { case capturing, processing, ready, failed }

    public enum Banner: Sendable, Equatable {
        case failed(message: String?)
        case noSpeech
        case ask(TranscriptSpeaker)
        case newVoices([TranscriptSpeaker])
        case recognised(names: [String])
        case none
    }

    /// A highlighted span of a turn's displayed text, in Character offsets.
    public struct TextSpan: Sendable, Equatable, Hashable {
        public var turnIndex: Int
        public var range: Range<Int>
        public init(turnIndex: Int, range: Range<Int>) { self.turnIndex = turnIndex; self.range = range }
    }

    public let phase: Phase
    public let turns: [Turn]
    public let speakers: [TranscriptSpeaker]          // ordinal order
    public let marks: [TimeInterval]
    public let duration: TimeInterval
    public let noSpeech: Bool
    public let failureMessage: String?
    private let speakerByKey: [SpeakerKey: TranscriptSpeaker]

    public init(stage: RecordingStage, document: TranscriptDocument?, speakers: [TranscriptSpeaker],
                marks: [TimeInterval] = [], duration: TimeInterval = 0, noSpeech: Bool = false, failureMessage: String? = nil) {
        switch stage {
        case .capturing: phase = .capturing
        case .ready: phase = .ready
        case .failed: phase = .failed
        default: phase = .processing
        }
        self.turns = document?.turns ?? []
        self.speakers = speakers.sorted { $0.ordinal < $1.ordinal }
        self.marks = marks
        self.duration = duration
        self.noSpeech = noSpeech
        self.failureMessage = failureMessage
        self.speakerByKey = Dictionary(speakers.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
    }

    /// `profileNames` resolves `suggestedProfileID` → name for the ask banner and suggested chips.
    @MainActor public init(recording: Recording, document: TranscriptDocument?, profileNames: [UUID: String]) {
        let speakers = recording.speakers.map { s in
            TranscriptSpeaker(s, suggestedName: s.suggestedProfileID.flatMap { profileNames[$0] })
        }
        self.init(stage: recording.stage, document: document, speakers: speakers, marks: recording.marks,
                  duration: recording.duration, noSpeech: recording.noSpeech, failureMessage: recording.failureMessage)
    }

    // MARK: Speakers

    public func speaker(_ key: SpeakerKey?) -> TranscriptSpeaker? { key.flatMap { speakerByKey[$0] } }

    /// The speaker shown on turn `i` (effective key, so "Just this turn" overrides apply).
    public func speaker(forTurn i: Int) -> TranscriptSpeaker? {
        guard turns.indices.contains(i) else { return nil }
        return speaker(turns[i].effectiveSpeakerKey)
    }

    /// True once speaker separation has labelled the turns.
    public var hasSpeakers: Bool { turns.contains { $0.effectiveSpeakerKey != nil } }

    /// Turns whose effective key is `key` ("Save and label 2 turns").
    public func turnCount(for key: SpeakerKey) -> Int { turns.filter { $0.effectiveSpeakerKey == key }.count }

    /// Speakers that still need a name, in ordinal order.
    public var speakersNeedingName: [TranscriptSpeaker] { speakers.filter(\.needsName) }

    /// Auto-labelled names in ordinal order, without duplicates ("Recognised Liam and Karan"). Once turns carry
    /// speakers, a speaker whose every turn was moved elsewhere ("Just this turn") is left out.
    public var recognisedNames: [String] {
        var seen = Set<String>()
        let heard = Set(turns.compactMap(\.effectiveSpeakerKey))
        return speakers.filter { $0.label == .autoLabelled && (heard.isEmpty || heard.contains($0.key)) }
            .map(\.name).filter { seen.insert($0).inserted }
    }

    // MARK: Banner (priority: failed > noSpeech > ask > newVoices > recognised > none)

    public var banner: Banner {
        if phase == .failed {
            let message = failureMessage.flatMap { $0 == Self.failedTitle || $0.isEmpty ? nil : $0 }
            return .failed(message: message)
        }
        guard phase == .ready else { return .none }
        if noSpeech { return .noSpeech }
        if let ask = speakers.first(where: \.isAskable) { return .ask(ask) }
        let needing = speakersNeedingName
        if !needing.isEmpty { return .newVoices(needing) }
        let names = recognisedNames
        if !names.isEmpty { return .recognised(names: names) }
        return .none
    }

    public static let failedTitle = "Couldn't finish processing"

    /// "1 new voice" / "2 new voices"
    public static func newVoicesTitle(_ count: Int) -> String { count == 1 ? "1 new voice" : "\(count) new voices" }

    // MARK: Turn text

    /// Turn timestamp, rounded to the nearest second (words start 0.1 s into a segment; mockups show 0:01, 0:07, 0:15, 0:20).
    public func timestamp(_ i: Int) -> String {
        guard turns.indices.contains(i) else { return "" }
        return DisplayFormat.duration(turns[i].range.start.rounded())
    }

    /// The text shown for turn `i` (filler words removed when the setting is on; the stored transcript is untouched).
    public func displayText(_ i: Int, removeFillers: Bool) -> String {
        guard turns.indices.contains(i) else { return "" }
        let text = turns[i].text
        return removeFillers ? FillerWordFilter.filter(text) : text
    }

    /// Indices of turns that contain a marked moment (bookmark glyph).
    public var markedTurnIndices: Set<Int> {
        var result = Set<Int>()
        for mark in marks {
            if let i = turns.firstIndex(where: { mark >= $0.range.start && mark <= $0.range.end }) { result.insert(i) }
        }
        return result
    }

    // MARK: Now playing

    /// The phrase being played at `time`: the words between punctuation (, . ? ! ; :) around the last word that has
    /// started, inside the turn that covers `time` (or the last turn before it). Character offsets into `displayText`.
    public func nowPlaying(at time: TimeInterval, removeFillers: Bool) -> TextSpan? {
        guard let ti = SpeakerTimeline.turnIndex(at: time, in: turns) else { return nil }
        let words = turns[ti].words
        guard let wi = words.lastIndex(where: { $0.range.start <= time }) else { return nil }
        var start = wi
        while start > 0, !Self.endsPhrase(words[start - 1].text) { start -= 1 }
        var end = wi
        while end < words.count - 1, !Self.endsPhrase(words[end].text) { end += 1 }

        if !removeFillers {
            var offset = 0
            for w in words[..<start] { offset += w.text.count + 1 }
            let length = words[start...end].map(\.text).joined(separator: " ").count
            return TextSpan(turnIndex: ti, range: offset..<(offset + length))
        }
        let display = displayText(ti, removeFillers: true)
        let phrase = FillerWordFilter.filter(words[start...end].map(\.text).joined(separator: " "))
            .trimmingCharacters(in: .whitespaces)
        guard !phrase.isEmpty else { return nil }
        // Approximate position of the phrase in the filtered text, then search from just before it.
        let before = words[..<start].map(\.text).joined(separator: " ")
        let approx = FillerWordFilter.filter(before).count
        let searchFrom = display.index(display.startIndex, offsetBy: Swift.max(0, Swift.min(display.count, approx - 2)))
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        guard let r = display.range(of: phrase, options: options, range: searchFrom..<display.endIndex)
                ?? display.range(of: phrase, options: options) else { return nil }
        return TextSpan(turnIndex: ti, range: Self.offsets(r, in: display))
    }

    static func endsPhrase(_ word: String) -> Bool {
        guard let last = word.last else { return false }
        return ",.?!;:…".contains(last)
    }

    // MARK: Search

    /// Every case- and diacritic-insensitive match of `query` in the displayed turn texts, in reading order.
    public func searchHits(_ query: String, removeFillers: Bool) -> [TextSpan] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        var hits: [TextSpan] = []
        for i in turns.indices {
            let text = displayText(i, removeFillers: removeFillers)
            var from = text.startIndex
            while from < text.endIndex,
                  let r = text.range(of: q, options: [.caseInsensitive, .diacriticInsensitive], range: from..<text.endIndex) {
                hits.append(TextSpan(turnIndex: i, range: Self.offsets(r, in: text)))
                from = r.upperBound
            }
        }
        return hits
    }

    /// "2 of 5", or "No matches".
    public static func searchCountText(current: Int?, total: Int) -> String {
        guard total > 0 else { return "No matches" }
        return "\((current ?? 0) + 1) of \(total)"
    }

    static func offsets(_ r: Range<String.Index>, in text: String) -> Range<Int> {
        let lower = text.distance(from: text.startIndex, to: r.lowerBound)
        return lower..<(lower + text.distance(from: r.lowerBound, to: r.upperBound))
    }
}
