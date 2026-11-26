import CloudKit
import Foundation
import Testing
@testable import TranscribeCloudKit
@testable import TranscribeKit

/// The audio blob codec (§3.3, WP2): `AudioFile` records named `af.<UUID>` in the default zone, a plain asset pointing
/// at the staged file, the four scalars encrypted, `sv` plain; and the CloudKit error table.
@Suite("CloudKit: audio codec")
struct CKAudioCodecTests {
    let codec = CKAudioCodec()
    let descriptor = AudioDescriptor(recordingID: UUID(), format: .aac16kMono, bytes: 14_400_123,
                                     sha256: String(repeating: "ab", count: 32), duration: 3_600.016_5)

    /// A temporary transfer file with `bytes`, in a folder of its own.
    func stagedFile(_ bytes: Data = Data((0 ..< 4_096).map { UInt8($0 % 251) })) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ckaudio-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("\(descriptor.recordingID.uuidString).m4a")
        try bytes.write(to: file)
        return file
    }

    /// What arrives from the server: the whole record archived and decoded again.
    func overTheWire(_ record: CKRecord) throws -> CKRecord {
        let data = try NSKeyedArchiver.archivedData(withRootObject: record, requiringSecureCoding: true)
        return try #require(try NSKeyedUnarchiver.unarchivedObject(ofClass: CKRecord.self, from: data))
    }

    @Test func recordIDIsAfInTheDefaultZone() {
        let id = UUID()
        let recordID = codec.recordID(id)
        #expect(recordID.recordName == "af.\(id.uuidString)")
        #expect(recordID.zoneID == CKRecordZone.default().zoneID)
        #expect(recordID.zoneID != CKRecordCodec.zoneID)
        #expect(codec.recordingID(recordID) == id)
        #expect(CKAudioCodec.recordType == "AudioFile")
        #expect(CKAudioCodec.prefix == "af")
    }

    @Test func anotherZoneOrAForeignNameHasNoRecordingID() {
        let id = UUID()
        let otherZone = CKRecordZone.ID(zoneName: "Other", ownerName: CKCurrentUserDefaultName)
        #expect(codec.recordingID(CKRecord.ID(recordName: "af.\(id.uuidString)", zoneID: otherZone)) == nil)
        #expect(codec.recordingID(CKRecord.ID(recordName: "af.\(id.uuidString)", zoneID: CKRecordCodec.zoneID)) == nil)
        #expect(codec.recordingID(CKRecord.ID(recordName: "rec.\(id.uuidString)", zoneID: CKRecordZone.default().zoneID)) == nil)
        #expect(codec.recordingID(CKRecord.ID(recordName: "au.\(id.uuidString)", zoneID: CKRecordZone.default().zoneID)) == nil)
        #expect(codec.recordingID(CKRecord.ID(recordName: "af.nonsense", zoneID: CKRecordZone.default().zoneID)) == nil)
        #expect(codec.recordingID(CKRecord.ID(recordName: "af\(id.uuidString)", zoneID: CKRecordZone.default().zoneID)) == nil)
    }

    @Test func theAssetIsPlainAndTheScalarsAreEncrypted() throws {
        let bytes = Data((0 ..< 4_096).map { UInt8($0 % 251) })
        let file = try stagedFile(bytes)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let ck = codec.encode(descriptor, file: file)
        #expect(ck.recordType == "AudioFile")
        #expect(ck.recordID == codec.recordID(descriptor.recordingID))
        #expect(ck.recordChangeTag == nil)                    // new: saved create-only
        // The asset is the staged file itself: not copied, not compressed.
        let asset = try #require(ck[CKAudioCodec.Key.audio] as? CKAsset)
        #expect(asset.fileURL?.standardizedFileURL == file.standardizedFileURL)
        #expect(try Data(contentsOf: file) == bytes)
        let encrypted = Set(ck.encryptedValues.allKeys())
        #expect(encrypted == ["bytes", "sha256", "format", "duration"])
        #expect(Set(ck.allKeys()).subtracting(encrypted) == ["audio", "sv"])
        #expect((ck[CKAudioCodec.Key.schema] as? NSNumber)?.int64Value == 1)
        #expect(ck[CKAudioCodec.Key.bytes] == nil)            // never as a plain value
        #expect(ck[CKAudioCodec.Key.sha256] == nil)
        #expect(CKAudioCodec.metadataKeys == ["bytes", "sha256", "format", "duration", "sv"])
        #expect(!CKAudioCodec.metadataKeys.contains(CKAudioCodec.Key.audio))
    }

    @Test func aRoundTripThroughTheArchiveDecodesPresent() throws {
        let file = try stagedFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let back = try overTheWire(codec.encode(descriptor, file: file))
        #expect(codec.decode(back) == .present(descriptor))
        // An exact whole number of bytes and a fractional duration keep their kinds.
        let d2 = AudioDescriptor(recordingID: UUID(), format: AudioFormat(rawValue: "opus/48000/2"), bytes: 4,
                                 sha256: "00", duration: 2)
        #expect(codec.decode(try overTheWire(codec.encode(d2, file: file))) == .present(d2))
    }

    @Test func aMissingOrMistypedEncryptedFieldIsUnreadable() throws {
        let file = try stagedFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        for key in [CKAudioCodec.Key.bytes, CKAudioCodec.Key.sha256, CKAudioCodec.Key.format, CKAudioCodec.Key.duration] {
            let ck = codec.encode(descriptor, file: file)
            ck.encryptedValues.setObject(nil, forKey: key)
            #expect(codec.decode(ck) == .unreadable, "without \(key)")
        }
        let mistyped = codec.encode(descriptor, file: file)
        mistyped.encryptedValues.setObject(NSNumber(value: 1), forKey: CKAudioCodec.Key.sha256)
        #expect(codec.decode(mistyped) == .unreadable)
        // A plain copy of a field (an encrypted one could not be read) does not count.
        let plain = codec.encode(descriptor, file: file)
        plain.encryptedValues.setObject(nil, forKey: CKAudioCodec.Key.bytes)
        plain[CKAudioCodec.Key.bytes] = NSNumber(value: descriptor.bytes)
        #expect(codec.decode(plain) == .unreadable)
        // Another record type under the same name is not a blob.
        let other = CKRecord(recordType: "Recording", recordID: codec.recordID(descriptor.recordingID))
        #expect(codec.decode(other) == .unreadable)
    }

    @Test func aMetadataProbeWithoutTheAssetAndANewerSchemaStillDecode() throws {
        let file = try stagedFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let ck = codec.encode(descriptor, file: file)
        ck[CKAudioCodec.Key.audio] = nil                       // desiredKeys left the asset out
        ck[CKAudioCodec.Key.schema] = NSNumber(value: 2)
        #expect(codec.decode(try overTheWire(ck)) == .present(descriptor))
    }

    @Test func cloudKitErrorsMapToAudioTransferErrors() {
        func map(_ code: CKError.Code, _ info: [String: Any] = [:]) -> AudioTransferError {
            CKAudioCodec.error(CKError(code, userInfo: info))
        }
        #expect(map(.quotaExceeded) == .quotaExceeded)
        #expect(map(.unknownItem) == .notFound)
        #expect(map(.limitExceeded) == .tooLarge)
        #expect(map(CKError.Code(rawValue: 16)!) == .sourceChanged)        // assetFileNotFound
        #expect(map(CKError.Code(rawValue: 17)!) == .sourceChanged)        // assetFileModified
        #expect(map(CKError.Code(rawValue: 35)!) == .retryable(retryAfter: nil))   // assetNotAvailable
        #expect(map(.networkFailure) == .retryable(retryAfter: nil))
        #expect(map(.networkUnavailable) == .networkUnavailable)
        #expect(map(.requestRateLimited, [CKErrorRetryAfterKey: NSNumber(value: 7.5)]) == .retryable(retryAfter: 7.5))
        #expect(map(.zoneBusy, [CKErrorRetryAfterKey: NSNumber(value: 3)]) == .retryable(retryAfter: 3))
        #expect(map(.serviceUnavailable) == .retryable(retryAfter: nil))
        #expect(map(.serverResponseLost) == .retryable(retryAfter: nil))
        #expect(map(.notAuthenticated) == .noAccount)
        #expect(map(.accountTemporarilyUnavailable) == .noAccount)
        #expect(map(.operationCancelled) == .cancelled)
        #expect(CKAudioCodec.error(CancellationError()) == .cancelled)
        // The transfer decides these by call; the codec alone never says indexMissing or zoneMissing.
        #expect(map(.invalidArguments) == .other(code: 12))
        #expect(map(.zoneNotFound) == .other(code: 26))
        #expect(map(.userDeletedZone) == .other(code: 28))
        #expect(map(.serverRecordChanged) == .other(code: 14))
        #expect(map(.permissionFailure) == .other(code: 10))
        // Errors already mapped pass through; other errors keep their code.
        #expect(CKAudioCodec.error(AudioTransferError.zoneMissing) == .zoneMissing)
        #expect(CKAudioCodec.error(NSError(domain: "Elsewhere", code: 5)) == .other(code: 5))
    }

    @Test func aPartialFailureReportsItsItemsError() {
        let id = CKAudioCodec().recordID(UUID())
        let other = CKAudioCodec().recordID(UUID())
        let partial = CKError(.partialFailure, userInfo: [
            CKPartialErrorsByItemIDKey: [id: CKError(.quotaExceeded) as NSError, other: CKError(.batchRequestFailed) as NSError],
        ])
        #expect(CKAudioCodec.error(partial) == .quotaExceeded)
        #expect(CKAudioCodec.error(CKError(.partialFailure)) == .other(code: 2))
    }

    @Test func theLogNamesAssetNotAvailable() {
        #expect(CloudKitTransport.codeName(.assetNotAvailable) == "assetNotAvailable")
        #expect(CloudKitTransport.describe(CKError(.assetNotAvailable)) == "CKError 35 assetNotAvailable")
    }

    @Test func theSchemaSeedCoversBothAudioRecordTypes() throws {
        // RecordingAudio, through the loop over every sync record type, with every kind.
        let marker = try #require(CloudSchemaSeeder.records().first { $0.id.type == .audio })
        #expect(Set(marker.fields.keys) == Set(CKRecordCodec.kinds(.audio).keys))
        let seedZone = CKRecordZone.ID(zoneName: "SchemaSeed", ownerName: CKCurrentUserDefaultName)
        let ck = try CKRecordCodec(zoneID: seedZone).encode(marker)
        #expect(ck.recordType == "RecordingAudio")
        #expect(Set(ck.encryptedValues.allKeys()) == ["bytes", "sha256", "format", "duration"])
        // AudioFile, in the default zone, with every key.
        let file = try stagedFile(Data([1, 2, 3, 4]))
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let blob = CloudSchemaSeeder.audioFileRecord(asset: file)
        #expect(blob.recordType == "AudioFile")
        #expect(blob.recordID.zoneID == CKRecordZone.default().zoneID)
        #expect(blob.recordID.recordName == "af.00000000-0000-4000-8000-000000000000")
        #expect(Set(blob.allKeys()) == ["audio", "bytes", "sha256", "format", "duration", "sv"])
        #expect(Set(blob.encryptedValues.allKeys()) == ["bytes", "sha256", "format", "duration"])
        #expect((blob["audio"] as? CKAsset)?.fileURL?.standardizedFileURL == file.standardizedFileURL)
        #expect(CKAudioCodec().decode(blob) != .unreadable)
    }
}
