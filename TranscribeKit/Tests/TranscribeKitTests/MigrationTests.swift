import CoreData
import Foundation
import SwiftData
import Testing
import TranscribeCore
@testable import TranscribeFakes
@testable import TranscribeKit

/// Opens the committed store written by the V1 schema (`Fixtures/V1Library`, made once before V2 existed) under the
/// current schema. This is the guard for the owner's phone: nothing in a V1 store may be lost.
@Suite("Store migration")
@MainActor
struct MigrationTests {
    /// The fixture's manifest, written by the V1 code alongside the store.
    struct Manifest: Decodable {
        struct Counts: Decodable { var recordings, speakers, profiles, samples, folders: Int }
        struct Sample: Decodable {
            var id: UUID; var profileID: UUID?; var origin: String; var speechSeconds: Double
            var embeddingModelKey: String; var packed: String
        }
        struct Speaker: Decodable {
            var id: UUID; var recordingID: UUID?; var key: String; var label: String; var profileID: UUID?
            var suggestedProfileID: UUID?; var rejectedProfileIDs: [UUID]; var cleanSeconds: Double
            var matchScore: Double?; var vector: String?
        }
        struct RecordingRow: Decodable { var id: UUID; var stage: Int; var folderID: UUID?; var folderName: String? }
        struct Profile: Decodable { var id: UUID; var name: String; var embeddingModelKey: String; var sampleCount: Int }
        var schemaVersion: String
        var modelKey: String
        var counts: Counts
        var profiles: [Profile]
        var samples: [Sample]
        var speakers: [Speaker]
        var recordings: [RecordingRow]
    }

    static var fixtureDirectory: URL {
        get throws {
            try #require(Bundle.module.url(forResource: "V1Library", withExtension: nil, subdirectory: "Fixtures"))
        }
    }

    /// A temp folder holding a copy of the fixture's store files.
    func copyFixture() throws -> (root: URL, storeURL: URL, manifest: Manifest) {
        let fm = FileManager.default
        let source = try Self.fixtureDirectory
        let root = fm.temporaryDirectory.appendingPathComponent("v1-migration-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        for name in try fm.contentsOfDirectory(atPath: source.path) where name.hasPrefix("Library.store") {
            try fm.copyItem(at: source.appendingPathComponent(name), to: root.appendingPathComponent(name))
        }
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: source.appendingPathComponent("manifest.json")))
        return (root, root.appendingPathComponent("Library.store"), manifest)
    }

    /// The entity version hashes Core Data recorded in a store's metadata.
    static func versionHashes(at storeURL: URL) throws -> [String: Data] {
        let metadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(ofType: NSSQLiteStoreType, at: storeURL)
        return try #require(metadata[NSStoreModelVersionHashesKey] as? [String: Data])
    }

    /// The entity version hashes of a fresh, empty store written by `schema` as it is compiled now.
    static func versionHashes(of schema: Schema) throws -> [String: Data] {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("schema-hash-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Library.store")
        do {
            let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: url))
            try container.mainContext.save()
        }
        return try versionHashes(at: url)
    }

    @Test func fixtureWasWrittenByV1() throws {
        let fm = FileManager.default
        let source = try Self.fixtureDirectory
        #expect(fm.fileExists(atPath: source.appendingPathComponent("Library.store").path))
        let (root, storeURL, manifest) = try copyFixture()
        defer { try? fm.removeItem(at: root) }
        #expect(manifest.schemaVersion == "1.0.0")
        #expect(manifest.counts.recordings == 4 && manifest.counts.profiles == 2 && manifest.counts.samples == 5)
        #expect(manifest.counts.folders == 1)

        // The manifest is written by the generator, so it cannot tell V1 from V2 (pitfall 11). The store's own
        // metadata can: its entity hashes must be exactly those of the frozen V1 schema, which also catches any edit
        // to TranscribeSchemaV1 (pitfall 1), and must not be V2's (a regenerated fixture would make
        // v1FixtureOpensUnderTheCurrentSchema test no migration at all).
        let fixture = try Self.versionHashes(at: storeURL)
        #expect(Set(fixture.keys) == ["Folder", "Recording", "RecordingSpeaker", "VoiceProfile", "VoiceSample"])
        #expect(fixture["VoiceNegative"] == nil)
        #expect(fixture == (try Self.versionHashes(of: Schema(versionedSchema: TranscribeSchemaV1.self))))
        let v2 = try Self.versionHashes(of: Schema(versionedSchema: TranscribeSchemaV2.self))
        #expect(fixture != v2 && v2["VoiceNegative"] != nil)
    }

    /// V1 → V2 → V3 → V4 in one open: every V1 row survives, with the V2, V3 and V4 additions empty.
    @Test func v1FixtureOpensUnderTheCurrentSchema() throws {
        let (root, storeURL, m) = try copyFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let container = try ModelContainerFactory.make(inMemory: false, url: storeURL)
        let context = container.mainContext

        #expect(try context.fetchCount(FetchDescriptor<Recording>()) == m.counts.recordings)
        #expect(try context.fetchCount(FetchDescriptor<RecordingSpeaker>()) == m.counts.speakers)
        #expect(try context.fetchCount(FetchDescriptor<VoiceProfile>()) == m.counts.profiles)
        #expect(try context.fetchCount(FetchDescriptor<VoiceSample>()) == m.counts.samples)
        #expect(try context.fetchCount(FetchDescriptor<Folder>()) == m.counts.folders)
        #expect(try context.fetchCount(FetchDescriptor<VoiceNegative>()) == 0)

        let samples = Dictionary(uniqueKeysWithValues: try context.fetch(FetchDescriptor<VoiceSample>()).map { ($0.id, $0) })
        #expect(samples.count == m.samples.count)
        for expected in m.samples {
            let s = try #require(samples[expected.id])
            #expect(s.vectorData == Data(base64Encoded: expected.packed))
            #expect(s.vector != nil && s.originRaw == expected.origin && s.origin.rawValue == expected.origin)
            #expect(s.speechSeconds == expected.speechSeconds && s.embeddingModelKey == expected.embeddingModelKey)
            #expect(s.profile?.id == expected.profileID)
        }

        let speakers = Dictionary(uniqueKeysWithValues: try context.fetch(FetchDescriptor<RecordingSpeaker>()).map { ($0.id, $0) })
        #expect(speakers.count == m.speakers.count)
        for expected in m.speakers {
            let s = try #require(speakers[expected.id])
            #expect(s.key == expected.key && s.labelRaw == expected.label && s.recording?.id == expected.recordingID)
            #expect(s.profile?.id == expected.profileID && s.suggestedProfileID == expected.suggestedProfileID)
            #expect(s.rejectedProfileIDs == expected.rejectedProfileIDs && s.cleanSeconds == expected.cleanSeconds)
            #expect(s.matchScore == expected.matchScore)
            #expect(s.vectorData == expected.vector.flatMap { Data(base64Encoded: $0) })
            #expect(s.matchTraceData == nil && s.vectorCoherence == nil && s.coherence == nil)
        }
        // The fixture covers the cases that matter: a suggestion with its score and a rejected profile.
        #expect(m.speakers.contains { $0.label == SpeakerLabelState.suggested.rawValue && $0.matchScore != nil })
        #expect(m.speakers.contains { !$0.rejectedProfileIDs.isEmpty })

        let recordings = Dictionary(uniqueKeysWithValues: try context.fetch(FetchDescriptor<Recording>()).map { ($0.id, $0) })
        for expected in m.recordings {
            let r = try #require(recordings[expected.id])
            #expect(r.stageRaw == expected.stage && r.folder?.id == expected.folderID && r.folder?.name == expected.folderName)
            #expect(r.movedSpeakerTracesData == nil)
        }
        #expect(m.recordings.contains { $0.folderID != nil })

        let profiles = try context.fetch(FetchDescriptor<VoiceProfile>())
        #expect(profiles.allSatisfy { $0.negatives.isEmpty })
        for expected in m.profiles {
            let p = try #require(profiles.first { $0.id == expected.id })
            #expect(p.name == expected.name && p.samples.count == expected.sampleCount)
        }

        #expect(try context.fetch(FetchDescriptor<Recording>()).allSatisfy { $0.captureChannel == nil && $0.captureDetailJSON == nil })
        #expect(try context.fetch(FetchDescriptor<VoiceSample>()).allSatisfy { $0.captureChannel == nil && $0.captureInput == nil })
        #expect(try context.fetchCount(FetchDescriptor<SyncRecordState>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<SyncAccountState>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<VoiceGroupLabel>()) == 0)

        let store = LibraryStore(context: context, paths: AppPaths(root: root), deviceIdentity: FixedDeviceIdentity("d"),
                                 clock: .frozen(Seeds.Dates.d), localChannel: CaptureChannel.iphone)
        let candidates = try store.matchCandidates(modelKey: EmbeddingModelID.fake.key)
        #expect(candidates.count == 2)
        for c in candidates {
            #expect(c.samples.count == m.profiles.first { $0.id == c.id }?.sampleCount)
            #expect(c.negatives.isEmpty)
        }
    }

    /// A V1 store (a phone that never ran a V2 build) is backed up once, as the current version's pre-upgrade backup.
    @Test func v1BackupIsTakenOnceBeforeTheFirstOpen() throws {
        let (root, storeURL, _) = try copyFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        let fixtureBytes = try Data(contentsOf: try Self.fixtureDirectory.appendingPathComponent("Library.store"))
        let backup = ModelContainerFactory.backupURL(storeURL: storeURL)
        let marker = ModelContainerFactory.markerURL(storeURL: storeURL)
        let current = ModelContainerFactory.currentVersion
        #expect(backup.lastPathComponent == "Library.pre-v\(current)-backup.store" && marker.lastPathComponent == "Library.schema-v\(current)")
        #expect(!fm.fileExists(atPath: backup.path) && !fm.fileExists(atPath: marker.path))

        do {
            let container = try ModelContainerFactory.make(inMemory: false, url: storeURL)
            #expect(try container.mainContext.fetchCount(FetchDescriptor<Recording>()) == 4)
        }
        #expect(try Data(contentsOf: backup) == fixtureBytes)
        #expect(fm.fileExists(atPath: marker.path))
        let backupAfterFirst = try Data(contentsOf: backup)

        // Opening again (now a store of the current schema) takes no new backup.
        do {
            let container = try ModelContainerFactory.make(inMemory: false, url: storeURL)
            #expect(try container.mainContext.fetchCount(FetchDescriptor<Recording>()) == 4)
        }
        #expect(try Data(contentsOf: backup) == backupAfterFirst)
        #expect(fm.fileExists(atPath: marker.path))
    }
}
