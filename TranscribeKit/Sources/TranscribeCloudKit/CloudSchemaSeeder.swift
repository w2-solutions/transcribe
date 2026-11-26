import CloudKit
import Foundation
import os
import TranscribeKit

/// Makes the Development iCloud schema complete before it is deployed to Production.
///
/// Development creates a record type or field the first time a record with it is saved; Production never does, and a
/// save with an unknown type or field fails there. A field that has only ever been empty on the developer's devices
/// (a title, bookmarks, a rejected name, a negative) is therefore missing from the schema. This saves one record of
/// every type with every field filled, in a zone of its own, then deletes that zone. Audio markers (`RecordingAudio`)
/// are one of those types. The audio blob type (`AudioFile`) lives in the default zone, so one blob with every key is
/// saved there and deleted by id. Run it from a Debug build with the launch argument `-seedCloudSchema`, then deploy
/// the schema in the CloudKit Console.
public enum CloudSchemaSeeder {
    private static let log = Logger(subsystem: "ai.w2solutions.transcribe", category: "cloudkit")

    /// The recording id of the seeded `AudioFile` (`af.00000000-0000-4000-8000-000000000000`), never a real one.
    static let audioSeedID = UUID(uuidString: "00000000-0000-4000-8000-000000000000")!

    /// A value of each kind that CloudKit stores as that kind (never empty: an empty list is sent as nothing).
    static func sample(_ kind: CKRecordCodec.Kind) -> SyncValue {
        switch kind {
        case .string: .string("seed")
        case .int: .int(1)
        case .double: .double(1.5)
        case .dateMillis: .dateMillis(1_700_000_000_000)
        case .bytes: .bytes(Data([1, 2, 3, 4]))
        case .strings: .strings(["seed"])
        case .doubles: .doubles([1.5])
        case .asset: .asset(Data("seed".utf8))
        }
    }

    /// One record per type with every field of `CKRecordCodec.kinds` set.
    static func records() -> [SyncRecord] {
        SyncRecordType.allCases.map { type in
            var fields = CKRecordCodec.kinds(type).mapValues(sample)
            fields[SyncSchema.versionField] = .int(1)
            return SyncRecord(id: SyncRecordID(type: type, entityID: UUID()), fields: fields)
        }
    }

    /// The seeded `AudioFile`: in the default zone, every scalar set, and `file` (4 bytes) as its asset.
    static func audioFileRecord(asset file: URL) -> CKRecord {
        CKAudioCodec().encode(AudioDescriptor(recordingID: audioSeedID, format: .aac16kMono, bytes: 4,
                                              sha256: String(repeating: "0", count: 64), duration: 1.5), file: file)
    }

    public static func seed(containerIdentifier: String = CloudKitTransport.containerIdentifier) async {
        let database = CKContainer(identifier: containerIdentifier).privateCloudDatabase
        let zoneID = CKRecordZone.ID(zoneName: "SchemaSeed", ownerName: CKCurrentUserDefaultName)
        let codec = CKRecordCodec(zoneID: zoneID)
        do {
            _ = try await database.save(CKRecordZone(zoneID: zoneID))
            let records = try records().map(codec.encode)
            let result = try await database.modifyRecords(saving: records, deleting: [], savePolicy: .allKeys, atomically: false)
            for (id, outcome) in result.saveResults {
                switch outcome {
                case .success: log.notice("Schema seed saved \(id.recordName, privacy: .public)")
                case .failure(let error):
                    log.error("Schema seed could not save \(id.recordName, privacy: .public): \(CloudKitTransport.describe(error), privacy: .public)")
                }
            }
            try await database.deleteRecordZone(withID: zoneID)
            guard await seedAudioFile(database) else { return }
            log.notice("Schema seed finished: \(records.count + 1, privacy: .public) record types, seed zone deleted")
        } catch {
            log.error("Schema seed failed: \(CloudKitTransport.describe(error), privacy: .public)")
            _ = try? await database.deleteRecordZone(withID: zoneID)
        }
    }

    /// Saves one `AudioFile` in the default zone with `.allKeys` (so a seed left by an earlier run is overwritten),
    /// then deletes it by id and removes the temporary file. False (logged as "Schema seed failed") when the save did not
    /// go through, so the log never says "finished" without it.
    private static func seedAudioFile(_ database: CKDatabase) async -> Bool {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("audio-seed-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appendingPathComponent("seed.m4a")
            try Data([1, 2, 3, 4]).write(to: file)
            let record = audioFileRecord(asset: file)
            let result = try await database.modifyRecords(saving: [record], deleting: [], savePolicy: .allKeys, atomically: false)
            if case .failure(let error)? = result.saveResults[record.recordID] {
                log.error("Schema seed failed: could not save \(record.recordID.recordName, privacy: .public): \(CloudKitTransport.describe(error), privacy: .public)")
                return false
            }
            log.notice("Schema seed saved \(record.recordID.recordName, privacy: .public)")
            let deleted = try await database.modifyRecords(saving: [], deleting: [record.recordID], atomically: false)
            if case .failure(let error)? = deleted.deleteResults[record.recordID] {
                log.error("Schema seed could not delete \(record.recordID.recordName, privacy: .public): \(CloudKitTransport.describe(error), privacy: .public)")
            }
            return true
        } catch {
            log.error("Schema seed failed (audio file): \(CloudKitTransport.describe(error), privacy: .public)")
            return false
        }
    }
}
