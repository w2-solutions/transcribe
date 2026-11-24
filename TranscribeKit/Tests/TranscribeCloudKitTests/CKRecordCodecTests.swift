import CloudKit
import Foundation
import SwiftData
import Testing
import TranscribeCore
@testable import TranscribeCloudKit
@testable import TranscribeFakes
@testable import TranscribeKit

/// The CloudKit codec (stage 8a): `SyncRecord` → `CKRecord` (encrypted values, a compressed asset) → archived as if
/// it had crossed the network → `SyncRecord` gives identical fields, for every record type of a real library.
@Suite("CloudKit: record codec")
@MainActor
struct CKRecordCodecTests {
    let outgoing = FileManager.default.temporaryDirectory.appendingPathComponent("ckcodec-\(UUID().uuidString)", isDirectory: true)
    var codec: CKRecordCodec { CKRecordCodec(outgoingDirectory: outgoing) }

    /// The seeded library plus a folder, a negative, odd floats and empty lists: every record type and field kind.
    func library() throws -> (ModelContainer, [SyncRecord]) {
        let container = try ModelContainerFactory.make(inMemory: true, url: nil)
        let context = container.mainContext
        let paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent("ckcodec-lib-\(UUID().uuidString)"))
        try paths.prepare()
        try Seeds.apply(.library, context: context, paths: paths, clock: .frozen(Seeds.Dates.d))
        let profile = try #require(try context.fetch(FetchDescriptor<VoiceProfile>()).first)
        let recording = try #require(try context.fetch(FetchDescriptor<Recording>()).first)
        let folder = Folder(name: "Work ✓", createdAt: Date(timeIntervalSince1970: 1_763_500_000.123_4))
        context.insert(folder)
        recording.folder = folder
        recording.marks = []                                   // an empty list of doubles
        recording.peaks = [0, 0.333_333_34, 1, -0.0]
        let negative = VoiceNegative(vector: try #require(VoiceVector(raw: [0.1, -0.2, 0.3])), embeddingModelKey: "k",
                                     addedAt: Date(timeIntervalSince1970: 1_763_500_001.000_9), speechSeconds: 6.5)
        negative.profile = profile
        negative.captureChannel = CaptureChannel.mac
        context.insert(negative)
        let speakers = try context.fetch(FetchDescriptor<RecordingSpeaker>())
        speakers.first?.rejectedProfileIDs = [UUID(), UUID()]
        speakers.last?.rejectedProfileIDs = []                 // an empty list of strings
        speakers.first?.matchScore = 0.123_456_789
        try context.save()

        let projector = RecordProjector(context: context)
        var records: [SyncRecord] = []
        for type in SyncRecordType.allCases {
            for e in try projector.all(type) { records.append(RecordProjector.record(e)) }
        }
        return (container, records)
    }

    /// What arrives from the server: the whole record archived and decoded again (values, encrypted values, assets).
    func overTheWire(_ record: CKRecord) throws -> CKRecord {
        let data = try NSKeyedArchiver.archivedData(withRootObject: record, requiringSecureCoding: true)
        return try #require(try NSKeyedUnarchiver.unarchivedObject(ofClass: CKRecord.self, from: data))
    }

    @Test func everyProjectedFieldHasAKind() throws {
        let (_, records) = try library()
        #expect(Set(records.map(\.id.type)) == Set(SyncRecordType.allCases))
        for record in records {
            #expect(Set(record.fields.keys) == Set(CKRecordCodec.kinds(record.id.type).keys), "\(record.id.type)")
            for (name, value) in record.fields where value != .null {
                let kind = try #require(CKRecordCodec.kinds(record.id.type)[name])
                #expect(Self.kind(of: value) == kind, "\(record.id.type).\(name)")
            }
        }
    }

    @Test func roundTripsEveryTypeThroughEncryptedValuesAndAssets() throws {
        defer { try? FileManager.default.removeItem(at: outgoing) }
        let (_, records) = try library()
        var sawAsset = false
        for record in records {
            let ck = try codec.encode(record)
            #expect(ck.recordType == record.id.type.rawValue)
            #expect(ck.recordID.zoneID.zoneName == "Library")
            #expect(ck.recordID.recordName == record.id.recordName)
            // Only sv (and an asset) are plain values; every other field is encrypted.
            let encrypted = Set(ck.encryptedValues.allKeys())
            for key in Set(ck.allKeys()).subtracting(encrypted) {
                #expect(key == SyncSchema.versionField || ck[key] is CKAsset, "\(record.id.recordName).\(key) is not encrypted")
            }
            #expect(!encrypted.contains(SyncSchema.versionField))
            #expect(!encrypted.isEmpty)
            if case .asset? = record.fields["transcript"] {
                sawAsset = true
                let asset = try #require(ck["transcript"] as? CKAsset)
                #expect(asset.fileURL?.pathExtension == "lzfse")
            }
            let back = try #require(try codec.decode(try overTheWire(ck)))
            #expect(back.id == record.id)
            #expect(back.fields == record.fields, "\(record.id.recordName)")
            #expect(SyncSchema.hashes(back) == SyncSchema.hashes(record))
            #expect(back.systemFields != nil)
        }
        #expect(sawAsset, "the seeded library has a transcript")
    }

    @Test func assetsAreCompressedAndRemovedAfterSending() throws {
        defer { try? FileManager.default.removeItem(at: outgoing) }
        let id = SyncRecordID(type: .recording, entityID: UUID())
        let transcript = Data(String(repeating: "hello transcript ", count: 500).utf8)
        let ck = try codec.encode(SyncRecord(id: id, fields: ["transcript": .asset(transcript), "sv": .int(1)]))
        let url = try #require((ck["transcript"] as? CKAsset)?.fileURL)
        #expect(url.deletingLastPathComponent().standardizedFileURL == outgoing.standardizedFileURL)
        #expect(url.lastPathComponent.hasPrefix(id.recordName + "-"))
        #expect(try Data(contentsOf: url).count < transcript.count / 4)
        #expect(try codec.decode(ck)?.fields["transcript"] == .asset(transcript))
        codec.removeOutgoingAssets(recordNames: ["rec.someone-else"])
        #expect(FileManager.default.fileExists(atPath: url.path))
        codec.removeOutgoingAssets(recordNames: [id.recordName])
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func systemFieldsMakeAnUpdateAndNilMakesANewRecord() throws {
        defer { try? FileManager.default.removeItem(at: outgoing) }
        let id = SyncRecordID(type: .folder, entityID: UUID())
        let fields: [String: SyncValue] = ["name": .string("Work"), "createdAt": .dateMillis(1_763_500_000_123), "sv": .int(1)]
        let first = try codec.encode(SyncRecord(id: id, fields: fields))
        let system = CKRecordCodec.systemFields(first)
        // Rebuilt from system fields: same record, carrying the new values.
        let update = try codec.encode(SyncRecord(id: id, fields: fields.merging(["name": .string("Home")]) { $1 }, systemFields: system))
        #expect(update.recordID == first.recordID)
        #expect(update.encryptedValues.object(forKey: "name") as? String == "Home")
        #expect(CKRecordCodec.systemFields(update) == system)
        // System fields of another record, or garbage, say nothing about this one: it goes out as new.
        let other = try codec.encode(SyncRecord(id: SyncRecordID(type: .folder, entityID: UUID()), fields: fields))
        let wrong = try codec.encode(SyncRecord(id: id, fields: fields, systemFields: CKRecordCodec.systemFields(other)))
        #expect(wrong.recordID == first.recordID)
        let junk = try codec.encode(SyncRecord(id: id, fields: fields, systemFields: Data("x".utf8)))
        #expect(junk.recordID == first.recordID)
    }

    @Test func nullClearsAValueOnUpdateAndEmptyListsReadBackEmpty() throws {
        defer { try? FileManager.default.removeItem(at: outgoing) }
        let id = SyncRecordID(type: .speaker, entityID: UUID())
        let named = try codec.encode(SyncRecord(id: id, fields: ["nameSnapshot": .string("Karan"),
                                                                 "rejectedProfileIDs": .strings([UUID().uuidString])]))
        let cleared = try codec.encode(SyncRecord(id: id, fields: ["nameSnapshot": .null, "rejectedProfileIDs": .strings([])],
                                                  systemFields: CKRecordCodec.systemFields(named)))
        #expect(cleared.encryptedValues.object(forKey: "nameSnapshot") == nil)
        let back = try #require(try codec.decode(try overTheWire(cleared)))
        #expect(back.fields["nameSnapshot"] == .null)
        #expect(back.fields["rejectedProfileIDs"] == .strings([]))
        #expect(back.fields["marks"] == nil)                  // not a speaker field
        #expect(back.fields["sv"] == .int(1))                 // absent sv reads as 1
    }

    @Test func numbersKeepTheirKindAndUnknownFieldsAreKept() throws {
        let id = SyncRecordID(type: .speaker, entityID: UUID())
        let ck = CKRecord(recordType: "Speaker", recordID: codec.recordID(id))
        ck.encryptedValues.setObject(NSNumber(value: 3), forKey: "matchScore")      // a whole double sent as an int
        ck.encryptedValues.setObject(NSNumber(value: 2.0), forKey: "ordinal")       // and the reverse
        ck.encryptedValues.setObject("x" as NSString, forKey: "futureField")
        ck["sv"] = NSNumber(value: 2)
        let back = try #require(try codec.decode(ck))
        #expect(back.fields["matchScore"] == .double(3))
        #expect(back.fields["ordinal"] == .int(2))
        #expect(back.fields["futureField"] == .string("x"))
        #expect(SyncSchema.recordVersion(back) == 2)
    }

    @Test func recordsOutsideTheZoneOrWithForeignNamesAreIgnored() throws {
        let otherZone = CKRecordZone.ID(zoneName: "Other", ownerName: CKCurrentUserDefaultName)
        let id = SyncRecordID(type: .folder, entityID: UUID())
        #expect(try codec.decode(CKRecord(recordType: "Folder", recordID: CKRecord.ID(recordName: id.recordName, zoneID: otherZone))) == nil)
        #expect(try codec.decode(CKRecord(recordType: "Folder", recordID: CKRecord.ID(recordName: "nonsense", zoneID: codec.zoneID))) == nil)
        #expect(try codec.decode(CKRecord(recordType: "Recording", recordID: codec.recordID(id))) == nil)   // type mismatch
    }

    @Test func sendFailuresMapToTheCoordinatorsCases() {
        let id = SyncRecordID(type: .folder, entityID: UUID())
        #expect(CloudKitTransport.failure(id, CKError(.unknownItem)) == .unknownItem(id))
        #expect(CloudKitTransport.failure(id, CKError(.zoneNotFound)) == .zoneNotFound(id))
        #expect(CloudKitTransport.failure(id, CKError(.userDeletedZone)) == .zoneNotFound(id))
        #expect(CloudKitTransport.failure(id, CKError(.quotaExceeded)) == .quotaExceeded(id))
        for code in [CKError.Code.networkFailure, .networkUnavailable, .zoneBusy, .serviceUnavailable, .requestRateLimited] {
            #expect(CloudKitTransport.failure(id, CKError(code)) == .retryable(id))
        }
        if case .permanent(let failed, _) = CloudKitTransport.failure(id, CKError(.invalidArguments)) {
            #expect(failed == id)
        } else {
            Issue.record("invalidArguments should be permanent")
        }
    }

    static func kind(of value: SyncValue) -> CKRecordCodec.Kind? {
        switch value {
        case .null: nil
        case .string: .string
        case .int: .int
        case .double: .double
        case .dateMillis: .dateMillis
        case .bytes: .bytes
        case .strings: .strings
        case .doubles: .doubles
        case .asset: .asset
        }
    }
}

/// The app must launch and work with no iCloud: the test process has no container entitlement, which is how a Mac
/// build signed to run locally (or a device with no account) looks to the transport.
@Suite("CloudKit: transport without iCloud")
@MainActor
struct CloudKitTransportNoAccountTests {
    @Test func withoutAnEntitlementTheAccountReadsAsSignedOut() async throws {
        let transport = CloudKitTransport()
        #expect(await transport.accountHash() == nil)
        await transport.start(state: nil, provider: { _ in nil })
        await transport.ensureZone()
        await transport.enqueue(saves: [SyncRecordID(type: .folder, entityID: UUID())], deletes: [])
        await #expect(throws: SyncTransportError.noAccount) { try await transport.fetchChanges() }
        await #expect(throws: SyncTransportError.noAccount) { try await transport.sendChanges() }
        await #expect(throws: SyncTransportError.noAccount) { try await transport.deleteZone() }
        await transport.stop()
        await #expect(throws: SyncTransportError.notStarted) { try await transport.fetchChanges() }
    }

    @Test func turningSyncOnWithoutAnAccountPausesAndKeepsTheLibrary() async throws {
        let container = try ModelContainerFactory.make(inMemory: true, url: nil)
        let paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent("ck-noaccount-\(UUID().uuidString)"))
        defer { try? FileManager.default.removeItem(at: paths.root) }
        try paths.prepare()
        try Seeds.apply(.library, context: container.mainContext, paths: paths, clock: .frozen(Seeds.Dates.d))
        let store = LibraryStore(context: container.mainContext, paths: paths, deviceIdentity: FixedDeviceIdentity("t"),
                                 clock: .frozen(Seeds.Dates.d), localChannel: CaptureChannel.mac)
        let settings = AppSettings(defaults: try #require(UserDefaults(suiteName: "ck-noaccount-\(UUID().uuidString)")))
        let sync = SyncCoordinator(store: store, transport: CloudKitTransport(), settings: settings, clock: .frozen(Seeds.Dates.d))
        await sync.start()                       // off: nothing happens
        #expect(sync.status == .off)
        await sync.enable()
        #expect(sync.status == .paused(.noAccount))
        await sync.syncNow()                     // retrying stays paused, never crashes
        #expect(sync.status == .paused(.noAccount))
        try await sync.disable(removeCloudCopy: false)
        #expect(sync.status == .off)
        #expect(try container.mainContext.fetchCount(FetchDescriptor<Recording>()) == Seeds.expectedCounts(.library).recordings)
    }
}
