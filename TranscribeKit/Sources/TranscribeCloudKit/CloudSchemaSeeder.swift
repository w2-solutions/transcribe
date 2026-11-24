import CloudKit
import Foundation
import os
import TranscribeKit

/// Makes the Development iCloud schema complete before it is deployed to Production.
///
/// Development creates a record type or field the first time a record with it is saved; Production never does, and a
/// save with an unknown type or field fails there. A field that has only ever been empty on the developer's devices
/// (a title, bookmarks, a rejected name, a negative) is therefore missing from the schema. This saves one record of
/// every type with every field filled, in a zone of its own, then deletes that zone. Run it from a Debug build with
/// the launch argument `-seedCloudSchema`, then deploy the schema in the CloudKit Console.
public enum CloudSchemaSeeder {
    private static let log = Logger(subsystem: "ai.w2solutions.transcribe", category: "cloudkit")

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
            log.notice("Schema seed finished: \(records.count, privacy: .public) record types, seed zone deleted")
        } catch {
            log.error("Schema seed failed: \(CloudKitTransport.describe(error), privacy: .public)")
            _ = try? await database.deleteRecordZone(withID: zoneID)
        }
    }
}
