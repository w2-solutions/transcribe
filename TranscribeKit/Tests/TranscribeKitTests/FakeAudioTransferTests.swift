import CryptoKit
import Foundation
import Synchronization
import Testing
import TranscribeCore
@testable import TranscribeFakes
@testable import TranscribeKit

/// The fake audio transfer and the fake cloud's audio controls do what §3.3 says, so the audio sync tests can rely on
/// them.
@Suite("Fake audio transfer")
struct FakeAudioTransferTests {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fake-audio-\(UUID().uuidString)",
                                                                               isDirectory: true)
    let account = "account-1"
    let cloud = FakeCloud()
    let transport: FakeTransport
    let transfer: FakeAudioTransfer

    static let automatic = AudioTransferOptions(userInitiated: false, allowsMetered: false, expectedBytes: 0)
    static let asked = AudioTransferOptions(userInitiated: true, allowsMetered: true, expectedBytes: 0)

    init() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        transport = FakeTransport(cloud: cloud, account: account)
        transfer = FakeAudioTransfer(cloud: cloud, transport: transport)
    }

    func cleanup() { try? FileManager.default.removeItem(at: dir) }

    /// A staged file with `count` bytes and its descriptor.
    func staged(_ id: UUID = UUID(), count: Int = 1_000, seed: UInt8 = 1) throws -> (URL, AudioDescriptor) {
        let data = Data((0..<count).map { UInt8(truncatingIfNeeded: $0) &+ seed })
        let url = dir.appendingPathComponent("\(id.uuidString).wav")
        try data.write(to: url)
        let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return (url, AudioDescriptor(recordingID: id, format: .pcm16kMono, bytes: Int64(count), sha256: sha, duration: 1))
    }

    @discardableResult
    func upload(_ file: URL, _ d: AudioDescriptor, _ options: AudioTransferOptions = automatic) async throws -> AudioUploadOutcome {
        try await transfer.upload(file, descriptor: d, options: options, progress: { _ in })
    }

    func download(_ id: UUID, _ options: AudioTransferOptions = automatic) async throws -> (URL, AudioDescriptor) {
        let to = dir.appendingPathComponent("in").appendingPathComponent("\(id.uuidString).wav.part")
        let d = try await transfer.download(id, to: to, options: options, progress: { _ in })
        return (to, d)
    }

    // MARK: Upload, download, probe

    @Test func anUploadIsStoredOnceAndDownloadsByteForByte() async throws {
        defer { cleanup() }
        let (file, d) = try staged(count: 5_000)
        await cloud.setNow { Seeds.Dates.d }
        #expect(try await upload(file, d) == .uploaded)
        let stored = try #require(await cloud.audio(account: account)[d.recordingID])
        #expect(stored.descriptor == d)
        #expect(stored.data == (try Data(contentsOf: file)))
        #expect(stored.created == Seeds.Dates.d)
        #expect(!stored.unreadable)
        // Create-only: a second upload adopts the server's.
        #expect(try await upload(file, d) == .alreadyThere(d))
        #expect(await transfer.uploads == 2)
        #expect(await transfer.bytesUp == 5_000)

        let (to, got) = try await download(d.recordingID)
        #expect(got == d)
        #expect(try Data(contentsOf: to) == Data(contentsOf: file))
        #expect(await transfer.downloads == 1)
        #expect(await transfer.bytesDown == 5_000)
    }

    @Test func probesAreMetadataAndBatchedBy200() async throws {
        defer { cleanup() }
        let (file, d) = try staged()
        try await upload(file, d)
        let missing = UUID()
        let answer = try await transfer.probe([d.recordingID, missing])
        #expect(answer == [d.recordingID: .present(d), missing: .absent])
        #expect(try await transfer.probeFully(d.recordingID) == .present(d))
        #expect(try await transfer.probeFully(missing) == .absent)
        #expect(await transfer.probes == 3)
        _ = try await transfer.probe((0..<450).map { _ in UUID() })
        #expect(await transfer.probes == 6)
        #expect(try await transfer.probe([]) == [:])
        #expect(await transfer.probes == 6)
        #expect(await transfer.downloads == 0)
    }

    @Test func aProbeCanBeMadeToSayUnreadableOnce() async throws {
        defer { cleanup() }
        let (file, d) = try staged()
        try await upload(file, d)
        await cloud.failProbeAsUnreadable(d.recordingID)
        #expect(try await transfer.probe([d.recordingID]) == [d.recordingID: .unreadable])
        #expect(try await transfer.probe([d.recordingID]) == [d.recordingID: .present(d)])
        await cloud.failProbeAsUnreadable(d.recordingID)
        #expect(try await transfer.probeFully(d.recordingID) == .present(d))   // a full fetch reads it
        #expect(await cloud.audio(account: account)[d.recordingID]?.unreadable == false)
    }

    @Test func aMissingSourceIsSourceChangedAndADownloadOfNothingIsNotFound() async throws {
        defer { cleanup() }
        let (file, d) = try staged()
        try FileManager.default.removeItem(at: file)
        await #expect(throws: AudioTransferError.sourceChanged) { try await upload(file, d) }
        await #expect(throws: AudioTransferError.notFound) { try await download(d.recordingID) }
        #expect(await cloud.audio(account: account).isEmpty)
    }

    @Test func optionsAreRecordedPerCall() async throws {
        defer { cleanup() }
        let (file, d) = try staged()
        try await upload(file, d, Self.automatic)
        _ = try await download(d.recordingID, Self.asked)
        _ = try await download(d.recordingID, Self.automatic)
        #expect(await transfer.options(.upload, d.recordingID).map(\.userInitiated) == [false])
        #expect(await transfer.options(.download, d.recordingID).map(\.userInitiated) == [true, false])
        #expect(await transfer.calls.map(\.op) == [.upload, .download, .download])
    }

    // MARK: Deletes, listing, recording records

    @Test func deletesListingAndTheIndex() async throws {
        defer { cleanup() }
        let clock = Mutex(Seeds.Dates.d)
        await cloud.setNow { clock.withLock { $0 } }
        let (f1, d1) = try staged()
        try await upload(f1, d1)
        clock.withLock { $0 = $0.addingTimeInterval(3_600) }
        let (f2, d2) = try staged()
        try await upload(f2, d2)
        let listed = try await transfer.listAll()
        let expected = [AudioListing(recordingID: d1.recordingID, created: Seeds.Dates.d),
                        AudioListing(recordingID: d2.recordingID, created: Seeds.Dates.d.addingTimeInterval(3_600))]
        #expect(listed == expected.sorted { $0.recordingID.uuidString < $1.recordingID.uuidString })
        #expect(await transfer.listings == 1)

        await cloud.setAudioIndexExists(false)
        await #expect(throws: AudioTransferError.indexMissing) { try await transfer.listAll() }
        await cloud.setAudioIndexExists(true)

        // A missing id counts as deleted; 201 ids are two requests.
        try await transfer.delete([d1.recordingID] + (0..<200).map { _ in UUID() })
        #expect(await transfer.deletes == 2)
        #expect(Set(await cloud.audio(account: account).keys) == [d2.recordingID])
        try await transfer.delete([])
        #expect(await transfer.deletes == 2)
    }

    @Test func recordingRecordsComeFromTheLibraryZone() async throws {
        defer { cleanup() }
        let here = UUID(), gone = UUID()
        await cloud.inject(account: account, SyncRecord(id: SyncRecordID(type: .recording, entityID: here), fields: ["sv": .int(1)]))
        // A speaker with the other id is not a recording record.
        await cloud.inject(account: account, SyncRecord(id: SyncRecordID(type: .speaker, entityID: gone), fields: ["sv": .int(1)]))
        #expect(try await transfer.recordingRecordsExist([here, gone]) == [here])
        #expect(await transfer.recordingChecks == 1)
        await cloud.removeZone(account: account, reason: .deleted)
        await #expect(throws: AudioTransferError.zoneMissing) { try await transfer.recordingRecordsExist([here]) }
    }

    // MARK: Accounts and the network

    @Test func eachAccountHasItsOwnAudioAndNoAccountIsRefused() async throws {
        defer { cleanup() }
        let (file, d) = try staged()
        try await upload(file, d)
        // Nothing runs a coordinator here: acknowledge the account events the transport delivers.
        let transport = self.transport
        let events = Task {
            for await _ in transport.events { await transport.eventHandled() }
        }
        defer { events.cancel() }
        await transport.signIn("account-2")
        #expect(try await transfer.probe([d.recordingID]) == [d.recordingID: .absent])
        try await upload(file, d)
        #expect(await cloud.audio(account: "account-2").count == 1)
        await transport.signOut()
        await #expect(throws: AudioTransferError.noAccount) { try await transfer.probe([d.recordingID]) }
        await #expect(throws: AudioTransferError.noAccount) { try await upload(file, d) }
        await #expect(throws: AudioTransferError.noAccount) { try await transfer.listAll() }
        #expect(await transfer.uploads == 2)
    }

    @Test func networkDownRefusesEveryOperationBeforeItReachesTheCloud() async throws {
        defer { cleanup() }
        let (file, d) = try staged()
        try await upload(file, d)
        await cloud.setNetworkDown(true)
        let id = d.recordingID
        await #expect(throws: AudioTransferError.networkUnavailable) { try await transfer.probe([id]) }
        await #expect(throws: AudioTransferError.networkUnavailable) { try await transfer.probeFully(id) }
        await #expect(throws: AudioTransferError.networkUnavailable) { try await transfer.recordingRecordsExist([id]) }
        await #expect(throws: AudioTransferError.networkUnavailable) { try await upload(file, d) }
        await #expect(throws: AudioTransferError.networkUnavailable) { try await download(id) }
        await #expect(throws: AudioTransferError.networkUnavailable) { try await transfer.delete([id]) }
        await #expect(throws: AudioTransferError.networkUnavailable) { try await transfer.listAll() }
        #expect(await transfer.uploads == 1)
        #expect(await transfer.probes == 0)
        #expect(await transfer.downloads == 0)
        #expect(await transfer.deletes == 0)
        #expect(await transfer.listings == 0)
        #expect(await transfer.recordingChecks == 0)
        await cloud.setNetworkDown(false)
        #expect(await cloud.audio(account: account).count == 1)
    }

    // MARK: Quota

    @Test func theAudioQuotaRefusesUploadsPastIt() async throws {
        defer { cleanup() }
        await cloud.setAudioQuota(bytes: 2_500)
        let (f1, d1) = try staged(count: 1_000), (f2, d2) = try staged(count: 1_000), (f3, d3) = try staged(count: 1_000)
        try await upload(f1, d1)
        try await upload(f2, d2)
        await #expect(throws: AudioTransferError.quotaExceeded) { try await upload(f3, d3) }
        #expect(await cloud.audio(account: account).count == 2)
        #expect(await transfer.bytesUp == 2_000)
        // Records are unaffected by the audio quota.
        await cloud.inject(account: account, SyncRecord(id: SyncRecordID(type: .folder, entityID: UUID()), fields: ["sv": .int(1)]))
        #expect(await cloud.records(account: account).count == 1)
        await cloud.setAudioQuota(bytes: nil)
        try await upload(f3, d3)
        // A full iCloud refuses audio too.
        await cloud.setQuotaFull(true)
        let (f4, d4) = try staged()
        await #expect(throws: AudioTransferError.quotaExceeded) { try await upload(f4, d4) }
        await cloud.setQuotaFull(false)
        try await upload(f4, d4)
    }

    // MARK: Injected failures

    @Test func failNextAudioFailsOnceForThatOpAndId() async throws {
        defer { cleanup() }
        let (file, d) = try staged(count: 2_000)
        let id = d.recordingID
        await cloud.failNextAudio(.upload, id, with: .retryable(retryAfter: 5))
        await #expect(throws: AudioTransferError.retryable(retryAfter: 5)) { try await upload(file, d) }
        #expect(await cloud.audio(account: account).isEmpty)                    // nothing stored
        try await upload(file, d)

        await cloud.failNextAudio(.probe, id, with: .other(code: 7))
        await #expect(throws: AudioTransferError.other(code: 7)) { try await transfer.probe([UUID(), id]) }
        #expect(try await transfer.probe([id]) == [id: .present(d)])

        await cloud.failNextAudio(.probeFully, id, with: .networkUnavailable)
        await #expect(throws: AudioTransferError.networkUnavailable) { try await transfer.probeFully(id) }

        await cloud.failNextAudio(.checkRecordings, id, with: .retryable(retryAfter: nil))
        await #expect(throws: AudioTransferError.retryable(retryAfter: nil)) { try await transfer.recordingRecordsExist([id]) }

        await cloud.failNextAudio(.list, UUID(), with: .networkUnavailable)   // the id does not matter for a listing
        await #expect(throws: AudioTransferError.networkUnavailable) { try await transfer.listAll() }
        #expect(try await transfer.listAll().count == 1)

        await cloud.failNextAudio(.delete, id, with: .networkUnavailable)
        await #expect(throws: AudioTransferError.networkUnavailable) { try await transfer.delete([id]) }
        #expect(await cloud.audio(account: account)[id] != nil)                 // nothing deleted

        // A failed download leaves a part file behind, as an interrupted transfer would; the next one works.
        await cloud.failNextAudio(.download, id, with: .networkUnavailable)
        let part = dir.appendingPathComponent("in").appendingPathComponent("\(id.uuidString).wav.part")
        await #expect(throws: AudioTransferError.networkUnavailable) { try await download(id) }
        #expect(try Data(contentsOf: part).count == 1_000)
        await cloud.failNextAudio(.download, id, with: .notFound)
        await #expect(throws: AudioTransferError.notFound) { try await download(id) }
        let (to, got) = try await download(id)
        #expect(got == d)
        #expect(try Data(contentsOf: to) == Data(contentsOf: file))
        try await transfer.delete([id])
        #expect(await cloud.audio(account: account).isEmpty)
    }

    @Test func aCorruptDownloadFlipsAByteAndKeepsTheDescriptor() async throws {
        defer { cleanup() }
        let (file, d) = try staged(count: 3_000)
        try await upload(file, d)
        await cloud.corruptNextDownload(d.recordingID)
        let (to, got) = try await download(d.recordingID)
        #expect(got == d)
        let data = try Data(contentsOf: to), original = try Data(contentsOf: file)
        #expect(data.count == original.count)
        #expect(zip(data, original).filter { $0 != $1 }.count == 1)
        #expect(try await FileDigest.sha256(of: to) != d.sha256)
        let (again, _) = try await download(d.recordingID)
        #expect(try await FileDigest.sha256(of: again) == d.sha256)
    }

    @Test func aCommittedUploadCanLoseItsReply() async throws {
        defer { cleanup() }
        let (file, d) = try staged(count: 1_500)
        await cloud.commitThenLoseReply(d.recordingID)
        await #expect(throws: AudioTransferError.retryable(retryAfter: nil)) { try await upload(file, d) }
        #expect(await cloud.audio(account: account)[d.recordingID]?.descriptor == d)   // stored all the same
        #expect(await transfer.bytesUp == 1_500)
        #expect(try await transfer.probe([d.recordingID]) == [d.recordingID: .present(d)])
        #expect(try await upload(file, d) == .alreadyThere(d))
        #expect(await transfer.bytesUp == 1_500)
    }

    // MARK: Zone removal

    @Test func removingTheLibraryZoneKeepsTheBlobs() async throws {
        defer { cleanup() }
        let (file, d) = try staged()
        try await upload(file, d)
        await transport.start(state: nil, provider: { _ in nil })
        try await transport.deleteZone()
        #expect(await cloud.audio(account: account).count == 1)
        await cloud.removeZone(account: account, reason: .deleted)
        #expect(try await transfer.probe([d.recordingID]) == [d.recordingID: .present(d)])
    }

    @Test func aPurgeDropsTheBlobs() async throws {
        defer { cleanup() }
        let (file, d) = try staged()
        try await upload(file, d)
        await cloud.removeZone(account: account, reason: .purged)
        #expect(await cloud.audio(account: account).isEmpty)
        #expect(try await transfer.probe([d.recordingID]) == [d.recordingID: .absent])
    }

    @Test func anEncryptedDataResetMakesTheBlobsUnreadable() async throws {
        defer { cleanup() }
        let (file, d) = try staged()
        try await upload(file, d)
        await cloud.removeZone(account: account, reason: .encryptedDataReset)
        #expect(await cloud.audio(account: account)[d.recordingID]?.unreadable == true)
        #expect(try await transfer.probe([d.recordingID]) == [d.recordingID: .unreadable])
        #expect(try await transfer.probeFully(d.recordingID) == .unreadable)
        await #expect(throws: AudioTransferError.other(code: 0)) { try await download(d.recordingID) }
        // Its holder deletes it and uploads again.
        await #expect(throws: AudioTransferError.other(code: 14)) { try await upload(file, d) }
        try await transfer.delete([d.recordingID])
        #expect(try await upload(file, d) == .uploaded)
        #expect(try await transfer.probe([d.recordingID]) == [d.recordingID: .present(d)])
    }

    @Test func aCloudBuiltWithAudioAppliesItsZoneRemovals() async throws {
        let d = AudioDescriptor(recordingID: UUID(), format: .pcm16kMono, bytes: 3, sha256: "x", duration: 0)
        let stored = FakeCloud.StoredAudio(descriptor: d, data: Data([1, 2, 3]), created: Seeds.Dates.d)
        let built = FakeCloud(accounts: ["a": [], "b": [], "c": [], "d": []],
                              removed: ["b": .deleted, "c": .purged, "d": .encryptedDataReset],
                              audio: ["a": [stored], "b": [stored], "c": [stored], "d": [stored]])
        #expect(await built.audio(account: "a") == [d.recordingID: stored])
        #expect(await built.audio(account: "b") == [d.recordingID: stored])
        #expect(await built.audio(account: "c").isEmpty)
        #expect(await built.audio(account: "d")[d.recordingID]?.unreadable == true)
        let injected = FakeCloud()
        await injected.injectAudio(account: "a", d, data: Data([9]), created: Seeds.Dates.d)
        #expect(await injected.audio(account: "a")[d.recordingID]?.data == Data([9]))
    }

    // MARK: The hook and cancellation

    @Test func theHookHoldsAnOperationAfterItsEffect() async throws {
        defer { cleanup() }
        let gate = HookGate()
        let (file, d) = try staged()
        await cloud.setAudioHook { op, id in if op == .upload { await gate.hold(id) } }
        let transfer = self.transfer
        let upload = Task {
            try await transfer.upload(file, descriptor: d, options: Self.automatic, progress: { _ in })
        }
        await gate.waitForArrival()
        #expect(await cloud.audio(account: account)[d.recordingID] != nil)     // stored while the reply is held
        await gate.release()
        #expect(try await upload.value == .uploaded)
        #expect(await gate.seen == [d.recordingID])
        await cloud.setAudioHook(nil)
        #expect(try await self.upload(file, d) == .alreadyThere(d))
    }

    @Test func cancellationIsHonouredBeforeAndAfterTheCloud() async throws {
        defer { cleanup() }
        let (file, d) = try staged()
        let transfer = self.transfer
        // Cancelled before: nothing reaches the cloud.
        let early = Task {
            while !Task.isCancelled { await Task.yield() }
            return try await transfer.upload(file, descriptor: d, options: Self.automatic, progress: { _ in })
        }
        early.cancel()
        await #expect(throws: AudioTransferError.cancelled) { try await early.value }
        #expect(await cloud.audio(account: account).isEmpty)
        #expect(await transfer.uploads == 0)

        // Cancelled while held: the blob stays, the call throws `.cancelled`.
        let gate = HookGate()
        await cloud.setAudioHook { op, id in if op == .upload { await gate.hold(id) } }
        let held = Task {
            try await transfer.upload(file, descriptor: d, options: Self.automatic, progress: { _ in })
        }
        await gate.waitForArrival()
        held.cancel()
        await gate.release()
        await #expect(throws: AudioTransferError.cancelled) { try await held.value }
        #expect(await cloud.audio(account: account)[d.recordingID] != nil)

        // A download cancelled while held writes nothing.
        let to = dir.appendingPathComponent("held.part")
        let downloadGate = HookGate()
        await cloud.setAudioHook { op, id in if op == .download { await downloadGate.hold(id) } }
        let download = Task {
            try await transfer.download(d.recordingID, to: to, options: Self.automatic, progress: { _ in })
        }
        await downloadGate.waitForArrival()
        download.cancel()
        await downloadGate.release()
        await #expect(throws: AudioTransferError.cancelled) { try await download.value }
        #expect(!FileManager.default.fileExists(atPath: to.path))
    }

    @Test func theHookSeesEveryIdAndTheListing() async throws {
        defer { cleanup() }
        let seen = Mutex<[(FakeCloud.AudioOp, UUID)]>([])
        await cloud.setAudioHook { op, id in seen.withLock { $0.append((op, id)) } }
        let a = UUID(), b = UUID()
        _ = try await transfer.probe([a, b])
        _ = try await transfer.listAll()
        try await transfer.delete([b])
        let got = seen.withLock { $0 }
        #expect(got.map(\.0) == [.probe, .probe, .list, .delete])
        #expect(got.map(\.1) == [a, b, FakeCloud.audioListID, b])
    }

    // MARK: Device conditions

    @Test func fakeDeviceConditionsReportWhatTheTestSets() {
        let conditions = FakeDeviceConditions()
        #expect(conditions.network == .unmetered && !conditions.lowPowerMode && conditions.free == nil)
        let fired = Mutex(0)
        conditions.setOnChange { fired.withLock { $0 += 1 } }
        conditions.network = .metered
        conditions.lowPowerMode = true
        conditions.free = 42
        #expect(fired.withLock { $0 } == 0)                    // setting a value does not notify
        conditions.change()
        #expect(fired.withLock { $0 } == 1)
        #expect(conditions.network == .metered && conditions.lowPowerMode)
        #expect(conditions.freeBytes(at: dir, opportunistic: true) == 42)
        #expect(conditions.freeBytes(at: dir, opportunistic: false) == 42)
    }

    @Test func liveDeviceConditionsReadTheVolume() {
        let conditions = LiveDeviceConditions()
        let temp = FileManager.default.temporaryDirectory
        #expect((conditions.freeBytes(at: temp, opportunistic: false) ?? 0) > 0)
        #expect(conditions.freeBytes(at: temp, opportunistic: true) != nil)
        conditions.setOnChange {}
        _ = conditions.network
        _ = conditions.lowPowerMode
    }
}

/// Holds hooked operations until released, and tells the test when one arrived.
private actor HookGate {
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var seen: [UUID] = []

    func hold(_ id: UUID) async {
        seen.append(id)
        guard !open else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        open = true
        for w in waiters { w.resume() }
        waiters = []
    }

    func waitForArrival() async {
        while seen.isEmpty {
            try? await Task.sleep(for: .milliseconds(2))
        }
    }
}
