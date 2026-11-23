import Foundation
import SwiftData
import Testing
import TranscribeCore
@testable import TranscribeFakes
@testable import TranscribeKit

/// Whole journeys through the store, matched as the pipeline matches (library seed). Karan's seed voice has one
/// trusted named sample and one short (4.6 s) named sample; the car is setting axis 56.
@Suite("Voice learning: journeys")
@MainActor
struct LearningJourneyTests {
    static func car(_ i: Int) -> VoiceVector { SyntheticVoices.mix([(.karan, 0.35)], setting: (56, 0.7), variant: 51 + i) }

    /// A separated recording with one speaker, matched like the pipeline.
    func record(_ h: WP3Harness, _ vector: VoiceVector, at minutes: Double) throws -> (UUID, RecordingSpeaker) {
        let id = try h.separatedRecording(turns: SeedContent.conversationA,
                                          drafts: [WP3Docs.draft("S1", 1, clean: 12, vector: vector)],
                                          createdAt: Seeds.Dates.d.addingTimeInterval(minutes * 60))
        try h.matchLikeThePipeline(id)
        return (id, try #require(try h.recording(id).speaker("S1")))
    }

    func trace(_ s: RecordingSpeaker) throws -> MatchTrace {
        try JSONDecoder().decode(MatchTrace.self, from: try #require(s.matchTraceData))
    }

    @Test func carKaranLearnsInTwoSteps() throws {
        let h = try WP3Harness()
        defer { h.cleanup() }
        try h.seed(.library)
        let karan = try #require(try h.profile(named: "Karan"))

        // 1. Not recognised in the car (0.35): the user names it Karan, which stores a trusted corrected sample.
        let (id1, s1) = try record(h, Self.car(1), at: 1)
        #expect(s1.label == .unnamed)
        #expect(try trace(s1).kind == .unknown && abs((try trace(s1).score ?? 0) - 0.35) < 1e-4)
        let named = try h.store.nameSpeaker(recordingID: id1, key: "S1", as: .existing(profileID: karan.id), remember: true)
        #expect(named.sampleStored)
        let corrected = try #require(karan.samples.first { $0.sourceSpeakerID == s1.id })
        #expect(corrected.origin == .corrected && corrected.isTrusted)

        // 2. Next car recording: (0.6125 + 0.35) / 2 = 0.48125, so the app asks. Yes → a confirmed sample.
        let (id2, s2) = try record(h, Self.car(2), at: 2)
        #expect(s2.label == .suggested && s2.suggestedProfileID == karan.id)
        #expect(abs((s2.matchScore ?? 0) - 0.48125) < 1e-4)
        _ = try h.store.confirmSuggestion(recordingID: id2, key: "S1")
        #expect(karan.samples.first { $0.sourceSpeakerID == s2.id }?.origin == .confirmed)

        // 3. Third car recording: both car samples agree at 0.6125, clear of everyone: auto-labelled.
        let (_, s3) = try record(h, Self.car(3), at: 3)
        #expect(s3.label == .autoLabelled && s3.profile?.id == karan.id)
        #expect(abs((s3.matchScore ?? 0) - 0.6125) < 1e-4 && abs((s3.matchMargin ?? 0) - 0.6125) < 1e-4)
        // Its trusted score (0.6125) is under 0.70, so it stores no automatic sample.
        #expect(!karan.samples.contains { $0.sourceSpeakerID == s3.id })
    }

    @Test func aStrangerInTheSameCarIsNotAsked() throws {
        let h = try WP3Harness()
        defer { h.cleanup() }
        try h.seed(.library)
        let karan = try #require(try h.profile(named: "Karan"))
        let (id1, _) = try record(h, Self.car(1), at: 1)
        _ = try h.store.nameSpeaker(recordingID: id1, key: "S1", as: .existing(profileID: karan.id), remember: true)

        // Shares only the car with Karan's corrected sample: (0.49 + 0) / 2 = 0.245.
        let (_, stranger) = try record(h, SyntheticVoices.mix([(.stranger, 0.35)], setting: (56, 0.7), variant: 44), at: 2)
        #expect(stranger.label == .unnamed && stranger.suggestedProfileID == nil)
        let evidence = try #require(try trace(stranger).profiles.first { $0.profileID == karan.id })
        #expect(abs(evidence.score - 0.245) < 1e-4)
    }
}
