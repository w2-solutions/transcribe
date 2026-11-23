import Foundation
import SwiftData
import Synchronization
import Testing
import TranscribeCore
@testable import TranscribeFakes
@testable import TranscribeKit

/// A clock that moves on one second every time it is read, so stored items get distinct dates.
final class TickingClock: Sendable {
    private let ticks = Mutex(0)
    let start: Date
    init(start: Date) { self.start = start }
    var clock: AppClock {
        AppClock { [self] in start.addingTimeInterval(Double(ticks.withLock { $0 += 1; return $0 }))}
    }
}

@Suite("Voice learning: store")
@MainActor
struct VoiceLearningStoreTests {
    let d = Seeds.ID.recordingD

    func allNegatives(_ h: WP3Harness) throws -> [VoiceNegative] { try h.context.fetch(FetchDescriptor<VoiceNegative>()) }

    /// A ready recording with one speaker, optionally with a decision applied.
    func oneSpeaker(_ h: WP3Harness, _ vector: VoiceVector, clean: Double, decision: MatchDecision? = nil,
                    coherence: Float? = 1, createdAt: Date = Seeds.Dates.d) throws -> UUID {
        try h.readyRecording(turns: SeedContent.conversationA,
                             drafts: [WP3Docs.draft("S1", 1, clean: clean, vector: vector, coherence: coherence)],
                             createdAt: createdAt, decisions: decision.map { ["S1": $0] } ?? [:])
    }

    // MARK: Positives

    @Test func missAsExistingStoresShortCorrectedSampleFromFiveSeconds() throws {
        let h = try WP3Harness()
        defer { h.cleanup() }
        try h.seed(.library)
        let karan = try #require(try h.profile(named: "Karan"))
        let id = try oneSpeaker(h, SyntheticVoices.mix([(.karan, 0.35)], setting: (57, 0.7), variant: 45), clean: 6)
        let s1 = try #require(try h.recording(id).speaker("S1"))
        let result = try h.store.nameSpeaker(recordingID: id, key: "S1", as: .existing(profileID: karan.id), remember: true)
        #expect(result == NameResult(profileID: karan.id, sampleStored: true, skipReason: nil))
        let sample = try #require(karan.samples.first { $0.sourceSpeakerID == s1.id })
        #expect(sample.origin == .corrected && sample.speechSeconds == 6 && !sample.isTrusted)
        #expect(karan.samples.count == 3)
    }

    @Test func missUnderFiveSecondsStoresNothing() throws {
        let h = try WP3Harness()
        defer { h.cleanup() }
        try h.seed(.library)
        let karan = try #require(try h.profile(named: "Karan"))
        let samples = try h.count(VoiceSample.self)
        let id = try oneSpeaker(h, SyntheticVoices.mix([(.karan, 0.35)], setting: (57, 0.7), variant: 45), clean: 4.9)
        let result = try h.store.nameSpeaker(recordingID: id, key: "S1", as: .existing(profileID: karan.id), remember: true)
        #expect(result == NameResult(profileID: karan.id, sampleStored: false, skipReason: .tooLittleSpeech(seconds: 4.9)))
        #expect(try h.count(VoiceSample.self) == samples)
        #expect(try h.count(VoiceNegative.self) == 0)
    }

    // MARK: Negatives

    @Test func wrongSuggestionNamedAsSomeoneElseStoresNegative() throws {
        let h = try WP3Harness()
        defer { h.cleanup() }
        try h.seed(.askKaran)
        let liam = try #require(try h.profile(named: "Liam"))
        let karan = try #require(try h.profile(named: "Karan"))
        let s2 = try #require(try h.recording(d).speaker("S2"))
        _ = try h.store.nameSpeaker(recordingID: d, key: "S2", as: .existing(profileID: liam.id), remember: true)
        #expect(karan.negatives.count == 1 && karan.negatives[0].sourceSpeakerID == s2.id)
        #expect(karan.negatives[0].sourceRecordingID == d)
        #expect(liam.samples.first { $0.sourceSpeakerID == s2.id }?.origin == .corrected)
        #expect(liam.negatives.isEmpty)
    }

    @Test func rejectStoresNegative() throws {
        let h = try WP3Harness()
        defer { h.cleanup() }
        try h.seed(.askKaran)
        let s2 = try #require(try h.recording(d).speaker("S2"))
        try h.store.rejectSuggestion(recordingID: d, key: "S2")
        let karan = try #require(try h.profile(named: "Karan"))
        #expect(karan.negatives.count == 1)
        let n = try #require(karan.negatives.first)
        #expect(n.sourceSpeakerID == s2.id && n.embeddingModelKey == EmbeddingModelID.fake.key)
        #expect(n.vector == s2.vector && n.speechSeconds == s2.cleanSeconds && n.addedAt == Seeds.Dates.d)
        #expect(karan.samples.count == 2)
    }

    @Test func rejectUnderFiveSecondsStoresNoNegative() throws {
        let h = try WP3Harness()
        defer { h.cleanup() }
        try h.seed(.askKaran)
        try #require(try h.recording(d).speaker("S2")).cleanSeconds = 4.9
        try h.store.rejectSuggestion(recordingID: d, key: "S2")
        #expect(try h.count(VoiceNegative.self) == 0)
        #expect(try h.recording(d).speaker("S2")?.rejectedProfileIDs == [Seeds.ID.karan])
    }

    @Test func namingAfterRejectRemovesThatNegative() throws {
        let h = try WP3Harness()
        defer { h.cleanup() }
        try h.seed(.askKaran)
        let karan = try #require(try h.profile(named: "Karan"))
        try h.store.rejectSuggestion(recordingID: d, key: "S2")
        #expect(karan.negatives.count == 1)
        _ = try h.store.nameSpeaker(recordingID: d, key: "S2", as: .existing(profileID: karan.id), remember: true)
        #expect(try karan.negatives.isEmpty && h.count(VoiceNegative.self) == 0)
        #expect(try h.recording(d).speaker("S2")?.rejectedProfileIDs.isEmpty == true)
    }

    @Test func confirmedProbeRemovesOnlyConflictingNegatives() throws {
        let h = try WP3Harness()
        defer { h.cleanup() }
        try h.seed(.library)
        let karan = try #require(try h.profile(named: "Karan"))
        let ask = MatchDecision.ask(profileID: karan.id, score: 0.5)
        let x = try oneSpeaker(h, SyntheticVoices.mix([(.karan, 0.5)], setting: (57, 0.7), variant: 46), clean: 12, decision: ask)
        try h.store.rejectSuggestion(recordingID: x, key: "S1")
        let z = try oneSpeaker(h, SyntheticVoices.mix([(.stranger, 0.5)], setting: (57, 0.7), variant: 47), clean: 12, decision: ask)
        try h.store.rejectSuggestion(recordingID: z, key: "S1")
        let y = try oneSpeaker(h, SyntheticVoices.mix([(.karan, 0.5)], setting: (57, 0.7), variant: 48), clean: 12)
        #expect(karan.negatives.count == 2)

        // Karan's score before the add is 0.5; X is 0.74 from Y (conflicts), Z is 0.49 (kept).
        _ = try h.store.nameSpeaker(recordingID: y, key: "S1", as: .existing(profileID: karan.id), remember: true)
        let zSpeaker = try #require(try h.recording(z).speaker("S1"))
        #expect(karan.negatives.map(\.sourceSpeakerID) == [zSpeaker.id])
        #expect(try h.count(VoiceNegative.self) == 1)
    }

    @Test func rememberOffLearnsNothing() throws {
        let h = try WP3Harness()
        defer { h.cleanup() }
        try h.seed(.library)
        let liam = try #require(try h.profile(named: "Liam"))
        let karan = try #require(try h.profile(named: "Karan"))
        let id = try oneSpeaker(h, SyntheticVoices.vector(near: .liam, cosine: 0.85, variant: 44), clean: 12,
                                decision: .autoLabel(profileID: liam.id, score: 0.85, margin: 0.85))
        let s1 = try #require(try h.recording(id).speaker("S1"))
        #expect(liam.samples.contains { $0.sourceSpeakerID == s1.id && $0.origin == .strongMatch })

        let result = try h.store.nameSpeaker(recordingID: id, key: "S1", as: .existing(profileID: karan.id), remember: false)
        #expect(result == NameResult(profileID: karan.id, sampleStored: false, skipReason: .rememberOff))
        #expect(karan.samples.count == 2 && !karan.samples.contains { $0.sourceSpeakerID == s1.id })
        #expect(liam.samples.count == 3 && !liam.samples.contains { $0.sourceSpeakerID == s1.id })   // still rolled back
        #expect(try h.count(VoiceNegative.self) == 0)
        #expect(s1.rejectedProfileIDs == [liam.id] && s1.profile?.id == karan.id)
    }

    @Test func rememberOffOnTheSuggestedVoiceStoresNothing() throws {
        // What the sheet sends when the suggested voice is kept but Remember is switched off.
        let h = try WP3Harness()
        defer { h.cleanup() }
        try h.seed(.askKaran)
        let karan = try #require(try h.profile(named: "Karan"))
        let samples = try h.count(VoiceSample.self)
        let result = try h.store.nameSpeaker(recordingID: d, key: "S2", as: .existing(profileID: karan.id), remember: false)
        #expect(result == NameResult(profileID: karan.id, sampleStored: false, skipReason: .rememberOff))
        #expect(try h.count(VoiceSample.self) == samples)
        #expect(try h.count(VoiceNegative.self) == 0)
        let s2 = try #require(try h.recording(d).speaker("S2"))
        #expect(s2.label == .named && s2.profile?.id == karan.id)
    }

    @Test func shortWrongAutoLabelCorrectedToANewPersonStoresNegative() throws {
        // 7 s is too little to create a profile (10 s) but enough for a negative (5 s).
        let h = try WP3Harness()
        defer { h.cleanup() }
        try h.seed(.library)
        let liam = try #require(try h.profile(named: "Liam"))
        let id = try oneSpeaker(h, SyntheticVoices.vector(near: .liam, cosine: 0.6, variant: 44), clean: 7,
                                decision: .autoLabel(profileID: liam.id, score: 0.6, margin: 0.6))
        let s1 = try #require(try h.recording(id).speaker("S1"))
        #expect(s1.label == .autoLabelled)

        let result = try h.store.nameSpeaker(recordingID: id, key: "S1", as: .newPerson(name: "Sam"), remember: true)
        #expect(result == NameResult(profileID: nil, sampleStored: false, skipReason: .tooLittleSpeech(seconds: 7)))
        #expect(try h.profile(named: "Sam") == nil)
        #expect(s1.profile == nil && s1.nameSnapshot == "Sam" && s1.rejectedProfileIDs == [liam.id])
        #expect(liam.negatives.count == 1 && liam.negatives.first?.sourceSpeakerID == s1.id)
        #expect(try h.count(VoiceNegative.self) == 1)
    }

    @Test func justThisTurnLearnsNothing() throws {
        let h = try WP3Harness()
        defer { h.cleanup() }
        try h.seed(.askKaran)
        let karan = try #require(try h.profile(named: "Karan"))
        let samples = try h.count(VoiceSample.self)
        let turns = try #require(try h.recording(d).transcript?.turns)
        let s2Turn = try #require(turns.first { $0.speakerKey == "S2" })
        let s1Turn = try #require(turns.first { $0.speakerKey == "S1" })
        try h.store.reassignTurn(recordingID: d, turnID: s2Turn.id, to: .profile(karan.id))
        try h.store.reassignTurn(recordingID: d, turnID: s1Turn.id, to: .speaker("S2"))
        try h.store.reassignTurn(recordingID: d, turnID: s1Turn.id, to: .newName("Mei"))
        #expect(try h.count(VoiceSample.self) == samples)
        #expect(try h.count(VoiceNegative.self) == 0)
        #expect(try h.context.fetch(FetchDescriptor<VoiceProfile>()).allSatisfy { $0.negatives.isEmpty })
    }

    @Test func negativesAreCappedAtEight() throws {
        let h = try WP3Harness()
        defer { h.cleanup() }
        try h.seed(.library)
        let karan = try #require(try h.profile(named: "Karan"))
        let ticking = LibraryStore(context: h.context, paths: h.paths, deviceIdentity: FixedDeviceIdentity("device-A"),
                                   clock: TickingClock(start: Seeds.Dates.d).clock, localChannel: h.store.localChannel)
        var sources: [UUID] = []
        for i in 0..<9 {   // nine distinct voices (pairwise cosine 0.25), each suggested as Karan and rejected
            let id = try oneSpeaker(h, SyntheticVoices.vector(near: .stranger, cosine: 0.5, variant: 30 + i), clean: 8,
                                    decision: .ask(profileID: karan.id, score: 0.45))
            sources.append(try #require(try h.recording(id).speaker("S1")).id)
            try ticking.rejectSuggestion(recordingID: id, key: "S1")
        }
        #expect(karan.negatives.count == MatchPolicy.default.maxNegativesPerProfile)
        #expect(try h.count(VoiceNegative.self) == 8)
        #expect(Set(karan.negatives.compactMap(\.sourceSpeakerID)) == Set(sources.dropFirst()))   // the oldest is gone
    }

    // MARK: Automatic samples

    @Test func automaticSampleNeedsCoherence() throws {
        let h = try WP3Harness()
        defer { h.cleanup() }
        try h.seed(.library)
        let liam = try #require(try h.profile(named: "Liam"))
        let auto = MatchDecision.autoLabel(profileID: liam.id, score: 0.9, margin: 0.9)
        let cases: [(Float?, Bool, Int)] = [(0.4, false, 45), (nil, false, 46), (0.9, true, 47)]
        for (coherence, stored, variant) in cases {
            let id = try oneSpeaker(h, SyntheticVoices.vector(near: .liam, cosine: 0.9, variant: variant), clean: 12,
                                    decision: auto, coherence: coherence)
            let s1 = try #require(try h.recording(id).speaker("S1"))
            #expect(s1.label == .autoLabelled && s1.coherence == coherence)
            #expect(liam.samples.contains { $0.sourceSpeakerID == s1.id && $0.origin == .strongMatch } == stored,
                    "coherence \(String(describing: coherence))")
        }
        #expect(liam.samples.count == 4)
    }

    @Test func automaticSampleIgnoresUntrustedEvidence() throws {
        let h = try WP3Harness()
        defer { h.cleanup() }
        try h.seed(.empty)
        let key = EmbeddingModelID.fake.key
        let liam = VoiceProfile(id: Seeds.ID.liam, name: "Liam", colourSlot: 0, embeddingModelKey: key, now: Seeds.Dates.c)
        h.context.insert(liam)
        func add(_ vector: VoiceVector, _ origin: SampleOrigin, seconds: Double) {
            let s = VoiceSample(vector: vector, embeddingModelKey: key, origin: origin, addedAt: Seeds.Dates.c, speechSeconds: seconds)
            h.context.insert(s)
            s.profile = liam
        }
        add(SyntheticVoices.base(.liam), .named, seconds: 12)
        // Two automatic samples in a direction the probe matches at 0.9125 (shared Liam 0.65 and setting 0.7).
        add(SyntheticVoices.mix([(.liam, 0.65)], setting: (58, 0.7), variant: 45), .strongMatch, seconds: 12)
        add(SyntheticVoices.mix([(.liam, 0.65)], setting: (58, 0.7), variant: 46), .strongMatch, seconds: 12)
        try h.context.save()

        let probe = SyntheticVoices.mix([(.liam, 0.65)], setting: (58, 0.7), variant: 47)
        let candidate = LibraryStore.candidate(liam)
        let evidence = try #require(VoiceMatcher.evidence(probe, against: candidate))
        #expect(abs((evidence.trustedScore ?? 0) - 0.65) < 1e-4 && abs(evidence.score - 0.78125) < 1e-4)

        let id = try oneSpeaker(h, probe, clean: 12, decision: .autoLabel(profileID: liam.id, score: 0.9, margin: 0.9))
        let s1 = try #require(try h.recording(id).speaker("S1"))
        #expect(s1.label == .autoLabelled)
        #expect(liam.samples.count == 3 && !liam.samples.contains { $0.sourceSpeakerID == s1.id })
    }

    // MARK: Merge, forget, model change, removal

    @Test func mergeKeepsOriginsAndReconcilesNegatives() throws {
        let h = try WP3Harness()
        defer { h.cleanup() }
        try h.seed(.library)
        let c = Seeds.ID.recordingC
        let karan = try #require(try h.profile(named: "Karan"))
        let cS2 = try #require(try h.recording(c).speaker("S2"))
        // Karan once got "No" for C's Speaker 2 …
        cS2.label = .suggested
        cS2.suggestedProfileID = karan.id
        cS2.matchScore = 0.45
        try h.context.save()
        try h.store.rejectSuggestion(recordingID: c, key: "S2")
        #expect(karan.negatives.map(\.sourceSpeakerID) == [cS2.id])
        // … who is then named Kay, and Kay gets "No" for speaker A.
        _ = try h.store.nameSpeaker(recordingID: c, key: "S2", as: .newPerson(name: "Kay"), remember: true)
        let kay = try #require(try h.profile(named: "Kay"))
        let a = try oneSpeaker(h, SyntheticVoices.mix([(.stranger, 0.6)], variant: 45), clean: 9,
                               decision: .ask(profileID: kay.id, score: 0.54))
        let speakerA = try #require(try h.recording(a).speaker("S1"))
        try h.store.rejectSuggestion(recordingID: a, key: "S1")
        #expect(kay.negatives.map(\.sourceSpeakerID) == [speakerA.id])

        try h.store.mergeProfiles(source: kay.id, into: karan.id)
        #expect(try h.profile(named: "Kay") == nil)
        #expect(karan.samples.contains { $0.origin == .named && $0.sourceSpeakerID == cS2.id })
        #expect(!karan.samples.contains { $0.origin == .merged })
        // A's negative moved; Karan's negative from C's Speaker 2 went, since that speaker is now Karan.
        #expect(karan.negatives.map(\.sourceSpeakerID) == [speakerA.id])
        #expect(karan.negatives.first?.vector == speakerA.vector)
        #expect(try h.count(VoiceNegative.self) == 1)
    }

    @Test func forgetCascadesNegatives() throws {
        let h = try WP3Harness()
        defer { h.cleanup() }
        try h.seed(.askKaran)
        try h.store.rejectSuggestion(recordingID: d, key: "S2")
        #expect(try h.count(VoiceNegative.self) == 1)
        try h.store.forgetProfile(Seeds.ID.karan)
        #expect(try h.count(VoiceNegative.self) == 0)
    }

    @Test func modelChangeReEnrolDropsNegatives() throws {
        let h = try WP3Harness()
        defer { h.cleanup() }
        try h.seed(.empty)
        let old = "old@1#256"
        let p = VoiceProfile(name: "Mei", colourSlot: 2, embeddingModelKey: old, now: Seeds.Dates.c)
        h.context.insert(p)
        for v in [40, 41] {
            let n = VoiceNegative(vector: SyntheticVoices.vector(near: .stranger, cosine: 0.5, variant: v),
                                  embeddingModelKey: old, addedAt: Seeds.Dates.c, speechSeconds: 8)
            h.context.insert(n)
            n.profile = p
        }
        try h.context.save()
        #expect(p.negatives.count == 2)

        let id = try oneSpeaker(h, SyntheticVoices.vector(near: .karan, cosine: 0.9, variant: 42), clean: 12)
        let result = try h.store.nameSpeaker(recordingID: id, key: "S1", as: .existing(profileID: p.id), remember: true)
        #expect(result.sampleStored)
        #expect(p.embeddingModelKey == EmbeddingModelID.fake.key && p.samples.count == 1)
        #expect(try p.negatives.isEmpty && h.count(VoiceNegative.self) == 0)
    }

    @Test func removeSampleMarksNeedsResampleWhenLast() throws {
        let h = try WP3Harness()
        defer { h.cleanup() }
        try h.seed(.library)
        let karan = try #require(try h.profile(named: "Karan"))
        let ids = karan.sortedSamples.map(\.id)
        #expect(ids.count == 2)
        try h.store.removeSample(id: ids[0])
        #expect(karan.samples.map(\.id) == [ids[1]] && !karan.needsResample)
        try h.store.removeSample(id: ids[1])
        #expect(karan.samples.isEmpty && karan.needsResample)
        #expect(try h.count(VoiceSample.self) == 3)
        let unknown = UUID()
        #expect(throws: StoreError.notFound("sample \(unknown)")) { try h.store.removeSample(id: unknown) }
    }

    @Test func addSampleSavesRemovedNegativesEvenWhenNoSampleIsStored() throws {
        let h = try WP3Harness()
        defer { h.cleanup() }
        try h.seed(.askKaran)
        let karan = try #require(try h.profile(named: "Karan"))
        try h.store.rejectSuggestion(recordingID: d, key: "S2")
        #expect(karan.negatives.count == 1)
        // The same voice is then added to Karan from voice detail, but it duplicates a sample Karan already has.
        let s2 = try #require(try h.recording(d).speaker("S2"))
        s2.vectorData = try #require(karan.sortedSamples.first?.vectorData)
        try h.context.save()
        let samples = karan.samples.count

        let result = try h.store.addSample(profileID: karan.id, fromSpeaker: s2.id)
        #expect(result == NameResult(profileID: karan.id, sampleStored: false, skipReason: .duplicate))
        #expect(karan.samples.count == samples)
        // The negative from this speaker is gone, and the deletion is saved rather than left pending.
        #expect(karan.negatives.isEmpty)
        #expect(!h.context.hasChanges)
        #expect(try h.count(VoiceNegative.self) == 0)
    }

    // MARK: Cohort and traces

    @Test func cohortExcludesCurrentRecordingLabelledAndShortVoices() throws {
        let h = try WP3Harness()
        defer { h.cleanup() }
        try h.seed(.library)
        let liam = try #require(try h.profile(named: "Liam"))
        let karan = try #require(try h.profile(named: "Karan"))
        let key = EmbeddingModelID.fake.key
        let later = Seeds.Dates.d.addingTimeInterval(3600)

        // A snapshot-named 6 s voice (kept) and an unnamed 4.9 s voice (too short).
        let mei = SyntheticVoices.vector(near: .stranger, cosine: 0.5, variant: 40)
        let r1 = try h.readyRecording(turns: SeedContent.conversationB, drafts: [
            WP3Docs.draft("S1", 1, clean: 6, vector: mei),
            WP3Docs.draft("S2", 2, clean: 4.9, vector: SyntheticVoices.vector(near: .stranger, cosine: 0.5, variant: 41))],
            createdAt: later)
        _ = try h.store.nameSpeaker(recordingID: r1, key: "S1", as: .newPerson(name: "Mei"), remember: false)
        #expect(try h.recording(r1).speaker("S1")?.nameSnapshot == "Mei")
        // Suggested and auto-labelled voices (excluded).
        _ = try h.readyRecording(turns: SeedContent.conversationB, drafts: [
            WP3Docs.draft("S1", 1, clean: 12, vector: SyntheticVoices.vector(near: .liam, cosine: 0.5, variant: 42)),
            WP3Docs.draft("S2", 2, clean: 12, vector: SyntheticVoices.vector(near: .karan, cosine: 0.8, variant: 43))],
            createdAt: later.addingTimeInterval(60),
            decisions: ["S1": .ask(profileID: liam.id, score: 0.5), "S2": .autoLabel(profileID: karan.id, score: 0.8, margin: 0.8)])
        // Another model's unnamed voice (excluded).
        let other = EmbeddingModelID(name: "other", revision: "1", dimension: 256)
        _ = try h.readyRecording(turns: SeedContent.conversationA, drafts: [
            SpeakerDraft(key: "S1", ordinal: 1, cleanSeconds: 12, totalSeconds: 12, turnCount: 1,
                         vector: SyntheticVoices.vector(near: .stranger, cosine: 0.5, variant: 44), embeddingModel: other)])
        // The recording being matched (excluded).
        let current = try oneSpeaker(h, SyntheticVoices.vector(near: .stranger, cosine: 0.5, variant: 45), clean: 12)

        let cS2 = try #require(try h.recording(Seeds.ID.recordingC).speaker("S2")?.vector)
        #expect(try h.store.matchCohort(modelKey: key, excludingRecording: current) == [mei, cS2])
        // Without the exclusion the current recording's voice joins them.
        #expect(try h.store.matchCohort(modelKey: key, excludingRecording: UUID()).count == 3)
    }

    @Test func traceIsWrittenOnceAndSurvivesEdits() throws {
        let h = try WP3Harness()
        defer { h.cleanup() }
        try h.seed(.library)
        let id = try h.separatedRecording(turns: SeedContent.conversationB, drafts: [
            WP3Docs.draft("S1", 1, clean: 12, turns: 2, vector: SyntheticVoices.vector(near: .liam, cosine: 0.82, variant: 44)),
            WP3Docs.draft("S2", 2, clean: 11.5, turns: 2, vector: SyntheticVoices.vector(near: .karan, cosine: 0.47, variant: 45))])
        try h.matchLikeThePipeline(id)
        let r = try h.recording(id)
        let s1 = try #require(r.speaker("S1")), s2 = try #require(r.speaker("S2"))
        #expect(s1.label == .autoLabelled && s2.label == .suggested)
        let t1 = try #require(s1.matchTraceData), t2 = try #require(s2.matchTraceData)
        let trace1 = try JSONDecoder().decode(MatchTrace.self, from: t1)
        let trace2 = try JSONDecoder().decode(MatchTrace.self, from: t2)
        #expect(trace1.kind == .auto && trace1.reason == "auto" && trace1.profileID == Seeds.ID.liam)
        #expect(trace2.kind == .ask && trace2.reason == "belowAuto" && trace2.profileID == Seeds.ID.karan)

        try h.store.rejectSuggestion(recordingID: id, key: "S2")
        #expect(s1.matchTraceData == t1 && s2.matchTraceData == t2)
        _ = try h.store.nameSpeaker(recordingID: id, key: "S2", as: .newPerson(name: "Mei"), remember: true)
        #expect(s1.matchTraceData == t1 && s2.matchTraceData == t2)
        #expect(r.movedSpeakerTracesData == nil)
        try h.store.moveAllTurns(recordingID: id, from: "S1", to: "S2")
        #expect(try h.recording(id).speaker("S1") == nil)
        #expect(try h.recording(id).speaker("S2")?.matchTraceData == t2)
        // The removed speaker's trace (here a wrong auto-label the user corrected) is kept on the recording.
        let moved = MovedSpeakerTrace.decode(try h.recording(id).movedSpeakerTracesData)
        #expect(moved.count == 1)
        #expect(moved.first?.key == "S1" && moved.first?.movedTo == "S2" && moved.first?.trace == trace1)
        #expect(moved.first?.rejectedProfileIDs == [Seeds.ID.liam] && moved.first?.cleanSeconds == 12)
        let log = try MatchLog.decoder().decode(MatchLog.self, from: Data(try h.store.matchingLog().utf8))
        #expect(log.recordings.first { $0.id == id }?.movedSpeakers == moved)
    }
}
