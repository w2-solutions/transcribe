import Foundation
import SwiftData
import Testing
import TranscribeCore
@testable import TranscribeFakes
@testable import TranscribeKit

@Suite("WP3: Rematcher")
@MainActor
struct RematcherTests {
    /// Library seed plus one finished recording whose only speaker is unnamed.
    func setUp(vector: VoiceVector, clean: Double = 9, rejected: [UUID] = []) throws -> (WP3Harness, UUID) {
        let h = try WP3Harness()
        try h.seed(.library)
        let id = try h.readyRecording(turns: SeedContent.conversationA,
                                      drafts: [WP3Docs.draft("S1", 1, clean: clean, vector: vector)])
        try #require(try h.recording(id).speaker("S1")).rejectedProfileIDs = rejected
        try h.context.save()
        return (h, id)
    }

    func nameStranger(_ h: WP3Harness) throws -> VoiceProfile {
        _ = try h.store.nameSpeaker(recordingID: Seeds.ID.recordingC, key: "S2", as: .newPerson(name: "Sam"), remember: true)
        return try #require(try h.profile(named: "Sam"))
    }

    @Test func aCloseVoiceBecomesASuggestionNeverAnAutoLabel() throws {
        let (h, id) = try setUp(vector: SyntheticVoices.vector(near: .stranger, cosine: 0.85, variant: 22))
        defer { h.cleanup() }
        let sam = try nameStranger(h)
        let s1 = try #require(try h.recording(id).speaker("S1"))
        #expect(s1.label == .suggested && s1.suggestedProfileID == sam.id && s1.profile == nil)
        #expect(try !h.recording(id).hasUnseenResult)
        // The recording that was just named is not touched by its own rematch.
        #expect(try h.recording(Seeds.ID.recordingC).speaker("S2")?.label == .named)
    }

    @Test func aDistantVoiceStaysUnnamed() throws {
        let (h, id) = try setUp(vector: SyntheticVoices.vector(near: .stranger, cosine: 0.3, variant: 23))
        defer { h.cleanup() }
        _ = try nameStranger(h)
        #expect(try h.recording(id).speaker("S1")?.label == .unnamed)
    }

    @Test func aRejectedProfileIsNeverSuggested() throws {
        let (h, id) = try setUp(vector: SyntheticVoices.vector(near: .stranger, cosine: 0.85, variant: 22))
        defer { h.cleanup() }
        let sam = try nameStranger(h)
        try h.store.rejectSuggestion(recordingID: id, key: "S1")
        #expect(try h.recording(id).speaker("S1")?.rejectedProfileIDs == [sam.id])
        // Feeding Sam another sample re-runs the rematch; the rejection holds.
        let extra = try h.readyRecording(
            turns: SeedContent.conversationB,
            drafts: [WP3Docs.draft("S1", 1, clean: 12, vector: SyntheticVoices.vector(near: .stranger, cosine: 0.8, variant: 24))])
        _ = try h.store.nameSpeaker(recordingID: extra, key: "S1", as: .existing(profileID: sam.id), remember: true)
        #expect(try h.recording(id).speaker("S1")?.label == .unnamed)
    }

    @Test func tooLittleSpeechIsNotSuggested() throws {
        let (h, id) = try setUp(vector: SyntheticVoices.vector(near: .stranger, cosine: 0.85, variant: 22), clean: 2)
        defer { h.cleanup() }
        _ = try nameStranger(h)
        #expect(try h.recording(id).speaker("S1")?.label == .unnamed)
    }

    @Test func aNegativeBlocksTheSuggestion() throws {
        let h = try WP3Harness()
        defer { h.cleanup() }
        try h.seed(.library)
        func ready(_ vector: VoiceVector, clean: Double = 9) throws -> UUID {
            try h.readyRecording(turns: SeedContent.conversationA, drafts: [WP3Docs.draft("S1", 1, clean: clean, vector: vector)])
        }
        // 1–2. Sam is C's Speaker 2 (the stranger at 0.9); R1's voice (0.54 to Sam) is suggested, then rejected.
        let r1 = try ready(SyntheticVoices.mix([(.stranger, 0.6)], setting: (58, 0.7), variant: 22))
        let sam = try nameStranger(h)
        let r1S1 = try #require(try h.recording(r1).speaker("S1"))
        #expect(r1S1.label == .suggested && r1S1.suggestedProfileID == sam.id)
        #expect(abs((r1S1.matchScore ?? 0) - 0.54) < 1e-4)
        try h.store.rejectSuggestion(recordingID: r1, key: "S1")
        #expect(sam.negatives.count == 1 && sam.negatives[0].sourceSpeakerID == r1S1.id)

        // 3. Two unnamed voices: R2 shares R1's setting (axis 58), R3 does not.
        let r2 = try ready(SyntheticVoices.mix([(.stranger, 0.6)], setting: (58, 0.7), variant: 23))
        let r3 = try ready(SyntheticVoices.mix([(.stranger, 0.6)], setting: (59, 0.7), variant: 25))

        // 4. A new 12 s voice named Sam: the negative is 0.48 from it, under Sam's pre-add score of 0.72, so it stays.
        let r4 = try ready(SyntheticVoices.vector(near: .stranger, cosine: 0.8, variant: 24), clean: 12)
        _ = try h.store.nameSpeaker(recordingID: r4, key: "S1", as: .existing(profileID: sam.id), remember: true)
        #expect(sam.samples.count == 2)

        // 5. Both score (0.54 + 0.48) / 2 = 0.51. R2 is 0.85 from the negative (blocked); R3 is 0.36 (suggested).
        #expect(try h.recording(r2).speaker("S1")?.label == .unnamed)
        let r3S1 = try #require(try h.recording(r3).speaker("S1"))
        #expect(r3S1.label == .suggested && r3S1.suggestedProfileID == sam.id)
        #expect(abs((r3S1.matchScore ?? 0) - 0.51) < 1e-4)
        #expect(sam.negatives.count == 1)
    }

    @Test func aPersonAlreadyInTheRecordingIsNotSuggestedTwice() throws {
        let h = try WP3Harness()
        defer { h.cleanup() }
        try h.seed(.library)
        let liam = try #require(try h.profile(named: "Liam"))
        // Liam is S1 here; S2 sounds like Liam too but must not be suggested as a second Liam.
        let id = try h.readyRecording(
            turns: SeedContent.conversationB,
            drafts: [WP3Docs.draft("S1", 1, clean: 11, vector: SyntheticVoices.vector(near: .liam, cosine: 0.9, variant: 50)),
                     WP3Docs.draft("S2", 2, clean: 11, vector: SyntheticVoices.vector(near: .liam, cosine: 0.8, variant: 51))],
            decisions: ["S1": .autoLabel(profileID: liam.id, score: 0.9, margin: 0.9)])
        let changed = try Rematcher.run(changed: liam, excludingRecording: nil, context: h.context)
        #expect(changed == 0)
        #expect(try h.recording(id).speaker("S2")?.label == .unnamed)
    }
}
