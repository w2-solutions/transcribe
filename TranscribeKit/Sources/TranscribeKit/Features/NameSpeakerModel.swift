import Foundation
import Observation
import TranscribeCore

/// Logic of the "Who is this?" / "Who said this?" sheet (§6.5): selection, name validation, the Remember rules,
/// the button title and what Save writes.
@MainActor @Observable
public final class NameSpeakerModel {
    public enum Mode: Sendable, Equatable {
        case name                       // whole speaker
        case correct(turnID: UUID?)     // "Wrong speaker? Change"; a turn id enables "Just this turn"
    }

    public enum Scope: String, Sendable, Equatable, CaseIterable { case allTurns, justThisTurn }

    public enum Selection: Sendable, Equatable, Hashable {
        case newPerson
        case profile(UUID)
        case speaker(SpeakerKey)        // correct mode: another speaker already in this recording
    }

    public struct ProfileOption: Sendable, Equatable, Identifiable {
        public var id: UUID
        public var name: String
        public var slot: Int
        public var isMe: Bool
        public init(id: UUID, name: String, slot: Int, isMe: Bool) { self.id = id; self.name = name; self.slot = slot; self.isMe = isMe }
        /// AX slug: lower-cased, spaces → "-".
        public var slug: String { name.lowercased().replacingOccurrences(of: " ", with: "-") }
    }

    public struct SpeakerOption: Sendable, Equatable, Identifiable {
        public var key: SpeakerKey
        public var ordinal: Int
        public var slot: Int
        public var name: String
        public var hasName: Bool
        public var id: SpeakerKey { key }
        public init(key: SpeakerKey, ordinal: Int, slot: Int, name: String, hasName: Bool) {
            self.key = key; self.ordinal = ordinal; self.slot = slot; self.name = name; self.hasName = hasName
        }
    }

    public struct Clip: Sendable, Equatable, Identifiable {
        public var id: String
        public var range: TimeRange
        public var quote: String
        public var peaks: [Float]
        public init(id: String, range: TimeRange, quote: String, peaks: [Float]) {
            self.id = id; self.range = range; self.quote = quote; self.peaks = peaks
        }
    }

    /// The speaker being named, as stored.
    public struct Subject: Sendable, Equatable {
        public var key: SpeakerKey
        public var ordinal: Int
        public var slot: Int
        public var label: SpeakerLabelState
        public var displayName: String
        public var profileID: UUID?
        public var suggestedProfileID: UUID?
        public var cleanSeconds: Double
        public var totalSeconds: Double
        public var canBeRemembered: Bool
        /// False for speakers the user added ("Just this turn") and for voices whose vector was dropped.
        public var hasVector: Bool
        public init(key: SpeakerKey, ordinal: Int, slot: Int, label: SpeakerLabelState, displayName: String,
                    profileID: UUID? = nil, suggestedProfileID: UUID? = nil, cleanSeconds: Double, totalSeconds: Double,
                    canBeRemembered: Bool, hasVector: Bool = true) {
            self.key = key; self.ordinal = ordinal; self.slot = slot; self.label = label; self.displayName = displayName
            self.profileID = profileID; self.suggestedProfileID = suggestedProfileID
            self.cleanSeconds = cleanSeconds; self.totalSeconds = totalSeconds; self.canBeRemembered = canBeRemembered
            self.hasVector = hasVector
        }
    }

    /// Why "Is this Karan?" is only a question (§7): the suggested voice was learned on another device.
    public enum AskContext: Sendable, Equatable {
        /// The suggested profile has trusted samples, but none heard on this recording's capture channel. `channel`
        /// is the channel holding most of them ("iphone", "ipad" or "mac"; ties go to the first by name). The UI turns
        /// it into device copy (`DeviceCopy.askFromOtherDevice`).
        case otherDevice(channel: String)
    }

    public static let maxNameLength = 60

    public let recordingID: UUID
    public let mode: Mode
    public let subject: Subject
    public let profiles: [ProfileOption]            // "me" first, then by name
    public let otherSpeakers: [SpeakerOption]       // correct mode only; speakers not already offered as a saved voice
    public let clips: [Clip]
    /// Set when the subject is suggested as a voice learned only on another device; nil otherwise.
    public let askContext: AskContext?
    /// Turns in the recording (for counting and "Just this turn").
    private let turns: [Turn]
    private let speakerProfiles: [SpeakerKey: UUID]

    public private(set) var selection: Selection = .newPerson
    public var scope: Scope = .allTurns
    /// The Toggle's value; `rememberEffective` is what Save uses.
    public var remember: Bool = true
    public var name: String = "" {
        didSet { if !isSyncingName { syncSelectionToName() } }
    }
    @ObservationIgnored private var isSyncingName = false
    /// Device wording ("Saved on this iPhone only", or the synced variant).
    public let copy: DeviceCopy

    public init(recordingID: UUID, mode: Mode, subject: Subject, profiles: [ProfileOption],
                speakers: [SpeakerOption], speakerProfiles: [SpeakerKey: UUID], turns: [Turn], clips: [Clip],
                askContext: AskContext? = nil, platform: DevicePlatform = .current, syncOn: Bool = false) {
        self.copy = DeviceCopy(platform: platform, syncOn: syncOn)
        self.recordingID = recordingID
        self.askContext = subject.label == .suggested ? askContext : nil
        self.mode = mode
        self.subject = subject
        self.profiles = profiles.sorted { a, b in
            if a.isMe != b.isMe { return a.isMe }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
        self.turns = turns
        self.speakerProfiles = speakerProfiles
        self.clips = clips
        if case .correct = mode {
            let offeredProfiles = Set(profiles.map(\.id))
            self.otherSpeakers = speakers
                .filter { $0.key != subject.key && !(speakerProfiles[$0.key].map(offeredProfiles.contains) ?? false) }
                .sorted { $0.ordinal < $1.ordinal }
        } else {
            self.otherSpeakers = []
        }
        // On whenever the voice could be added somewhere: 5 s to a saved voice (new voices still need 10 s).
        remember = subject.hasVector && subject.cleanSeconds >= MatchPolicy.default.minLearnSeconds
        // Prefill: the suggested profile's name, else empty.
        if mode == .name, let suggested = subject.suggestedProfileID, let p = self.profiles.first(where: { $0.id == suggested }) {
            setName(p.name, selecting: .profile(p.id))
        }
    }

    /// Builds the model from the stored recording and every saved profile.
    public convenience init(recording: Recording, key: SpeakerKey, mode: Mode, profiles: [VoiceProfile],
                            config: AlignmentConfig = .default, platform: DevicePlatform = .current, syncOn: Bool = false) {
        let speaker = recording.speaker(key)
        let subject = Subject(
            key: key, ordinal: speaker?.ordinal ?? 0, slot: speaker?.colourSlot ?? 0, label: speaker?.label ?? .unnamed,
            displayName: speaker?.displayName ?? "Speaker", profileID: speaker?.profile?.id,
            suggestedProfileID: speaker?.label == .suggested ? speaker?.suggestedProfileID : nil,
            cleanSeconds: speaker?.cleanSeconds ?? 0, totalSeconds: speaker?.totalSeconds ?? 0,
            canBeRemembered: speaker?.canBeRemembered ?? false, hasVector: speaker?.vectorData != nil)
        let turns = recording.transcript?.turns ?? []
        let peaks = recording.peaks
        let duration = recording.duration
        let clips = CleanSpeech.listenClips(for: key, turns: turns, max: 2, config: config).enumerated().map { i, clip in
            Clip(id: "\(recording.id.uuidString)-\(key)-\(i)", range: clip.range, quote: clip.quote,
                 peaks: Self.peaks(peaks, duration: duration, range: clip.range))
        }
        let speakerOptions = recording.sortedSpeakers.map {
            SpeakerOption(key: $0.key, ordinal: $0.ordinal, slot: $0.colourSlot, name: $0.displayName, hasName: $0.hasName)
        }
        var links: [SpeakerKey: UUID] = [:]
        for s in recording.speakers { if let p = s.profile { links[s.key] = p.id } }
        let suggested = subject.suggestedProfileID.flatMap { id in profiles.first { $0.id == id } }
        self.init(recordingID: recording.id, mode: mode, subject: subject,
                  profiles: profiles.map { ProfileOption(id: $0.id, name: $0.name, slot: $0.colourSlot, isMe: $0.isMe) },
                  speakers: speakerOptions, speakerProfiles: links, turns: turns, clips: clips,
                  askContext: suggested.flatMap { Self.askContext(for: $0, recordingChannel: recording.captureChannel) },
                  platform: platform, syncOn: syncOn)
    }

    /// `.otherDevice` when `profile` has trusted samples on its model but none heard on `recordingChannel` (§7): the
    /// matcher could then only ask, with reason `otherChannel`. Nil otherwise, and when the other samples' channel is
    /// unknown.
    public static func askContext(for profile: VoiceProfile, recordingChannel: String?,
                                  policy: MatchPolicy = .default) -> AskContext? {
        let trusted = profile.samples.filter {
            $0.embeddingModelKey == profile.embeddingModelKey
                && SampleTrust.isTrusted(origin: $0.origin, speechSeconds: $0.speechSeconds, policy: policy)
        }
        guard !trusted.contains(where: { $0.captureChannel == recordingChannel }) else { return nil }
        var counts: [String: Int] = [:]
        for sample in trusted { if let c = sample.captureChannel { counts[c, default: 0] += 1 } }
        let top = counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.first
        return top.map { .otherDevice(channel: $0.key) }
    }

    /// The other-device question for a suggested voice outside the sheet (the transcript's ask banner, the Voices list):
    /// "Karan was named on your iPhone. … Is this Karan?", or nil when the suggestion is an ordinary ask.
    public static func askPrompt(suggested profile: VoiceProfile?, recordingChannel: String?, copy: DeviceCopy) -> String? {
        guard let profile, case .otherDevice(let channel)? = askContext(for: profile, recordingChannel: recordingChannel),
              let other = DevicePlatform(channel: channel) else { return nil }
        return copy.askFromOtherDevice(name: profile.name, other: other)
    }

    /// The other-device question for the sheet ("Karan was named on your iPhone. … Is this Karan?"), or nil when the
    /// suggestion is not an other-device ask or the channel is not a known device class.
    public var askPrompt: String? {
        guard case .otherDevice(let channel)? = askContext,
              let other = DevicePlatform(channel: channel),
              let suggested = subject.suggestedProfileID,
              let p = profiles.first(where: { $0.id == suggested }) else { return nil }
        return copy.askFromOtherDevice(name: p.name, other: other)
    }

    // MARK: Derived text

    public var title: String { mode == .name ? "Who is this?" : "Who said this?" }

    /// "Speaker 2 · spoke for " — the view appends `spokeFor` in mono.
    public var subtitlePrefix: String { "\(subject.displayName) · spoke for " }
    public var spokeFor: String { DisplayFormat.duration(subject.totalSeconds) }
    public var subtitle: String { subtitlePrefix + spokeFor }

    public var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    public var isNameValid: Bool { !trimmedName.isEmpty && trimmedName.count <= Self.maxNameLength }

    /// Correct mode with a turn: the scope picker is shown.
    public var showsScope: Bool {
        if case .correct(let turnID) = mode { return turnID != nil }
        return false
    }

    public var effectiveScope: Scope { showsScope ? scope : .allTurns }

    /// "All of Karan's turns here"
    public var allTurnsTitle: String { "All of \(subject.displayName)'s turns here" }

    /// Turns that Save relabels.
    public var labelledTurnCount: Int {
        effectiveScope == .justThisTurn ? 1 : turns.filter { $0.effectiveSpeakerKey == subject.key }.count
    }

    /// "Save and label 2 turns" / "Save and label 1 turn"
    public var saveTitle: String {
        let n = labelledTurnCount
        return "Save and label \(n) \(n == 1 ? "turn" : "turns")"
    }

    public var canSave: Bool { isNameValid }

    /// The Remember card is hidden for "Just this turn" and for "same as another speaker here".
    public var showsRemember: Bool {
        if effectiveScope == .justThisTurn { return false }
        if case .speaker = selection { return false }
        return true
    }

    /// The toggle is disabled (and off) under ~5 s of clear speech for a saved voice, and under ~10 s for a new one.
    public var rememberEnabled: Bool {
        switch selection {
        case .profile: subject.hasVector && subject.cleanSeconds >= MatchPolicy.default.minLearnSeconds
        case .newPerson, .speaker: subject.canBeRemembered
        }
    }

    /// What the toggle shows, and what Save passes as `remember` except in the case `rememberForSave` covers.
    public var rememberEffective: Bool { rememberEnabled && remember }

    /// True when the user switched an enabled Remember toggle off (D14: then nothing is stored).
    var rememberSwitchedOff: Bool { rememberEnabled && !remember }

    /// What Save passes as `remember`. A new person under 10 s has the toggle disabled only because a new voice
    /// needs 10 s, not because the user opted out: the store still creates no profile (it checks 10 s itself), but
    /// it keeps this voice as a negative (5 s) for the person it was wrongly labelled or suggested as.
    var rememberForSave: Bool {
        if case .newPerson = selection, !rememberEnabled {
            return remember && subject.hasVector && subject.cleanSeconds >= MatchPolicy.default.minLearnSeconds
        }
        return rememberEffective
    }

    public var rememberHelp: String {
        if !subject.hasVector {
            return "Voices can only be remembered from speakers Transcribe separated."
        }
        if case .profile(let id) = selection, let p = profiles.first(where: { $0.id == id }) {
            if subject.cleanSeconds < MatchPolicy.default.minLearnSeconds {
                return "Needs about 5 seconds of clear speech to add to \(p.name)'s voice. \(subject.displayName) spoke for \(DisplayFormat.duration(subject.cleanSeconds))."
            }
            return "Adds this recording to \(p.name)'s voice."
        }
        if !subject.canBeRemembered {
            return "Needs about 10 seconds of clear speech to remember a voice. \(subject.displayName) spoke for \(DisplayFormat.duration(subject.cleanSeconds))."
        }
        let who = isNameValid ? trimmedName : "them"
        return copy.rememberHelp(who: who)
    }

    /// Slot colour for the dot inside the name field: the selected voice's colour, else the speaker's.
    public var fieldSlot: Int {
        switch selection {
        case .profile(let id): profiles.first { $0.id == id }?.slot ?? subject.slot
        case .speaker(let key): otherSpeakers.first { $0.key == key }?.slot ?? subject.slot
        case .newPerson: subject.slot
        }
    }

    // MARK: Selection

    public func select(_ selection: Selection) {
        switch selection {
        case .newPerson:
            // Keep typed text unless it names a saved voice or another speaker.
            if case .newPerson = self.selection {} else { setName("", selecting: .newPerson) }
            self.selection = .newPerson
        case .profile(let id):
            guard let p = profiles.first(where: { $0.id == id }) else { return }
            setName(p.name, selecting: selection)
        case .speaker(let key):
            guard let s = otherSpeakers.first(where: { $0.key == key }) else { return }
            setName(s.name, selecting: selection)
        }
    }

    public func clearName() {
        setName("", selecting: .newPerson)
    }

    private func setName(_ value: String, selecting s: Selection) {
        isSyncingName = true
        name = value
        isSyncingName = false
        selection = s
    }

    /// Typing a saved voice's name selects it; anything else is a new person.
    private func syncSelectionToName() {
        let typed = trimmedName
        if let p = profiles.first(where: { VoiceProfile.nameMatches($0.name, typed) }) {
            selection = .profile(p.id)
        } else if case .speaker(let key) = selection,
                  otherSpeakers.first(where: { $0.key == key })?.name.caseInsensitiveCompare(typed) == .orderedSame {
            // Still the other speaker's name.
        } else {
            selection = .newPerson
        }
    }

    // MARK: Save

    /// What Save will write (pure, tested).
    public enum Action: Sendable, Equatable {
        case name(NameTarget, remember: Bool)
        case confirmSuggestion
        case reassignTurn(UUID, TurnTarget)
        case reassignAllTurns([UUID], TurnTarget)
        case none
    }

    public var action: Action {
        guard canSave else { return .none }
        if effectiveScope == .justThisTurn, case .correct(let turnID?) = mode {
            guard let turn = turns.first(where: { $0.id == turnID }) else { return .none }
            switch selection {
            case .speaker(let key):
                return key == turn.effectiveSpeakerKey ? .none : .reassignTurn(turnID, .speaker(key))
            case .profile(let id):
                // Reuse a speaker in this recording that is already this person.
                if let key = speakerProfiles.first(where: { $0.value == id })?.key {
                    return key == turn.effectiveSpeakerKey ? .none : .reassignTurn(turnID, .speaker(key))
                }
                return .reassignTurn(turnID, .profile(id))
            case .newPerson:
                return .reassignTurn(turnID, .newName(trimmedName))
            }
        }
        switch selection {
        case .speaker(let key):
            let ids = turns.filter { $0.effectiveSpeakerKey == subject.key }.map(\.id)
            return ids.isEmpty ? .none : .reassignAllTurns(ids, .speaker(key))
        case .profile(let id):
            // Yes to the suggestion, unless Remember was switched off: then name the voice without storing a sample.
            if subject.label == .suggested, subject.suggestedProfileID == id, !rememberSwitchedOff { return .confirmSuggestion }
            return .name(.existing(profileID: id), remember: rememberForSave)
        case .newPerson:
            return .name(.newPerson(name: trimmedName), remember: rememberForSave)
        }
    }

    /// Writes through the store. Returns the store's result when a name was saved.
    @discardableResult
    public func save(using store: any LibraryStoring) throws -> NameResult? {
        switch action {
        case .none:
            return nil
        case .confirmSuggestion:
            return try store.confirmSuggestion(recordingID: recordingID, key: subject.key)
        case .name(let target, let remember):
            return try store.nameSpeaker(recordingID: recordingID, key: subject.key, as: target, remember: remember)
        case .reassignTurn(let turnID, let target):
            try store.reassignTurn(recordingID: recordingID, turnID: turnID, to: target)
            return nil
        case .reassignAllTurns(let ids, let target):
            if case .speaker(let key) = target {
                // One transaction that also rolls back what this speaker fed a wrongly matched voice.
                try store.moveAllTurns(recordingID: recordingID, from: subject.key, to: key)
            } else {
                for id in ids { try store.reassignTurn(recordingID: recordingID, turnID: id, to: target) }
            }
            return nil
        }
    }

    /// User-facing text for a save error.
    public static func message(for error: any Error) -> String {
        switch error {
        case StoreError.invalidName: "Enter a name."
        case StoreError.notFound: "This recording or voice no longer exists."
        case StoreError.notImplemented: "Saving isn't available yet."
        default: "Couldn't save. Please try again."
        }
    }

    /// Note after a save that kept the name but stored no voice sample, else nil.
    public static func note(for result: NameResult?) -> String? {
        switch result?.skipReason {
        case .tooLittleSpeech: "Name saved. Not enough clear speech to remember the voice yet."
        case .duplicate, .rememberOff, .noVector, nil: nil
        }
    }

    // MARK: Helpers

    /// The recording's peak bins that fall inside `range` (at least one bin).
    public static func peaks(_ peaks: [Float], duration: TimeInterval, range: TimeRange) -> [Float] {
        guard !peaks.isEmpty, duration > 0 else { return [] }
        let n = peaks.count
        let a = Swift.max(0, Swift.min(n - 1, Int((range.start / duration * Double(n)).rounded(.down))))
        let b = Swift.max(a + 1, Swift.min(n, Int((range.end / duration * Double(n)).rounded(.up))))
        return Array(peaks[a..<b])
    }
}
