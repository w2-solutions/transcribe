import Foundation
import SwiftData
import Testing
import TranscribeCore
@testable import TranscribeFakes
@testable import TranscribeKit

/// Capture channels in the store (§7): where samples and negatives get their channel, per-channel caps, the automatic
/// sample gate, the `karanFromIPhone` seed, `NameSpeakerModel.askContext` and the v2 matching log.
@Suite("Channel-aware store")
@MainActor
struct ChannelAwareStoreTests {
    static let phone = CaptureChannel.iphone, mac = CaptureChannel.mac

    /// A separated recording with one speaker, heard on `channel` (and `input`), matched like the pipeline.
    @discardableResult
    func record(_ h: WP3Harness, _ vector: VoiceVector, on channel: String, input: String? = nil, clean: Double = 12,
                at minutes: Double) throws -> (UUID, RecordingSpeaker) {
        let id = try h.separatedRecording(turns: SeedContent.conversationA,
                                          drafts: [WP3Docs.draft("S1", 1, clean: clean, vector: vector)],
                                          createdAt: Seeds.Dates.d.addingTimeInterval(minutes * 60))
        let r = try h.recording(id)
        r.captureChannel = channel
        if let input { r.captureDetailJSON = CaptureDetail(hardwareModel: "test", input: input, inputName: "Desk Mic").json() }
        try h.context.save()
        try h.matchLikeThePipeline(id)
        return (id, try #require(try h.recording(id).speaker("S1")))
    }

    func trace(_ s: RecordingSpeaker) throws -> MatchTrace {
        try JSONDecoder().decode(MatchTrace.self, from: try #require(s.matchTraceData))
    }

    func samples(_ p: VoiceProfile, on channel: String?) -> [VoiceSample] {
        p.samples.filter { $0.captureChannel == channel }
    }

    // MARK: Sample channels

    @Test func namingAnIPhoneRecordingOnAMacStoresAnIPhoneSample() throws {
        let h = try WP3Harness(channel: Self.mac)
        defer { h.cleanup() }
        try h.seed(.library)
        let (id, s1) = try record(h, SyntheticVoices.vector(near: .stranger, cosine: 0.9, variant: 30), on: Self.phone,
                                  input: CaptureDetail.Input.bluetoothHFP, at: 1)
        #expect(s1.label == .unnamed)
        let named = try h.store.nameSpeaker(recordingID: id, key: "S1", as: .newPerson(name: "Zed"), remember: true)
        #expect(named.sampleStored)
        let zed = try #require(try h.profile(named: "Zed"))
        let sample = try #require(zed.samples.first)
        // D10: the source recording's channel, never the device that clicked.
        #expect(sample.captureChannel == Self.phone && sample.captureInput == CaptureDetail.Input.bluetoothHFP)
    }

    @Test func confirmingAndNegativesTakeTheRecordingsChannelAndInput() throws {
        let h = try WP3Harness(channel: Self.mac)
        defer { h.cleanup() }
        try h.seed(.askKaran)
        let karan = try #require(try h.profile(named: "Karan"))
        // Recording D (S2 suggested as Karan) was heard on an iPhone over USB.
        let d = try h.recording(Seeds.ID.recordingD)
        d.captureChannel = Self.phone
        d.captureDetailJSON = CaptureDetail(hardwareModel: "iPhone15,4", input: CaptureDetail.Input.usbAudio).json()
        try h.context.save()
        try h.store.rejectSuggestion(recordingID: Seeds.ID.recordingD, key: "S2")
        let negative = try #require(karan.negatives.first)
        #expect(negative.captureChannel == Self.phone && negative.captureInput == CaptureDetail.Input.usbAudio)

        // Naming it Karan after all (D14) drops that negative and stores an iPhone sample.
        _ = try h.store.nameSpeaker(recordingID: Seeds.ID.recordingD, key: "S2", as: .existing(profileID: karan.id),
                                    remember: true)
        #expect(karan.negatives.isEmpty)
        let fed = try #require(karan.samples.first { $0.sourceRecordingID == Seeds.ID.recordingD })
        #expect(fed.captureChannel == Self.phone && fed.captureInput == CaptureDetail.Input.usbAudio)
    }

    // MARK: Per-channel caps (D12)

    @Test func insertionIntoOneChannelNeverEvictsAnother() throws {
        let h = try WP3Harness(channel: Self.mac)
        defer { h.cleanup() }
        try h.seed(.library)
        let karan = try #require(try h.profile(named: "Karan"))
        let macBefore = Set(samples(karan, on: Self.mac).map(\.id))
        #expect(macBefore.count == 2 && karan.samples.count == 2)

        // The same vector as a Mac sample is not a duplicate on another channel.
        #expect(h.store.insertSample(into: karan, vector: SyntheticVoices.base(.karan), modelKey: EmbeddingModelID.fake.key,
                                     origin: .confirmed, speechSeconds: 12, sourceRecordingID: nil, sourceSpeakerID: nil,
                                     clip: nil, quote: nil, channel: Self.phone, input: nil))
        // ...but it is on its own channel.
        #expect(!h.store.insertSample(into: karan, vector: SyntheticVoices.base(.karan), modelKey: EmbeddingModelID.fake.key,
                                      origin: .confirmed, speechSeconds: 12, sourceRecordingID: nil, sourceSpeakerID: nil,
                                      clip: nil, quote: nil, channel: Self.mac, input: nil))
        for v in 0..<14 {   // distinct voices near Karan (pairwise cosine 0.25): the iPhone set fills past its cap
            h.store.insertSample(into: karan, vector: SyntheticVoices.vector(near: .karan, cosine: 0.5, variant: 30 + v),
                                 modelKey: EmbeddingModelID.fake.key, origin: .confirmed, speechSeconds: 12,
                                 sourceRecordingID: nil, sourceSpeakerID: nil, clip: nil, quote: nil,
                                 channel: Self.phone, input: CaptureDetail.Input.builtInMic)
        }
        try h.context.save()
        #expect(samples(karan, on: Self.phone).count == MatchPolicy.default.maxSamplesPerProfile)
        #expect(Set(samples(karan, on: Self.mac).map(\.id)) == macBefore)
        #expect(karan.samples.count == MatchPolicy.default.maxSamplesPerProfile + 2)
        #expect(try h.count(VoiceSample.self) == 3 + MatchPolicy.default.maxSamplesPerProfile + 2)   // Liam's 3 untouched

        // Filling the Mac set evicts only Mac samples, and keeps the earliest named one.
        let earliestNamed = try #require(karan.sortedSamples.first { $0.origin == .named && $0.captureChannel == Self.mac })
        let phoneBefore = Set(samples(karan, on: Self.phone).map(\.id))
        for v in 0..<12 {
            h.store.insertSample(into: karan, vector: SyntheticVoices.vector(near: .karan, cosine: 0.5, variant: 45 + v),
                                 modelKey: EmbeddingModelID.fake.key, origin: .confirmed, speechSeconds: 12,
                                 sourceRecordingID: nil, sourceSpeakerID: nil, clip: nil, quote: nil, channel: Self.mac, input: nil)
        }
        try h.context.save()
        #expect(samples(karan, on: Self.mac).count == MatchPolicy.default.maxSamplesPerProfile)
        #expect(samples(karan, on: Self.mac).contains { $0.id == earliestNamed.id })
        #expect(Set(samples(karan, on: Self.phone).map(\.id)) == phoneBefore)
    }

    @Test func negativesAreCappedPerChannel() throws {
        let h = try WP3Harness(channel: Self.mac)
        defer { h.cleanup() }
        try h.seed(.askKaran)
        let karan = try #require(try h.profile(named: "Karan"))
        for v in 0..<MatchPolicy.default.maxNegativesPerProfile {
            let n = VoiceNegative(vector: SyntheticVoices.vector(near: .stranger, cosine: 0.3, variant: 30 + v),
                                  embeddingModelKey: EmbeddingModelID.fake.key,
                                  addedAt: Seeds.Dates.c.addingTimeInterval(Double(v)), speechSeconds: 8)
            h.context.insert(n)
            n.captureChannel = Self.mac
            n.profile = karan
        }
        try h.context.save()
        let macNegatives = Set(karan.negatives.map(\.id))
        try h.recording(Seeds.ID.recordingD).captureChannel = Self.phone
        try h.store.rejectSuggestion(recordingID: Seeds.ID.recordingD, key: "S2")
        #expect(karan.negatives.count == MatchPolicy.default.maxNegativesPerProfile + 1)
        #expect(macNegatives.isSubset(of: Set(karan.negatives.map(\.id))))
        #expect(karan.negatives.filter { $0.captureChannel == Self.phone }.count == 1)
    }

    // MARK: Matching across channels

    @Test func aForeignNegativeBlocksOnThisDevice() throws {
        let h = try WP3Harness(channel: Self.mac)
        defer { h.cleanup() }
        try h.seed(.askKaran)
        // On the iPhone, D's second voice was "not Karan".
        try h.recording(Seeds.ID.recordingD).captureChannel = Self.phone
        try h.store.rejectSuggestion(recordingID: Seeds.ID.recordingD, key: "S2")
        // The same voice recorded on the Mac would score 0.47 against Karan, but the iPhone negative blocks it.
        let (_, s) = try record(h, SyntheticVoices.vector(near: .karan, cosine: 0.47, variant: 6), on: Self.mac, at: 1)
        #expect(s.label == .unnamed && s.suggestedProfileID == nil)
        let t = try trace(s)
        #expect(t.reason == "blocked" && t.probeChannel == Self.mac)
        #expect(t.profiles.first { $0.profileID == Seeds.ID.karan }?.blocked == true)
    }

    @Test func theAutomaticSampleNeedsASameChannelTrustedScore() throws {
        let h = try WP3Harness(channel: Self.mac)
        defer { h.cleanup() }
        try h.seed(.library)
        let liam = try #require(try h.profile(named: "Liam"))
        for sample in liam.samples { sample.captureChannel = Self.phone }   // Liam learned on the iPhone only
        try h.context.save()

        // 1. A Mac recording of Liam at 0.6: only "Is this Liam?" (otherChannel). Yes stores a Mac sample.
        let (id1, s1) = try record(h, SyntheticVoices.vector(near: .liam, cosine: 0.6, variant: 40), on: Self.mac, at: 1)
        #expect(s1.label == .suggested && s1.suggestedProfileID == liam.id)
        #expect(try trace(s1).reason == "otherChannel")
        _ = try h.store.confirmSuggestion(recordingID: id1, key: "S1")
        #expect(samples(liam, on: Self.mac).map(\.origin) == [.confirmed])

        // 2. A clear Mac recording (0.9 to the iPhone samples, 0.54 to the Mac one): (0.54 + 0.9) / 2 = 0.72 auto-labels,
        //    but the Mac trusted score is 0.54, under 0.70, so no automatic sample. Before channels it would be 0.9.
        let (_, s2) = try record(h, SyntheticVoices.vector(near: .liam, cosine: 0.9, variant: 41), on: Self.mac, at: 2)
        #expect(s2.label == .autoLabelled && s2.profile?.id == liam.id)
        #expect(abs((s2.matchScore ?? 0) - 0.72) < 1e-4)
        let liamEvidence = try #require(try trace(s2).profiles.first { $0.profileID == liam.id })
        #expect(abs((liamEvidence.trustedScore ?? 0) - 0.54) < 1e-4 && liamEvidence.otherChannelTrustedCount == 3)
        #expect(!liam.samples.contains { $0.sourceSpeakerID == s2.id })

        // 3. The same clear voice on the iPhone: trusted score 0.9, so the automatic sample is stored there.
        let (_, s3) = try record(h, SyntheticVoices.vector(near: .liam, cosine: 0.9, variant: 42), on: Self.phone, at: 3)
        #expect(s3.label == .autoLabelled)
        let auto = try #require(liam.samples.first { $0.sourceSpeakerID == s3.id })
        #expect(auto.origin == .strongMatch && auto.captureChannel == Self.phone)
    }

    // MARK: Merge

    @Test func mergeKeepsEachSamplesAndNegativesChannel() throws {
        let h = try WP3Harness(channel: Self.mac)
        defer { h.cleanup() }
        try h.seed(.library)
        let karan = try #require(try h.profile(named: "Karan"))
        let source = VoiceProfile(name: "K2", colourSlot: 4, embeddingModelKey: EmbeddingModelID.fake.key, now: Seeds.Dates.d)
        h.context.insert(source)
        let sample = VoiceSample(vector: SyntheticVoices.vector(near: .karan, cosine: 0.5, variant: 30),
                                 embeddingModelKey: EmbeddingModelID.fake.key, origin: .confirmed, addedAt: Seeds.Dates.d,
                                 speechSeconds: 12)
        h.context.insert(sample)
        sample.captureChannel = Self.phone
        sample.captureInput = CaptureDetail.Input.headsetMic
        sample.profile = source
        let negative = VoiceNegative(vector: SyntheticVoices.vector(near: .stranger, cosine: 0.5, variant: 31),
                                     embeddingModelKey: EmbeddingModelID.fake.key, addedAt: Seeds.Dates.d, speechSeconds: 8)
        h.context.insert(negative)
        negative.captureChannel = Self.phone
        negative.captureInput = CaptureDetail.Input.headsetMic
        negative.profile = source
        try h.context.save()

        try h.store.mergeProfiles(source: source.id, into: karan.id)
        let moved = try #require(samples(karan, on: Self.phone).first)
        #expect(moved.captureInput == CaptureDetail.Input.headsetMic && moved.origin == .confirmed)
        #expect(samples(karan, on: Self.mac).count == 2)
        let movedNegative = try #require(karan.negatives.first)
        #expect(movedNegative.captureChannel == Self.phone && movedNegative.captureInput == CaptureDetail.Input.headsetMic)
    }

    // MARK: Seed and ask context

    @Test func karanFromIPhoneSeed() throws {
        let h = try WP3Harness(channel: Self.mac)
        defer { h.cleanup() }
        try h.seed(.karanFromIPhone)
        let karan = try #require(try h.profile(named: "Karan"))
        let liam = try #require(try h.profile(named: "Liam"))
        #expect(karan.samples.count == 2 && karan.samples.allSatisfy { $0.captureChannel == Self.phone })
        #expect(try h.recording(Seeds.ID.recordingA).captureChannel == Self.phone)
        #expect(try h.recording(Seeds.ID.recordingB).captureChannel == Self.phone)
        #expect(try h.recording(Seeds.ID.recordingC).captureChannel == Self.mac)
        // Liam's samples follow their source recordings: C on this Mac, A and B on the iPhone.
        for s in liam.samples {
            #expect(s.captureChannel == (s.sourceRecordingID == Seeds.ID.recordingC ? Self.mac : Self.phone))
        }
        let counts = Seeds.expectedCounts(.karanFromIPhone)
        let actual = (try h.count(Recording.self), try h.count(VoiceProfile.self), try h.count(VoiceSample.self))
        #expect(actual == counts)

        // Karan on the Mac: asked about (otherChannel); Liam on the Mac: auto-labelled from C.
        let (id, s) = try record(h, SyntheticVoices.vector(near: .karan, cosine: 0.8, variant: 33), on: Self.mac, at: 1)
        #expect(s.label == .suggested && s.suggestedProfileID == karan.id)
        #expect(try trace(s).reason == "otherChannel")
        let (_, l) = try record(h, SyntheticVoices.vector(near: .liam, cosine: 0.8, variant: 34), on: Self.mac, at: 2)
        #expect(l.label == .autoLabelled && l.profile?.id == liam.id)

        // The sheet knows the suggestion was learned on the iPhone.
        let profiles = try h.context.fetch(FetchDescriptor<VoiceProfile>())
        let model = NameSpeakerModel(recording: try h.recording(id), key: "S1", mode: .name, profiles: profiles)
        #expect(model.askContext == .otherDevice(channel: Self.phone))
        // The device copy names the other device (`DeviceCopy.askFromOtherDevice`).
        let macModel = NameSpeakerModel(recording: try h.recording(id), key: "S1", mode: .name, profiles: profiles,
                                        platform: .mac)
        #expect(macModel.askPrompt == "Karan was named on your iPhone. Each microphone hears a voice a little differently, so Transcribe asks once here. Is this Karan?")
        #expect(NameSpeakerModel.askContext(for: karan, recordingChannel: Self.phone) == nil)
        #expect(NameSpeakerModel.askContext(for: liam, recordingChannel: Self.mac) == nil)
        // An ordinary suggestion on Karan's own channel has no ask context.
        let (homeID, home) = try record(h, SyntheticVoices.vector(near: .karan, cosine: 0.5, variant: 35), on: Self.phone, at: 3)
        #expect(home.label == .suggested)
        let homeModel = NameSpeakerModel(recording: try h.recording(homeID), key: "S1", mode: .name, profiles: profiles)
        #expect(homeModel.askContext == nil)
        #expect(homeModel.askPrompt == nil)
    }

    /// The `MacCrossDeviceTests` flow through the fake engine (`karanFromIPhone` seed, `newVoices` script, a Mac
    /// store): Karan is asked about once, confirmed, and auto-labelled in the next Mac recording; Liam auto-labels
    /// throughout from his Mac sample. (`knownVoices` cannot teach the Mac: Karan speaks 4.6 s in conversation A,
    /// under the 5 s needed to add a sample.)
    @Test func macCrossDeviceFlowThroughTheFakeEngine() async throws {
        let p = try await WP3Pipeline(.newVoices, seed: .karanFromIPhone, harness: try WP3Harness(channel: Self.mac))
        defer { p.cleanup() }
        let karan = try #require(try p.h.profile(named: "Karan"))
        let liam = try #require(try p.h.profile(named: "Liam"))

        let first = try p.record()
        _ = await p.run(first)
        let r1 = try p.h.recording(first)
        #expect(r1.captureChannel == Self.mac)
        let liam1 = try #require(r1.speaker("S1")), karan1 = try #require(r1.speaker("S2"))
        #expect(liam1.label == .autoLabelled && liam1.profile?.id == liam.id)
        #expect(karan1.label == .suggested && karan1.suggestedProfileID == karan.id)
        #expect(try trace(karan1).reason == "otherChannel")

        _ = try p.h.store.confirmSuggestion(recordingID: first, key: "S2")
        #expect(karan.samples.contains { $0.captureChannel == Self.mac && $0.isTrusted })

        let second = try p.record()
        _ = await p.run(second)
        let r2 = try p.h.recording(second)
        #expect(r2.speaker("S1")?.label == .autoLabelled && r2.speaker("S1")?.profile?.id == liam.id)
        #expect(r2.speaker("S2")?.label == .autoLabelled && r2.speaker("S2")?.profile?.id == karan.id)
    }

    // MARK: Matching log v2

    @Test func matchingLogV2Shape() throws {
        let h = try WP3Harness(channel: Self.mac)
        defer { h.cleanup() }
        try h.seed(.karanFromIPhone)
        let (id, _) = try record(h, SyntheticVoices.vector(near: .karan, cosine: 0.8, variant: 33), on: Self.mac,
                                 input: CaptureDetail.Input.builtInMic, at: 1)
        let text = try h.store.matchingLog()
        #expect(!text.contains("Desk Mic"))   // the input's device name is never exported
        let log = try MatchLog.decoder().decode(MatchLog.self, from: Data(text.utf8))
        #expect(log.version == 2 && MatchLog.currentVersion == 2)
        let karan = try #require(log.profiles.first { $0.id == Seeds.ID.karan })
        #expect(karan.samplesByChannel == [Self.phone: 2] && karan.trustedByChannel == [Self.phone: 1])
        let liam = try #require(log.profiles.first { $0.id == Seeds.ID.liam })
        #expect(liam.samplesByChannel == [Self.mac: 1, Self.phone: 2] && liam.trustedByChannel == [Self.mac: 1, Self.phone: 2])
        let row = try #require(log.recordings.first { $0.id == id })
        #expect(row.channel == Self.mac && row.input == CaptureDetail.Input.builtInMic)
        #expect(row.speakers.first?.trace?.probeChannel == Self.mac && row.speakers.first?.trace?.version == 2)
        #expect(row.speakers.first?.trace?.reason == "otherChannel")
        let seeded = try #require(log.recordings.first { $0.id == Seeds.ID.recordingA })
        #expect(seeded.channel == Self.phone && seeded.input == nil)

        // The v2 keys are present in the JSON.
        for key in ["\"samplesByChannel\"", "\"trustedByChannel\"", "\"channel\"", "\"input\"", "\"probeChannel\""] {
            #expect(text.contains(key), "missing \(key)")
        }
    }
}

extension ChannelAwareStoreTests {
    /// The cohort window (100 recordings, 300 voices) applies per capture channel, so many recordings synced from another
    /// device never push this channel's never-named voices out of it.
    @Test func anotherChannelsRecordingsDoNotPushThisChannelsVoicesOutOfTheCohort() throws {
        let h = try WP3Harness(channel: Self.phone)
        defer { h.cleanup() }
        let key = EmbeddingModelID.fake.key
        let brother = SyntheticVoices.vector(near: .stranger, cosine: 0.9, variant: 52)
        let old = try h.readyRecording(turns: SeedContent.conversationA, drafts: [WP3Docs.draft("S1", 1, clean: 12, vector: brother)],
                                       createdAt: Seeds.Dates.d)
        try h.recording(old).captureChannel = Self.phone
        for i in 0..<100 {
            let v = SyntheticVoices.vector(near: .liam, cosine: 0.2 + Float(i) * 0.005, variant: 10 + i % 40)
            let id = try h.readyRecording(turns: SeedContent.conversationA, drafts: [WP3Docs.draft("S1", 1, clean: 12, vector: v)],
                                          createdAt: Seeds.Dates.d.addingTimeInterval(Double(i + 1) * 60))
            try h.recording(id).captureChannel = Self.mac
        }
        try h.context.save()
        let cohort = try h.store.matchCohort(modelKey: key, excludingRecording: UUID())
        #expect(cohort.contains(brother))
        #expect(cohort.count == 101)   // every Mac voice still counts too
    }
}
