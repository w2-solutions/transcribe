import CloudKit
import Foundation
import TranscribeKit

/// Converts between an audio blob's `AudioDescriptor` and its `AudioFile` record (§3.1, decision 1).
///
/// - The record is `af.<recording UUID>` in the private database's **default zone**, which no `CKSyncEngine` and no
///   database subscription sees, so only `CloudKitAudioTransfer` ever moves it.
/// - `audio` is a plain `CKAsset` pointing at the caller's staged transfer file, as it is (never copied or
///   compressed: AAC does not compress). CloudKit cannot hold an asset in `encryptedValues`; it encrypts asset files
///   itself.
/// - `bytes`, `sha256`, `format` and `duration` go in `encryptedValues`; `sv` is plain (1), as on every record type.
/// - A record whose four scalars do not all read is `.unreadable` (after an encrypted-data reset, say); a newer `sv`
///   still decodes, because the blob's bytes and description do not depend on it.
public struct CKAudioCodec: Sendable {
    public static let recordType = "AudioFile"
    public static let prefix = "af"

    public enum Key {
        public static let audio = "audio", bytes = "bytes", sha256 = "sha256", format = "format",
                          duration = "duration", schema = "sv"
    }

    /// Every key but the asset: what a metadata probe asks for.
    public static let metadataKeys: [CKRecord.FieldKey] = [Key.bytes, Key.sha256, Key.format, Key.duration, Key.schema]

    /// The private database's default zone.
    static let zoneID = CKRecordZone.ID(zoneName: CKRecordZone.ID.defaultZoneName, ownerName: CKCurrentUserDefaultName)

    public init() {}

    // MARK: Record ids

    /// "af.<UUID>" in the default zone.
    public func recordID(_ id: UUID) -> CKRecord.ID {
        CKRecord.ID(recordName: "\(Self.prefix).\(id.uuidString)", zoneID: Self.zoneID)
    }

    /// The recording id an `AudioFile` record id names; nil for another zone or another kind of name.
    public func recordingID(_ id: CKRecord.ID) -> UUID? {
        guard id.zoneID == Self.zoneID else { return nil }
        let name = id.recordName
        let head = Self.prefix + "."
        guard name.hasPrefix(head) else { return nil }
        return UUID(uuidString: String(name.dropFirst(head.count)))
    }

    // MARK: Encode and decode

    /// A new `AudioFile` record (no system fields: saved create-only) whose asset is `file`.
    public func encode(_ d: AudioDescriptor, file: URL) -> CKRecord {
        let ck = CKRecord(recordType: Self.recordType, recordID: recordID(d.recordingID))
        ck[Key.audio] = CKAsset(fileURL: file)
        ck.encryptedValues.setObject(NSNumber(value: d.bytes), forKey: Key.bytes)
        ck.encryptedValues.setObject(d.sha256 as NSString, forKey: Key.sha256)
        ck.encryptedValues.setObject(d.format.rawValue as NSString, forKey: Key.format)
        ck.encryptedValues.setObject(NSNumber(value: d.duration), forKey: Key.duration)
        ck[Key.schema] = NSNumber(value: Int64(SyncSchema.version))
        return ck
    }

    /// `.present` when the record is an `AudioFile` of ours and all four scalars read; otherwise `.unreadable`. The
    /// asset is not looked at (a metadata probe has none).
    public func decode(_ ck: CKRecord) -> AudioPresence {
        guard ck.recordType == Self.recordType, let id = recordingID(ck.recordID),
              let bytes = ck.encryptedValues.object(forKey: Key.bytes) as? NSNumber,
              let sha = ck.encryptedValues.object(forKey: Key.sha256) as? String,
              let format = ck.encryptedValues.object(forKey: Key.format) as? String,
              let duration = ck.encryptedValues.object(forKey: Key.duration) as? NSNumber
        else { return .unreadable }
        return .present(AudioDescriptor(recordingID: id, format: AudioFormat(rawValue: format), bytes: bytes.int64Value,
                                        sha256: sha, duration: duration.doubleValue))
    }

    // MARK: Errors

    /// The `AudioTransferError` for a CloudKit (or other) error. `.indexMissing` and `.zoneMissing` are never returned
    /// here: they depend on the call, so `CloudKitAudioTransfer` decides them (`invalidArguments` on a listing,
    /// `zoneNotFound`/`userDeletedZone` when checking `rec.` records).
    public static func error(_ error: any Error) -> AudioTransferError {
        if let mine = error as? AudioTransferError { return mine }
        if error is CancellationError { return .cancelled }
        guard let ck = error as? CKError else {
            let ns = error as NSError
            return ns.domain == NSCocoaErrorDomain && ns.code == NSUserCancelledError ? .cancelled : .other(code: ns.code)
        }
        switch ck.code {
        case .partialFailure:
            // One request's items failed: report the first real item error (an atomic batch's "batchRequestFailed"
            // only says another item failed).
            let items = (ck.partialErrorsByItemID ?? [:]).values.compactMap { $0 as? CKError }
            if let first = items.first(where: { $0.code != .batchRequestFailed }) ?? items.first {
                return Self.error(first)
            }
            return .other(code: ck.code.rawValue)
        case .quotaExceeded: return .quotaExceeded
        case .unknownItem: return .notFound
        case .limitExceeded: return .tooLarge
        case .assetFileNotFound, .assetFileModified: return .sourceChanged
        case .networkUnavailable: return .networkUnavailable
        case .assetNotAvailable, .requestRateLimited, .zoneBusy, .serviceUnavailable, .serverResponseLost, .networkFailure:
            return .retryable(retryAfter: ck.retryAfterSeconds)
        case .notAuthenticated, .accountTemporarilyUnavailable: return .noAccount
        case .operationCancelled: return .cancelled
        default: return .other(code: ck.code.rawValue)
        }
    }

    /// An order-of-magnitude size for `CKOperationGroup.expectedSendSize`/`expectedReceiveSize`: ≤ 0 unknown,
    /// < 1 MB kilobytes, < 10 MB megabytes, < 100 MB tens of megabytes, < 1 GB hundreds of megabytes, else gigabytes
    /// (decimal megabytes, like every size in audio sync).
    public static func transferSize(_ bytes: Int64) -> CKOperationGroup.TransferSize {
        switch bytes {
        case ...0: .unknown
        case ..<1_000_000: .kilobytes
        case ..<10_000_000: .megabytes
        case ..<100_000_000: .tensOfMegabytes
        case ..<1_000_000_000: .hundredsOfMegabytes
        default: .gigabytes
        }
    }
}
