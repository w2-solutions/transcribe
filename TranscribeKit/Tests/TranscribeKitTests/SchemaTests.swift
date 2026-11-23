import Foundation
import SwiftData
import Testing
import TranscribeCore
@testable import TranscribeFakes
@testable import TranscribeKit

@Suite("WP3: schema")
@MainActor
struct SchemaTests {
    @Test func migrationPlanListsV1() {
        #expect(TranscribeMigrationPlan.schemas.count == 1)
        #expect(TranscribeMigrationPlan.schemas.first == TranscribeSchemaV1.self)
        #expect(TranscribeMigrationPlan.stages.isEmpty)
        #expect(TranscribeSchemaV1.versionIdentifier == Schema.Version(1, 0, 0))
        #expect(TranscribeSchemaV1.models.count == 5)
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
                                     deviceIdentity: FixedDeviceIdentity("d"), clock: .frozen(Seeds.Dates.d))
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
            _ = try store.reconcileDevice()
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
        let store = LibraryStore(context: context, paths: paths, deviceIdentity: FixedDeviceIdentity("d"), clock: .system)
        #expect(try store.reconcileDevice() == false)
    }
}
