import Foundation
import SwiftData
import Testing
import TranscribeCore
@testable import TranscribeFakes
@testable import TranscribeKit

@Suite("Skeleton: store container and seeds")
@MainActor
struct SkeletonSeedTests {
    func tempPaths() -> AppPaths {
        AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent("seed-\(UUID().uuidString)", isDirectory: true))
    }

    @Test func inMemoryContainerOpens() throws {
        let container = try ModelContainerFactory.make(inMemory: true, url: nil)
        #expect(try container.mainContext.fetchCount(FetchDescriptor<Recording>()) == 0)
    }

    @Test(arguments: SeedName.allCases)
    func everySeedApplies(_ seed: SeedName) throws {
        let container = try ModelContainerFactory.make(inMemory: true, url: nil)
        let paths = tempPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let context = container.mainContext
        try Seeds.apply(seed, context: context, paths: paths, clock: .frozen(Seeds.Dates.a))
        let expected = Seeds.expectedCounts(seed)
        #expect(try context.fetchCount(FetchDescriptor<Recording>()) == expected.recordings)
        #expect(try context.fetchCount(FetchDescriptor<VoiceProfile>()) == expected.profiles)
        #expect(try context.fetchCount(FetchDescriptor<VoiceSample>()) == expected.samples)
        for r in try context.fetch(FetchDescriptor<Recording>()) {
            // A recording seeded with a channel may have been heard on another device, whose audio stays there; one
            // without a channel is this device's and has its WAV.
            if r.captureChannel == nil {
                #expect(FileManager.default.fileExists(atPath: paths.audioURL(fileName: r.audioFileName).path))
            }
            #expect(r.transcript != nil)
            #expect(r.peaks.count == SyntheticAudio.peakBins)
        }
        // Applying again replaces rather than duplicates.
        try Seeds.apply(seed, context: context, paths: paths, clock: .system)
        #expect(try context.fetchCount(FetchDescriptor<Recording>()) == expected.recordings)
    }

    @Test func librarySeedMatchesTheMockup() throws {
        let container = try ModelContainerFactory.make(inMemory: true, url: nil)
        let paths = tempPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let context = container.mainContext
        try Seeds.apply(.library, context: context, paths: paths, clock: .system)
        let recordings = try context.fetch(FetchDescriptor<Recording>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)]))
        #expect(recordings.map(\.id) == [Seeds.ID.recordingA, Seeds.ID.recordingB, Seeds.ID.recordingC])
        let a = recordings[0], b = recordings[1], c = recordings[2]
        #expect(a.hasUnseenResult && a.duration == 20 && a.sortedSpeakers.map(\.displayName) == ["Liam", "Karan"])
        #expect(a.sortedSpeakers.map(\.label) == [.autoLabelled, .autoLabelled])
        #expect(b.isFavourite && b.duration == 24 && b.transcript?.turns.count == 4)
        #expect(c.duration == 768 && c.speakersNeedingName.map(\.ordinal) == [2])
        #expect(c.sortedSpeakers.map(\.displayName) == ["Liam", "Speaker 2"])
        let liam = try #require(try context.fetch(FetchDescriptor<VoiceProfile>()).first { $0.name == "Liam" })
        #expect(liam.isMe && liam.colourSlot == 0 && liam.samples.count == 3)
        #expect(liam.recordingCount == 3)
        #expect(liam.samples.allSatisfy { $0.sourceSpeakerID != nil })
    }

    /// The numbers the samples card and the voice-groups UI tests rely on, checked through the real grouping, resolver
    /// and view model after the launch stamp, on both channels the UI tests run on.
    @Test(arguments: [CaptureChannel.iphone, CaptureChannel.mac])
    func voiceGroupsSeedMakesThreeLocalGroupsAndOneOnIPad(_ local: String) throws {
        let h = try WP3Harness(channel: local)
        defer { h.cleanup() }
        try h.seed(.voiceGroups)   // applies the seed, then stamps channels as a launch does
        let ids = Seeds.ID.tomSamples
        let tom = try #require(try h.profile(named: "Tom"))
        let samples = tom.sortedSamples
        #expect(samples.map(\.id) == ids)
        #expect(samples.map(\.captureChannel) == Array(repeating: local, count: 8) + [CaptureChannel.ipad, CaptureChannel.ipad])
        #expect(tom.recordingCount == 2)
        let label = try #require(tom.groupLabels.first)
        #expect(tom.groupLabels.count == 1 && label.id == Seeds.ID.closeLabel && label.text == "Close")
        #expect(label.captureChannel == local)

        let recordings = try h.context.fetch(FetchDescriptor<Recording>())
        let byID = Dictionary(uniqueKeysWithValues: recordings.map { ($0.id, $0) })
        let t1 = try #require(byID[Seeds.ID.recordingT1]), t2 = try #require(byID[Seeds.ID.recordingT2])
        #expect(t1.captureChannel == local && t2.captureChannel == CaptureChannel.ipad)
        #expect(FileManager.default.fileExists(atPath: h.paths.audioURL(fileName: t1.audioFileName).path))
        #expect(!FileManager.default.fileExists(atPath: h.paths.audioURL(fileName: t2.audioFileName).path))
        #expect(t1.sortedSpeakers.map(\.displayName) == ["Liam", "Tom"])
        // Every clip but the gone recording's points at Tom's own turn.
        for s in samples where s.sourceRecordingID != Seeds.ID.goneRecording {
            let sourceID = try #require(s.sourceRecordingID)
            let source = try #require(byID[sourceID])
            #expect(source.speakers.first { $0.id == s.sourceSpeakerID }?.profile?.id == Seeds.ID.tom)
        }

        // The grouping and the resolver, on exactly what the screen and the store feed them.
        let split = GroupingInput.split(tom, localChannel: local)
        #expect(split.items.count == 10 && split.ungrouped.isEmpty)
        let dimension = try #require(GroupingInput.dimension(ofModelKey: tom.embeddingModelKey))
        let groups = SampleGrouping.group(split.items, dimension: dimension)
        let byChannel = Dictionary(grouping: groups, by: \.channel)
        #expect(byChannel[local]?.map(\.memberIDs) == [[ids[0], ids[1], ids[5]], [ids[2], ids[3], ids[4]], [ids[6], ids[7]]])
        #expect(byChannel[CaptureChannel.ipad]?.map(\.memberIDs) == [[ids[8], ids[9]]])
        let anchors = GroupingInput.anchors(tom)
        let vectors = Dictionary(uniqueKeysWithValues: split.items.map { ($0.id, $0.vector) })
        let placement = GroupLabelResolver.resolve(groups: groups, memberVectors: vectors, labels: anchors)
        #expect(placement.placed == [ids[0]: Seeds.ID.closeLabel])
        #expect(placement.contenders.isEmpty && placement.unplaced.isEmpty)
        let close = try #require(byChannel[local]?.first)
        let anchor = try #require(anchors.first)
        let fit = try #require(GroupLabelResolver.fit(anchor, close, memberVectors: vectors))
        #expect(fit.present == 3)

        // The samples card.
        let view = VoiceSampleGroups.build(profile: tom, recordingsByID: byID, localChannel: local, paths: h.paths)
        #expect(view.showsNote && view.showsChannelHeaders)
        #expect(view.channels.map(\.channel) == [local, CaptureChannel.ipad])
        #expect(view.channels.map(\.sampleCount) == [8, 2])
        #expect(view.channels.allSatisfy { $0.ungroupedIndexes.isEmpty && $0.ungroupedSubtitle == nil })

        let here = view.channels[0].groups
        #expect(here.map(\.title) == ["Close", "Group 2", "Group 3"])
        #expect(here.map(\.isLabelled) == [true, false, false])
        #expect(here.map(\.position) == [0, 1, 2])
        #expect(here.map(\.sampleIndexes) == [[0, 1, 5], [2, 3, 4], [6, 7]])
        #expect(here.map(\.sampleIndexes.count) == [3, 3, 2])
        #expect(here.map(\.showsHeader) == [true, true, true])
        #expect(here.map(\.subtitle) == Array(repeating: "From \u{201C}Kitchen chat\u{201D}", count: 3))
        #expect(here.map(\.ref.shownLabelID) == [Seeds.ID.closeLabel, nil, nil])
        #expect(here.map(\.playSampleID) == [ids[0], ids[2], ids[6]])
        let closePlays = try #require(samples.first { $0.id == here[0].playSampleID }?.clipRange)
        #expect(closePlays.duration >= 4)

        let iPad = view.channels[1].groups
        #expect(iPad.count == 1)
        #expect(iPad.first?.title == "Group 1" && iPad.first?.isLabelled == false && iPad.first?.showsHeader == false)
        #expect(iPad.first?.sampleIndexes == [8, 9] && iPad.first?.playSampleID == nil)

        // Every sample's clip state: 3 recording deleted, 4 no clip saved, 8 and 9 audio on the iPad, the rest play.
        for (i, s) in samples.enumerated() {
            let state = view.clipStates[s.id]
            switch i {
            case 3: #expect(state == .recordingDeleted)
            case 4: #expect(state == .noClip)
            case 8, 9: #expect(state == .audioElsewhere(channel: CaptureChannel.ipad))
            default:
                let clip = try #require(s.clipRange)
                #expect(state == .playable(fileName: t1.audioFileName, range: clip), "sample \(i)")
            }
        }
        let copy = DeviceCopy(platform: local == CaptureChannel.mac ? .mac : .iPhone)
        #expect(view.clipStates[ids[3]]?.caption(copy) == "Recording deleted")
        #expect(view.clipStates[ids[4]]?.caption(copy) == "No clip saved")
        #expect(view.clipStates[ids[8]]?.caption(copy) == "Audio is on your iPad")

        // The store accepts the screen's refs: labelling Group 2 shows it, and the seeded label stays on Close.
        try h.store.setGroupLabel(here[1].ref, text: "Far")
        let relabelled = VoiceSampleGroups.build(profile: tom, recordingsByID: byID, localChannel: local, paths: h.paths)
        #expect(relabelled.channels[0].groups.map(\.title) == ["Close", "Far", "Group 3"])
    }
}

@Suite("Skeleton: synthetic voices")
struct SyntheticVoicesTests {
    @Test func basesAreOrthonormal() {
        for p in SyntheticPerson.allCases {
            for q in SyntheticPerson.allCases {
                let c = SyntheticVoices.base(p).cosine(SyntheticVoices.base(q))
                #expect(abs(c - (p == q ? 1 : 0)) < 1e-4, "\(p) · \(q) = \(c)")
            }
        }
    }

    @Test(arguments: [(SyntheticPerson.liam, Float(0.90), 1), (.karan, 0.90, 2), (.liam, 0.82, 3), (.karan, 0.71, 4),
                      (.karan, 0.47, 6), (.stranger, 0.9, 20)])
    func exactCosines(_ p: SyntheticPerson, _ c: Float, _ variant: Int) {
        let v = SyntheticVoices.vector(near: p, cosine: c, variant: variant)
        #expect(v.dimension == 256)
        #expect(abs(v.cosine(SyntheticVoices.base(p)) - c) < 1e-4)
        for other in SyntheticPerson.allCases where other != p {
            #expect(abs(v.cosine(SyntheticVoices.base(other))) < 1e-4)
        }
    }

    @Test func variantsOfOnePersonMultiply() {
        let a = SyntheticVoices.vector(near: .liam, cosine: 0.9, variant: 1)
        let b = SyntheticVoices.vector(near: .liam, cosine: 0.82, variant: 3)
        #expect(abs(a.cosine(b) - 0.9 * 0.82) < 1e-4)
    }
}

@Suite("Skeleton: fake engine")
struct FakeEngineTests {
    func config(_ env: [String: String] = [:]) -> LaunchConfig {
        LaunchConfig(arguments: ["-useFakeEngine", "-uiTesting"], environment: env)
    }

    @Test func missingModelsMeanASlowFirstPrepare() async throws {
        // "missing" = first launch on this device: the models ship in the app, so nothing downloads, but the
        // first on-device prepare is slow (2 s at instant speed).
        let engine = FakeSpeechEngine(config: config(["TRANSCRIBE_MODELS": "missing"]), script: .named(.newVoices))
        #expect(await engine.modelStatus() == .installed)
        let clock = ContinuousClock()
        let start = clock.now
        try await engine.prepareModels()
        #expect(clock.now - start >= .milliseconds(1_500))
        #expect(await engine.modelStatus() == .ready)
    }

    @Test func installedModelsPrepareQuickly() async throws {
        let engine = FakeSpeechEngine(config: config(["TRANSCRIBE_MODELS": "installed"]), script: .named(.newVoices))
        #expect(await engine.modelStatus() == .installed)
        let clock = ContinuousClock()
        let start = clock.now
        try await engine.prepareModels()
        #expect(clock.now - start < .milliseconds(1_500))
        #expect(await engine.modelStatus() == .ready)
    }

    @Test func scriptedProcessing() async throws {
        let engine = FakeSpeechEngine(config: config(), script: .named(.newVoices))
        try await engine.prepareModels()
        let url = URL(fileURLWithPath: "/dev/null")
        let words = try await engine.transcribe(url, language: .automatic) { _ in }
        #expect(words.first?.text == "Hey," && words.count == SeedContent.allWords(SeedContent.conversationB).count)
        let separation = try await engine.separateSpeakers(url) { _ in }
        #expect(Set(separation.segments.map(\.speakerKey)) == ["S1", "S2"])
        let vectors = try await engine.embedVoice(url, spans: [TimeRange(start: 1, end: 3), TimeRange(start: 8, end: 10)])
        #expect(abs(vectors[0].cosine(SyntheticVoices.base(.liam)) - 0.9) < 1e-4)
        #expect(abs(vectors[1].cosine(SyntheticVoices.base(.karan)) - 0.9) < 1e-4)
        #expect(await engine.callCount("transcribe") == 1)
        #expect(await engine.maxConcurrentCalls == 1)
    }

    @Test func liveRecordingWritesTheScriptDuration() async throws {
        let engine = FakeSpeechEngine(config: config(), script: .named(.newVoices))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("fake-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let session = try await engine.startRecording(RecordingRequest(audioURL: url, liveText: true, language: .automatic))
        var sawTick = false, sawText = false
        for await event in session.events {
            if case .tick = event { sawTick = true }
            if case .liveText = event { sawText = true }
            if sawTick && sawText { break }
        }
        _ = await session.markMoment()
        let audio = try await session.stop()
        #expect(audio.duration == 24 && audio.marks.count == 1 && audio.peaks.count == 200)
        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int
        #expect(size == 44 + 24 * 16_000 * 2)
    }

    @Test func deniedMicrophone() async {
        let engine = FakeSpeechEngine(config: config(["TRANSCRIBE_MIC": "denied"]), script: .named(.newVoices))
        #expect(await engine.microphonePermission() == .denied)
        #expect(await engine.requestMicrophonePermission() == false)
    }
}
