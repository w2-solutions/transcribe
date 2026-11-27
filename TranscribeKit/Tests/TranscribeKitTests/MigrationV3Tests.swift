import CoreData
import Foundation
import SwiftData
import Testing
import TranscribeCore
@testable import TranscribeFakes
@testable import TranscribeKit

/// Opens the committed V2 library (`Fixtures/V2Library`, written by `V2FixtureWriter`; the owner's phone ran V2)
/// and the V1 library under the current schema, through V3. Nothing may be lost, the V3 channel fields start empty,
/// and the one-time backup is taken exactly once. The current version's own checks (the marker, a
/// fresh install) are in `MigrationV5Tests`.
@Suite("Store migration through V3")
@MainActor
struct MigrationV3Tests {
    typealias Manifest = V2FixtureWriter.Manifest

    static var v2FixtureDirectory: URL {
        get throws { try #require(Bundle.module.url(forResource: "V2Library", withExtension: nil, subdirectory: "Fixtures")) }
    }

    static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    /// A temp folder holding a copy of the V2 fixture's store files, and its manifest.
    func copyV2Fixture() throws -> (root: URL, storeURL: URL, manifest: Manifest) {
        let fm = FileManager.default
        let source = try Self.v2FixtureDirectory
        let root = fm.temporaryDirectory.appendingPathComponent("v3-migration-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        for name in try fm.contentsOfDirectory(atPath: source.path) where name.hasPrefix("Library.store") {
            try fm.copyItem(at: source.appendingPathComponent(name), to: root.appendingPathComponent(name))
        }
        let manifest = try Self.decoder.decode(Manifest.self, from: Data(contentsOf: source.appendingPathComponent("manifest.json")))
        return (root, root.appendingPathComponent("Library.store"), manifest)
    }

    // MARK: V2 → V3 → current

    @Test func v2FixtureOpensWithEmptyV3Fields() throws {
        let (root, storeURL, expected) = try copyV2Fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        // The copy really is a V2 store (not one a later schema already touched).
        #expect(try MigrationTests.versionHashes(at: storeURL) == (try V2FixtureWriter.v2VersionHashes()))

        do {
            let container = try ModelContainerFactory.make(inMemory: false, url: storeURL)
            let context = container.mainContext

            // Every manifest row round-trips through the current types.
            let readBack = try Self.manifest(context)
            #expect(readBack.counts == expected.counts)
            #expect(readBack.stages == expected.stages)
            #expect(readBack.profiles == expected.profiles)
            #expect(readBack.samples == expected.samples)
            #expect(readBack.negatives == expected.negatives)
            #expect(readBack.speakers == expected.speakers)
            #expect(readBack.recordings == expected.recordings)
            #expect(readBack.folders == expected.folders)
            #expect(expected.counts.negatives == 2 && expected.counts.recordings == 6)

            // The V3 additions start empty: no channel until stamping, no sync state.
            #expect(try context.fetch(FetchDescriptor<Recording>()).allSatisfy { $0.captureChannel == nil && $0.captureDetailJSON == nil })
            #expect(try context.fetch(FetchDescriptor<VoiceSample>()).allSatisfy { $0.captureChannel == nil && $0.captureInput == nil })
            #expect(try context.fetch(FetchDescriptor<VoiceNegative>()).allSatisfy { $0.captureChannel == nil && $0.captureInput == nil })
            #expect(try context.fetchCount(FetchDescriptor<SyncRecordState>()) == 0)
            #expect(try context.fetchCount(FetchDescriptor<SyncAccountState>()) == 0)

            // The first V3 launch on the phone stamps every voice row "iphone" and loses nothing.
            let store = LibraryStore(context: context, paths: AppPaths(root: root), deviceIdentity: FixedDeviceIdentity("phone"),
                                     clock: .frozen(Seeds.Dates.d), localChannel: CaptureChannel.iphone)
            let stamped = try store.stampCaptureChannels()
            #expect(stamped == expected.counts.recordings + expected.counts.samples + expected.counts.negatives)
            #expect(try context.fetch(FetchDescriptor<Recording>()).allSatisfy { $0.captureChannel == CaptureChannel.iphone })
            #expect(try context.fetch(FetchDescriptor<VoiceSample>()).allSatisfy { $0.captureChannel == CaptureChannel.iphone })
            #expect(try context.fetch(FetchDescriptor<VoiceNegative>()).allSatisfy { $0.captureChannel == CaptureChannel.iphone })
            #expect(try Self.manifest(context).samples == expected.samples)

            let candidates = try store.matchCandidates(modelKey: expected.modelKey)
            #expect(candidates.count == expected.counts.profiles)
            for c in candidates {
                let p = try #require(expected.profiles.first { $0.id == c.id })
                #expect(c.samples.count == p.sampleCount && c.negatives.count == p.negativeCount)
            }
        }

        // The store on disk is now a store of the current schema.
        #expect(try MigrationTests.versionHashes(at: storeURL) == (try MigrationV5Tests.v5VersionHashes()))
        let reopened = try ModelContainerFactory.make(inMemory: false, url: storeURL)
        let again = try Self.manifest(reopened.mainContext)
        #expect(again.recordings == expected.recordings && again.speakers == expected.speakers)
        #expect(try reopened.mainContext.fetch(FetchDescriptor<VoiceSample>()).allSatisfy { $0.captureChannel == CaptureChannel.iphone })
    }

    // MARK: V1 → V3 → current

    @Test func v1FixtureOpensWithEmptyV3Fields() throws {
        let (root, storeURL, m) = try MigrationTests().copyFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            let container = try ModelContainerFactory.make(inMemory: false, url: storeURL)
            let context = container.mainContext
            #expect(try context.fetchCount(FetchDescriptor<Recording>()) == m.counts.recordings)
            #expect(try context.fetchCount(FetchDescriptor<RecordingSpeaker>()) == m.counts.speakers)
            #expect(try context.fetchCount(FetchDescriptor<VoiceProfile>()) == m.counts.profiles)
            #expect(try context.fetchCount(FetchDescriptor<VoiceSample>()) == m.counts.samples)
            #expect(try context.fetchCount(FetchDescriptor<Folder>()) == m.counts.folders)
            #expect(try context.fetchCount(FetchDescriptor<VoiceNegative>()) == 0)
            #expect(try context.fetchCount(FetchDescriptor<SyncRecordState>()) == 0)
            #expect(try context.fetch(FetchDescriptor<Recording>()).allSatisfy { $0.captureChannel == nil })
            let samples = Dictionary(uniqueKeysWithValues: try context.fetch(FetchDescriptor<VoiceSample>()).map { ($0.id, $0) })
            for expected in m.samples {
                let s = try #require(samples[expected.id])
                #expect(s.vectorData == Data(base64Encoded: expected.packed) && s.profile?.id == expected.profileID)
                #expect(s.captureChannel == nil)
            }

            let store = LibraryStore(context: context, paths: AppPaths(root: root), deviceIdentity: FixedDeviceIdentity("phone"),
                                     clock: .frozen(Seeds.Dates.d), localChannel: CaptureChannel.iphone)
            #expect(try store.stampCaptureChannels() == m.counts.recordings + m.counts.samples)
            #expect(try context.fetchCount(FetchDescriptor<VoiceSample>()) == m.counts.samples)
        }
        #expect(try MigrationTests.versionHashes(at: storeURL) == (try MigrationV5Tests.v5VersionHashes()))
    }

    // MARK: Backup and marker

    /// A phone that still runs V2 upgrades straight to the current schema: one backup, of the V2 store as it was.
    @Test func v2StoreIsBackedUpOnceBeforeTheUpgrade() throws {
        let (root, storeURL, _) = try copyV2Fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        let fixtureBytes = try Data(contentsOf: try Self.v2FixtureDirectory.appendingPathComponent("Library.store"))
        // A phone that ran V2 has the V2 marker and the pre-V2 backup next to the store: both must stay untouched.
        let v2Marker = root.appendingPathComponent("Library.schema-v2")
        let v2Backup = root.appendingPathComponent("Library.pre-v2-backup.store")
        try Data("2.0.0\n".utf8).write(to: v2Marker)
        try Data("old v1 backup".utf8).write(to: v2Backup)

        let backup = ModelContainerFactory.backupURL(storeURL: storeURL)
        let marker = ModelContainerFactory.markerURL(storeURL: storeURL)
        let current = ModelContainerFactory.currentVersion
        #expect(backup.lastPathComponent == "Library.pre-v\(current)-backup.store" && marker.lastPathComponent == "Library.schema-v\(current)")
        #expect(!fm.fileExists(atPath: root.appendingPathComponent("Library.schema-v3").path))
        #expect(!fm.fileExists(atPath: backup.path) && !fm.fileExists(atPath: marker.path))

        do {
            let container = try ModelContainerFactory.make(inMemory: false, url: storeURL)
            #expect(try container.mainContext.fetchCount(FetchDescriptor<Recording>()) == 6)
        }
        #expect(try Data(contentsOf: backup) == fixtureBytes)
        #expect(fm.fileExists(atPath: ModelContainerFactory.backupURL(storeURL: storeURL, suffix: "-wal").path))
        #expect(fm.fileExists(atPath: ModelContainerFactory.backupURL(storeURL: storeURL, suffix: "-shm").path))
        // The backup is the V2 store as it was, still openable by a V2 build.
        #expect(try MigrationTests.versionHashes(at: backup) == (try V2FixtureWriter.v2VersionHashes()))
        #expect(try String(contentsOf: marker, encoding: .utf8) == "\(current).0.0\n")
        let backupAfterFirst = try Data(contentsOf: backup)

        // Opening again (now a store of the current schema) takes no new backup.
        do {
            let container = try ModelContainerFactory.make(inMemory: false, url: storeURL)
            #expect(try container.mainContext.fetchCount(FetchDescriptor<Recording>()) == 6)
        }
        #expect(try Data(contentsOf: backup) == backupAfterFirst)
        #expect(fm.fileExists(atPath: marker.path))
        #expect(try Data(contentsOf: v2Marker) == Data("2.0.0\n".utf8))
        #expect(try Data(contentsOf: v2Backup) == Data("old v1 backup".utf8))
    }

    // MARK: Manifest read with the current types

    /// The same rows `V2FixtureWriter.readManifest` reads with the V2 types, read through the current aliases.
    static func manifest(_ context: ModelContext) throws -> Manifest {
        let recordings = try context.fetch(FetchDescriptor<Recording>()).sorted { $0.id.uuidString < $1.id.uuidString }
        let speakers = try context.fetch(FetchDescriptor<RecordingSpeaker>()).sorted { $0.id.uuidString < $1.id.uuidString }
        let profiles = try context.fetch(FetchDescriptor<VoiceProfile>()).sorted { $0.id.uuidString < $1.id.uuidString }
        let samples = try context.fetch(FetchDescriptor<VoiceSample>()).sorted { $0.id.uuidString < $1.id.uuidString }
        let negatives = try context.fetch(FetchDescriptor<VoiceNegative>()).sorted { $0.id.uuidString < $1.id.uuidString }
        let folders = try context.fetch(FetchDescriptor<Folder>()).sorted { $0.id.uuidString < $1.id.uuidString }
        var stages: [String: Int] = [:]
        for r in recordings { stages[RecordingStage(rawValue: r.stageRaw).map { "\($0)" } ?? "\(r.stageRaw)", default: 0] += 1 }
        return Manifest(
            schemaVersion: "\(TranscribeSchemaV3.versionIdentifier)",
            modelKey: EmbeddingModelID.fake.key,
            counts: .init(recordings: recordings.count, speakers: speakers.count, profiles: profiles.count, samples: samples.count,
                          folders: folders.count, negatives: negatives.count),
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
                      clipEnd: $0.clipEnd, quote: $0.quote)
            },
            negatives: negatives.map {
                .init(id: $0.id, profileID: $0.profile?.id, speechSeconds: $0.speechSeconds, embeddingModelKey: $0.embeddingModelKey,
                      packed: $0.vectorData.base64EncodedString(), addedAt: $0.addedAt, sourceRecordingID: $0.sourceRecordingID,
                      sourceSpeakerID: $0.sourceSpeakerID)
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
                      speakerCount: $0.speakers.count, movedSpeakerTraces: $0.movedSpeakerTracesData?.base64EncodedString())
            },
            folders: folders.map { .init(id: $0.id, name: $0.name, createdAt: $0.createdAt, recordingCount: $0.recordings.count) }
        )
    }
}
