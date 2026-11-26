import CoreData
import Foundation
import SwiftData
import Testing
import TranscribeCore
@testable import TranscribeFakes
@testable import TranscribeKit

/// Opens the committed V4 library (`Fixtures/V4Library`, written by `V4FixtureWriter`; 0.3.3 runs V4 on the iPhone and
/// the Mac) under schema V5. Nothing may be lost, group labels included, the sync state must come through byte for
/// byte so the upgrade sends nothing, every speaker reads as heard on the microphone, and the one-time pre-V5 backup
/// is taken exactly once. Older libraries reach V5 through `MigrationTests`, `MigrationV3Tests` and `MigrationV4Tests`.
@Suite("Store migration to V5")
@MainActor
struct MigrationV5Tests {
    typealias Manifest = V4FixtureWriter.Manifest

    /// A temp folder holding a copy of the V4 fixture's store files, and its manifest.
    func copyV4Fixture() throws -> (root: URL, storeURL: URL, manifest: Manifest) {
        let fm = FileManager.default
        let source = try V4FixtureWriter.fixtureDirectory
        let root = fm.temporaryDirectory.appendingPathComponent("v5-migration-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        for name in try fm.contentsOfDirectory(atPath: source.path) where name.hasPrefix("Library.store") {
            try fm.copyItem(at: source.appendingPathComponent(name), to: root.appendingPathComponent(name))
        }
        let manifest = try V4FixtureWriter.decoder.decode(Manifest.self, from: Data(contentsOf: source.appendingPathComponent("manifest.json")))
        return (root, root.appendingPathComponent("Library.store"), manifest)
    }

    /// The current schema's entity hashes.
    static func v5VersionHashes() throws -> [String: Data] {
        try MigrationTests.versionHashes(of: Schema(versionedSchema: TranscribeSchemaV5.self))
    }

    func store(_ context: ModelContext, root: URL, channel: String = CaptureChannel.iphone) -> LibraryStore {
        LibraryStore(context: context, paths: AppPaths(root: root), deviceIdentity: FixedDeviceIdentity("phone"),
                     clock: .frozen(Seeds.Dates.d), localChannel: channel)
    }

    // MARK: V4 → V5

    @Test func v4ToV5KeepsEveryRowAndSyncBaseHashes() throws {
        let (root, storeURL, expected) = try copyV4Fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        // The copy really is a V4 store (not one a later schema already touched).
        #expect(try MigrationTests.versionHashes(at: storeURL) == (try V4FixtureWriter.v4VersionHashes()))

        do {
            let container = try ModelContainerFactory.make(inMemory: false, url: storeURL)
            let context = container.mainContext

            // Every manifest row round-trips through the current (V5) types, labels and sync rows included.
            let readBack = try Self.manifest(context)
            #expect(readBack == expected)
            #expect(expected.counts.syncRecords == 16 && expected.counts.groupLabels == 1)

            // The typed accessors read the kept bookkeeping as before.
            let rows = try context.fetch(FetchDescriptor<SyncRecordState>())
            let mustMerge = try #require(rows.first { $0.entityID == V4FixtureWriter.ID.liamMac })
            #expect(mustMerge.mustMergeWithServer && mustMerge.pending == .save && !mustMerge.baseHashes.isEmpty)
            let unresolved = try #require(rows.first { $0.entityID == V4FixtureWriter.ID.speakerB2 })
            #expect(unresolved.unresolvedLinks == ["profileID": V4FixtureWriter.ID.unresolvedProfile.uuidString])
            #expect(rows.first { $0.entityID == V4FixtureWriter.ID.deletedSample }?.pending == .delete)
            let account = try #require(try context.fetch(FetchDescriptor<SyncAccountState>()).first)
            #expect(account.engineState == V4FixtureWriter.engineState && account.pausedReason == nil)

            // Every speaker of a V4 library was heard on the microphone.
            let speakers = try context.fetch(FetchDescriptor<RecordingSpeaker>())
            #expect(speakers.count == expected.counts.speakers)
            #expect(speakers.allSatisfy { $0.captureSource == nil && $0.source == .mic })

            // The label still anchors on Liam's Mac samples, bit for bit.
            let label = try #require(try context.fetch(FetchDescriptor<VoiceGroupLabel>()).first)
            #expect(label.profile?.id == V4FixtureWriter.ID.liam)
            #expect(VoiceVector.packed(label.anchors) == VoiceVector.packed(V4FixtureWriter.deskAnchors))
            #expect(try store(context, root: root).stampCaptureChannels() == 0)
        }

        // The store on disk is now a V5 store, and reopening it changes nothing.
        #expect(try MigrationTests.versionHashes(at: storeURL) == (try Self.v5VersionHashes()))
        let reopened = try ModelContainerFactory.make(inMemory: false, url: storeURL)
        #expect(try Self.manifest(reopened.mainContext) == expected)
    }

    /// V5 adds a speaker field that is nil for every V4 speaker, so every record's projected hashes still equal the
    /// base hashes the V4 build agreed with the server, labels included. A full scan right after the upgrade queues
    /// only what was already pending. (When the speaker's sync fields gain `captureSource`, nil must not change them.)
    @Test func upgradeQueuesNothingToSync() async throws {
        let (root, storeURL, _) = try copyV4Fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let container = try ModelContainerFactory.make(inMemory: false, url: storeURL)
        let context = container.mainContext
        let projector = RecordProjector(context: context)

        let rows = try context.fetch(FetchDescriptor<SyncRecordState>())
        var compared: [SyncRecordType: Int] = [:]
        for row in rows {
            guard let id = row.recordID, let e = projector.entity(id) else { continue }
            #expect(RecordProjector.hashes(e, unresolved: row.unresolvedLinks) == row.baseHashes, "\(row.recordName)")
            compared[id.type, default: 0] += 1
        }
        #expect(compared.values.reduce(0, +) == 15)
        #expect(compared[.speaker] == 4 && compared[.groupLabel] == 1)

        let detector = ChangeDetector(store: store(context, root: root), clock: .frozen(Seeds.Dates.d))
        let outcome = try await detector.fullScan()
        #expect(outcome.massDelete == nil)
        #expect(outcome.saves == [SyncRecordID(type: .sample, entityID: V4FixtureWriter.ID.liamMac)])
        #expect(outcome.deletes == [SyncRecordID(type: .sample, entityID: V4FixtureWriter.ID.deletedSample)])
        #expect(try context.fetchCount(FetchDescriptor<SyncRecordState>()) == 16)
    }

    @Test func onDiskHashesAreV5() throws {
        let (root, storeURL, _) = try copyV4Fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        do { _ = try ModelContainerFactory.make(inMemory: false, url: storeURL) }
        let hashes = try MigrationTests.versionHashes(at: storeURL)
        let v4 = try V4FixtureWriter.v4VersionHashes()
        #expect(hashes == (try Self.v5VersionHashes()))
        #expect(Set(hashes.keys) == Set(v4.keys))
        // Only the speaker (a new attribute) changed shape; every other V4 entity is exactly as it was.
        for (entity, hash) in v4 where entity != "RecordingSpeaker" { #expect(hashes[entity] == hash, "\(entity)") }
        #expect(hashes["RecordingSpeaker"] != v4["RecordingSpeaker"])
    }

    // MARK: Older libraries

    @Test func v3ToV5ReadsEverySpeakerAsMic() throws {
        let (root, storeURL, expected) = try MigrationV4Tests().copyV3Fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            let container = try ModelContainerFactory.make(inMemory: false, url: storeURL)
            let speakers = try container.mainContext.fetch(FetchDescriptor<RecordingSpeaker>())
            #expect(speakers.count == expected.counts.speakers)
            #expect(speakers.allSatisfy { $0.captureSource == nil && $0.source == .mic })
        }
        #expect(try MigrationTests.versionHashes(at: storeURL) == (try Self.v5VersionHashes()))
    }

    // MARK: Backup and marker

    @Test func backupOnceAndMarkerV5() throws {
        let (root, storeURL, _) = try copyV4Fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        let fixtureBytes = try Data(contentsOf: try V4FixtureWriter.fixtureDirectory.appendingPathComponent("Library.store"))
        // A device that ran V2, V3 and V4 has their markers and backups next to the store: all must stay untouched.
        let leftAlone: [(String, Data)] = [
            ("Library.schema-v2", Data("2.0.0\n".utf8)), ("Library.pre-v2-backup.store", Data("old v1 backup".utf8)),
            ("Library.schema-v3", Data("3.0.0\n".utf8)), ("Library.pre-v3-backup.store", Data("old v2 backup".utf8)),
            ("Library.schema-v4", Data("4.0.0\n".utf8)), ("Library.pre-v4-backup.store", Data("old v3 backup".utf8)),
            ("Library.pre-v4-backup.store-wal", Data("old v3 wal".utf8)),
        ]
        for (name, bytes) in leftAlone { try bytes.write(to: root.appendingPathComponent(name)) }

        let backup = ModelContainerFactory.backupURL(storeURL: storeURL)
        let marker = ModelContainerFactory.markerURL(storeURL: storeURL)
        #expect(backup.lastPathComponent == "Library.pre-v5-backup.store" && marker.lastPathComponent == "Library.schema-v5")
        #expect(ModelContainerFactory.currentVersion == 5)
        #expect(!fm.fileExists(atPath: backup.path) && !fm.fileExists(atPath: marker.path))

        do {
            let container = try ModelContainerFactory.make(inMemory: false, url: storeURL)
            #expect(try container.mainContext.fetchCount(FetchDescriptor<Recording>()) == 3)
        }
        #expect(try Data(contentsOf: backup) == fixtureBytes)
        #expect(fm.fileExists(atPath: ModelContainerFactory.backupURL(storeURL: storeURL, suffix: "-wal").path))
        #expect(fm.fileExists(atPath: ModelContainerFactory.backupURL(storeURL: storeURL, suffix: "-shm").path))
        // The backup is the V4 store as it was, still openable by a V4 build.
        #expect(try MigrationTests.versionHashes(at: backup) == (try V4FixtureWriter.v4VersionHashes()))
        #expect(try String(contentsOf: marker, encoding: .utf8) == "5.0.0\n")
        let backupAfterFirst = try Data(contentsOf: backup)

        // Opening again (now a V5 store) takes no new backup.
        do {
            let container = try ModelContainerFactory.make(inMemory: false, url: storeURL)
            #expect(try container.mainContext.fetchCount(FetchDescriptor<Recording>()) == 3)
        }
        #expect(try Data(contentsOf: backup) == backupAfterFirst)
        #expect(fm.fileExists(atPath: marker.path))
        for (name, bytes) in leftAlone { #expect(try Data(contentsOf: root.appendingPathComponent(name)) == bytes, "\(name)") }
    }

    @Test func freshInstallTakesNoBackup() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("v5-fresh-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        let paths = AppPaths(root: root)
        try paths.prepare()
        do { _ = try ModelContainerFactory.make(inMemory: false, url: paths.storeURL) }
        #expect(try String(contentsOf: ModelContainerFactory.markerURL(storeURL: paths.storeURL), encoding: .utf8) == "5.0.0\n")
        #expect(!fm.fileExists(atPath: ModelContainerFactory.backupURL(storeURL: paths.storeURL).path))
        #expect(!fm.fileExists(atPath: ModelContainerFactory.backupURL(storeURL: paths.storeURL, suffix: "-wal").path))
        #expect(try MigrationTests.versionHashes(at: paths.storeURL) == (try Self.v5VersionHashes()))
    }

    // MARK: The new field

    @Test func captureSourceRoundTripsAndReadsUnknownAsMic() throws {
        let (root, storeURL, _) = try copyV4Fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            let container = try ModelContainerFactory.make(inMemory: false, url: storeURL)
            let context = container.mainContext
            let speakers = try context.fetch(FetchDescriptor<RecordingSpeaker>())
            let a1 = try #require(speakers.first { $0.id == V4FixtureWriter.ID.speakerA1 })
            let a2 = try #require(speakers.first { $0.id == V4FixtureWriter.ID.speakerA2 })
            let b1 = try #require(speakers.first { $0.id == V4FixtureWriter.ID.speakerB1 })
            a1.captureSource = SpeakerSource.system.rawValue
            a2.captureSource = SpeakerSource.mixed.rawValue
            b1.captureSource = "fromTheFuture"
            try context.save()
        }
        do {
            let container = try ModelContainerFactory.make(inMemory: false, url: storeURL)
            let speakers = try container.mainContext.fetch(FetchDescriptor<RecordingSpeaker>())
            let byID = Dictionary(uniqueKeysWithValues: speakers.map { ($0.id, $0) })
            #expect(byID[V4FixtureWriter.ID.speakerA1]?.captureSource == "system" && byID[V4FixtureWriter.ID.speakerA1]?.source == .system)
            #expect(byID[V4FixtureWriter.ID.speakerA2]?.source == .mixed)
            #expect(byID[V4FixtureWriter.ID.speakerB1]?.captureSource == "fromTheFuture" && byID[V4FixtureWriter.ID.speakerB1]?.source == .mic)
            #expect(byID[V4FixtureWriter.ID.speakerB2]?.captureSource == nil && byID[V4FixtureWriter.ID.speakerB2]?.source == .mic)
        }
    }

    // MARK: Manifest read with the current types

    /// The same rows `V4FixtureWriter.readManifest` reads with the V4 types, read through the current (V5) aliases.
    static func manifest(_ context: ModelContext) throws -> Manifest {
        let base = try MigrationV4Tests.manifest(context)
        let labels = try context.fetch(FetchDescriptor<VoiceGroupLabel>()).sorted { $0.id.uuidString < $1.id.uuidString }
        return Manifest(
            schemaVersion: "\(TranscribeSchemaV4.versionIdentifier)",
            modelKey: base.modelKey,
            counts: .init(recordings: base.counts.recordings, speakers: base.counts.speakers, profiles: base.counts.profiles,
                          samples: base.counts.samples, folders: base.counts.folders, negatives: base.counts.negatives,
                          syncRecords: base.counts.syncRecords, syncAccounts: base.counts.syncAccounts, groupLabels: labels.count),
            stages: base.stages, profiles: base.profiles, samples: base.samples, negatives: base.negatives,
            speakers: base.speakers, recordings: base.recordings, folders: base.folders, syncRecords: base.syncRecords,
            syncAccounts: base.syncAccounts,
            groupLabels: labels.map {
                .init(id: $0.id, profileID: $0.profile?.id, text: $0.text, createdAt: $0.createdAt, editedAt: $0.editedAt,
                      embeddingModelKey: $0.embeddingModelKey, captureChannel: $0.captureChannel,
                      anchor: $0.anchorVectorData.base64EncodedString(), anchorDimension: $0.anchorDimension)
            }
        )
    }
}
