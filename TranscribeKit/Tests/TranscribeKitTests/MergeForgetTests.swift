import Foundation
import SwiftData
import Testing
import TranscribeCore
@testable import TranscribeFakes
@testable import TranscribeKit

@Suite("WP3: merge and forget")
@MainActor
struct MergeForgetTests {
    @Test func forgetKeepsNameSnapshotsAndDeletesSamples() throws {
        let h = try WP3Harness()
        defer { h.cleanup() }
        try h.seed(.library)
        let karan = try #require(try h.profile(named: "Karan"))
        try h.store.forgetProfile(karan.id)
        #expect(try h.profile(named: "Karan") == nil)
        #expect(try h.count(VoiceSample.self) == 3)          // Liam's three remain
        for id in [Seeds.ID.recordingA, Seeds.ID.recordingB] {
            let s2 = try #require(try h.recording(id).speaker("S2"))
            #expect(s2.profile == nil && s2.nameSnapshot == "Karan" && s2.displayName == "Karan" && s2.label == .named)
            #expect(try h.recording(id).searchText.contains("karan"))
        }
        // Recording A is no longer "recognised" for Karan, but Liam is still auto-labelled.
        #expect(try h.recording(Seeds.ID.recordingA).hasUnseenResult)
        #expect(throws: StoreError.self) { try h.store.forgetProfile(karan.id) }
    }

    @Test func forgetClearsSuggestionsOfTheProfile() throws {
        let h = try WP3Harness()
        defer { h.cleanup() }
        try h.seed(.askKaran)
        try h.store.forgetProfile(Seeds.ID.karan)
        let s2 = try #require(try h.recording(Seeds.ID.recordingD).speaker("S2"))
        #expect(s2.label == .unnamed && s2.suggestedProfileID == nil && s2.matchScore == nil)
        #expect(try h.recording(Seeds.ID.recordingD).speakersNeedingName.map(\.key) == ["S2"])
    }

    @Test func mergeRepointsSpeakersKeepsSlotsAndTransfersMe() throws {
        let h = try WP3Harness()
        defer { h.cleanup() }
        try h.seed(.library)
        let c = Seeds.ID.recordingC
        // C's Speaker 2 becomes a separate "Kay" profile that is really Karan.
        _ = try h.store.nameSpeaker(recordingID: c, key: "S2", as: .newPerson(name: "Kay"), remember: true)
        let kay = try #require(try h.profile(named: "Kay"))
        let karan = try #require(try h.profile(named: "Karan"))
        try h.store.setIsMe(profileID: kay.id)
        let slotBefore = try #require(try h.recording(c).speaker("S2")?.colourSlot)
        let cS2 = try #require(try h.recording(c).speaker("S2"))

        try h.store.mergeProfiles(source: kay.id, into: karan.id)
        #expect(try h.profile(named: "Kay") == nil)
        let s2 = try #require(try h.recording(c).speaker("S2"))
        #expect(s2.profile?.id == karan.id && s2.colourSlot == slotBefore && s2.displayName == "Karan")
        #expect(karan.samples.count == 3 && karan.samples.contains { $0.origin == .named && $0.sourceSpeakerID == cS2.id })
        let liamIsMe = try #require(try h.profile(named: "Liam")).isMe
        #expect(karan.isMe && !liamIsMe)
        #expect(try h.recording(c).searchText.contains("karan"))
        #expect(karan.recordingCount == 3)
        #expect(throws: StoreError.self) { try h.store.mergeProfiles(source: karan.id, into: karan.id) }
    }

    @Test func mergeCuratesToTheCap() throws {
        let h = try WP3Harness()
        defer { h.cleanup() }
        try h.seed(.library)
        let karan = try #require(try h.profile(named: "Karan"))
        let source = VoiceProfile(name: "K2", colourSlot: 4, embeddingModelKey: EmbeddingModelID.fake.key, now: Seeds.Dates.d)
        h.context.insert(source)
        for v in 0..<11 {   // eleven distinct voices near Karan (pairwise cosine 0.25): 2 + 11 = 13, one over the cap
            let sample = VoiceSample(vector: SyntheticVoices.vector(near: .karan, cosine: 0.5, variant: 30 + v),
                                     embeddingModelKey: EmbeddingModelID.fake.key, origin: .confirmed,
                                     addedAt: Seeds.Dates.d.addingTimeInterval(Double(v)), speechSeconds: 12)
            h.context.insert(sample)
            sample.captureChannel = CaptureChannel.iphone   // Karan's channel: the cap is per channel (D12)
            sample.profile = source
        }
        try h.context.save()
        try h.store.mergeProfiles(source: source.id, into: karan.id)
        #expect(karan.samples.count == MatchPolicy.default.maxSamplesPerProfile)
        #expect(karan.samples.contains { $0.origin == .named })          // the first named sample survives
        #expect(try h.count(VoiceProfile.self) == 2)
    }

    @Test func mergeIntoAFullDestinationKeepsTheNewestNegatives() throws {
        let h = try WP3Harness()
        defer { h.cleanup() }
        try h.seed(.library)
        let karan = try #require(try h.profile(named: "Karan"))
        let source = VoiceProfile(name: "K2", colourSlot: 4, embeddingModelKey: EmbeddingModelID.fake.key, now: Seeds.Dates.d)
        h.context.insert(source)
        let day: TimeInterval = 86_400
        func negative(variant: Int, day d: Double, on p: VoiceProfile) -> VoiceNegative {
            // Distinct voices (pairwise cosine 0.25) from no speaker in the library.
            let n = VoiceNegative(vector: SyntheticVoices.vector(near: .stranger, cosine: 0.5, variant: variant),
                                  embeddingModelKey: EmbeddingModelID.fake.key,
                                  addedAt: Seeds.Dates.a.addingTimeInterval(d * day), speechSeconds: 8)
            h.context.insert(n)
            n.profile = p
            return n
        }
        // Karan is at the cap with d1…d8 (days 10 to 17); K2 has two older ones (days 1 and 2).
        let dst = (0..<8).map { negative(variant: 30 + $0, day: Double(10 + $0), on: karan) }
        _ = (0..<2).map { negative(variant: 38 + $0, day: Double(1 + $0), on: source) }
        try h.context.save()
        let dstVectors = dst.map(\.vectorData)

        try h.store.mergeProfiles(source: source.id, into: karan.id)
        // The newest eight overall are Karan's own: no newer negative is dropped for an older moved one.
        #expect(karan.negatives.count == MatchPolicy.default.maxNegativesPerProfile)
        #expect(Set(karan.negatives.map(\.vectorData)) == Set(dstVectors))
        #expect(try h.count(VoiceNegative.self) == 8)
    }

    @Test func forgetAndMergeRejectionsFollowTheProfile() throws {
        let h = try WP3Harness()
        defer { h.cleanup() }
        try h.seed(.askKaran)
        try h.store.rejectSuggestion(recordingID: Seeds.ID.recordingD, key: "S2")
        let k2 = VoiceProfile(name: "K2", colourSlot: 4, embeddingModelKey: EmbeddingModelID.fake.key, now: Seeds.Dates.d)
        h.context.insert(k2)
        try h.context.save()
        try h.store.mergeProfiles(source: Seeds.ID.karan, into: k2.id)
        let s2 = try #require(try h.recording(Seeds.ID.recordingD).speaker("S2"))
        #expect(s2.rejectedProfileIDs == [k2.id])
    }
}
