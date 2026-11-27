import CoreData
import Foundation
import SwiftData
import Testing
import TranscribeCore
@testable import TranscribeFakes
@testable import TranscribeKit

/// Opens the committed V3 library (`Fixtures/V3Library`, written by `V3FixtureWriter`; 0.3.0 to 0.3.2 run V3 on the
/// iPhone and the Mac), the V2 library and the V1 library under the current schema, through V4. Nothing may be lost,
/// the sync state must come through byte for byte so the upgrade sends nothing, there are no group labels yet, and
/// the one-time backup is taken exactly once. The current version's own checks (the marker, a fresh install) are in
/// `MigrationV5Tests`.
@Suite("Store migration through V4")
@MainActor
struct MigrationV4Tests {
    typealias Manifest = V3FixtureWriter.Manifest

    /// A temp folder holding a copy of the V3 fixture's store files, and its manifest.
    func copyV3Fixture() throws -> (root: URL, storeURL: URL, manifest: Manifest) {
        let fm = FileManager.default
        let source = try V3FixtureWriter.fixtureDirectory
        let root = fm.temporaryDirectory.appendingPathComponent("v4-migration-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        for name in try fm.contentsOfDirectory(atPath: source.path) where name.hasPrefix("Library.store") {
            try fm.copyItem(at: source.appendingPathComponent(name), to: root.appendingPathComponent(name))
        }
        let manifest = try V3FixtureWriter.decoder.decode(Manifest.self, from: Data(contentsOf: source.appendingPathComponent("manifest.json")))
        return (root, root.appendingPathComponent("Library.store"), manifest)
    }

    static func v4VersionHashes() throws -> [String: Data] {
        try MigrationTests.versionHashes(of: Schema(versionedSchema: TranscribeSchemaV4.self))
    }

    func store(_ context: ModelContext, root: URL, channel: String = CaptureChannel.iphone) -> LibraryStore {
        LibraryStore(context: context, paths: AppPaths(root: root), deviceIdentity: FixedDeviceIdentity("phone"),
                     clock: .frozen(Seeds.Dates.d), localChannel: channel)
    }

    // MARK: V3 → V4

    @Test func v3ToV4KeepsEveryRowAndSyncBaseHashes() throws {
        let (root, storeURL, expected) = try copyV3Fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        // The copy really is a V3 store (not one a later schema already touched).
        #expect(try MigrationTests.versionHashes(at: storeURL) == (try V3FixtureWriter.v3VersionHashes()))

        do {
            let container = try ModelContainerFactory.make(inMemory: false, url: storeURL)
            let context = container.mainContext

            // Every manifest row round-trips through the current types, sync rows and account included.
            let readBack = try Self.manifest(context)
            #expect(readBack.counts == expected.counts)
            #expect(readBack.stages == expected.stages)
            #expect(readBack.profiles == expected.profiles)
            #expect(readBack.samples == expected.samples)
            #expect(readBack.negatives == expected.negatives)
            #expect(readBack.speakers == expected.speakers)
            #expect(readBack.recordings == expected.recordings)
            #expect(readBack.folders == expected.folders)
            #expect(readBack.syncRecords == expected.syncRecords)
            #expect(readBack.syncAccounts == expected.syncAccounts)
            #expect(expected.counts.syncRecords == 15 && expected.counts.samples == 4)

            // The typed accessors read the kept bookkeeping as before.
            let rows = try context.fetch(FetchDescriptor<SyncRecordState>())
            let mustMerge = try #require(rows.first { $0.entityID == V3FixtureWriter.ID.liamMac })
            #expect(mustMerge.mustMergeWithServer && mustMerge.pending == .save && !mustMerge.baseHashes.isEmpty)
            #expect(mustMerge.baseHashes["~mustMerge"] == nil)
            let unresolved = try #require(rows.first { $0.entityID == V3FixtureWriter.ID.speakerB2 })
            #expect(unresolved.unresolvedLinks == ["profileID": V3FixtureWriter.ID.unresolvedProfile.uuidString])
            #expect(rows.first { $0.entityID == V3FixtureWriter.ID.deletedSample }?.pending == .delete)
            let account = try #require(try context.fetch(FetchDescriptor<SyncAccountState>()).first)
            #expect(account.engineState == V3FixtureWriter.engineState && account.pausedReason == nil)

            // Nothing needs stamping: V3 already has every channel.
            #expect(try store(context, root: root).stampCaptureChannels() == 0)
        }

        // The store on disk is now a store of the current schema, and reopening it changes nothing.
        #expect(try MigrationTests.versionHashes(at: storeURL) == (try MigrationV5Tests.v5VersionHashes()))
        let reopened = try ModelContainerFactory.make(inMemory: false, url: storeURL)
        let again = try Self.manifest(reopened.mainContext)
        #expect(again.syncRecords == expected.syncRecords && again.samples == expected.samples)
        #expect(again.recordings == expected.recordings && again.speakers == expected.speakers)
    }

    /// Trap T1: V4 and V5 add no synced value a V3 record holds, so every record's projected hashes still equal the
    /// base hashes the V3 build agreed with the server. A full scan right after the upgrade queues only what was already pending.
    @Test func upgradeQueuesNothingToSync() async throws {
        let (root, storeURL, _) = try copyV3Fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let container = try ModelContainerFactory.make(inMemory: false, url: storeURL)
        let context = container.mainContext
        let projector = RecordProjector(context: context)

        let rows = try context.fetch(FetchDescriptor<SyncRecordState>())
        var compared = 0
        for row in rows {
            guard let id = row.recordID, let e = projector.entity(id) else { continue }
            #expect(RecordProjector.hashes(e, unresolved: row.unresolvedLinks) == row.baseHashes, "\(row.recordName)")
            compared += 1
        }
        #expect(compared == 14)

        let detector = ChangeDetector(store: store(context, root: root), clock: .frozen(Seeds.Dates.d))
        let outcome = try await detector.fullScan()
        #expect(outcome.massDelete == nil)
        #expect(outcome.saves == [SyncRecordID(type: .sample, entityID: V3FixtureWriter.ID.liamMac)])
        #expect(outcome.deletes == [SyncRecordID(type: .sample, entityID: V3FixtureWriter.ID.deletedSample)])
        #expect(try context.fetchCount(FetchDescriptor<SyncRecordState>()) == 15)
    }

    @Test func v4StartsWithNoLabels() throws {
        let (root, storeURL, expected) = try copyV3Fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let container = try ModelContainerFactory.make(inMemory: false, url: storeURL)
        let context = container.mainContext
        #expect(try context.fetchCount(FetchDescriptor<VoiceGroupLabel>()) == 0)
        let profiles = try context.fetch(FetchDescriptor<VoiceProfile>())
        #expect(profiles.count == expected.counts.profiles)
        #expect(profiles.allSatisfy { $0.groupLabels.isEmpty })
        // The matcher's input is untouched by the upgrade.
        let candidates = try store(context, root: root).matchCandidates(modelKey: expected.modelKey)
        #expect(candidates.count == expected.counts.profiles)
        for c in candidates {
            let p = try #require(expected.profiles.first { $0.id == c.id })
            #expect(c.samples.count == p.sampleCount && c.negatives.count == p.negativeCount)
        }
    }

    @Test func v4AddsOnlyTheLabelEntity() throws {
        let (root, storeURL, _) = try copyV3Fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        do { _ = try ModelContainerFactory.make(inMemory: false, url: storeURL) }
        #expect(try MigrationTests.versionHashes(at: storeURL) == (try MigrationV5Tests.v5VersionHashes()))
        // The frozen V4 schema against the frozen V3 schema.
        let hashes = try Self.v4VersionHashes()
        let v3 = try V3FixtureWriter.v3VersionHashes()
        #expect(Set(hashes.keys) == Set(v3.keys).union(["VoiceGroupLabel"]))
        // Only the profile (a new relationship) changed shape; every other V3 entity is exactly as it was.
        for (entity, hash) in v3 where entity != "VoiceProfile" { #expect(hashes[entity] == hash, "\(entity)") }
        #expect(hashes["VoiceProfile"] != v3["VoiceProfile"])
    }

    // MARK: V2 → V4 and V1 → V4

    @Test func v2ToV4() throws {
        let (root, storeURL, expected) = try MigrationV3Tests().copyV2Fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            let container = try ModelContainerFactory.make(inMemory: false, url: storeURL)
            let context = container.mainContext
            let readBack = try MigrationV3Tests.manifest(context)
            #expect(readBack.counts == expected.counts)
            #expect(readBack.samples == expected.samples && readBack.speakers == expected.speakers)
            #expect(try context.fetchCount(FetchDescriptor<VoiceGroupLabel>()) == 0)
            #expect(try context.fetch(FetchDescriptor<VoiceProfile>()).allSatisfy { $0.groupLabels.isEmpty })
            #expect(try context.fetchCount(FetchDescriptor<SyncRecordState>()) == 0)
        }
        #expect(try MigrationTests.versionHashes(at: storeURL) == (try MigrationV5Tests.v5VersionHashes()))
    }

    @Test func v1ToV4() throws {
        let (root, storeURL, m) = try MigrationTests().copyFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            let container = try ModelContainerFactory.make(inMemory: false, url: storeURL)
            let context = container.mainContext
            #expect(try context.fetchCount(FetchDescriptor<Recording>()) == m.counts.recordings)
            #expect(try context.fetchCount(FetchDescriptor<VoiceProfile>()) == m.counts.profiles)
            #expect(try context.fetchCount(FetchDescriptor<VoiceSample>()) == m.counts.samples)
            #expect(try context.fetchCount(FetchDescriptor<VoiceGroupLabel>()) == 0)
            #expect(try context.fetch(FetchDescriptor<VoiceProfile>()).allSatisfy { $0.groupLabels.isEmpty })
        }
        #expect(try MigrationTests.versionHashes(at: storeURL) == (try MigrationV5Tests.v5VersionHashes()))
    }

    // MARK: Backup and marker

    /// A V3 store (a device that never ran a V4 build) is backed up once, as the current version's backup.
    @Test func v3BackupIsTakenOnceBeforeTheFirstOpen() throws {
        let (root, storeURL, _) = try copyV3Fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        let fixtureBytes = try Data(contentsOf: try V3FixtureWriter.fixtureDirectory.appendingPathComponent("Library.store"))
        // A device that ran V2 and then V3 has both markers and both backups next to the store: all must stay untouched.
        let leftAlone: [(String, Data)] = [
            ("Library.schema-v2", Data("2.0.0\n".utf8)), ("Library.pre-v2-backup.store", Data("old v1 backup".utf8)),
            ("Library.schema-v3", Data("3.0.0\n".utf8)), ("Library.pre-v3-backup.store", Data("old v2 backup".utf8)),
            ("Library.pre-v3-backup.store-wal", Data("old v2 wal".utf8)),
        ]
        for (name, bytes) in leftAlone { try bytes.write(to: root.appendingPathComponent(name)) }

        let backup = ModelContainerFactory.backupURL(storeURL: storeURL)
        let marker = ModelContainerFactory.markerURL(storeURL: storeURL)
        let current = ModelContainerFactory.currentVersion
        #expect(backup.lastPathComponent == "Library.pre-v\(current)-backup.store" && marker.lastPathComponent == "Library.schema-v\(current)")
        #expect(!fm.fileExists(atPath: root.appendingPathComponent("Library.schema-v4").path))
        #expect(!fm.fileExists(atPath: backup.path) && !fm.fileExists(atPath: marker.path))

        do {
            let container = try ModelContainerFactory.make(inMemory: false, url: storeURL)
            #expect(try container.mainContext.fetchCount(FetchDescriptor<Recording>()) == 3)
        }
        #expect(try Data(contentsOf: backup) == fixtureBytes)
        #expect(fm.fileExists(atPath: ModelContainerFactory.backupURL(storeURL: storeURL, suffix: "-wal").path))
        #expect(fm.fileExists(atPath: ModelContainerFactory.backupURL(storeURL: storeURL, suffix: "-shm").path))
        // The backup is the V3 store as it was, still openable by a V3 build.
        #expect(try MigrationTests.versionHashes(at: backup) == (try V3FixtureWriter.v3VersionHashes()))
        #expect(try String(contentsOf: marker, encoding: .utf8) == "\(current).0.0\n")
        let backupAfterFirst = try Data(contentsOf: backup)

        // Opening again (now a store of the current schema) takes no new backup.
        do {
            let container = try ModelContainerFactory.make(inMemory: false, url: storeURL)
            #expect(try container.mainContext.fetchCount(FetchDescriptor<Recording>()) == 3)
        }
        #expect(try Data(contentsOf: backup) == backupAfterFirst)
        #expect(fm.fileExists(atPath: marker.path))
        for (name, bytes) in leftAlone { #expect(try Data(contentsOf: root.appendingPathComponent(name)) == bytes, "\(name)") }
    }

    // MARK: The new entity

    @Test func labelRoundTripsBitForBitAndCascadesWithItsProfile() throws {
        let (root, storeURL, _) = try copyV3Fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let labelID = UUID(uuidString: "D4000000-0000-4000-8000-000000000001")!
        var anchorBytes = Data()
        do {
            let container = try ModelContainerFactory.make(inMemory: false, url: storeURL)
            let context = container.mainContext
            let liam = try #require(try context.fetch(FetchDescriptor<VoiceProfile>()).first { $0.id == V3FixtureWriter.ID.liam })
            // Members in canonical order, decoded the way grouping decodes them.
            let members = liam.samples.filter { $0.captureChannel == CaptureChannel.mac }.sorted { $0.id.uuidString < $1.id.uuidString }
            let anchors = members.compactMap(\.vector)
            #expect(anchors.count == 2)
            let label = VoiceGroupLabel(id: labelID, text: "Desk", createdAt: Seeds.Dates.d, embeddingModelKey: liam.embeddingModelKey,
                                        captureChannel: CaptureChannel.mac, anchors: anchors)
            context.insert(label)
            label.profile = liam
            try context.save()
            anchorBytes = VoiceVector.packed(anchors)
            #expect(label.anchorVectorData == anchorBytes && label.anchorDimension == 256 && label.editedAt == Seeds.Dates.d)
        }
        do {
            let container = try ModelContainerFactory.make(inMemory: false, url: storeURL)
            let context = container.mainContext
            let label = try #require(try context.fetch(FetchDescriptor<VoiceGroupLabel>()).first)
            #expect(label.id == labelID && label.text == "Desk" && label.captureChannel == CaptureChannel.mac)
            #expect(label.createdAt == Seeds.Dates.d && label.editedAt == Seeds.Dates.d)
            #expect(label.embeddingModelKey == EmbeddingModelID.fake.key && label.profile?.id == V3FixtureWriter.ID.liam)
            #expect(label.anchorVectorData == anchorBytes)
            #expect(VoiceVector.packed(label.anchors) == anchorBytes && label.anchors.count == 2)
            let liam = try #require(label.profile)
            #expect(liam.groupLabels.map(\.id) == [labelID])

            // Forgetting the voice takes its labels with it; nothing else goes.
            let samplesBefore = try context.fetchCount(FetchDescriptor<VoiceSample>())
            context.delete(liam)
            try context.save()
            #expect(try context.fetchCount(FetchDescriptor<VoiceGroupLabel>()) == 0)
            #expect(try context.fetchCount(FetchDescriptor<VoiceSample>()) == samplesBefore - 3)
            #expect(try context.fetchCount(FetchDescriptor<VoiceProfile>()) == 1)
        }
    }

    @Test func unreadableAnchorsDecodeToNothing() {
        let v = SyntheticVoices.base(.liam)
        func label(_ data: Data, _ dimension: Int) -> VoiceGroupLabel {
            let l = VoiceGroupLabel(text: "x", createdAt: Seeds.Dates.d, embeddingModelKey: "", captureChannel: "", anchors: [])
            l.anchorVectorData = data
            l.anchorDimension = dimension
            return l
        }
        #expect(label(Data(), 0).anchors.isEmpty)
        #expect(label(v.packed, 0).anchors.isEmpty)
        #expect(label(v.packed, 255).anchors.isEmpty)
        #expect(label(v.packed.dropLast(4), 256).anchors.isEmpty)
        #expect(label(Data(v.packed) + Data(repeating: 0, count: 256 * 4), 256).anchors.isEmpty)   // a zero vector is not unit length
        #expect(label(v.packed, 256).anchors == [v])
        let empty = VoiceGroupLabel(text: "x", createdAt: Seeds.Dates.d, embeddingModelKey: "", captureChannel: "", anchors: [])
        #expect(empty.anchorVectorData.isEmpty && empty.anchorDimension == 0 && empty.anchors.isEmpty)
    }

    // MARK: Manifest read with the current types

    /// The same rows `V3FixtureWriter.readManifest` reads with the V3 types, read through the current aliases.
    static func manifest(_ context: ModelContext) throws -> Manifest {
        let recordings = try context.fetch(FetchDescriptor<Recording>()).sorted { $0.id.uuidString < $1.id.uuidString }
        let speakers = try context.fetch(FetchDescriptor<RecordingSpeaker>()).sorted { $0.id.uuidString < $1.id.uuidString }
        let profiles = try context.fetch(FetchDescriptor<VoiceProfile>()).sorted { $0.id.uuidString < $1.id.uuidString }
        let samples = try context.fetch(FetchDescriptor<VoiceSample>()).sorted { $0.id.uuidString < $1.id.uuidString }
        let negatives = try context.fetch(FetchDescriptor<VoiceNegative>()).sorted { $0.id.uuidString < $1.id.uuidString }
        let folders = try context.fetch(FetchDescriptor<Folder>()).sorted { $0.id.uuidString < $1.id.uuidString }
        let states = try context.fetch(FetchDescriptor<SyncRecordState>()).sorted { $0.recordName < $1.recordName }
        let accounts = try context.fetch(FetchDescriptor<SyncAccountState>()).sorted { $0.key < $1.key }
        var stages: [String: Int] = [:]
        for r in recordings { stages[RecordingStage(rawValue: r.stageRaw).map { "\($0)" } ?? "\(r.stageRaw)", default: 0] += 1 }
        return Manifest(
            schemaVersion: "\(TranscribeSchemaV3.versionIdentifier)",
            modelKey: EmbeddingModelID.fake.key,
            counts: .init(recordings: recordings.count, speakers: speakers.count, profiles: profiles.count, samples: samples.count,
                          folders: folders.count, negatives: negatives.count, syncRecords: states.count, syncAccounts: accounts.count),
            stages: stages,
            profiles: profiles.map {
                .init(id: $0.id, name: $0.name, isMe: $0.isMe, colourSlot: $0.colourSlot, createdAt: $0.createdAt, namedAt: $0.namedAt,
                      autoLabel: $0.autoLabel, embeddingModelKey: $0.embeddingModelKey, needsResample: $0.needsResample,
                      sampleCount: $0.samples.count, negativeCount: $0.negatives.count)
            },
            samples: samples.map {
                .init(id: $0.id, profileID: $0.profile?.id, origin: $0.originRaw, speechSeconds: $0.speechSeconds,
                      embeddingModelKey: $0.embeddingModelKey, packed: $0.vectorData.base64EncodedString(), addedAt: $0.addedAt,
                      sourceRecordingID: $0.sourceRecordingID, sourceSpeakerID: $0.sourceSpeakerID, clipStart: $0.clipStart,
                      clipEnd: $0.clipEnd, quote: $0.quote, captureChannel: $0.captureChannel, captureInput: $0.captureInput)
            },
            negatives: negatives.map {
                .init(id: $0.id, profileID: $0.profile?.id, speechSeconds: $0.speechSeconds, embeddingModelKey: $0.embeddingModelKey,
                      packed: $0.vectorData.base64EncodedString(), addedAt: $0.addedAt, sourceRecordingID: $0.sourceRecordingID,
                      sourceSpeakerID: $0.sourceSpeakerID, captureChannel: $0.captureChannel, captureInput: $0.captureInput)
            },
            speakers: speakers.map {
                .init(id: $0.id, recordingID: $0.recording?.id, key: $0.key, ordinal: $0.ordinal, colourSlot: $0.colourSlot,
                      label: $0.labelRaw, profileID: $0.profile?.id, suggestedProfileID: $0.suggestedProfileID,
                      rejectedProfileIDs: $0.rejectedProfileIDs, nameSnapshot: $0.nameSnapshot, cleanSeconds: $0.cleanSeconds,
                      totalSeconds: $0.totalSeconds, turnCount: $0.turnCount, matchScore: $0.matchScore, matchMargin: $0.matchMargin,
                      vector: $0.vectorData?.base64EncodedString(), embeddingModelKey: $0.embeddingModelKey,
                      vectorCoherence: $0.vectorCoherence, matchTrace: $0.matchTraceData?.base64EncodedString())
            },
            recordings: recordings.map {
                .init(id: $0.id, createdAt: $0.createdAt, title: $0.title, duration: $0.duration, audioFileName: $0.audioFileName,
                      source: $0.sourceRaw, stage: $0.stageRaw, queueReason: $0.queueReasonRaw, failureMessage: $0.failureMessage,
                      attemptCount: $0.attemptCount, isFavourite: $0.isFavourite, hasUnseenResult: $0.hasUnseenResult,
                      noSpeech: $0.noSpeech, language: $0.languageRaw, marks: $0.marks, peakCount: $0.peaks.count,
                      previewText: $0.previewText, searchText: $0.searchText,
                      transcriptSHA256: $0.transcriptData.map(V2FixtureWriter.sha256Hex), asrModelID: $0.asrModelID,
                      embeddingModelKey: $0.embeddingModelKey, folderID: $0.folder?.id, folderName: $0.folder?.name,
                      speakerCount: $0.speakers.count, movedSpeakerTraces: $0.movedSpeakerTracesData?.base64EncodedString(),
                      captureChannel: $0.captureChannel, captureDetailJSON: $0.captureDetailJSON)
            },
            folders: folders.map { .init(id: $0.id, name: $0.name, createdAt: $0.createdAt, recordingCount: $0.recordings.count) },
            syncRecords: states.map {
                .init(recordName: $0.recordName, typeRaw: $0.typeRaw, entityID: $0.entityID,
                      systemFields: $0.systemFields?.base64EncodedString(), baseHashesJSON: String(decoding: $0.baseHashesJSON, as: UTF8.self),
                      pendingRaw: $0.pendingRaw, unresolvedLinksJSON: $0.unresolvedLinksJSON.map { String(decoding: $0, as: UTF8.self) },
                      updatedAt: $0.updatedAt)
            },
            syncAccounts: accounts.map {
                .init(key: $0.key, accountHash: $0.accountHash, engineState: $0.engineState?.base64EncodedString(),
                      zoneReady: $0.zoneReady, pausedReasonRaw: $0.pausedReasonRaw, lastFetchAt: $0.lastFetchAt,
                      lastSendAt: $0.lastSendAt)
            }
        )
    }
}
