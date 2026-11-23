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
            #expect(FileManager.default.fileExists(atPath: paths.audioURL(fileName: r.audioFileName).path))
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

    @Test func modelsInstallAndPrepare() async throws {
        let engine = FakeSpeechEngine(config: config(["TRANSCRIBE_MODELS": "missing"]), script: .named(.newVoices))
        #expect(await engine.modelStatus() == .notInstalled)
        await #expect(throws: EngineError.modelsMissing) { try await engine.prepareModels() }
        try await engine.installModels { _ in }
        #expect(await engine.modelStatus() == .installed)
        try await engine.prepareModels()
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
