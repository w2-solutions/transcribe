import Foundation
import SwiftData
import Synchronization
import Testing
import TranscribeCore
@testable import TranscribeFakes
@testable import TranscribeKit

/// A fake engine that records which file each voice embedding was read from (the pipeline embeds each speaker of a
/// Both recording from its own stream). Everything else is the fake engine's.
actor StreamSpyEngine: SpeechEngine {
    nonisolated let inner: FakeSpeechEngine
    nonisolated var info: EngineInfo { inner.info }
    /// The file of each `embedVoice` call and the midpoint of its first span.
    private(set) var embeds: [(file: String, firstMid: Double)] = []

    init(_ inner: FakeSpeechEngine) { self.inner = inner }

    func modelStatus() async -> ModelStatus { await inner.modelStatus() }
    func prepareModels() async throws { try await inner.prepareModels() }
    func microphonePermission() async -> MicPermission { await inner.microphonePermission() }
    func requestMicrophonePermission() async -> Bool { await inner.requestMicrophonePermission() }
    func startRecording(_ request: RecordingRequest) async throws -> any LiveRecording { try await inner.startRecording(request) }
    func transcribe(_ audio: URL, language: LanguageHint, progress: @escaping @Sendable (Double) -> Void) async throws -> [TimedWord] {
        try await inner.transcribe(audio, language: language, progress: progress)
    }
    func separateSpeakers(_ audio: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> SpeakerSeparation {
        try await inner.separateSpeakers(audio, progress: progress)
    }
    func embedVoice(_ audio: URL, spans: [TimeRange]) async throws -> [VoiceVector] {
        embeds.append((audio.lastPathComponent, spans.first?.mid ?? -1))
        return try await inner.embedVoice(audio, spans: spans)
    }

    /// The file each speaker was embedded from, by the script's segment holding the first span.
    func files(script: FakeScript) -> [SpeakerKey: String] {
        var out: [SpeakerKey: String] = [:]
        for e in embeds {
            if let key = script.segments.first(where: { $0.range.contains(e.firstMid) })?.speakerKey { out[key] = e.file }
        }
        return out
    }
}

/// Recordings that captured Mac audio (decisions D1 and D2): which stream each speaker was heard on, which file each is
/// embedded from, what a voice heard on both streams may and may not do, and the temporary stems.
@Suite("Mac audio: mixed recordings in the store and the pipeline")
@MainActor
struct MixedRecordingStoreTests {
    static let mac = CaptureChannel.mac

    static func detail(_ sources: CaptureSources) -> CaptureDetail {
        CaptureDetail(hardwareModel: "Mac15,3", input: sources.detailInput ?? CaptureDetail.Input.builtInMic,
                      sources: sources == .microphone ? nil : sources.detailValue,
                      outputRoute: sources == .microphone ? nil : CaptureDetail.OutputRoute.headphones)
    }

    // MARK: Pipeline

    /// A coordinator on the `callVoices` script with a spy engine, and a captured recording with its audio and, unless
    /// `stems` is false, its stems written as the Both capture would.
    @MainActor
    final class Rig {
        let h: WP3Harness
        let spy: StreamSpyEngine
        let coordinator: ProcessingCoordinator
        let script = FakeScript.named(.callVoices)

        init(seed: SeedName = .library) async throws {
            h = try WP3Harness(channel: MixedRecordingStoreTests.mac)
            try h.seed(seed)
            let engine = FakeSpeechEngine(config: LaunchConfig(arguments: ["-useFakeEngine", "-uiTesting"], environment: [:]),
                                          script: script)
            try await engine.prepareModels()
            spy = StreamSpyEngine(engine)
            let settings = AppSettings(defaults: UserDefaults(suiteName: "mixed-\(UUID().uuidString)")!)
            coordinator = ProcessingCoordinator(engine: spy, store: h.store, monitor: ProcessingMonitor(), settings: settings,
                                                paths: h.paths, background: SpyBackgroundBridge())
        }

        func capture(_ sources: CaptureSources, stems: Bool = true) throws -> UUID {
            let id = UUID()
            let file = h.paths.newAudioFileName(for: id)
            try h.store.createRecording(id: id, createdAt: Seeds.Dates.d, audioFileName: file, source: .microphone)
            let audio = h.paths.audioURL(fileName: file)
            let peaks = try SyntheticAudio.write(to: audio, duration: script.duration, segments: script.audioSegments)
            let stemURLs = h.paths.stems(recordingID: id)
            if sources == .both && stems { try SyntheticAudio.writeStems(for: script, to: stemURLs) }
            try h.store.finishCapture(id: id, audio: CapturedAudio(url: audio, duration: script.duration, marks: [], peaks: peaks,
                                                                  detail: MixedRecordingStoreTests.detail(sources),
                                                                  stems: sources == .both ? stemURLs : nil),
                                      language: .automatic)
            return id
        }

        func run(_ id: UUID) async throws -> Recording {
            await coordinator.enqueue(id)
            await coordinator.waitUntilIdle()
            return try h.recording(id)
        }

        func trace(_ s: RecordingSpeaker?) -> MatchTrace? {
            s?.matchTraceData.flatMap { try? JSONDecoder().decode(MatchTrace.self, from: $0) }
        }
    }

    @Test func bothModeAttributesEachSpeakerAndEmbedsItFromItsOwnStream() async throws {
        let rig = try await Rig()
        defer { rig.h.cleanup() }
        let id = try rig.capture(.both)
        let stems = rig.h.paths.stems(recordingID: id)
        let r = try await rig.run(id)
        #expect(r.stage == .ready)

        // The room voice on the microphone, the far side through Mac audio, the voice on both mixed.
        #expect(r.speaker("S1")?.captureSource == "mic" && r.speaker("S1")?.source == .mic)
        #expect(r.speaker("S2")?.captureSource == "system" && r.speaker("S2")?.source == .system)
        #expect(r.speaker("S3")?.captureSource == "mixed" && r.speaker("S3")?.source == .mixed)
        // Each from its own file: the microphone stem, the system stem, and the mixed recording.
        let files = await rig.spy.files(script: rig.script)
        #expect(files["S1"] == stems.mic.lastPathComponent)
        #expect(files["S2"] == stems.system.lastPathComponent)
        #expect(files["S3"] == r.audioFileName)

        // The traces say so (v3), with the system share rounded to two places.
        let t1 = try #require(rig.trace(r.speaker("S1"))), t2 = try #require(rig.trace(r.speaker("S2")))
        let t3 = try #require(rig.trace(r.speaker("S3")))
        #expect(t1.speakerSource == "mic" && (t1.systemShare ?? 1) <= 0.2)
        #expect(t2.speakerSource == "system" && (t2.systemShare ?? 0) >= 0.8)
        #expect(t3.speakerSource == "mixed" && (t3.systemShare ?? 0) > 0.2 && (t3.systemShare ?? 1) < 0.8)
        #expect([t1, t2, t3].allSatisfy { $0.version >= MatchTrace.groupsVersion })
        // Liam is still recognised on the microphone; the blended voice is never an automatic label.
        #expect(r.speaker("S1")?.label == .autoLabelled && r.speaker("S1")?.profile?.id == Seeds.ID.liam)
        #expect(r.speaker("S3")?.label != .autoLabelled && t3.kind != .auto)

        // The stems were temporary: gone once the recording is ready. The recording itself stays.
        #expect(!FileManager.default.fileExists(atPath: stems.mic.path))
        #expect(!FileManager.default.fileExists(atPath: stems.system.path))
        #expect(FileManager.default.fileExists(atPath: rig.h.paths.audioURL(fileName: r.audioFileName).path))
    }

    @Test func bothModeWithoutStemsMakesEverySpeakerMixed() async throws {
        let rig = try await Rig()
        defer { rig.h.cleanup() }
        let r = try await rig.run(try rig.capture(.both, stems: false))
        #expect(r.sortedSpeakers.count == 3 && r.sortedSpeakers.allSatisfy { $0.source == .mixed })
        #expect(r.sortedSpeakers.allSatisfy { $0.label != .autoLabelled })
        let files = Set(await rig.spy.files(script: rig.script).values)
        #expect(files == [r.audioFileName])
    }

    @Test func macAudioOnlyMakesEverySpeakerSystem() async throws {
        let rig = try await Rig()
        defer { rig.h.cleanup() }
        let r = try await rig.run(try rig.capture(.macAudio))
        #expect(r.sortedSpeakers.allSatisfy { $0.captureSource == "system" })
        #expect(Set(await rig.spy.files(script: rig.script).values) == [r.audioFileName])
        #expect(r.sortedSpeakers.allSatisfy { rig.trace($0).map { $0.speakerSource == "system" && $0.systemShare == nil } ?? true })
    }

    /// A microphone recording is exactly as before: no source stored (so nothing new syncs) and no source in traces.
    @Test func microphoneOnlyStoresNoSourceAndLeavesTracesAsBefore() async throws {
        let rig = try await Rig()
        defer { rig.h.cleanup() }
        let r = try await rig.run(try rig.capture(.microphone))
        #expect(r.sortedSpeakers.count == 3 && r.sortedSpeakers.allSatisfy { $0.captureSource == nil && $0.source == .mic })
        for s in r.sortedSpeakers {
            guard let t = rig.trace(s) else { continue }
            #expect(t.speakerSource == nil && t.systemShare == nil && t.version == MatchTrace.currentVersion)
        }
    }

    // MARK: Store: a Both recording built through the store API

    /// A separated Both recording on `callConversation`: S1 (mic), S2 (system), S3 (mixed), with the given vectors.
    func bothRecording(_ h: WP3Harness, _ vectors: [SpeakerKey: VoiceVector], sources: [SpeakerKey: SpeakerSource] = [
        "S1": .mic, "S2": .system, "S3": .mixed,
    ], capture: CaptureSources = .both, clean: Double = 12) throws -> UUID {
        let id = UUID()
        let file = h.paths.newAudioFileName(for: id)
        try h.store.createRecording(id: id, createdAt: Seeds.Dates.d, audioFileName: file, source: .microphone)
        try Data("RIFF".utf8).write(to: h.paths.audioURL(fileName: file))
        try h.store.finishCapture(id: id, audio: CapturedAudio(url: h.paths.audioURL(fileName: file), duration: 40, marks: [],
                                                              peaks: [], detail: Self.detail(capture)), language: .automatic)
        let turns = SeedContent.callConversation
        try h.store.checkpointTranscript(id: id, document: WP3Docs.paragraphs(turns))
        let drafts = ["S1", "S2", "S3"].enumerated().map { i, key in
            var d = WP3Docs.draft(key, i + 1, clean: clean, turns: 2, vector: vectors[key])
            d.source = sources[key]
            return d
        }
        try h.store.checkpointSeparation(id: id, document: WP3Docs.speakers(turns), speakers: drafts)
        return id
    }

    static let liamVoice = SyntheticVoices.vector(near: .liam, cosine: 0.9, variant: 40)
    static let karanVoice = SyntheticVoices.vector(near: .karan, cosine: 0.9, variant: 41)
    static let blend = SyntheticVoices.mix([(.liam, 0.6), (.karan, 0.6)], variant: 42)

    @Test func sourcesAreWrittenWithTheSpeakersAndProbesOfMixedVoicesAreAskOnly() throws {
        let h = try WP3Harness(channel: Self.mac)
        defer { h.cleanup() }
        try h.seed(.library)
        let id = try bothRecording(h, ["S1": Self.liamVoice, "S2": Self.karanVoice, "S3": Self.blend])
        let r = try h.recording(id)
        #expect(r.stage == .separated)
        #expect(r.sortedSpeakers.map(\.captureSource) == ["mic", "system", "mixed"])
        let probes = try h.store.probes(for: id)
        #expect(probes.map(\.askOnly) == [false, false, true])
        #expect(probes.allSatisfy { $0.channel == Self.mac })   // Mac audio stays on the recording's channel (D2)
        #expect(try h.store.snapshot(of: id).captureSources == .both)
    }

    /// Even when the matcher would auto-label a mixed voice, the store only asks. (The matcher reads `askOnly` itself
    /// once sound-group scoring lands; this keeps the rule on this branch too.)
    @Test func aMixedVoiceIsNeverAutoLabelledAndLearnsNoAutomaticSample() throws {
        let h = try WP3Harness(channel: Self.mac)
        defer { h.cleanup() }
        try h.seed(.library)
        let id = try bothRecording(h, ["S1": Self.liamVoice, "S2": Self.karanVoice, "S3": Self.blend])
        let karan = try #require(try h.profile(named: "Karan"))
        let before = karan.samples.count
        _ = try h.store.applyMatches(id: id, decisions: ["S3": .autoLabel(profileID: karan.id, score: 0.9, margin: 0.5)],
                                     policy: .default)
        let s3 = try #require(try h.recording(id).speaker("S3"))
        #expect(s3.label == .suggested && s3.suggestedProfileID == karan.id && s3.profile == nil)
        #expect(karan.samples.count == before)
    }

    @Test func namingAMixedVoiceSavesTheNameOnlyAndLearnsNothing() throws {
        let h = try WP3Harness(channel: Self.mac)
        defer { h.cleanup() }
        try h.seed(.library)
        let id = try bothRecording(h, ["S1": Self.liamVoice, "S2": Self.karanVoice, "S3": Self.blend])
        _ = try h.store.applyMatches(id: id, decisions: [:], policy: .default)
        let karan = try #require(try h.profile(named: "Karan"))
        let samplesBefore = try h.count(VoiceSample.self), negativesBefore = try h.count(VoiceNegative.self)

        // A new person: the name is kept on the speaker, but no voice is saved.
        let asNew = try h.store.nameSpeaker(recordingID: id, key: "S3", as: .newPerson(name: "Priya"), remember: true)
        #expect(asNew == NameResult(profileID: nil, sampleStored: false, skipReason: .mixedSource))
        #expect(try h.recording(id).speaker("S3")?.displayName == "Priya")
        #expect(try h.profile(named: "Priya") == nil)

        // A saved voice: the speaker is labelled, but nothing is learned (no sample, no negative for the old name).
        let asKaran = try h.store.nameSpeaker(recordingID: id, key: "S3", as: .existing(profileID: karan.id), remember: true)
        #expect(asKaran == NameResult(profileID: karan.id, sampleStored: false, skipReason: .mixedSource))
        #expect(try h.recording(id).speaker("S3")?.profile?.id == karan.id)
        #expect(try h.count(VoiceSample.self) == samplesBefore)
        #expect(try h.count(VoiceNegative.self) == negativesBefore)

        // Adding it from the voice screen is refused the same way, and it is never offered there.
        let s3 = try #require(try h.recording(id).speaker("S3"))
        #expect(try h.store.addSample(profileID: karan.id, fromSpeaker: s3.id).skipReason == .mixedSource)
        #expect(try !h.store.sampleCandidates(for: karan.id).contains { $0.id == s3.id })
    }

    @Test func rejectingASuggestionForAMixedVoiceStoresNoNegative() throws {
        let h = try WP3Harness(channel: Self.mac)
        defer { h.cleanup() }
        try h.seed(.library)
        let id = try bothRecording(h, ["S1": Self.liamVoice, "S2": Self.karanVoice, "S3": Self.blend])
        let karan = try #require(try h.profile(named: "Karan"))
        _ = try h.store.applyMatches(id: id, decisions: ["S3": .ask(profileID: karan.id, score: 0.5)], policy: .default)
        try h.store.rejectSuggestion(recordingID: id, key: "S3")
        #expect(karan.negatives.isEmpty)
        #expect(try h.recording(id).speaker("S3")?.rejectedProfileIDs == [karan.id])   // never asked again
    }

    @Test func aVoiceHeardThroughMacAudioLearnsOnTheRecordingsChannelAsSystemAudio() throws {
        let h = try WP3Harness(channel: Self.mac)
        defer { h.cleanup() }
        try h.seed(.library)
        let id = try bothRecording(h, ["S1": Self.liamVoice, "S2": SyntheticVoices.vector(near: .stranger, cosine: 0.9, variant: 43),
                                       "S3": Self.blend])
        _ = try h.store.applyMatches(id: id, decisions: ["S2": .ask(profileID: Seeds.ID.karan, score: 0.45)], policy: .default)
        // "Not Karan": the negative says it was heard through Mac audio.
        try h.store.rejectSuggestion(recordingID: id, key: "S2")
        let negative = try #require(try h.profile(named: "Karan")?.negatives.first)
        #expect(negative.captureInput == CaptureDetail.Input.systemAudio && negative.captureChannel == Self.mac)
        let result = try h.store.nameSpeaker(recordingID: id, key: "S2", as: .newPerson(name: "Tom"), remember: true)
        #expect(result.sampleStored)
        let tom = try #require(try h.profile(named: "Tom"))
        let sample = try #require(tom.samples.first)
        #expect(sample.captureChannel == Self.mac)                              // D2: no channel of its own
        #expect(sample.captureInput == CaptureDetail.Input.systemAudio)
        // The room voice of the same recording keeps the recording's input.
        _ = try h.store.nameSpeaker(recordingID: id, key: "S1", as: .newPerson(name: "Sam"), remember: true)
        let sam = try #require(try h.profile(named: "Sam")?.samples.first)
        #expect(sam.captureInput == CaptureDetail.Input.micAndSystem && sam.captureChannel == Self.mac)
    }

    @Test func mixedVoicesStayOutOfTheCohort() throws {
        let h = try WP3Harness(channel: Self.mac)
        defer { h.cleanup() }
        try h.seed(.empty)
        let stranger = SyntheticVoices.vector(near: .stranger, cosine: 0.9, variant: 44)
        let id = try bothRecording(h, ["S1": Self.liamVoice, "S2": stranger, "S3": Self.blend])
        _ = try h.store.applyMatches(id: id, decisions: [:], policy: .default)
        let cohort = try h.store.matchCohort(modelKey: EmbeddingModelID.fake.key, excludingRecording: UUID())
        #expect(cohort.count == 2)
        #expect(!cohort.contains(Self.blend))
    }

    @Test func sameAsAcrossStreamsMakesTheSpeakerMixed() throws {
        let h = try WP3Harness(channel: Self.mac)
        defer { h.cleanup() }
        try h.seed(.empty)
        let stranger = SyntheticVoices.vector(near: .stranger, cosine: 0.9, variant: 45)
        let id = try bothRecording(h, ["S1": Self.liamVoice, "S2": stranger, "S3": Self.blend],
                                   sources: ["S1": .mic, "S2": .system, "S3": .system])
        _ = try h.store.applyMatches(id: id, decisions: [:], policy: .default)
        // Same stream: the speaker stays as it was.
        try h.store.moveAllTurns(recordingID: id, from: "S3", to: "S2")
        #expect(try h.recording(id).speaker("S2")?.source == .system)
        // Different streams: from now on the speaker is mixed, and asks only.
        try h.store.moveAllTurns(recordingID: id, from: "S2", to: "S1")
        let s1 = try #require(try h.recording(id).speaker("S1"))
        #expect(s1.captureSource == "mixed")
        #expect(try h.store.probes(for: id).first { $0.key == "S1" }?.askOnly == true)
    }

    @Test func aSpeakerTheUserMakesFollowsTheRecordingsSources() throws {
        let h = try WP3Harness(channel: Self.mac)
        defer { h.cleanup() }
        try h.seed(.empty)
        let both = try bothRecording(h, ["S1": Self.liamVoice, "S2": Self.karanVoice, "S3": Self.blend])
        let macOnly = try bothRecording(h, ["S1": Self.liamVoice, "S2": Self.karanVoice, "S3": Self.blend],
                                        sources: ["S1": .system, "S2": .system, "S3": .system], capture: .macAudio)
        for id in [both, macOnly] {
            _ = try h.store.applyMatches(id: id, decisions: [:], policy: .default)
            let turn = try #require(try h.recording(id).transcript?.turns.first)
            try h.store.reassignTurn(recordingID: id, turnID: turn.id, to: .newName("Priya"))
        }
        #expect(try h.recording(both).speaker("U1")?.source == .mixed)
        #expect(try h.recording(macOnly).speaker("U1")?.source == .system)
    }

    // MARK: Stems

    @Test func stemsGoWithTheAudioAndOrphansAreSwept() throws {
        let h = try WP3Harness(channel: Self.mac)
        defer { h.cleanup() }
        try h.seed(.empty)
        let fm = FileManager.default
        func writeStems(_ id: UUID) throws -> CaptureStems {
            let stems = h.paths.stems(recordingID: id)
            try fm.createDirectory(at: h.paths.stemsDirectory, withIntermediateDirectories: true)
            for stream in CaptureStream.allCases { try Data("RIFF".utf8).write(to: stems.url(stream)) }
            return stems
        }
        func exists(_ stems: CaptureStems) -> [Bool] { CaptureStream.allCases.map { fm.fileExists(atPath: stems.url($0).path) } }

        // Deleting a recording deletes its stems with its audio.
        let deleted = try bothRecording(h, ["S1": Self.liamVoice, "S2": Self.karanVoice, "S3": Self.blend])
        let deletedStems = try writeStems(deleted)
        try h.store.delete(id: deleted)
        #expect(exists(deletedStems) == [false, false])

        // A recording still processing keeps its stems; a ready one (stems left by a crash) and a missing one lose
        // theirs, once old enough.
        let processing = try bothRecording(h, ["S1": Self.liamVoice, "S2": Self.karanVoice, "S3": Self.blend])
        let processingStems = try writeStems(processing)
        let ready = try bothRecording(h, ["S1": Self.liamVoice, "S2": Self.karanVoice, "S3": Self.blend])
        _ = try h.store.applyMatches(id: ready, decisions: [:], policy: .default)
        let readyStems = try writeStems(ready)   // written after the ready save removed the first ones
        let orphanStems = try writeStems(UUID())
        #expect(try h.store.sweepOrphanStems(minimumAge: 3_600, now: Date()) == 0)   // too new
        let removed = try h.store.sweepOrphanAudio(minimumAge: 3_600, now: Date().addingTimeInterval(7_200))
        #expect(removed == 4)
        #expect(exists(processingStems) == [true, true])
        #expect(exists(readyStems) == [false, false] && exists(orphanStems) == [false, false])
    }

    // MARK: Matching log

    @Test func matchingLogV3CarriesSourcesAndNoNames() throws {
        let h = try WP3Harness(channel: Self.mac)
        defer { h.cleanup() }
        try h.seed(.voiceGroupsCalls)
        let text = try h.store.matchingLog()
        for word in ["Teams", "Tom", "Liam", "Teams call", "You're on mute"] { #expect(!text.contains(word), "log contains \(word)") }
        let log = try MatchLog.decoder().decode(MatchLog.self, from: Data(text.utf8))
        #expect(log.version == 3)
        #expect(log.policy.groupJoinCosine == SampleGroupPolicy.default.joinCosine && log.policy.groupScoring == true)
        #expect(log.policy.sampleCeilingPerChannel == 20 && log.policy.attribution == SourceAttributionPolicy.default)
        let call = try #require(log.recordings.first { $0.id == Seeds.ID.recordingT3 })
        #expect(call.sources == CaptureDetail.Sources.both && call.outputRoute == CaptureDetail.OutputRoute.headphones)
        #expect(call.input == CaptureDetail.Input.micAndSystem)
        #expect(call.speakers.map(\.source) == ["mic", "system"])
        let tom = try #require(log.profiles.first { $0.id == Seeds.ID.tom })
        // Close, Far, On speaker and the call on this device; the iPad's pair.
        #expect(tom.groupSizesByChannel?[Self.mac] == [3, 3, 2, 2] && tom.groupSizesByChannel?[CaptureChannel.ipad] == [2])
        #expect(tom.trustedGroupsByChannel?[Self.mac] == 4)
        #expect(tom.macAudioByChannel == [Self.mac: 2])
        // Microphone-only recordings carry no sources.
        let a = try #require(log.recordings.first { $0.id == Seeds.ID.recordingA })
        #expect(a.sources == nil && a.outputRoute == nil && a.speakers.allSatisfy { $0.source == nil })
    }

    // MARK: Seed

    @Test func voiceGroupsCallsSeedHasTheCallGroupLabelledTeams() throws {
        let h = try WP3Harness(channel: Self.mac)
        defer { h.cleanup() }
        try h.seed(.voiceGroupsCalls)
        let tom = try #require(try h.profile(named: "Tom"))
        let call = try h.recording(Seeds.ID.recordingT3)
        #expect(call.captureChannel == Self.mac)
        #expect(call.speaker("S2")?.source == .system && call.speaker("S1")?.source == .mic)
        let callSamples = tom.samples.filter { Seeds.ID.tomCallSamples.contains($0.id) }
        #expect(callSamples.count == 2)
        #expect(callSamples.allSatisfy { $0.captureChannel == Self.mac && $0.captureInput == CaptureDetail.Input.systemAudio })
        // The "Teams" label sits on exactly the call group.
        let split = GroupingInput.split(tom, localChannel: Self.mac)
        let groups = SampleGrouping.group(split.items, dimension: SyntheticVoices.dimension)
        let vectors = Dictionary(uniqueKeysWithValues: split.items.map { ($0.id, $0.vector) })
        let resolved = GroupLabelResolver.resolve(groups: groups, memberVectors: vectors, labels: GroupingInput.anchors(tom))
        let teams = try #require(groups.first { resolved.placed[$0.key] == Seeds.ID.teamsLabel })
        #expect(Set(teams.memberIDs) == Set(Seeds.ID.tomCallSamples))
        #expect(groups.filter { $0.channel == Self.mac }.count == 4)
    }
}
