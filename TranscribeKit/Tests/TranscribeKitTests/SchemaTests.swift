import Foundation
import SwiftData
import Testing
import TranscribeCore
@testable import TranscribeFakes
@testable import TranscribeKit

@Suite("WP3: schema")
@MainActor
struct SchemaTests {
    @Test func migrationPlanListsV1V2V3() {
        let schemas = TranscribeMigrationPlan.schemas
        #expect(schemas.count == 3)
        #expect(schemas[0] == TranscribeSchemaV1.self && schemas[1] == TranscribeSchemaV2.self && schemas[2] == TranscribeSchemaV3.self)
        #expect(TranscribeMigrationPlan.stages.count == 2)
        #expect(TranscribeSchemaV1.versionIdentifier == Schema.Version(1, 0, 0))
        #expect(TranscribeSchemaV1.models.count == 5)
        #expect(TranscribeSchemaV2.versionIdentifier == Schema.Version(2, 0, 0))
        #expect(TranscribeSchemaV2.models.count == 6)
        #expect(TranscribeSchemaV3.versionIdentifier == Schema.Version(3, 0, 0))
        #expect(TranscribeSchemaV3.models.count == 8)
        let v3Names = Set(TranscribeSchemaV3.models.map { String(describing: $0) })
        #expect(v3Names == ["Recording", "RecordingSpeaker", "VoiceProfile", "VoiceSample", "Folder", "VoiceNegative",
                            "SyncRecordState", "SyncAccountState"])
        // The aliases name the current schema.
        #expect(Recording.self == TranscribeSchemaV3.Recording.self && VoiceNegative.self == TranscribeSchemaV3.VoiceNegative.self)
        #expect(SyncRecordState.self == TranscribeSchemaV3.SyncRecordState.self)
    }

    @Test func v3StoreRoundTripsChannelsAndSyncState() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("v3-schema-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(root: root)
        try paths.prepare()
        let entity = UUID()
        let detail = CaptureDetail(hardwareModel: "Mac15,3", input: CaptureDetail.Input.usbAudio, inputName: "Desk mic",
                                   inputModelUID: "usb:1234", routeChanged: true)
        let id = Seeds.ID.recordingB
        do {
            let container = try ModelContainerFactory.make(inMemory: false, url: paths.storeURL)
            let store = LibraryStore(context: container.mainContext, paths: paths, deviceIdentity: FixedDeviceIdentity("d"),
                                     clock: .frozen(Seeds.Dates.d), localChannel: CaptureChannel.mac)
            try store.createRecording(id: id, createdAt: Seeds.Dates.b, audioFileName: "b.wav", source: .microphone)
            try store.finishCapture(id: id, audio: CapturedAudio(url: paths.audioURL(fileName: "b.wav"), duration: 24,
                                                                 marks: [], peaks: [], detail: detail), language: .automatic)
            let state = SyncRecordState(recordName: "\(SyncRecordType.recording.prefix).\(entity.uuidString)",
                                        type: .recording, entityID: entity, now: Seeds.Dates.d)
            state.pendingRaw = 1
            container.mainContext.insert(state)
            let account = SyncAccountState()
            account.zoneReady = true
            account.engineState = Data([1, 2, 3])
            container.mainContext.insert(account)
            try container.mainContext.save()
        }

        let container = try ModelContainerFactory.make(inMemory: false, url: paths.storeURL)
        let context = container.mainContext
        let r = try #require(try context.fetch(FetchDescriptor<Recording>()).first)
        #expect(r.captureChannel == CaptureChannel.mac)
        #expect(CaptureDetail.decode(r.captureDetailJSON) == detail)
        let state = try #require(try context.fetch(FetchDescriptor<SyncRecordState>()).first)
        #expect(state.recordName == "rec.\(entity.uuidString)" && state.typeRaw == "Recording" && state.entityID == entity)
        #expect(state.baseHashesJSON == Data("{}".utf8) && state.systemFields == nil && state.pendingRaw == 1)
        #expect(state.unresolvedLinksJSON == nil && state.updatedAt == Seeds.Dates.d)
        let account = try #require(try context.fetch(FetchDescriptor<SyncAccountState>()).first)
        #expect(account.key == "default" && account.zoneReady && account.engineState == Data([1, 2, 3]))
        #expect(account.accountHash == nil && account.pausedReasonRaw == nil && account.lastFetchAt == nil)
    }

    @Test func syncRecordStateNamesAreUnique() throws {
        let container = try ModelContainerFactory.make(inMemory: true, url: nil)
        let context = container.mainContext
        let entity = UUID()
        let name = "vs.\(entity.uuidString)"
        context.insert(SyncRecordState(recordName: name, type: .sample, entityID: entity, now: Seeds.Dates.a))
        try context.save()
        let again = SyncRecordState(recordName: name, type: .sample, entityID: entity, now: Seeds.Dates.b)
        again.pendingRaw = 2
        context.insert(again)
        try context.save()
        // `.unique` upserts: one row, with the later values.
        let rows = try context.fetch(FetchDescriptor<SyncRecordState>())
        #expect(rows.count == 1 && rows.first?.pendingRaw == 2)
    }

    @Test func v2StoreRoundTripsNegativesAndTraces() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("v2-schema-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(root: root)
        try paths.prepare()
        let d = Seeds.ID.recordingD
        var expectedTrace: MatchTrace?
        var expectedNegative: (vector: VoiceVector?, source: UUID?, recording: UUID?)?

        do {
            let container = try ModelContainerFactory.make(inMemory: false, url: paths.storeURL)
            let h = try WP3Harness(container: container, paths: paths)
            try h.seed(.askKaran)
            // A trace from a pipeline-style match, then a reject that stores a negative.
            let id = try h.separatedRecording(turns: SeedContent.conversationB, drafts: [
                WP3Docs.draft("S1", 1, clean: 12, vector: SyntheticVoices.vector(near: .liam, cosine: 0.8, variant: 44))])
            try h.matchLikeThePipeline(id)
            let s1 = try #require(try h.recording(id).speaker("S1"))
            expectedTrace = try JSONDecoder().decode(MatchTrace.self, from: try #require(s1.matchTraceData))
            try h.store.rejectSuggestion(recordingID: d, key: "S2")
            let s2 = try #require(try h.recording(d).speaker("S2"))
            let karan = try #require(try h.profile(named: "Karan"))
            #expect(karan.negatives.count == 1)
            expectedNegative = (s2.vector, s2.id, d)
        }

        let container = try ModelContainerFactory.make(inMemory: false, url: paths.storeURL)
        let context = container.mainContext
        let negatives = try context.fetch(FetchDescriptor<VoiceNegative>())
        #expect(negatives.count == 1)
        let n = try #require(negatives.first)
        #expect(n.vector == expectedNegative?.vector && n.vector != nil)
        #expect(n.embeddingModelKey == EmbeddingModelID.fake.key)
        #expect(n.sourceSpeakerID == expectedNegative?.source && n.sourceRecordingID == expectedNegative?.recording)
        #expect(n.profile?.id == Seeds.ID.karan && n.speechSeconds == 11.5)
        let speakers = try context.fetch(FetchDescriptor<RecordingSpeaker>())
        let traced = speakers.compactMap(\.matchTraceData)
        #expect(traced.count == 1)
        let trace = try JSONDecoder().decode(MatchTrace.self, from: try #require(traced.first))
        #expect(trace == expectedTrace && trace.kind == .auto && trace.profileID == Seeds.ID.liam)
    }

    @Test func onDiskStoreSurvivesCloseAndReopen() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("wp3-schema-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(root: root)
        try paths.prepare()
        let vector = SyntheticVoices.vector(near: .karan, cosine: 0.9, variant: 2)

        do {
            let container = try ModelContainerFactory.make(inMemory: false, url: paths.storeURL)
            let store = LibraryStore(context: container.mainContext, paths: paths,
                                     deviceIdentity: FixedDeviceIdentity("d"), clock: .frozen(Seeds.Dates.d),
                                     localChannel: CaptureChannel.iphone)
            let id = Seeds.ID.recordingB
            try store.createRecording(id: id, createdAt: Seeds.Dates.b, audioFileName: "b.wav", source: .imported)
            try store.finishCapture(id: id, audio: CapturedAudio(url: paths.audioURL(fileName: "b.wav"), duration: 24,
                                                                 marks: [14], peaks: [0.25, 1]), language: .language("en"))
            try store.checkpointTranscript(id: id, document: WP3Docs.paragraphs(SeedContent.conversationB))
            try store.checkpointSeparation(id: id, document: WP3Docs.speakers(SeedContent.conversationB), speakers: [
                WP3Docs.draft("S1", 1, clean: 11, vector: SyntheticVoices.vector(near: .liam, cosine: 0.9, variant: 1)),
                WP3Docs.draft("S2", 2, clean: 11.5, vector: vector),
            ])
            _ = try store.applyMatches(id: id, decisions: [:], policy: .default)
            _ = try store.nameSpeaker(recordingID: id, key: "S2", as: .newPerson(name: "Karan"), remember: true)
            _ = try store.createFolder(name: "Work")
            _ = try store.stampCaptureChannels()
        }

        let container = try ModelContainerFactory.make(inMemory: false, url: paths.storeURL)
        let context = container.mainContext
        let r = try #require(try context.fetch(FetchDescriptor<Recording>()).first)
        #expect(r.id == Seeds.ID.recordingB && r.source == .imported && r.duration == 24 && r.marks == [14])
        #expect(r.peaks == [0.25, 1] && r.language == .language("en") && r.stage == .ready)
        #expect(r.transcript == WP3Docs.speakers(SeedContent.conversationB))
        #expect(r.sortedSpeakers.map(\.displayName) == ["Speaker 1", "Karan"])
        let karan = try #require(try context.fetch(FetchDescriptor<VoiceProfile>()).first)
        #expect(karan.name == "Karan" && karan.samples.count == 1 && karan.samples[0].vector == vector)
        #expect(karan.samples[0].origin == .named && karan.speakers.count == 1)
        #expect(try context.fetchCount(FetchDescriptor<Folder>()) == 1)
        #expect(r.captureChannel == CaptureChannel.iphone && karan.samples[0].captureChannel == CaptureChannel.iphone)
        let store = LibraryStore(context: context, paths: paths, deviceIdentity: FixedDeviceIdentity("d"), clock: .system,
                                 localChannel: CaptureChannel.iphone)
        #expect(try store.stampCaptureChannels() == 0)
    }
}
