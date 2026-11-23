import Foundation
import SwiftData
import Testing
import TranscribeCore
@testable import TranscribeFakes
@testable import TranscribeKit

@Suite("WP3: naming and correction")
@MainActor
struct NamingAndCorrectionTests {
    let b = Seeds.ID.recordingB

    @Test func newPersonWithEnoughSpeechCreatesAProfileAndANamedSample() throws {
        let h = try WP3Harness()
        defer { h.cleanup() }
        try h.seed(.twoSpeakersUnnamed)
        let result = try h.store.nameSpeaker(recordingID: b, key: "S2", as: .newPerson(name: "  Karan "), remember: true)
        let karan = try #require(try h.profile(named: "Karan"))
        #expect(result == NameResult(profileID: karan.id, sampleStored: true, skipReason: nil))
        #expect(karan.samples.count == 1 && karan.samples[0].origin == .named)
        #expect(karan.embeddingModelKey == EmbeddingModelID.fake.key && karan.autoLabel && !karan.isMe)
        let s2 = try #require(try h.recording(b).speaker("S2"))
        #expect(karan.samples[0].sourceSpeakerID == s2.id && karan.samples[0].sourceRecordingID == b)
        #expect(s2.label == .named && s2.profile?.id == karan.id && s2.displayName == "Karan" && s2.nameSnapshot == nil)
        // Speaker 2's rose carries through to Karan's rose; Liam keeps teal.
        #expect(karan.colourSlot == 1 && s2.colourSlot == 1)
        #expect(try h.recording(b).speaker("S1")?.colourSlot == 0)
        #expect(karan.namedAt == Seeds.Dates.d)
    }

    @Test func underTenSecondsKeepsTheNameWithoutAProfile() throws {
        let h = try WP3Harness()
        defer { h.cleanup() }
        try h.seed(.twoSpeakersUnnamed)
        let s2 = try #require(try h.recording(b).speaker("S2"))
        s2.cleanSeconds = 6.5
        let result = try h.store.nameSpeaker(recordingID: b, key: "S2", as: .newPerson(name: "Mei"), remember: true)
        #expect(result == NameResult(profileID: nil, sampleStored: false, skipReason: .tooLittleSpeech(seconds: 6.5)))
        #expect(try h.profile(named: "Mei") == nil)
        #expect(s2.label == .named && s2.nameSnapshot == "Mei" && s2.displayName == "Mei" && s2.profile == nil)
    }

    @Test func noVectorIsReported() throws {
        let h = try WP3Harness()
        defer { h.cleanup() }
        try h.seed(.twoSpeakersUnnamed)
        try #require(try h.recording(b).speaker("S2")).vectorData = nil
        let result = try h.store.nameSpeaker(recordingID: b, key: "S2", as: .newPerson(name: "Mei"), remember: true)
        #expect(result.skipReason == .noVector && result.profileID == nil)
    }

    @Test func anExistingNameReusesTheProfile() throws {
        let h = try WP3Harness()
        defer { h.cleanup() }
        try h.seed(.twoSpeakersUnnamed)
        let liam = try #require(try h.profile(named: "Liam"))
        let result = try h.store.nameSpeaker(recordingID: b, key: "S1", as: .newPerson(name: "liam"), remember: true)
        #expect(result.profileID == liam.id && result.sampleStored)
        #expect(try h.count(VoiceProfile.self) == 1)
        // The voice was unnamed, so naming it is a correction of a miss, not a confirmation.
        #expect(liam.samples.count == 4 && liam.sortedSamples.last?.origin == .corrected)
        #expect(try h.recording(b).speaker("S1")?.profile?.id == liam.id)
    }

    @Test func rememberOffSetsOnlyTheName() throws {
        let h = try WP3Harness()
        defer { h.cleanup() }
        try h.seed(.twoSpeakersUnnamed)
        let result = try h.store.nameSpeaker(recordingID: b, key: "S2", as: .newPerson(name: "Karan"), remember: false)
        #expect(result == NameResult(profileID: nil, sampleStored: false, skipReason: .rememberOff))
        #expect(try h.count(VoiceProfile.self) == 1)
        #expect(try h.recording(b).speaker("S2")?.displayName == "Karan")

        // Remember off for a saved voice links it but stores nothing.
        let liam = try #require(try h.profile(named: "Liam"))
        let linked = try h.store.nameSpeaker(recordingID: b, key: "S1", as: .existing(profileID: liam.id), remember: false)
        #expect(linked == NameResult(profileID: liam.id, sampleStored: false, skipReason: .rememberOff))
        #expect(liam.samples.count == 3)
    }

    @Test func emptyNameIsRejected() throws {
        let h = try WP3Harness()
        defer { h.cleanup() }
        try h.seed(.twoSpeakersUnnamed)
        #expect(throws: StoreError.invalidName) {
            _ = try h.store.nameSpeaker(recordingID: b, key: "S2", as: .newPerson(name: "   "), remember: true)
        }
        #expect(throws: StoreError.self) {
            _ = try h.store.nameSpeaker(recordingID: b, key: "S9", as: .newPerson(name: "Mei"), remember: true)
        }
    }

    @Test func slotsCarryOverWhenTheSpeakerSlotIsAlreadyOwned() throws {
        let h = try WP3Harness()
        defer { h.cleanup() }
        try h.seed(.twoSpeakersUnnamed)
        // Liam owns slot 0. Naming S1 (slot 0) as a new person must not take Liam's colour.
        _ = try h.store.nameSpeaker(recordingID: b, key: "S1", as: .newPerson(name: "Sam"), remember: true)
        let sam = try #require(try h.profile(named: "Sam"))
        #expect(sam.colourSlot != 0)
        let r = try h.recording(b)
        #expect(r.speaker("S1")?.colourSlot == sam.colourSlot)
        #expect(Set(r.speakers.map(\.colourSlot)).count == 2)
    }

    @Test func correctingAnAutoLabelRollsBackItsStrongSampleAndRejectsTheProfile() throws {
        let h = try WP3Harness()
        defer { h.cleanup() }
        try h.seed(.library)
        let liam = try #require(try h.profile(named: "Liam"))
        let karan = try #require(try h.profile(named: "Karan"))
        // A strong auto-match feeds Liam a sample from this speaker.
        let id = try h.readyRecording(
            turns: SeedContent.conversationB,
            drafts: [WP3Docs.draft("S1", 1, clean: 12, vector: SyntheticVoices.vector(near: .liam, cosine: 0.85, variant: 40)),
                     WP3Docs.draft("S2", 2, clean: 11, vector: SyntheticVoices.vector(near: .karan, cosine: 0.9, variant: 41))],
            decisions: ["S1": .autoLabel(profileID: liam.id, score: 0.85, margin: 0.85)])
        let s1 = try #require(try h.recording(id).speaker("S1"))
        #expect(s1.label == .autoLabelled && s1.profile?.id == liam.id && s1.matchScore == Double(Float(0.85)))
        #expect(liam.samples.filter { $0.sourceSpeakerID == s1.id }.map(\.origin) == [.strongMatch])
        #expect(liam.samples.count == 4)
        #expect(try h.recording(id).hasUnseenResult)

        // "Wrong speaker? Change" → it was Karan.
        let result = try h.store.nameSpeaker(recordingID: id, key: "S1", as: .existing(profileID: karan.id), remember: true)
        #expect(result.profileID == karan.id && result.sampleStored)
        #expect(liam.samples.count == 3 && !liam.samples.contains { $0.sourceSpeakerID == s1.id })
        #expect(s1.rejectedProfileIDs == [liam.id] && s1.profile?.id == karan.id && s1.label == .named)
        #expect(s1.colourSlot == karan.colourSlot)
        #expect(try h.recording(id).speaker("S2")?.colourSlot != karan.colourSlot)
        #expect(karan.samples.contains { $0.sourceSpeakerID == s1.id && $0.origin == .corrected })
        #expect(liam.negatives.count == 1 && liam.negatives[0].sourceSpeakerID == s1.id)
        #expect(try !h.recording(id).hasUnseenResult)
    }

    @Test func correctingANamedSpeakerToANewPersonAlsoRollsBack() throws {
        let h = try WP3Harness()
        defer { h.cleanup() }
        try h.seed(.twoSpeakersUnnamed)
        _ = try h.store.nameSpeaker(recordingID: b, key: "S2", as: .newPerson(name: "Karen"), remember: true)
        let karen = try #require(try h.profile(named: "Karen"))
        let karenID = karen.id
        #expect(karen.samples.count == 1)
        _ = try h.store.nameSpeaker(recordingID: b, key: "S2", as: .newPerson(name: "Karan"), remember: true)
        let s2 = try #require(try h.recording(b).speaker("S2"))
        #expect(s2.profile?.name == "Karan")
        // Karen had only this speaker's sample and no other speaker: the empty profile is removed, not left to
        // sit in the Voices list unable to match anyone.
        #expect(try h.profile(named: "Karen") == nil)
        #expect(!s2.rejectedProfileIDs.contains(karenID))
        #expect(try h.count(VoiceProfile.self) == 2)
    }

    @Test func aProfileLeftWithSpeakersButNoSamplesNeedsANewSample() throws {
        let h = try WP3Harness()
        defer { h.cleanup() }
        try h.seed(.twoSpeakersUnnamed)
        _ = try h.store.nameSpeaker(recordingID: b, key: "S2", as: .newPerson(name: "Karen"), remember: true)
        let karen = try #require(try h.profile(named: "Karen"))
        // Another recording's speaker is named Karen without feeding her a sample.
        let other = try h.readyRecording(turns: SeedContent.conversationA, drafts: [
            WP3Docs.draft("S1", 1, clean: 4, vector: SyntheticVoices.vector(near: .stranger, cosine: 0.8, variant: 30))])
        _ = try h.store.nameSpeaker(recordingID: other, key: "S1", as: .existing(profileID: karen.id), remember: false)
        _ = try h.store.nameSpeaker(recordingID: b, key: "S2", as: .newPerson(name: "Karan"), remember: true)
        #expect(karen.samples.isEmpty && karen.needsResample)
        #expect(try h.recording(other).speaker("S1")?.profile?.id == karen.id)
    }

    @Test func aNameDifferingOnlyInAccentsIsANewPerson() throws {
        let h = try WP3Harness()
        defer { h.cleanup() }
        try h.seed(.twoSpeakersUnnamed)
        let other = try h.readyRecording(turns: SeedContent.conversationA, drafts: [
            WP3Docs.draft("S1", 1, clean: 12, vector: SyntheticVoices.vector(near: .stranger, cosine: 0.8, variant: 31))])
        _ = try h.store.nameSpeaker(recordingID: other, key: "S1", as: .newPerson(name: "José"), remember: true)
        let jose = try #require(try h.profile(named: "José"))
        let result = try h.store.nameSpeaker(recordingID: b, key: "S2", as: .newPerson(name: "Jose"), remember: true)
        let plain = try #require(try h.profile(named: "Jose"))
        #expect(result.profileID == plain.id && plain.id != jose.id)
        #expect(!jose.samples.contains { $0.sourceRecordingID == b })
        // Case alone still names the saved voice, in the store and in the sheet alike.
        #expect(VoiceProfile.nameMatches("José", "josé") && !VoiceProfile.nameMatches("José", "Jose"))
    }

    @Test func sameAsAnotherSpeakerRollsBackAWrongAutoLabel() throws {
        let h = try WP3Harness()
        defer { h.cleanup() }
        try h.seed(.library)
        let liam = try #require(try h.profile(named: "Liam"))
        let id = try h.readyRecording(
            turns: SeedContent.conversationB,
            drafts: [WP3Docs.draft("S1", 1, clean: 12, turns: 2, vector: SyntheticVoices.vector(near: .liam, cosine: 0.85, variant: 42)),
                     WP3Docs.draft("S2", 2, clean: 11, turns: 2, vector: SyntheticVoices.vector(near: .karan, cosine: 0.9, variant: 43))],
            decisions: ["S1": .autoLabel(profileID: liam.id, score: 0.85, margin: 0.85)])
        let s1 = try #require(try h.recording(id).speaker("S1"))
        let s1ID = s1.id
        #expect(liam.samples.contains { $0.sourceSpeakerID == s1ID && $0.origin == .strongMatch })
        let s2Seconds = try #require(try h.recording(id).speaker("S2")).totalSeconds
        let moved = try #require(try h.recording(id).transcript).turns.filter { $0.effectiveSpeakerKey == "S1" }

        // "Wrong speaker? Change" → Same as Speaker 2, for every turn.
        try h.store.moveAllTurns(recordingID: id, from: "S1", to: "S2")
        let r = try h.recording(id)
        #expect(!liam.samples.contains { $0.sourceSpeakerID == s1ID })
        #expect(liam.samples.count == 3 && !liam.needsResample)
        #expect(liam.negatives.count == 1)
        #expect(r.speaker("S1") == nil)                        // no turns left: never waits for a name
        #expect(!liam.speakers.contains { $0.recording?.id == id })
        #expect(r.transcript?.turns.allSatisfy { $0.effectiveSpeakerKey == "S2" } == true)
        let s2 = try #require(r.speaker("S2"))
        #expect(s2.turnCount == r.transcript?.turns.count)
        #expect(abs(s2.totalSeconds - (s2Seconds + moved.map(\.range.duration).reduce(0, +))) < 0.001)
        #expect(!r.hasUnseenResult)
    }

    @Test func justThisTurnSpeakersGetTheirTurnTime() throws {
        let h = try WP3Harness()
        defer { h.cleanup() }
        try h.seed(.twoSpeakersUnnamed)
        let r0 = try h.recording(b)
        let turn = try #require(r0.transcript?.turns[0])
        let s1Before = try #require(r0.speaker(turn.speakerKey ?? "S1")).totalSeconds
        try h.store.reassignTurn(recordingID: b, turnID: turn.id, to: .newName("Priya"))
        let r = try h.recording(b)
        let u1 = try #require(r.speaker("U1"))
        #expect(abs(u1.totalSeconds - turn.range.duration) < 0.001 && u1.totalSeconds > 0)
        #expect(abs((r.speaker(turn.speakerKey ?? "S1")?.totalSeconds ?? 0) - max(0, s1Before - turn.range.duration)) < 0.001)
    }

    @Test func confirmAndRejectSuggestions() throws {
        let h = try WP3Harness()
        defer { h.cleanup() }
        try h.seed(.askKaran)
        let karan = try #require(try h.profile(named: "Karan"))
        let d = Seeds.ID.recordingD
        let result = try h.store.confirmSuggestion(recordingID: d, key: "S2")
        let s2 = try #require(try h.recording(d).speaker("S2"))
        #expect(result == NameResult(profileID: karan.id, sampleStored: true, skipReason: nil))
        #expect(s2.label == .named && s2.profile?.id == karan.id && s2.suggestedProfileID == nil)
        #expect(karan.samples.count == 3 && karan.sortedSamples.last?.origin == .confirmed)
        #expect(throws: StoreError.self) { _ = try h.store.confirmSuggestion(recordingID: d, key: "S2") }

        let h2 = try WP3Harness()
        defer { h2.cleanup() }
        try h2.seed(.askKaran)
        try h2.store.rejectSuggestion(recordingID: d, key: "S2")
        let r2 = try #require(try h2.recording(d).speaker("S2"))
        #expect(r2.label == .unnamed && r2.suggestedProfileID == nil && r2.rejectedProfileIDs == [Seeds.ID.karan])
        #expect(try h2.profile(named: "Karan")?.samples.count == 2)
    }

    @Test func reassignTurnToAnotherSpeakerTouchesNoProfile() throws {
        let h = try WP3Harness()
        defer { h.cleanup() }
        try h.seed(.library)
        let a = Seeds.ID.recordingA
        let samples = try h.count(VoiceSample.self)
        let doc = try #require(try h.recording(a).transcript)
        let turn1 = doc.turns[1]
        #expect(turn1.speakerKey == "S2")
        try h.store.reassignTurn(recordingID: a, turnID: turn1.id, to: .speaker("S1"))
        var r = try h.recording(a)
        #expect(r.transcript?.turns[1].speakerKeyOverride == "S1" && r.transcript?.turns[1].effectiveSpeakerKey == "S1")
        #expect(r.speaker("S1")?.turnCount == 3 && r.speaker("S2")?.turnCount == 0)
        #expect(try h.count(VoiceSample.self) == samples)
        #expect(r.speaker("S2")?.profile?.name == "Karan" && r.speaker("S2")?.label == .autoLabelled)

        // Back to its own speaker clears the override.
        try h.store.reassignTurn(recordingID: a, turnID: turn1.id, to: .speaker("S2"))
        r = try h.recording(a)
        #expect(r.transcript?.turns[1].speakerKeyOverride == nil)
    }

    @Test func reassignTurnToASavedVoiceCreatesAUserSpeaker() throws {
        let h = try WP3Harness()
        defer { h.cleanup() }
        try h.seed(.twoSpeakersUnnamed)
        let liam = try #require(try h.profile(named: "Liam"))
        let samples = liam.samples.count
        let turn = try #require(try h.recording(b).transcript?.turns[1])
        try h.store.reassignTurn(recordingID: b, turnID: turn.id, to: .profile(liam.id))
        let r = try h.recording(b)
        let u1 = try #require(r.speaker("U1"))
        #expect(u1.profile?.id == liam.id && u1.label == .named && u1.vectorData == nil && u1.ordinal == 3)
        #expect(u1.colourSlot == liam.colourSlot || r.speakers.contains { $0.key != "U1" && $0.colourSlot == liam.colourSlot })
        #expect(r.transcript?.turns[1].speakerKeyOverride == "U1" && u1.turnCount == 1)
        #expect(liam.samples.count == samples)
        #expect(try h.store.probes(for: b).first { $0.key == "U1" }?.vector == nil)

        // A second turn to the same saved voice reuses U1.
        let turn3 = try #require(r.transcript?.turns[3])
        try h.store.reassignTurn(recordingID: b, turnID: turn3.id, to: .profile(liam.id))
        #expect(try h.recording(b).speakers.filter { $0.key.hasPrefix("U") }.count == 1)
        #expect(try h.recording(b).speaker("U1")?.turnCount == 2)
    }

    @Test func reassignTurnToANewNameNeverRemembers() throws {
        let h = try WP3Harness()
        defer { h.cleanup() }
        try h.seed(.twoSpeakersUnnamed)
        let profiles = try h.count(VoiceProfile.self)
        let turn = try #require(try h.recording(b).transcript?.turns[0])
        try h.store.reassignTurn(recordingID: b, turnID: turn.id, to: .newName("Mei"))
        var r = try h.recording(b)
        let u1 = try #require(r.speaker("U1"))
        #expect(u1.nameSnapshot == "Mei" && u1.profile == nil && u1.label == .named && u1.displayName == "Mei")
        #expect(try h.count(VoiceProfile.self) == profiles)
        #expect(r.searchText.contains("mei"))
        #expect(throws: StoreError.invalidName) { try h.store.reassignTurn(recordingID: b, turnID: turn.id, to: .newName(" ")) }

        // Moving the only turn away removes the now-empty user speaker.
        try h.store.reassignTurn(recordingID: b, turnID: turn.id, to: .speaker("S1"))
        r = try h.recording(b)
        #expect(r.speaker("U1") == nil && r.transcript?.turns[0].speakerKeyOverride == nil)
    }

    @Test func rematcherOnlySuggests() throws {
        let h = try WP3Harness()
        defer { h.cleanup() }
        try h.seed(.library)
        // An older unnamed stranger whose voice is close to recording C's Speaker 2.
        let other = try h.readyRecording(
            turns: SeedContent.conversationA,
            drafts: [WP3Docs.draft("S1", 1, clean: 9, vector: SyntheticVoices.vector(near: .stranger, cosine: 0.85, variant: 22))])
        #expect(try h.recording(other).speaker("S1")?.label == .unnamed)
        let result = try h.store.nameSpeaker(recordingID: Seeds.ID.recordingC, key: "S2", as: .newPerson(name: "Sam"), remember: true)
        let sam = try #require(try h.profile(named: "Sam"))
        #expect(result.profileID == sam.id)
        let s1 = try #require(try h.recording(other).speaker("S1"))
        #expect(s1.label == .suggested && s1.suggestedProfileID == sam.id && s1.profile == nil)
        #expect(try h.context.fetch(FetchDescriptor<RecordingSpeaker>()).allSatisfy { $0.label != .autoLabelled || $0.profile?.id != sam.id })
    }
}
