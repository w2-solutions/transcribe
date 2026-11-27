import CloudKit
import CryptoKit
import Foundation
import TranscribeKit

/// Converts between the sync core's `SyncRecord` and `CKRecord` (§8.2, "CloudKit codec").
///
/// - Every field goes in `record.encryptedValues`, except `sv` (a plain value, so a newer schema is visible without
///   decrypting) and the transcript asset. CloudKit cannot hold a `CKAsset` in `encryptedValues`; asset files are
///   always encrypted at rest by CloudKit, so the asset field is a plain `CKAsset` holding LZFSE-compressed bytes.
/// - CloudKit has one number type on the wire and no element type for an empty list, so decoding needs each field's
///   kind. `kinds` lists every field the projector writes (`RecordProjector.fields`); `CKRecordCodecTests` checks the
///   two agree on a real library. A field this build does not know (a newer build's optional field) is decoded by
///   its CloudKit type.
/// - Dates travel as their canonical Int64 milliseconds, so they round-trip exactly. Empty lists are stored as
///   absent and read back as empty: the projector never writes a list as `.null`.
/// - `systemFields` is `CKRecord.encodeSystemFields` (secure keyed archive). A save with no system fields goes out as a
///   new record, so a record already on the server fails with `serverRecordChanged` and the coordinator merges.
public struct CKRecordCodec: Sendable {
    public static let zoneName = "Library"
    public static let zoneID = CKRecordZone.ID(zoneName: zoneName, ownerName: CKCurrentUserDefaultName)

    /// Kinds of field value, the `SyncValue` cases.
    public enum Kind: Sendable, Equatable {
        case string, int, double, dateMillis, bytes, strings, doubles, asset
    }

    public enum CodecError: Error, Equatable {
        case badRecordName(String)
        case assetUnreadable(String)
    }

    public let zoneID: CKRecordZone.ID
    /// Where outgoing asset files are written (`Caches/SyncOutgoing`). Deleted after their send result arrives.
    public let outgoingDirectory: URL

    public init(zoneID: CKRecordZone.ID = CKRecordCodec.zoneID, outgoingDirectory: URL = CKRecordCodec.defaultOutgoingDirectory) {
        self.zoneID = zoneID
        self.outgoingDirectory = outgoingDirectory
    }

    public static var defaultOutgoingDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("SyncOutgoing", isDirectory: true)
    }

    // MARK: Field kinds

    /// Every synced field's kind, per record type (the projector's output, §8.2). `sv` is an int on every type.
    public static func kinds(_ type: SyncRecordType) -> [String: Kind] {
        var k: [String: Kind]
        switch type {
        case .recording:
            k = ["createdAt": .dateMillis, "source": .string, "captureChannel": .string, "captureDetail": .string,
                 "language": .string, "title": .string, "isFavourite": .int, "folderID": .string, "duration": .double,
                 "noSpeech": .int, "marks": .doubles, "peaks": .bytes, "asrModelID": .string,
                 "embeddingModelKey": .string, "transcript": .asset]
        case .speaker:
            k = ["recordingID": .string, "key": .string, "ordinal": .int, "colourSlot": .int, "cleanSeconds": .double,
                 "vector": .bytes, "embeddingModelKey": .string, "vectorCoherence": .double, "turnCount": .int,
                 "totalSeconds": .double, "label": .string, "profileID": .string, "suggestedProfileID": .string,
                 "nameSnapshot": .string, "matchScore": .double, "matchMargin": .double, "rejectedProfileIDs": .strings,
                 "captureSource": .string]
        case .profile:
            k = ["name": .string, "namedAt": .dateMillis, "isMe": .int, "autoLabel": .int, "colourSlot": .int,
                 "createdAt": .dateMillis, "embeddingModelKey": .string]
        case .sample:
            k = ["profileID": .string, "vector": .bytes, "embeddingModelKey": .string, "origin": .string,
                 "addedAt": .dateMillis, "speechSeconds": .double, "sourceRecordingID": .string,
                 "sourceSpeakerID": .string, "clipStart": .double, "clipEnd": .double, "quote": .string,
                 "captureChannel": .string, "captureInput": .string]
        case .negative:
            k = ["profileID": .string, "vector": .bytes, "embeddingModelKey": .string, "addedAt": .dateMillis,
                 "speechSeconds": .double, "sourceRecordingID": .string, "sourceSpeakerID": .string,
                 "captureChannel": .string, "captureInput": .string]
        case .folder:
            k = ["name": .string, "createdAt": .dateMillis]
        case .groupLabel:
            k = ["profileID": .string, "text": .string, "createdAt": .dateMillis, "editedAt": .dateMillis,
                 "embeddingModelKey": .string, "captureChannel": .string, "anchor": .bytes, "anchorDimension": .int]
        case .audio:
            k = ["bytes": .int, "sha256": .string, "format": .string, "duration": .double]
        }
        k[SyncSchema.versionField] = .int
        return k
    }

    // MARK: Record ids

    public func recordID(_ id: SyncRecordID) -> CKRecord.ID {
        CKRecord.ID(recordName: id.recordName, zoneID: zoneID)
    }

    public func syncID(_ id: CKRecord.ID) -> SyncRecordID? {
        guard id.zoneID == zoneID else { return nil }
        return SyncRecordID(recordName: id.recordName)
    }

    // MARK: Encode

    /// The `CKRecord` to save: rebuilt from the system fields when there are any (an update), otherwise new (a create).
    /// Asset values are written to `outgoingDirectory`.
    public func encode(_ record: SyncRecord) throws -> CKRecord {
        let ckID = recordID(record.id)
        let ck = record.systemFields.flatMap { Self.record(systemFields: $0, expecting: ckID) }
            ?? CKRecord(recordType: record.id.type.rawValue, recordID: ckID)
        let kinds = Self.kinds(record.id.type)
        let added = SyncSchema.addedFields(record.id.type)
        for (name, value) in record.fields.sorted(by: { $0.key < $1.key }) {
            if name == SyncSchema.versionField {
                ck[name] = Self.plainObject(value)
                continue
            }
            switch value {
            case .asset(let data):
                ck[name] = try writeAsset(data, recordName: record.id.recordName)
            case .null where added.contains(name):
                // A field added after its group was first agreed (V5 `captureSource`) is never sent as a clear:
                // setting nil puts the key in `changedKeys()` and the save would delete the server's value. A device
                // upgraded from a build without the field holds nil for records it fetched back then, so sending
                // nil would wipe the source another device recorded. Nothing legitimately clears such a field.
                continue
            case .null where kinds[name] == .asset:
                ck[name] = nil
            default:
                ck.encryptedValues.setObject(Self.object(value), forKey: name)
            }
        }
        return ck
    }

    /// Asset bytes compressed with LZFSE into `<outgoing>/<recordName>-<hash8>.lzfse`.
    func writeAsset(_ data: Data, recordName: String) throws -> CKAsset {
        try FileManager.default.createDirectory(at: outgoingDirectory, withIntermediateDirectories: true)
        let hash8 = SHA256.hash(data: data).prefix(4).map { String(format: "%02x", $0) }.joined()
        let url = outgoingDirectory.appendingPathComponent("\(recordName)-\(hash8).lzfse")
        let compressed = try (data as NSData).compressed(using: .lzfse) as Data
        try compressed.write(to: url, options: .atomic)
        return CKAsset(fileURL: url)
    }

    /// Removes the outgoing asset files of these records (after their send result, saved or failed).
    public func removeOutgoingAssets(recordNames: some Sequence<String>) {
        let names = Set(recordNames)
        guard !names.isEmpty,
              let files = try? FileManager.default.contentsOfDirectory(at: outgoingDirectory, includingPropertiesForKeys: nil)
        else { return }
        for file in files {
            let base = file.deletingPathExtension().lastPathComponent
            guard let dash = base.lastIndex(of: "-"), names.contains(String(base[..<dash])) else { continue }
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// Removes every outgoing asset file (when the transport starts, no send is in flight).
    public func removeAllOutgoingAssets() {
        try? FileManager.default.removeItem(at: outgoingDirectory)
    }

    /// The object stored for a value: nil for `.null` and for an empty list (decoded back as empty).
    static func object(_ value: SyncValue) -> (any __CKRecordObjCValue)? {
        switch value {
        case .null: nil
        case .string(let s): s as NSString
        case .int(let i): NSNumber(value: i)
        case .double(let d): NSNumber(value: d)
        case .dateMillis(let ms): NSNumber(value: ms)
        case .bytes(let d): d as NSData
        case .strings(let a): a.isEmpty ? nil : a as NSArray
        case .doubles(let a): a.isEmpty ? nil : a.map { NSNumber(value: $0) } as NSArray
        case .asset: nil   // never stored as a value (see encode)
        }
    }

    static func plainObject(_ value: SyncValue) -> (any __CKRecordObjCValue)? { object(value) }

    // MARK: Decode

    /// The sync record for a fetched or saved `CKRecord`: every known field (absent reads as `.null`, or empty for a
    /// list), any unknown field by its CloudKit type, `sv`, and the record's system fields. Nil for a record that is not
    /// one of ours (another zone or an unknown record name).
    public func decode(_ ck: CKRecord) throws -> SyncRecord? {
        guard let id = syncID(ck.recordID), ck.recordType == id.type.rawValue else { return nil }
        let kinds = Self.kinds(id.type)
        var fields: [String: SyncValue] = [:]
        for (name, kind) in kinds {
            if name == SyncSchema.versionField {
                fields[name] = Self.value(ck[name], kind: kind) ?? .int(1)
            } else if kind == .asset {
                fields[name] = try Self.assetValue(ck[name] as? CKAsset)
            } else {
                fields[name] = Self.value(ck.encryptedValues.object(forKey: name), kind: kind) ?? Self.absent(kind)
            }
        }
        // Fields from a newer build of the same record schema, decoded by type.
        let encrypted = Set(ck.encryptedValues.allKeys())
        for name in encrypted where kinds[name] == nil {
            if let v = Self.inferred(ck.encryptedValues.object(forKey: name)) { fields[name] = v }
        }
        for name in ck.allKeys() where kinds[name] == nil && !encrypted.contains(name) {
            if let asset = ck[name] as? CKAsset {
                fields[name] = try Self.assetValue(asset)
            } else if let v = Self.inferred(ck[name]) {
                fields[name] = v
            }
        }
        return SyncRecord(id: id, fields: fields, systemFields: Self.systemFields(ck))
    }

    static func absent(_ kind: Kind) -> SyncValue {
        switch kind {
        case .strings: .strings([])
        case .doubles: .doubles([])
        default: .null
        }
    }

    static func value(_ object: (any __CKRecordObjCValue)?, kind: Kind) -> SyncValue? {
        guard let object else { return nil }
        switch kind {
        case .string: return (object as? String).map(SyncValue.string)
        case .int: return (object as? NSNumber).map { .int($0.int64Value) }
        case .double: return (object as? NSNumber).map { .double($0.doubleValue) }
        case .dateMillis:
            if let n = object as? NSNumber { return .dateMillis(n.int64Value) }
            if let d = object as? Date { return .dateMillis(Int64((d.timeIntervalSince1970 * 1000).rounded())) }
            return nil
        case .bytes: return (object as? Data).map(SyncValue.bytes)
        case .strings: return (object as? [String]).map(SyncValue.strings)
        case .doubles: return (object as? [NSNumber]).map { .doubles($0.map(\.doubleValue)) }
        case .asset: return nil
        }
    }

    static func inferred(_ object: (any __CKRecordObjCValue)?) -> SyncValue? {
        switch object {
        case let s as String: return .string(s)
        case let n as NSNumber: return CFNumberIsFloatType(n) ? .double(n.doubleValue) : .int(n.int64Value)
        case let d as Data: return .bytes(d)
        case let d as Date: return .dateMillis(Int64((d.timeIntervalSince1970 * 1000).rounded()))
        case let a as [String]: return .strings(a)
        case let a as [NSNumber]: return .doubles(a.map(\.doubleValue))
        default: return nil
        }
    }

    /// The decompressed bytes of an asset, read inside the fetch callback while CloudKit's file still exists.
    static func assetValue(_ asset: CKAsset?) throws -> SyncValue {
        guard let asset else { return .null }
        guard let url = asset.fileURL, let compressed = try? Data(contentsOf: url) else {
            throw CodecError.assetUnreadable(asset.fileURL?.lastPathComponent ?? "no file")
        }
        do {
            return .asset(try (compressed as NSData).decompressed(using: .lzfse) as Data)
        } catch {
            throw CodecError.assetUnreadable(url.lastPathComponent)
        }
    }

    // MARK: System fields

    public static func systemFields(_ record: CKRecord) -> Data {
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: archiver)
        archiver.finishEncoding()
        return archiver.encodedData
    }

    /// The record rebuilt from archived system fields; nil when they do not decode or name another record (they then
    /// say nothing about this record on the server, so it goes out as new).
    static func record(systemFields: Data, expecting id: CKRecord.ID) -> CKRecord? {
        guard let coder = try? NSKeyedUnarchiver(forReadingFrom: systemFields) else { return nil }
        coder.requiresSecureCoding = true
        defer { coder.finishDecoding() }
        guard let record = CKRecord(coder: coder), record.recordID == id else { return nil }
        return record
    }
}
