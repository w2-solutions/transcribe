import Foundation
import SwiftData
import TranscribeCore
import TranscribeKit

/// Seeded app states for the simulator, UI tests and Kit tests (§7.5).
/// Seeds insert `@Model` objects directly — the single documented exception to "writes go through LibraryStore".
/// Applying a seed first wipes the store, so a seed always describes the whole library.
public enum Seeds {
    // MARK: Fixed ids

    public enum ID {
        public static let recordingA = UUID(uuidString: "A0000000-0000-4000-8000-00000000000A")!
        public static let recordingB = UUID(uuidString: "A0000000-0000-4000-8000-00000000000B")!
        public static let recordingC = UUID(uuidString: "A0000000-0000-4000-8000-00000000000C")!
        public static let recordingD = UUID(uuidString: "A0000000-0000-4000-8000-00000000000D")!
        public static let recordingE = UUID(uuidString: "A0000000-0000-4000-8000-00000000000E")!
        public static let recordingF = UUID(uuidString: "A0000000-0000-4000-8000-00000000000F")!
        public static let recordingG = UUID(uuidString: "A0000000-0000-4000-8000-000000000010")!
        public static let liam = UUID(uuidString: "B0000000-0000-4000-8000-000000000001")!
        public static let karan = UUID(uuidString: "B0000000-0000-4000-8000-000000000002")!
        // `voiceGroups`
        public static let tom = UUID(uuidString: "B0000000-0000-4000-8000-000000000003")!
        /// Tom and Liam on this device (no channel until the launch stamp).
        public static let recordingT1 = UUID(uuidString: "A0000000-0000-4000-8000-000000000011")!
        /// Tom and Liam heard on an iPad: the row synced here, its audio did not.
        public static let recordingT2 = UUID(uuidString: "A0000000-0000-4000-8000-000000000012")!
        /// A source recording that exists nowhere (deleted after the sample was taken).
        public static let goneRecording = UUID(uuidString: "A0000000-0000-4000-8000-0000000000FF")!
        /// Tom's ten samples, in `sortedSamples` order. Their uuidString order is the same, so where the grouping ties
        /// on closeness to the centroid, representatives come in this order.
        public static let tomSamples: [UUID] = (0..<10).map {
            UUID(uuidString: "C0000000-0000-4000-8000-00000000000\($0)")!
        }
        /// The seeded "Close" label on Tom's first group.
        public static let closeLabel = UUID(uuidString: "D0000000-0000-4000-8000-000000000001")!
    }

    // MARK: Dates (Calendar.current, device time zone)

    public enum Dates {
        /// Wed 18 Nov 2026 14:29
        public static var a: Date { date(18, 14, 29) }
        /// Wed 18 Nov 2026 14:24
        public static var b: Date { date(18, 14, 24) }
        /// Tue 17 Nov 2026 09:02
        public static var c: Date { date(17, 9, 2) }
        /// Thu 19 Nov 2026 10:05
        public static var d: Date { date(19, 10, 5) }
        /// Fri 20 Nov 2026 11:15
        public static var g: Date { date(20, 11, 15) }
        /// Liam named: 17 Nov 09:20
        public static var liamNamed: Date { date(17, 9, 20) }
        /// Karan named: 18 Nov 14:25
        public static var karanNamed: Date { date(18, 14, 25) }
        /// T1: Tue 17 Nov 10:30
        public static var t1: Date { date(17, 10, 30) }
        /// T2 (iPad): Tue 17 Nov 11:40
        public static var t2: Date { date(17, 11, 40) }
        /// Tom named: 17 Nov 12:00; his sample k is added at 12:0k, the "Close" label saved at 12:30. All before the
        /// UI-test clock (18 Nov 14:31).
        public static var tomNamed: Date { date(17, 12, 0) }

        static func date(_ day: Int, _ hour: Int, _ minute: Int) -> Date {
            Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
        }
    }

    /// Documented counts per seed (checked by SkeletonKitTests).
    public static func expectedCounts(_ seed: SeedName) -> (recordings: Int, profiles: Int, samples: Int) {
        switch seed {
        case .firstRun, .empty: (0, 0, 0)
        case .library, .karanFromIPhone: (3, 2, 5)
        case .twoSpeakersUnnamed: (1, 1, 3)
        case .askKaran: (4, 2, 5)
        case .shortKaran: (4, 2, 5)
        case .processingHeld: (1, 2, 5)
        case .failedProcessing: (1, 0, 0)
        case .voiceGroups: (5, 3, 15)
        }
    }

    @MainActor public static func apply(_ seed: SeedName, context: ModelContext, paths: AppPaths, clock: AppClock) throws {
        try wipe(context)
        try paths.prepare()
        var s = SeedBuilder(context: context, paths: paths)
        switch seed {
        case .firstRun, .empty:
            break
        case .library:
            try s.library()
        case .twoSpeakersUnnamed:
            try s.twoSpeakersUnnamed()
        case .askKaran:
            try s.library()
            try s.askKaranD()
        case .shortKaran:
            try s.library()
            try s.shortKaranG()
        case .karanFromIPhone:
            try s.library()
            s.karanHeardOnIPhone()
        case .processingHeld:
            try s.profiles()
            try s.processingHeldE()
        case .failedProcessing:
            try s.failedF()
        case .voiceGroups:
            try s.library()
            try s.tomGroups()
        }
        s.linkSamplesToSpeakers()
        try context.save()
    }

    @MainActor static func wipe(_ context: ModelContext) throws {
        for label in try context.fetch(FetchDescriptor<VoiceGroupLabel>()) { context.delete(label) }
        for negative in try context.fetch(FetchDescriptor<VoiceNegative>()) { context.delete(negative) }
        for sample in try context.fetch(FetchDescriptor<VoiceSample>()) { context.delete(sample) }
        for speaker in try context.fetch(FetchDescriptor<RecordingSpeaker>()) { context.delete(speaker) }
        for recording in try context.fetch(FetchDescriptor<Recording>()) { context.delete(recording) }
        for profile in try context.fetch(FetchDescriptor<VoiceProfile>()) { context.delete(profile) }
        for folder in try context.fetch(FetchDescriptor<Folder>()) { context.delete(folder) }
        try context.save()
    }
}

/// Builds the seed objects.
@MainActor
struct SeedBuilder {
    let context: ModelContext
    let paths: AppPaths
    var liam: VoiceProfile?
    var karan: VoiceProfile?
    var tom: VoiceProfile?
    /// (sample, recording id, speaker key) for linking sourceSpeakerID once speakers exist.
    var pendingLinks: [(VoiceSample, UUID, SpeakerKey)] = []

    static let modelKey = EmbeddingModelID.fake.key
    static let asrModelID = "fake-parakeet"

    init(context: ModelContext, paths: AppPaths) { self.context = context; self.paths = paths }

    // MARK: Scenarios

    mutating func library() throws {
        try profiles()
        try recordingA()
        try recordingB(id: Seeds.ID.recordingB, named: true)
        try recordingC()
    }

    mutating func twoSpeakersUnnamed() throws {
        try liamProfile()
        try recordingB(id: Seeds.ID.recordingB, named: false)
    }

    mutating func profiles() throws {
        try liamProfile()
        try karanProfile()
    }

    mutating func liamProfile() throws {
        let p = VoiceProfile(id: Seeds.ID.liam, name: "Liam", colourSlot: 0, embeddingModelKey: Self.modelKey, now: Seeds.Dates.liamNamed)
        p.isMe = true
        context.insert(p)
        liam = p
        let base = SyntheticVoices.base(.liam)
        addSample(to: p, vector: base, origin: .named, added: Seeds.Dates.liamNamed, seconds: 12.0,
                  recording: Seeds.ID.recordingC, key: "S1", clip: TimeRange(start: 1.0, end: 5.8),
                  quote: "Morning. Before we start, can we go through what's left on the list from last week?")
        addSample(to: p, vector: base, origin: .confirmed, added: Seeds.Dates.b, seconds: 11.0,
                  recording: Seeds.ID.recordingB, key: "S1", clip: TimeRange(start: 0.6, end: 4.9),
                  quote: "Hey, Karan. Um, I just want to test out if this transcription app works.")
        addSample(to: p, vector: base, origin: .confirmed, added: Seeds.Dates.a, seconds: 14.1,
                  recording: Seeds.ID.recordingA, key: "S1", clip: TimeRange(start: 0.6, end: 3.4),
                  quote: "Just checking if it remembers who is speaking")
    }

    mutating func karanProfile() throws {
        let p = VoiceProfile(id: Seeds.ID.karan, name: "Karan", colourSlot: 1, embeddingModelKey: Self.modelKey, now: Seeds.Dates.karanNamed)
        context.insert(p)
        karan = p
        let base = SyntheticVoices.base(.karan)
        addSample(to: p, vector: base, origin: .named, added: Seeds.Dates.karanNamed, seconds: 11.5,
                  recording: Seeds.ID.recordingB, key: "S2", clip: TimeRange(start: 7.05, end: 10.0),
                  quote: "Uh yes, testing the transcription app.")
        addSample(to: p, vector: base, origin: .named, added: Seeds.Dates.a, seconds: 4.6,
                  recording: Seeds.ID.recordingA, key: "S2", clip: TimeRange(start: 10.8, end: 14.8),
                  quote: "And now this is me starting to speak…")
    }

    /// A (0:20): Conversation A, both auto-labelled, unseen result.
    mutating func recordingA() throws {
        let r = try makeRecording(id: Seeds.ID.recordingA, createdAt: Seeds.Dates.a, turns: SeedContent.conversationA,
                                  duration: SeedContent.conversationADuration, stage: .ready, speakers: true)
        r.hasUnseenResult = true
        addSpeaker(r, key: "S1", ordinal: 1, slot: 0, clean: 14.1, total: 14.5,
                   vector: SyntheticVoices.vector(near: .liam, cosine: 0.82, variant: 3),
                   label: .autoLabelled, profile: liam, score: 0.82, margin: 0.82)
        addSpeaker(r, key: "S2", ordinal: 2, slot: 1, clean: 4.6, total: 4.8,
                   vector: SyntheticVoices.vector(near: .karan, cosine: 0.71, variant: 4),
                   label: .autoLabelled, profile: karan, score: 0.71, margin: 0.71)
        finish(r)
    }

    /// B (0:24): Conversation B. `named` → S1 Liam / S2 Karan (favourite); otherwise B′ with both unnamed.
    mutating func recordingB(id: UUID, named: Bool) throws {
        let r = try makeRecording(id: id, createdAt: Seeds.Dates.b, turns: SeedContent.conversationB,
                                  duration: SeedContent.conversationBDuration, stage: .ready, speakers: true)
        if named {
            r.isFavourite = true
            addSpeaker(r, key: "S1", ordinal: 1, slot: 0, clean: 11.0, total: 11.4,
                       vector: SyntheticVoices.vector(near: .liam, cosine: 0.90, variant: 1), label: .named, profile: liam)
            addSpeaker(r, key: "S2", ordinal: 2, slot: 1, clean: 11.5, total: 13.0,
                       vector: SyntheticVoices.vector(near: .karan, cosine: 0.90, variant: 2), label: .named, profile: karan)
        } else {
            addSpeaker(r, key: "S1", ordinal: 1, slot: 0, clean: 11.0, total: 11.4,
                       vector: SyntheticVoices.vector(near: .liam, cosine: 0.90, variant: 11), label: .unnamed)
            addSpeaker(r, key: "S2", ordinal: 2, slot: 1, clean: 11.5, total: 13.0,
                       vector: SyntheticVoices.vector(near: .karan, cosine: 0.90, variant: 12), label: .unnamed)
        }
        finish(r)
    }

    /// C (12:48): S1 Liam (named) and an unnamed S2 with 42 s of clean speech.
    mutating func recordingC() throws {
        let turns = SeedContent.conversationC
        let r = try makeRecording(id: Seeds.ID.recordingC, createdAt: Seeds.Dates.c, turns: turns,
                                  duration: SeedContent.conversationCDuration, stage: .ready, speakers: true,
                                  persons: ["S1": .liam, "S2": .stranger])
        let s1Total = turns.filter { $0.key == "S1" }.reduce(0) { $0 + $1.segment.duration }
        let s2Total = turns.filter { $0.key == "S2" }.reduce(0) { $0 + $1.segment.duration }
        addSpeaker(r, key: "S1", ordinal: 1, slot: 0, clean: (s1Total * 0.9).rounded(), total: s1Total.rounded(),
                   vector: SyntheticVoices.vector(near: .liam, cosine: 0.88, variant: 21), label: .named, profile: liam)
        addSpeaker(r, key: "S2", ordinal: 2, slot: 1, clean: 42, total: s2Total.rounded(),
                   vector: SyntheticVoices.vector(near: .stranger, cosine: 0.9, variant: 20), label: .unnamed)
        finish(r)
    }

    /// D (0:24, Thu 19 Nov 10:05): B's content; S1 auto Liam, S2 suggested Karan (0.47).
    mutating func askKaranD() throws {
        let r = try makeRecording(id: Seeds.ID.recordingD, createdAt: Seeds.Dates.d, turns: SeedContent.conversationB,
                                  duration: SeedContent.conversationBDuration, stage: .ready, speakers: true)
        r.hasUnseenResult = true
        addSpeaker(r, key: "S1", ordinal: 1, slot: 0, clean: 11.0, total: 11.4,
                   vector: SyntheticVoices.vector(near: .liam, cosine: 0.82, variant: 5),
                   label: .autoLabelled, profile: liam, score: 0.82, margin: 0.82)
        let s2 = addSpeaker(r, key: "S2", ordinal: 2, slot: 1, clean: 11.5, total: 13.0,
                            vector: SyntheticVoices.vector(near: .karan, cosine: 0.47, variant: 6), label: .suggested)
        s2.suggestedProfileID = Seeds.ID.karan
        s2.matchScore = 0.47
        finish(r)
    }

    /// G (0:24, Fri 20 Nov 11:15): B's content; S1 Liam (named), S2 unnamed with 6.2 s of clean speech: Karan in
    /// another setting, too short for a new voice but enough to add to a saved one.
    mutating func shortKaranG() throws {
        let r = try makeRecording(id: Seeds.ID.recordingG, createdAt: Seeds.Dates.g, turns: SeedContent.conversationB,
                                  duration: SeedContent.conversationBDuration, stage: .ready, speakers: true)
        addSpeaker(r, key: "S1", ordinal: 1, slot: 0, clean: 11.0, total: 11.4,
                   vector: SyntheticVoices.vector(near: .liam, cosine: 0.90, variant: 1), label: .named, profile: liam)
        addSpeaker(r, key: "S2", ordinal: 2, slot: 1, clean: 6.2, total: 7.0,
                   vector: SyntheticVoices.mix([(.karan, 0.35)], setting: (56, 0.7), variant: 55), label: .unnamed)
        finish(r)
    }

    /// `karanFromIPhone` (§7): Karan's samples and the recordings they came from (A and B) were heard on an iPhone.
    /// Everything else is left without a channel, so the launch stamp puts it on this device's channel (Liam's
    /// samples follow their source recordings: A and B on the iPhone, C on this device). On a Mac, a new recording of
    /// Karan can then only ask "Is this Karan?" (reason `otherChannel`), while Liam still auto-labels from C.
    func karanHeardOnIPhone() {
        guard let karan else { return }
        let sources = Set(karan.samples.compactMap(\.sourceRecordingID))
        for sample in karan.samples { sample.captureChannel = CaptureChannel.iphone }
        let recordings = (try? context.fetch(FetchDescriptor<Recording>())) ?? []
        for r in recordings where sources.contains(r.id) { r.captureChannel = CaptureChannel.iphone }
    }

    /// One of Tom's seeded samples: its setting axis (57 close, 58 far, 59 on speaker), residual variant, origin, source
    /// (recording and clip; T1 and T2 clips lie in S2's first turn, words 7.05–14.5) and quote.
    private struct TomSample {
        let axis: Int, variant: Int, origin: SampleOrigin, seconds: Double
        let recording: UUID, clip: TimeRange?, quote: String
    }

    /// Tom's ten samples, index = `sortedSamples` index (voice sample groups §8, R6). Every vector is
    /// `mix([(.stranger, 0.6)], setting: (axis, 0.7))`: 0.85 within a setting, 0.36 across. On this device: Close
    /// {0, 1, 5}, Far {2, 3, 4} and On speaker {6, 7}; 8 and 9 were heard on an iPad. The honest non-playable states:
    /// 3's recording is gone, 4 has no clip, 8 and 9's audio is on the iPad.
    private static let tomSamples: [TomSample] = [
        TomSample(axis: 57, variant: 8, origin: .named, seconds: 12.0, recording: Seeds.ID.recordingT1,
                  clip: TimeRange(start: 7.05, end: 11.5), quote: "Can you pass me that?"),
        TomSample(axis: 57, variant: 9, origin: .confirmed, seconds: 11.0, recording: Seeds.ID.recordingT1,
                  clip: TimeRange(start: 9.0, end: 13.0), quote: "I'll be there in five."),
        TomSample(axis: 58, variant: 13, origin: .confirmed, seconds: 10.5, recording: Seeds.ID.recordingT1,
                  clip: TimeRange(start: 7.05, end: 10.4), quote: "Is anyone in the kitchen?"),
        TomSample(axis: 58, variant: 14, origin: .confirmed, seconds: 10.2, recording: Seeds.ID.goneRecording,
                  clip: TimeRange(start: 1.0, end: 4.0), quote: "I said the blue one!"),
        TomSample(axis: 58, variant: 15, origin: .confirmed, seconds: 11.4, recording: Seeds.ID.recordingT1,
                  clip: nil, quote: "Can you hear me from there?"),
        TomSample(axis: 57, variant: 10, origin: .confirmed, seconds: 10.8, recording: Seeds.ID.recordingT1,
                  clip: TimeRange(start: 10.2, end: 14.2), quote: "Sounds good to me."),
        TomSample(axis: 59, variant: 16, origin: .confirmed, seconds: 10.6, recording: Seeds.ID.recordingT1,
                  clip: TimeRange(start: 7.6, end: 11.0), quote: "You're breaking up a bit."),
        TomSample(axis: 59, variant: 17, origin: .strongMatch, seconds: 10.1, recording: Seeds.ID.recordingT1,
                  clip: TimeRange(start: 11.0, end: 14.4), quote: "Can you hear me now?"),
        TomSample(axis: 57, variant: 18, origin: .confirmed, seconds: 11.2, recording: Seeds.ID.recordingT2,
                  clip: TimeRange(start: 7.05, end: 11.0), quote: "Let's do it tomorrow."),
        TomSample(axis: 57, variant: 19, origin: .confirmed, seconds: 10.9, recording: Seeds.ID.recordingT2,
                  clip: TimeRange(start: 10.2, end: 14.4), quote: "That works for me."),
    ]

    /// `voiceGroups`: Tom, heard in T1 on this device and T2 on an iPad, with ten samples in three settings and a saved
    /// "Close" label on the first. The label has no channel (a seed does not know the run's), so the launch stamp
    /// gives it this device's, as it does T1 and the samples taken from it; T2 and its samples stay on `ipad`.
    mutating func tomGroups() throws {
        let p = VoiceProfile(id: Seeds.ID.tom, name: "Tom", colourSlot: 2, embeddingModelKey: Self.modelKey,
                             now: Seeds.Dates.tomNamed)
        context.insert(p)
        tom = p
        try tomRecording(id: Seeds.ID.recordingT1, createdAt: Seeds.Dates.t1, title: "Kitchen chat", channel: nil,
                         tomVariant: 26)
        let t2 = try tomRecording(id: Seeds.ID.recordingT2, createdAt: Seeds.Dates.t2, title: "Video call",
                                  channel: CaptureChannel.ipad, tomVariant: 27)
        // Only the row reached this device: the WAV stays on the iPad (the peaks came with the row).
        try FileManager.default.removeItem(at: paths.audioURL(fileName: t2.audioFileName))

        var samples: [VoiceSample] = []
        for (k, s) in Self.tomSamples.enumerated() {
            samples.append(addSample(
                to: p, id: Seeds.ID.tomSamples[k],
                vector: SyntheticVoices.mix([(.stranger, 0.6)], setting: (s.axis, 0.7), variant: s.variant),
                origin: s.origin, added: Seeds.Dates.date(17, 12, k), seconds: s.seconds,
                recording: s.recording, key: "S2", clip: s.clip, quote: s.quote,
                channel: s.recording == Seeds.ID.recordingT2 ? CaptureChannel.ipad : nil))
        }

        // The anchor is the group's member vectors as grouping decodes them, members by id (R1, R6).
        let close = [0, 1, 5].map { samples[$0] }.sorted { $0.id.uuidString < $1.id.uuidString }
        let label = VoiceGroupLabel(id: Seeds.ID.closeLabel, text: "Close", createdAt: Seeds.Dates.date(17, 12, 30),
                                    embeddingModelKey: Self.modelKey, captureChannel: "",
                                    anchors: close.compactMap(\.vector))
        context.insert(label)
        label.profile = p
    }

    /// A recording of Liam (S1) and Tom (S2, a stranger's voice), both named, on B's content.
    @discardableResult
    func tomRecording(id: UUID, createdAt: Date, title: String, channel: String?, tomVariant: Int) throws -> Recording {
        let r = try makeRecording(id: id, createdAt: createdAt, turns: SeedContent.conversationB,
                                  duration: SeedContent.conversationBDuration, stage: .ready, speakers: true,
                                  persons: ["S1": .liam, "S2": .stranger])
        r.title = title
        r.captureChannel = channel
        addSpeaker(r, key: "S1", ordinal: 1, slot: 0, clean: 11.0, total: 11.4,
                   vector: SyntheticVoices.vector(near: .liam, cosine: 0.90, variant: 1), label: .named, profile: liam)
        addSpeaker(r, key: "S2", ordinal: 2, slot: 2, clean: 11.5, total: 13.0,
                   vector: SyntheticVoices.mix([(.stranger, 0.6)], setting: (57, 0.7), variant: tomVariant),
                   label: .named, profile: tom)
        finish(r)
        return r
    }

    /// E: B's date and content, held at `.separating` with speaker-less paragraphs.
    mutating func processingHeldE() throws {
        let r = try makeRecording(id: Seeds.ID.recordingE, createdAt: Seeds.Dates.b, turns: SeedContent.conversationB,
                                  duration: SeedContent.conversationBDuration, stage: .separating, speakers: false)
        r.embeddingModelKey = nil
        finish(r)
    }

    /// F (0:24): failed, paragraphs present.
    mutating func failedF() throws {
        let r = try makeRecording(id: Seeds.ID.recordingF, createdAt: Seeds.Dates.b, turns: SeedContent.conversationB,
                                  duration: SeedContent.conversationBDuration, stage: .failed, speakers: false)
        r.failureMessage = "Couldn't finish processing"
        r.attemptCount = 3
        r.embeddingModelKey = nil
        finish(r)
    }

    // MARK: Helpers

    func makeRecording(id: UUID, createdAt: Date, turns: [ScriptTurn], duration: TimeInterval, stage: RecordingStage,
                       speakers: Bool, persons: [SpeakerKey: SyntheticPerson] = ["S1": .liam, "S2": .karan]) throws -> Recording {
        let paths = self.paths
        let fileName = paths.newAudioFileName(for: id)
        let audioSegments = turns.map { ($0.segment, persons[$0.key] ?? .stranger) }
        let peaks = try SyntheticAudio.write(to: paths.audioURL(fileName: fileName), duration: duration, segments: audioSegments)
        let doc = TranscriptDocument(words: SeedContent.allWords(turns),
                                     turns: speakers ? SeedContent.speakerTurns(turns) : SeedContent.paragraphs(turns),
                                     asrModelID: Self.asrModelID)
        let r = Recording(id: id, createdAt: createdAt, audioFileName: fileName, source: .microphone)
        context.insert(r)
        r.duration = duration
        r.peaks = peaks
        r.stage = stage
        r.transcriptData = try doc.encoded()
        r.asrModelID = Self.asrModelID
        r.embeddingModelKey = Self.modelKey
        r.previewText = String(doc.plainText.replacingOccurrences(of: "\n", with: " ").prefix(200))
        return r
    }

    @discardableResult
    func addSpeaker(_ r: Recording, key: SpeakerKey, ordinal: Int, slot: Int, clean: Double, total: Double,
                    vector: VoiceVector, label: SpeakerLabelState, profile: VoiceProfile? = nil,
                    score: Double? = nil, margin: Double? = nil) -> RecordingSpeaker {
        let s = RecordingSpeaker(key: key, ordinal: ordinal, colourSlot: slot)
        context.insert(s)
        s.recording = r
        s.cleanSeconds = clean
        s.totalSeconds = total
        s.turnCount = r.transcript?.turns.filter { $0.speakerKey == key }.count ?? 0
        s.vectorData = vector.packed
        s.embeddingModelKey = Self.modelKey
        s.label = label
        s.profile = profile
        s.matchScore = score
        s.matchMargin = margin
        return s
    }

    /// `clip` nil leaves the sample without a clip; `channel` nil leaves it to the launch stamp.
    @discardableResult
    mutating func addSample(to p: VoiceProfile, id: UUID = UUID(), vector: VoiceVector, origin: SampleOrigin, added: Date,
                            seconds: Double, recording: UUID, key: SpeakerKey, clip: TimeRange?, quote: String,
                            channel: String? = nil) -> VoiceSample {
        let sample = VoiceSample(id: id, vector: vector, embeddingModelKey: Self.modelKey, origin: origin, addedAt: added,
                                 speechSeconds: seconds)
        context.insert(sample)
        sample.profile = p
        sample.sourceRecordingID = recording
        sample.clipStart = clip?.start
        sample.clipEnd = clip?.end
        sample.quote = quote
        sample.captureChannel = channel
        pendingLinks.append((sample, recording, key))
        return sample
    }

    /// searchText = lowercased title + transcript + speaker names.
    func finish(_ r: Recording) {
        var parts: [String] = []
        if let title = r.title { parts.append(title) }
        if let doc = r.transcript { parts.append(doc.plainText) }
        parts.append(contentsOf: r.sortedSpeakers.filter(\.hasName).map(\.displayName))
        r.searchText = parts.joined(separator: "\n").lowercased()
    }

    /// Sets VoiceSample.sourceSpeakerID for samples whose source recording exists in this seed.
    func linkSamplesToSpeakers() {
        guard let speakers = try? context.fetch(FetchDescriptor<RecordingSpeaker>()) else { return }
        for (sample, recordingID, key) in pendingLinks {
            if let speaker = speakers.first(where: { $0.recording?.id == recordingID && $0.key == key }) {
                sample.sourceSpeakerID = speaker.id
            }
        }
    }
}
