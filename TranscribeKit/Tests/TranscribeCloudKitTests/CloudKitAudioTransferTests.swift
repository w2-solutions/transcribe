import CloudKit
import Foundation
import Testing
@testable import TranscribeCloudKit
@testable import TranscribeKit

/// The real audio transfer, as far as it can be tested without iCloud: `swift test` runs without the container
/// entitlement, so every call must read as "no account" without touching CloudKit; the request settings, the record
/// ids the sweep's check uses and the staged-file move are checked directly.
@Suite("CloudKit: audio transfer")
struct CloudKitAudioTransferTests {
    @Test func withoutAnEntitlementEveryCallReadsNoAccount() async throws {
        // The guard that keeps these tests away from CloudKit: never go on if this process could open the container.
        try #require(!AccountObserver.hasContainerEntitlement(CloudKitTransport.containerIdentifier))
        let transfer = CloudKitAudioTransfer()
        let id = UUID()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("ck-noaccount-\(UUID().uuidString).m4a")
        let descriptor = AudioDescriptor(recordingID: id, format: .aac16kMono, bytes: 4, sha256: "00", duration: 1)
        let options = AudioTransferOptions(userInitiated: true, allowsMetered: true, expectedBytes: 4)
        // Twice: the first call finds no entitlement, the second remembers it.
        for _ in 0 ..< 2 {
            await #expect(throws: AudioTransferError.noAccount) { try await transfer.probe([id]) }
            await #expect(throws: AudioTransferError.noAccount) { try await transfer.probeFully(id) }
            await #expect(throws: AudioTransferError.noAccount) { try await transfer.recordingRecordsExist([id]) }
            await #expect(throws: AudioTransferError.noAccount) {
                try await transfer.upload(file, descriptor: descriptor, options: options) { _ in }
            }
            await #expect(throws: AudioTransferError.noAccount) {
                try await transfer.download(id, to: file, options: options) { _ in }
            }
            await #expect(throws: AudioTransferError.noAccount) { try await transfer.delete([id]) }
            await #expect(throws: AudioTransferError.noAccount) { try await transfer.listAll() }
        }
        // Even an empty request says so, and nothing was written.
        await #expect(throws: AudioTransferError.noAccount) { try await transfer.probe([]) }
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func transferSizeBuckets() {
        let size: (Int64) -> CKOperationGroup.TransferSize = CKAudioCodec.transferSize
        #expect(size(-1) == .unknown)
        #expect(size(0) == .unknown)
        #expect(size(1_000) == .kilobytes)                   // 1 KB
        #expect(size(999_999) == .kilobytes)
        #expect(size(1_000_000) == .megabytes)               // 1 MB
        #expect(size(9_999_999) == .megabytes)
        #expect(size(14_000_000) == .tensOfMegabytes)        // about an hour of AAC
        #expect(size(200_000_000) == .hundredsOfMegabytes)   // the upload cap
        #expect(size(999_999_999) == .hundredsOfMegabytes)
        #expect(size(2_000_000_000) == .gigabytes)           // 2 GB
    }

    @Test func recordingCheckUsesTheLibraryZone() {
        let ids = [UUID(), UUID()]
        let recordIDs = CloudKitAudioTransfer().recordingCheckIDs(ids)
        #expect(recordIDs.map(\.recordName) == ids.map { "rec.\($0.uuidString)" })
        #expect(recordIDs.allSatisfy { $0.zoneID == CKRecordCodec.zoneID })
        #expect(recordIDs.map(\.recordName) == ids.map { SyncRecordID(type: .recording, entityID: $0).recordName })
        // A transfer built for another zone asks there.
        let zone = CKRecordZone.ID(zoneName: "Elsewhere", ownerName: CKCurrentUserDefaultName)
        #expect(CloudKitAudioTransfer(libraryZoneID: zone).recordingCheckIDs(ids).allSatisfy { $0.zoneID == zone })
    }

    @Test func downloadMovesTheStagedFileInsideTheResultBlock() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ck-adopt-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let staging = root.appendingPathComponent("staging", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let staged = staging.appendingPathComponent("A1B2C3")              // CloudKit's staged name, no extension
        let bytes = Data((0 ..< 10_000).map { UInt8($0 % 241) })
        try bytes.write(to: staged)
        // The destination's folder does not exist yet, and a stale partial file sits where the download goes.
        let destination = root.appendingPathComponent("AudioIncoming/\(UUID().uuidString).m4a.part")
        try CloudKitAudioTransfer.adopt(asset: CKAsset(fileURL: staged), to: destination)
        #expect(try Data(contentsOf: destination) == bytes)
        #expect(!FileManager.default.fileExists(atPath: staged.path))      // moved, not copied
        try Data("old".utf8).write(to: staged)
        try CloudKitAudioTransfer.adopt(asset: CKAsset(fileURL: staged), to: destination)
        #expect(try Data(contentsOf: destination) == Data("old".utf8))     // replaced
        // No asset is a broken blob; a staged file that vanished first is worth another try.
        #expect(throws: AudioTransferError.other(code: 0)) { try CloudKitAudioTransfer.adopt(asset: nil, to: destination) }
        #expect(throws: AudioTransferError.retryable(retryAfter: nil)) {
            try CloudKitAudioTransfer.adopt(asset: CKAsset(fileURL: staging.appendingPathComponent("gone")), to: destination)
        }
        #expect(try Data(contentsOf: destination) == Data("old".utf8))
    }

    @Test func requestsRunAtTheRightQualityAndNetwork() {
        let asked = CloudKitAudioTransfer.configuration(AudioTransferOptions(userInitiated: true, allowsMetered: true, expectedBytes: 1))
        #expect(asked.qualityOfService == .userInitiated)
        #expect(asked.allowsCellularAccess)
        let automatic = CloudKitAudioTransfer.configuration(AudioTransferOptions(userInitiated: false, allowsMetered: false, expectedBytes: 1))
        #expect(automatic.qualityOfService == .utility)
        #expect(!automatic.allowsCellularAccess)
        // Probes, checks, deletes and the listing: kilobytes that user-initiated work waits on, never held back.
        let metadata = CloudKitAudioTransfer.configuration(nil)
        #expect(metadata.qualityOfService == .userInitiated)
        #expect(metadata.allowsCellularAccess)
        let group = CloudKitAudioTransfer.group("audio-download", send: .kilobytes, receive: CKAudioCodec.transferSize(14_000_000),
                                                quantity: 3, configuration: automatic)
        #expect(group.name == "audio-download")
        #expect(group.expectedSendSize == .kilobytes)
        #expect(group.expectedReceiveSize == .tensOfMegabytes)
        #expect(group.quantity == 3)
        #expect(group.defaultConfiguration.qualityOfService == .utility)
        #expect(!group.defaultConfiguration.allowsCellularAccess)
    }

    @Test func idsAreDeduplicatedAndSentTwoHundredAtATime() {
        let ids = (0 ..< 450).map { _ in UUID() }
        #expect(CloudKitAudioTransfer.chunks(ids).map(\.count) == [200, 200, 50])
        #expect(CloudKitAudioTransfer.chunks(ids).flatMap { $0 } == ids)
        #expect(CloudKitAudioTransfer.chunks([]).isEmpty)
        #expect(CloudKitAudioTransfer.unique([ids[1], ids[0], ids[1], ids[2], ids[0]]) == [ids[1], ids[0], ids[2]])
    }

    @Test func logLinesNameCasesAndRoundSizes() {
        #expect(CloudKitAudioTransfer.megabytes(14_249_999) == "14.2 MB")
        #expect(CloudKitAudioTransfer.megabytes(0) == "0.0 MB")
        #expect(CloudKitAudioTransfer.name(.retryable(retryAfter: 29.6)) == "retryable after 30 s")
        #expect(CloudKitAudioTransfer.name(.retryable(retryAfter: nil)) == "retryable")
        #expect(CloudKitAudioTransfer.name(.other(code: 14)) == "other 14")
        #expect(CloudKitAudioTransfer.name(.indexMissing) == "indexMissing")
        #expect(CloudKitAudioTransfer.failed("audio list", AudioTransferError.indexMissing, cause: CKError(.invalidArguments)) == .indexMissing)
        #expect(CloudKitAudioTransfer.failed("audio upload", CKError(.quotaExceeded)) == .quotaExceeded)
    }
}
