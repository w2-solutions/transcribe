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

    /// With sound groups (decision D3), the car is a group of its own: naming Karan there once is enough for the next
    /// car recording to be auto-labelled. Before groups the car sample had to borrow its second place from Karan's
    /// room samples, (0.6125 + 0.35) / 2 = 0.48125, so the app asked once more.
    @Test func carKaranLearnsInOneStep() throws {
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

        // 2. Next car recording: the car group (one trusted sample) scores its own cosine, 0.6125, clear of everyone:
        //    auto-labelled. The whole score W is still 0.48125.
        let (_, s2) = try record(h, Self.car(2), at: 2)
        #expect(s2.label == .autoLabelled && s2.profile?.id == karan.id)
        #expect(abs((s2.matchScore ?? 0) - 0.6125) < 1e-4 && abs((s2.matchMargin ?? 0) - 0.6125) < 1e-4)
        let evidence = try #require(try trace(s2).profiles.first { $0.profileID == karan.id })
        #expect(abs((evidence.score ?? 0) - 0.48125) < 1e-4 && abs((evidence.autoScore ?? 0) - 0.6125) < 1e-4)
        #expect(evidence.groupSize == 1)
        // Its trusted score is the channel's top two trusted, (0.6125 + 0.35) / 2, under 0.70: no automatic sample.
        #expect(!karan.samples.contains { $0.sourceSpeakerID == s2.id })

        // 3. Third car recording: the same.
        let (_, s3) = try record(h, Self.car(3), at: 3)
        #expect(s3.label == .autoLabelled && s3.profile?.id == karan.id)
        #expect(abs((s3.matchScore ?? 0) - 0.6125) < 1e-4)
        #expect(!karan.samples.contains { $0.sourceSpeakerID == s3.id })
    }

    /// §7: Karan was learned on the iPhone (`karanFromIPhone`); this store is a Mac. The first Mac recording can only
    /// ask; confirming it stores a Mac sample, and the next Mac recording is auto-labelled.
    @Test func karanLearnedOnTheIPhoneIsAskedThenLearnedOnTheMac() throws {
        let h = try WP3Harness(channel: CaptureChannel.mac)
        defer { h.cleanup() }
        try h.seed(.karanFromIPhone)
        let karan = try #require(try h.profile(named: "Karan"))
        #expect(karan.samples.allSatisfy { $0.captureChannel == CaptureChannel.iphone })

        // 1. 0.8 to both iPhone samples, which can only fill second place on the Mac: "Is this Karan?".
        let (id1, s1) = try record(h, SyntheticVoices.vector(near: .karan, cosine: 0.8, variant: 36), at: 1)
        #expect(try h.recording(id1).captureChannel == CaptureChannel.mac)
        #expect(s1.label == .suggested && s1.suggestedProfileID == karan.id)
        let t1 = try trace(s1)
        #expect(t1.kind == .ask && t1.reason == "otherChannel" && t1.probeChannel == CaptureChannel.mac)
        #expect(abs((t1.score ?? 0) - 0.8) < 1e-4)

        // 2. Yes: a confirmed 12 s sample, heard on the Mac.
        _ = try h.store.confirmSuggestion(recordingID: id1, key: "S1")
        let confirmed = try #require(karan.samples.first { $0.sourceSpeakerID == s1.id })
        #expect(confirmed.origin == .confirmed && confirmed.isTrusted && confirmed.captureChannel == CaptureChannel.mac)
        #expect(karan.samples.filter { $0.captureChannel == CaptureChannel.iphone }.count == 2)

        // 3. The next Mac recording: the Mac sample is a sound group of its own and scores alone, 0.64: auto. (The
        //    whole score W is 0.72: the Mac sample first, an iPhone one (0.8) second; W still decides asking.)
        let (_, s2) = try record(h, SyntheticVoices.vector(near: .karan, cosine: 0.8, variant: 37), at: 2)
        #expect(s2.label == .autoLabelled && s2.profile?.id == karan.id)
        #expect(abs((s2.matchScore ?? 0) - 0.64) < 1e-4)
        let evidence = try #require(try trace(s2).profiles.first { $0.profileID == karan.id })
        #expect(evidence.trustedCount == 1 && evidence.otherChannelTrustedCount == 1)
        #expect(abs((evidence.score ?? 0) - 0.72) < 1e-4 && abs((evidence.autoScore ?? 0) - 0.64) < 1e-4)
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
