import Foundation
import SwiftData
import Synchronization
import Testing
import TranscribeCore
@testable import TranscribeFakes
@testable import TranscribeKit

// MARK: - WP3 test harness (shared by the WP3 suites)

/// One in-memory store with its own temp folder, a fixed device id and a fixed capture channel.
@MainActor
struct WP3Harness {
    let container: ModelContainer
    let paths: AppPaths
    let store: LibraryStore
    var context: ModelContext { container.mainContext }

    init(device: String = "device-A", now: Date = Seeds.Dates.d, container: ModelContainer? = nil, paths: AppPaths? = nil,
         channel: String = CaptureChannel.iphone) throws {
        self.container = try container ?? ModelContainerFactory.make(inMemory: true, url: nil)
        self.paths = paths ?? AppPaths(root: FileManager.default.temporaryDirectory
            .appendingPathComponent("wp3-\(UUID().uuidString)", isDirectory: true))
        try self.paths.prepare()
        store = LibraryStore(context: self.container.mainContext, paths: self.paths,
                             deviceIdentity: FixedDeviceIdentity(device), clock: .frozen(now), localChannel: channel)
    }

    func seed(_ seed: SeedName) throws {
        try Seeds.apply(seed, context: context, paths: paths, clock: .frozen(Seeds.Dates.d))
    }

    func cleanup() { try? FileManager.default.removeItem(at: paths.root) }

    func recording(_ id: UUID) throws -> Recording { try store.recording(id) }

    func profile(named name: String) throws -> VoiceProfile? {
        try context.fetch(FetchDescriptor<VoiceProfile>()).first { $0.name == name }
    }

    func count<T: PersistentModel>(_ type: T.Type) throws -> Int { try context.fetchCount(FetchDescriptor<T>()) }

    /// A captured, queued recording (optionally with a synthetic WAV of the script's audio).
    @discardableResult
    func queuedRecording(createdAt: Date = Seeds.Dates.d, script: FakeScript? = nil, writeAudio: Bool = false) throws -> UUID {
        let id = UUID()
        let fileName = paths.newAudioFileName(for: id)
        try store.createRecording(id: id, createdAt: createdAt, audioFileName: fileName, source: .microphone)
        var peaks: [Float] = []
        let duration = script?.duration ?? 24
        if writeAudio, let script {
            peaks = try SyntheticAudio.write(to: paths.audioURL(fileName: fileName), duration: script.duration,
                                             segments: script.audioSegments)
        }
        try store.finishCapture(id: id, audio: CapturedAudio(url: paths.audioURL(fileName: fileName), duration: duration,
                                                             marks: [], peaks: peaks), language: .automatic)
        return id
    }

    /// A finished recording built through the store API, from scripted turns and drafts.
    @discardableResult
    func readyRecording(turns: [ScriptTurn], drafts: [SpeakerDraft], createdAt: Date = Seeds.Dates.d,
                        decisions: [SpeakerKey: MatchDecision] = [:]) throws -> UUID {
        let id = try queuedRecording(createdAt: createdAt)
        try store.checkpointTranscript(id: id, document: WP3Docs.paragraphs(turns))
        try store.checkpointSeparation(id: id, document: WP3Docs.speakers(turns), speakers: drafts)
        _ = try store.applyMatches(id: id, decisions: decisions, policy: .default)
        return id
    }

    /// Matches a separated recording as the pipeline does: probes, candidates, cohort, `decideWithTrace`, then
    /// `applyMatches` with the traces.
    @discardableResult
    func matchLikeThePipeline(_ id: UUID, policy: MatchPolicy = .default) throws -> ProcessingOutcome {
        let key = EmbeddingModelID.fake.key
        let probes = try store.probes(for: id)
        let candidates = try store.matchCandidates(modelKey: key)
        let cohort = try store.matchCohort(modelKey: key, excludingRecording: id)
        let run = VoiceMatcher.decideWithTrace(probes: probes, profiles: candidates, modelKey: key, policy: policy, cohort: cohort)
        return try store.applyMatches(id: id, decisions: run.decisions, traces: run.traces, policy: policy)
    }

    /// A separated (not yet matched) recording built through the store API.
    @discardableResult
    func separatedRecording(turns: [ScriptTurn], drafts: [SpeakerDraft], createdAt: Date = Seeds.Dates.d) throws -> UUID {
        let id = try queuedRecording(createdAt: createdAt)
        try store.checkpointTranscript(id: id, document: WP3Docs.paragraphs(turns))
        try store.checkpointSeparation(id: id, document: WP3Docs.speakers(turns), speakers: drafts)
        return id
    }
}

enum WP3Docs {
    static func paragraphs(_ turns: [ScriptTurn]) -> TranscriptDocument {
        TranscriptDocument(words: SeedContent.allWords(turns), turns: SeedContent.paragraphs(turns), asrModelID: "fake-parakeet")
    }
    static func speakers(_ turns: [ScriptTurn]) -> TranscriptDocument {
        TranscriptDocument(words: SeedContent.allWords(turns), turns: SeedContent.speakerTurns(turns), asrModelID: "fake-parakeet")
    }
    static func draft(_ key: SpeakerKey, _ ordinal: Int, clean: Double, total: Double? = nil, turns: Int = 1,
                      vector: VoiceVector?, coherence: Float? = 1) -> SpeakerDraft {
        SpeakerDraft(key: key, ordinal: ordinal, cleanSeconds: clean, totalSeconds: total ?? clean + 0.5, turnCount: turns,
                     vector: vector, embeddingModel: .fake, coherence: coherence)
    }
}

/// Records every BackgroundTaskBridge call; `expire()` fires the last job's `onExpire`.
final class SpyBackgroundBridge: BackgroundTaskBridge, Sendable {
    struct State {
        var begun: [(id: UUID, token: BackgroundToken, onExpire: @Sendable () -> Void)] = []
        var updates = 0
        var ended: [(token: BackgroundToken, success: Bool)] = []
    }
    let state = Mutex(State())

    func begin(recordingID: UUID, title: String, onExpire: @escaping @Sendable () -> Void) async -> BackgroundToken? {
        let token = BackgroundToken()
        state.withLock { $0.begun.append((recordingID, token, onExpire)) }
        return token
    }
    func update(_ token: BackgroundToken, fraction: Double, subtitle: String) async { state.withLock { $0.updates += 1 } }
    func end(_ token: BackgroundToken, success: Bool) async { state.withLock { $0.ended.append((token, success)) } }

    func expireLatest() { state.withLock { $0.begun.last?.onExpire }?() }
    var beginCount: Int { state.withLock { $0.begun.count } }
    var endResults: [Bool] { state.withLock { $0.ended.map(\.success) } }
}

/// Polls `condition` on the main actor until it holds or `timeout` passes.
@MainActor
func wp3WaitFor(_ timeout: Duration = .seconds(10), _ condition: @MainActor () async throws -> Bool) async rethrows -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if try await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return try await condition()
}

// MARK: - LibraryStoreTests

@Suite("WP3: LibraryStore")
@MainActor
struct LibraryStoreTests {
    @Test func lifecycleTransitions() throws {
        let h = try WP3Harness()
        defer { h.cleanup() }
        let id = UUID()
        try h.store.createRecording(id: id, createdAt: Seeds.Dates.d, audioFileName: "x.wav", source: .microphone)
        #expect(try h.recording(id).stage == .capturing)

        try h.store.finishCapture(id: id, audio: CapturedAudio(url: h.paths.audioURL(fileName: "x.wav"), duration: 24,
                                                               marks: [3, 9], peaks: [0.1, 0.5]),
                                  language: .language("en"))
        var r = try h.recording(id)
        #expect(r.stage == .queued && r.duration == 24 && r.marks == [3, 9] && r.peaks == [0.1, 0.5] && r.languageRaw == "en")

        try h.store.setStage(.transcribing, queueReason: nil, for: id)
        #expect(try h.store.snapshot(of: id).stage == .transcribing)

        try h.store.checkpointTranscript(id: id, document: WP3Docs.paragraphs(SeedContent.conversationB))
        r = try h.recording(id)
        #expect(r.stage == .transcribed && r.asrModelID == "fake-parakeet")
        #expect(r.previewText.hasPrefix("Hey, Karan. Um, I just want") && r.previewText.count <= 200)
        #expect(r.searchText.contains("transcription app"))
        #expect(r.transcript?.hasSpeakers == false)

        let drafts = [WP3Docs.draft("S1", 1, clean: 11, turns: 2, vector: SyntheticVoices.vector(near: .liam, cosine: 0.9, variant: 1)),
                      WP3Docs.draft("S2", 2, clean: 11.5, turns: 2, vector: SyntheticVoices.vector(near: .karan, cosine: 0.9, variant: 2))]
        try h.store.checkpointSeparation(id: id, document: WP3Docs.speakers(SeedContent.conversationB), speakers: drafts)
        r = try h.recording(id)
        #expect(r.stage == .separated && r.embeddingModelKey == EmbeddingModelID.fake.key)
        #expect(r.sortedSpeakers.map(\.key) == ["S1", "S2"] && r.sortedSpeakers.map(\.colourSlot) == [0, 1])
        #expect(r.sortedSpeakers.map(\.turnCount) == [2, 2] && r.sortedSpeakers.allSatisfy { $0.vector != nil })
        #expect(try h.store.probes(for: id).map(\.key) == ["S1", "S2"])

        // Separation again replaces (never duplicates) the speakers.
        try h.store.checkpointSeparation(id: id, document: WP3Docs.speakers(SeedContent.conversationB), speakers: drafts)
        #expect(try h.count(RecordingSpeaker.self) == 2)

        let outcome = try h.store.applyMatches(id: id, decisions: ["S1": .unknown(.noEligibleProfiles),
                                                                   "S2": .unknown(.lowScore(best: 0.2))], policy: .default)
        r = try h.recording(id)
        #expect(outcome == ProcessingOutcome(unnamed: 2))
        #expect(r.stage == .ready && !r.hasUnseenResult && r.sortedSpeakers.allSatisfy { $0.label == .unnamed })
        #expect(r.speakersNeedingName.count == 2)
    }

    @Test func finishWithoutMatchingMarksNoSpeechAndDropsSpeakers() throws {
        let h = try WP3Harness()
        defer { h.cleanup() }
        let id = try h.readyRecording(turns: SeedContent.conversationB,
                                      drafts: [WP3Docs.draft("S1", 1, clean: 11, vector: SyntheticVoices.base(.liam))])
        let empty = TranscriptDocument(words: [], turns: [], asrModelID: "fake-parakeet")
        let outcome = try h.store.finishWithoutMatching(id: id, document: empty, noSpeech: true)
        let r = try h.recording(id)
        #expect(outcome == ProcessingOutcome(noSpeech: true))
        #expect(r.stage == .ready && r.noSpeech && r.speakers.isEmpty && r.previewText.isEmpty)
        #expect(try h.count(RecordingSpeaker.self) == 0)
    }

    @Test func failureAttemptsAndRetry() throws {
        let h = try WP3Harness()
        defer { h.cleanup() }
        let id = try h.queuedRecording()
        #expect(try h.store.incrementAttempt(id: id) == 1)
        #expect(try h.store.incrementAttempt(id: id) == 2)
        try h.store.markFailed(id: id, message: "Couldn't finish processing")
        var r = try h.recording(id)
        #expect(r.stage == .failed && r.failureMessage == "Couldn't finish processing" && r.attemptCount == 2)
        try h.store.resetForRetry(id: id)
        r = try h.recording(id)
        #expect(r.stage == .queued && r.failureMessage == nil && r.attemptCount == 0)
    }

    @Test func searchTextFollowsTitleAndNames() throws {
        let h = try WP3Harness()
        defer { h.cleanup() }
        try h.seed(.twoSpeakersUnnamed)
        let id = Seeds.ID.recordingB
        try h.store.rename(id: id, title: "  Standup  ")
        #expect(try h.recording(id).title == "Standup")
        #expect(try h.recording(id).searchText.hasPrefix("standup"))
        _ = try h.store.nameSpeaker(recordingID: id, key: "S2", as: .newPerson(name: "Karan"), remember: false)
        #expect(try h.recording(id).searchText.contains("\nkaran"))
        try h.store.rename(id: id, title: "   ")
        #expect(try h.recording(id).title == nil)
    }

    @Test func deleteCascadesSpeakersRemovesTheFileAndKeepsSamples() throws {
        let h = try WP3Harness()
        defer { h.cleanup() }
        try h.seed(.library)
        let a = try h.recording(Seeds.ID.recordingA)
        let file = h.paths.audioURL(fileName: a.audioFileName)
        #expect(FileManager.default.fileExists(atPath: file.path))
        let speakersBefore = try h.count(RecordingSpeaker.self)
        let samplesBefore = try h.count(VoiceSample.self)

        try h.store.delete(id: Seeds.ID.recordingA)
        #expect(throws: StoreError.self) { try h.store.snapshot(of: Seeds.ID.recordingA) }
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(try h.count(RecordingSpeaker.self) == speakersBefore - 2)
        #expect(try h.count(VoiceSample.self) == samplesBefore)
        let liam = try #require(try h.profile(named: "Liam"))
        #expect(liam.samples.contains { $0.sourceRecordingID == Seeds.ID.recordingA })
        #expect(liam.recordingCount == 2)
    }

    @Test func discardRemovesRowAndFile() throws {
        let h = try WP3Harness()
        defer { h.cleanup() }
        let id = try h.queuedRecording(script: .named(.newVoices), writeAudio: true)
        let file = h.paths.audioURL(fileName: try h.recording(id).audioFileName)
        #expect(FileManager.default.fileExists(atPath: file.path))
        try h.store.discardRecording(id: id)
        #expect(try h.count(Recording.self) == 0)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func folders() throws {
        let h = try WP3Harness()
        defer { h.cleanup() }
        try h.seed(.library)
        #expect(throws: StoreError.invalidName) { _ = try h.store.createFolder(name: "  ") }
        let work = try h.store.createFolder(name: " Work ")
        try h.store.move(recordingID: Seeds.ID.recordingA, toFolder: work)
        try h.store.move(recordingID: Seeds.ID.recordingC, toFolder: work)
        var folder = try #require(try h.context.fetch(FetchDescriptor<Folder>()).first)
        #expect(folder.name == "Work" && folder.recordings.count == 2)
        try h.store.renameFolder(id: work, name: "Projects")
        #expect(folder.name == "Projects")
        try h.store.move(recordingID: Seeds.ID.recordingC, toFolder: nil)
        #expect(try h.recording(Seeds.ID.recordingC).folder == nil)
        folder = try #require(try h.context.fetch(FetchDescriptor<Folder>()).first)
        #expect(folder.recordings.map(\.id) == [Seeds.ID.recordingA])
        try h.store.deleteFolder(id: work)
        #expect(try h.count(Folder.self) == 0)
        #expect(try h.count(Recording.self) == 3)
        #expect(try h.recording(Seeds.ID.recordingA).folder == nil)
        #expect(throws: StoreError.self) { try h.store.move(recordingID: Seeds.ID.recordingA, toFolder: UUID()) }
    }

    @Test func recoveryCandidatesListUnfinishedRecordingsOldestFirst() throws {
        let h = try WP3Harness()
        defer { h.cleanup() }
        try h.seed(.processingHeld)                                     // E at .separating, audio on disk
        let capturing = UUID()
        try h.store.createRecording(id: capturing, createdAt: Seeds.Dates.d, audioFileName: "missing.wav", source: .microphone)
        let done = try h.readyRecording(turns: SeedContent.conversationA, drafts: [])
        let candidates = try h.store.recoveryCandidates()
        #expect(candidates.map(\.id) == [Seeds.ID.recordingE, capturing])
        #expect(candidates[0].stage == .separating && candidates[0].hasTranscript && candidates[0].audioExists)
        #expect(candidates[1].stage == .capturing && !candidates[1].hasTranscript && !candidates[1].audioExists)
        #expect(!candidates.contains { $0.id == done })
    }

    @Test func repairCapturedQueuesTheRecording() throws {
        let h = try WP3Harness()
        defer { h.cleanup() }
        let id = UUID()
        try h.store.createRecording(id: id, createdAt: Seeds.Dates.d, audioFileName: "a.wav", source: .microphone)
        try h.store.repairCaptured(id: id, duration: 12.5, peaks: [0.2])
        let r = try h.recording(id)
        #expect(r.stage == .queued && r.duration == 12.5 && r.peaks == [0.2])
    }

    @Test func markSeenAndFavourite() throws {
        let h = try WP3Harness()
        defer { h.cleanup() }
        try h.seed(.library)
        try h.store.markSeen(id: Seeds.ID.recordingA)
        #expect(try !h.recording(Seeds.ID.recordingA).hasUnseenResult)
        try h.store.setFavourite(id: Seeds.ID.recordingC, true)
        #expect(try h.recording(Seeds.ID.recordingC).isFavourite)
    }
}
