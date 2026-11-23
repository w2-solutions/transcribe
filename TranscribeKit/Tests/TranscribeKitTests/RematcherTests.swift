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
