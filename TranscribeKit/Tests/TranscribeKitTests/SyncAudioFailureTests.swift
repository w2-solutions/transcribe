import AVFoundation
import Foundation
import SwiftData
import Synchronization
import Testing
import TranscribeCore
@testable import TranscribeFakes
@testable import TranscribeKit

/// Counts what the encoder was asked to do, around `CopyAudioEncoder`.
final class CountingEncoder: AudioEncoding, Sendable {
    private let inner = CopyAudioEncoder()
    private let counts = Mutex((encodes: 0, describes: 0))
    var encodes: Int { counts.withLock { $0.encodes } }
    var describes: Int { counts.withLock { $0.describes } }

    func encode(wav: URL, to destination: URL, recordingID: UUID) async throws -> AudioDescriptor {
        counts.withLock { $0.encodes += 1 }
        return try await inner.encode(wav: wav, to: destination, recordingID: recordingID)
    }

    func describe(_ file: URL, recordingID: UUID) async throws -> AudioDescriptor {
        counts.withLock { $0.describes += 1 }
        return try await inner.describe(file, recordingID: recordingID)
    }
}

/// A test fault at one of audio sync's fault points.
struct AudioFault: Error {}

/// `FakeAudioTransfer` whose downloads run `afterDownload` once the file is written and before they return: what lands
/// on the main actor between a finished transfer and the job's checks of the file.
final class AfterDownloadTransfer: AudioTransfer, @unchecked Sendable {
    let inner: FakeAudioTransfer
    let afterDownload: @Sendable (UUID) async -> Void

    init(_ inner: FakeAudioTransfer, afterDownload: @escaping @Sendable (UUID) async -> Void) {
        self.inner = inner
        self.afterDownload = afterDownload
    }

    func probe(_ ids: [UUID]) async throws -> [UUID: AudioPresence] { try await inner.probe(ids) }
    func probeFully(_ id: UUID) async throws -> AudioPresence { try await inner.probeFully(id) }
    func recordingRecordsExist(_ ids: [UUID]) async throws -> Set<UUID> { try await inner.recordingRecordsExist(ids) }
    func upload(_ file: URL, descriptor: AudioDescriptor, options: AudioTransferOptions,
                progress: @escaping @Sendable (Double) -> Void) async throws -> AudioUploadOutcome {
        try await inner.upload(file, descriptor: descriptor, options: options, progress: progress)
    }
    func download(_ id: UUID, to destination: URL, options: AudioTransferOptions,
                  progress: @escaping @Sendable (Double) -> Void) async throws -> AudioDescriptor {
        let d = try await inner.download(id, to: destination, options: options, progress: progress)
        await afterDownload(id)
        return d
    }
    func delete(_ ids: [UUID]) async throws { try await inner.delete(ids) }
    func listAll() async throws -> [AudioListing] { try await inner.listAll() }
}

extension AudioScenario {
    /// A recording made on a device that never syncs: its records and its audio as another device would upload them.
    static func foreign(clock: TestClock) async throws
        -> (records: [SyncRecord], audio: AudioDescriptor, data: Data, cleanup: () -> Void) {
        let maker = try FakeDevice("maker", cloud: FakeCloud(), clock: clock)
        let id = try maker.record([], audioSeconds: 2)
        let url = maker.paths.audioURL(fileName: "\(id.uuidString).wav")
        let d = try await CopyAudioEncoder().describe(url, recordingID: id)
        let records = try SyncSnapshot.records(maker.context).filter { $0.id.entityID == id || $0.id.type == .speaker }
        return (records, d, try Data(contentsOf: url), { maker.cleanup() })
    }

    /// The size of a device's own audio file for `id`.
    static func fileSize(_ d: FakeDevice, _ id: UUID) throws -> Int64 {
        let r = try #require(d.recording(id))
        return Int64(try Data(contentsOf: d.paths.audioURL(fileName: r.audioFileName)).count)
    }

    /// The audio row's facts for `id` on a device.
    @MainActor
    static func facts(_ d: FakeDevice, _ id: UUID) -> AudioRowFacts? {
        d.stateRows().first { $0.isAudioRow && $0.entityID == id }?.audioFacts
    }
}

extension SyncSuites {
    /// What goes wrong on the way (§5.1 "Sync: audio failures"): a full iCloud, lost replies, crashes at the fault
    /// points, interrupted and corrupt downloads, unreadable blobs.
    @Suite("Sync: audio failures")
    @MainActor
    struct SyncAudioFailureTests {
        typealias S = AudioScenario
        let account = "account-1"

        // MARK: A full iCloud

        @Test func iCloudFullPausesAudioUploadsOnly() async throws {
            let (cloud, clock, a, b) = try await S.pair()
            defer { a.cleanup(); b.cleanup() }
            // B's recording reaches iCloud before the quota bites; A waits on mobile data meanwhile.
            let fromB = try b.record([], audioSeconds: 2)
            a.conditions.network = .metered
            var ids: [UUID] = []
            for _ in 0..<3 {
                ids.append(try a.record([], audioSeconds: 2))
                clock.advance(60)
            }
            await a.sync.enable()
            await b.sync.enable()
            await settleAudio([a, b])
            #expect(await S.blobIDs(cloud) == [fromB])
            #expect(await a.transfer?.uploads == 0)

            // Room for B's file and two of A's: A's oldest (uploaded last) is refused.
            let size = try S.fileSize(a, ids[0])
            await cloud.setAudioQuota(bytes: try S.fileSize(b, fromB) + 2 * size + 1_000)
            a.conditions.network = .unmetered
            await a.audio.drain()
            #expect(await S.blobIDs(cloud) == [fromB, ids[2], ids[1]])
            #expect(await a.transfer?.calls.filter { $0.op == .upload }.map(\.id) == [ids[2], ids[1], ids[0]])
            #expect(a.audio.summary.wait == .iCloudFull)
            #expect(a.audio.summary.uploadsLeft == 1)
            #expect(!a.sync.status.isPaused)
            // Downloads continue.
            #expect(a.store.hasLocalAudio(try #require(a.recording(fromB))))
            #expect(await a.transfer?.downloads == 1)
            // No further upload is tried while the block lasts.
            await a.audio.drain()
            #expect(await a.transfer?.uploads == 3)

            // Transcripts and names still sync.
            try a.store.rename(id: ids[0], title: "While iCloud is full")
            await a.sync.flushAndEnqueue()
            await a.sync.sync(fullScan: false)
            await b.sync.sync(fullScan: false)
            #expect(b.recording(ids[0])?.title == "While iCloud is full")
            #expect(!a.sync.status.isPaused && !b.sync.status.isPaused)

            // Sync Now tries again (still full: refused again, still blocked).
            let before = await a.transfer?.uploads ?? 0
            await a.sync.syncNow()
            await a.audio.drain()
            #expect(await a.transfer?.uploads == before + 1)
            #expect(a.audio.summary.wait == .iCloudFull)
            // With room again, Sync Now uploads it.
            await cloud.setAudioQuota(bytes: nil)
            await a.sync.syncNow()
            await a.audio.drain()
            #expect(await S.blobIDs(cloud) == Set([fromB] + ids))
            #expect(a.audio.summary.wait == nil)
            #expect(a.audio.summary.uploadsLeft == 0)
        }

        @Test func quotaBlockEndsAfter24Hours() async throws {
            let (cloud, clock, a, _) = try await S.pair()
            defer { a.cleanup() }
            let id = try a.record([], audioSeconds: 2)
            await cloud.setAudioQuota(bytes: 0)
            await a.sync.enable()
            await a.audio.drain()
            #expect(await a.transfer?.uploads == 1)
            #expect(a.audio.summary.wait == .iCloudFull)
            await cloud.setAudioQuota(bytes: nil)
            // Sync rounds that are not Sync Now leave the block alone for 24 hours.
            clock.advance(23 * 3_600)
            await a.sync.sync(fullScan: false)
            await a.audio.drain()
            #expect(await a.transfer?.uploads == 1)
            #expect(await S.blobIDs(cloud).isEmpty)
            clock.advance(3_601)
            await a.sync.sync(fullScan: false)
            await a.audio.drain()
            #expect(await a.transfer?.uploads == 2)
            #expect(await S.blobIDs(cloud) == [id])
            #expect(a.audio.summary.wait == nil)
        }

        @Test func aFullICloudPausesEverythingAndBothResume() async throws {
            let (cloud, _, a, b) = try await S.pair()
            defer { a.cleanup(); b.cleanup() }
            // r0's record is on the server; its audio waits for the switch.
            a.settings.syncAudio = false
            let r0 = try a.record([], audioSeconds: 2)
            await a.sync.enable()
            await b.sync.enable()
            await settleAudio([a, b])
            #expect(a.stateRow(SyncRecordID(type: .recording, entityID: r0))?.systemFields != nil)

            await cloud.setQuotaFull(true)
            let r1 = try a.record([], audioSeconds: 2)
            a.settings.syncAudio = true
            a.audio.settingChanged()
            await a.sync.syncNow()
            await a.audio.drain()
            #expect(a.sync.status == .paused(.quotaFull))
            #expect(await S.blobIDs(cloud).isEmpty)
            #expect(await cloud.record(account: account, recordName: "rec.\(r1.uuidString)") == nil)

            // Space again: Sync Now resumes the records and the audio.
            await cloud.setQuotaFull(false)
            await a.sync.syncNow()
            await settleAudio([a, b])
            #expect(!a.sync.status.isPaused)
            #expect(await S.blobIDs(cloud) == [r0, r1])
            #expect(await S.markerIDs(cloud) == [r0, r1])
            for id in [r0, r1] { #expect(b.store.hasLocalAudio(try #require(b.recording(id)))) }
            await expectAudioConverged([a, b])
        }

        // MARK: Retries and lost replies

        @Test func retryableUploadBacksOff() async throws {
            let (cloud, clock, a, _) = try await S.pair()
            defer { a.cleanup() }
            let id = try a.record([], audioSeconds: 2)
            await cloud.failNextAudio(.upload, id, with: .retryable(retryAfter: nil))
            await a.sync.enable()
            await a.audio.drain()
            #expect(await a.transfer?.uploads == 1)
            #expect(await S.blobIDs(cloud).isEmpty)
            #expect(a.audio.failures[id] == 1)
            clock.advance(59)
            await a.sync.sync(fullScan: false)
            await a.audio.drain()
            #expect(await a.transfer?.uploads == 1)
            clock.advance(2)
            await a.audio.drain()
            #expect(await a.transfer?.uploads == 2)
            #expect(await S.blobIDs(cloud) == [id])
            #expect(await S.markerIDs(cloud) == [id])
            #expect(await a.transfer?.bytesUp == (try S.fileSize(a, id)))
            #expect(a.audio.failures[id] == nil)
        }

        @Test func aCrashAfterTheBlobUploadDoesNotUploadTwice() async throws {
            let (cloud, _, a, _) = try await S.pair()
            defer { a.cleanup() }
            let id = try a.record([], audioSeconds: 2)
            a.audio.fault = { if $0 == .afterUploadBeforeRowSave { throw AudioFault() } }
            await a.sync.enable()
            await a.audio.drain()
            #expect(a.audio.crashed)
            #expect(await S.blobIDs(cloud) == [id])
            #expect(await S.markerIDs(cloud).isEmpty)
            #expect(S.facts(a, id) == nil)
            #expect(await a.transfer?.bytesUp == (try S.fileSize(a, id)))

            await a.relaunch()
            await a.sync.start()
            await settleAudio([a])
            // The probe found the blob: adopted, nothing sent again.
            #expect(await a.transfer?.uploads == 0)
            #expect(await a.transfer?.bytesUp == 0)
            #expect(await S.markerIDs(cloud) == [id])
            #expect(S.facts(a, id)?.marker == .onServer)
            #expect(try FileManager.default.contentsOfDirectory(atPath: a.paths.audioOutgoingDirectory.path).isEmpty)
        }

        @Test func theServerKeptItButTheReplyWasLost() async throws {
            let (cloud, clock, a, _) = try await S.pair()
            defer { a.cleanup() }
            let id = try a.record([], audioSeconds: 2)
            await cloud.commitThenLoseReply(id)
            await a.sync.enable()
            await a.audio.drain()
            #expect(await a.transfer?.uploads == 1)
            #expect(await S.blobIDs(cloud) == [id])
            #expect(await S.markerIDs(cloud).isEmpty)
            clock.advance(61)
            await a.audio.drain()
            await settleAudio([a])
            #expect(await a.transfer?.uploads == 1)        // the next run's probe adopted it
            #expect(await a.transfer?.bytesUp == (try S.fileSize(a, id)))
            #expect(await S.blobIDs(cloud) == [id])
            #expect(await S.markerIDs(cloud) == [id])
        }

        // MARK: Downloads that go wrong

        @Test func aCrashAfterTheMoveIsAdoptedAtLaunch() async throws {
            let (_, _, a, b) = try await S.pair(aEncoder: AACAudioEncoder())
            defer { a.cleanup(); b.cleanup() }
            let id = try a.record([], audioSeconds: 3)
            b.audio.fault = { if $0 == .afterMoveBeforeRename { throw AudioFault() } }
            await a.sync.enable()
            await b.sync.enable()
            await settleAudio([a, b])
            #expect(b.audio.crashed)
            let copy = b.paths.audioURL(fileName: "\(id.uuidString).m4a")
            #expect(FileManager.default.fileExists(atPath: copy.path))
            let before = try #require(b.recording(id))
            #expect(before.audioFileName == "\(id.uuidString).wav")
            #expect(!b.store.hasLocalAudio(before))

            await b.relaunch()     // runs adoptStrayDownloads, as the app's launch does
            let r = try #require(b.recording(id))
            #expect(r.audioFileName == "\(id.uuidString).m4a")
            #expect(b.store.hasLocalAudio(r))
            // The orphan sweep that follows keeps the file its row names.
            #expect(try b.store.sweepOrphanAudio(minimumAge: 0, now: Date().addingTimeInterval(86_400)) == 0)
            #expect(FileManager.default.fileExists(atPath: copy.path))
            await b.sync.start()
            await settleAudio([a, b])
            #expect(await b.transfer?.downloads == 0)
            #expect(b.audio.state(of: r) == .local)
        }

        @Test func anInterruptedDownloadLeavesNothingPlayable() async throws {
            let (cloud, _, a, b) = try await S.pair()
            defer { a.cleanup(); b.cleanup() }
            b.conditions.network = .metered
            let id = try a.record([], audioSeconds: 2)
            await a.sync.enable()
            await b.sync.enable()
            await settleAudio([a, b])
            await cloud.failNextAudio(.download, id, with: .networkUnavailable)
            b.conditions.network = .unmetered
            await b.audio.drain()
            #expect(await b.transfer?.downloads == 1)
            let r = try #require(b.recording(id))
            #expect(!b.store.hasLocalAudio(r))
            let audioFiles = try FileManager.default.contentsOfDirectory(atPath: b.paths.audioDirectory.path)
            #expect(!audioFiles.contains { $0.hasPrefix(id.uuidString) })
            // The half-written part stays in AudioIncoming/ only.
            #expect(try FileManager.default.contentsOfDirectory(atPath: b.paths.audioIncomingDirectory.path)
                    == ["\(id.uuidString).wav.part"])
            #expect(b.audio.state(of: r) != .local)

            await b.relaunch()     // prepareOnLaunch empties AudioIncoming/
            #expect(try FileManager.default.contentsOfDirectory(atPath: b.paths.audioIncomingDirectory.path).isEmpty)
            await b.sync.start()
            await b.audio.drain()
            #expect(b.store.hasLocalAudio(try #require(b.recording(id))))
            #expect(try await S.sha(b.paths.audioURL(fileName: "\(id.uuidString).wav"))
                    == S.sha(a.paths.audioURL(fileName: "\(id.uuidString).wav")))
        }

        @Test func aCorruptDownloadIsRejected() async throws {
            let (cloud, _, a, b) = try await S.pair()
            defer { a.cleanup(); b.cleanup() }
            b.conditions.network = .metered
            let id = try a.record([], audioSeconds: 2)
            await a.sync.enable()
            await b.sync.enable()
            await settleAudio([a, b])
            await cloud.corruptNextDownload(id)
            b.conditions.network = .unmetered
            await b.audio.drain()
            let r = try #require(b.recording(id))
            let bytes = try #require(S.facts(b, id)).descriptor.bytes
            #expect(b.audio.state(of: r) == .failed(bytes: bytes))
            #expect(!b.store.hasLocalAudio(r))
            for dir in [b.paths.audioDirectory, b.paths.audioIncomingDirectory] {
                #expect(!(try FileManager.default.contentsOfDirectory(atPath: dir.path)).contains { $0.hasPrefix(id.uuidString) })
            }
            b.audio.downloadNow(id)
            await b.audio.drain()
            #expect(b.store.hasLocalAudio(r))
            #expect(b.audio.state(of: r) == .local)
            #expect(try await S.sha(b.paths.audioURL(fileName: r.audioFileName))
                    == S.sha(a.paths.audioURL(fileName: "\(id.uuidString).wav")))
            #expect(await b.transfer?.downloads == 2)
        }

        /// A download cancelled once its transfer returned, while its file is being checked (pre-empted by Download Now,
        /// the switch, the background time ending) is no failure: no "Couldn't download", no backoff; it runs again.
        @Test func aDownloadCancelledWhileItsFileIsCheckedIsNoFailure() async throws {
            // B is an iPhone: A's 40-day-old recording downloads only when asked; the recent one by itself.
            let (_, clock, a, b) = try await S.pair(bPlatform: .iPhone)
            defer { a.cleanup(); b.cleanup() }
            let old = try a.record([], at: clock.date.addingTimeInterval(-40 * 86_400), audioSeconds: 2)
            let recent = try a.record([], audioSeconds: 2)
            b.conditions.network = .metered      // automatic downloads wait until the test lets them go
            await a.sync.enable()
            await b.sync.enable()
            await settleAudio([a, b])
            let fired = Mutex(false)
            b.wrapTransfer = { [weak b] inner in
                AfterDownloadTransfer(inner) { id in
                    guard id == recent, fired.withLock({ f in defer { f = true }; return !f }) else { return }
                    await MainActor.run { b?.audio.downloadNow(old) }     // pre-empts the automatic download of `recent`
                }
            }
            await b.relaunch()
            await b.sync.start()
            b.conditions.network = .unmetered
            await b.audio.drain()
            let r = try #require(b.recording(recent))
            #expect(b.audio.failedDownloads.isEmpty)
            #expect(b.audio.failures[recent] == nil && b.audio.retryAt[recent] == nil)
            #expect(b.store.hasLocalAudio(try #require(b.recording(old))))
            #expect(b.store.hasLocalAudio(r))
            #expect(b.audio.state(of: r) == .local)
            #expect(await b.transfer?.calls.map(\.id) == [recent, old, recent])
        }

        /// Download Now whose download fails shows "Couldn't download the audio" with Try Again and stops there: it is
        /// not retried at once (a forced download skips backoff), and over mobile data not by itself either.
        @Test func aDownloadNowThatFailsWaitsForTryAgain() async throws {
            let (cloud, clock, a, b) = try await S.pair()
            defer { a.cleanup(); b.cleanup() }
            b.conditions.network = .metered      // automatic downloads wait; only Download Now goes
            let id = try a.record([], audioSeconds: 2)
            await a.sync.enable()
            await b.sync.enable()
            await settleAudio([a, b])
            #expect(await b.transfer?.downloads == 0)
            // The next two downloads of it fail; the third goes through.
            let remaining = Mutex(2)
            await cloud.failNextAudio(.download, id, with: .other(code: 1))
            await cloud.setAudioHook { op, opID in
                guard op == .download, opID == id, remaining.withLock({ $0 -= 1; return $0 > 0 }) else { return }
                await cloud.failNextAudio(.download, id, with: .other(code: 1))
            }
            let r = try #require(b.recording(id))
            let bytes = try #require(S.facts(b, id)).descriptor.bytes

            b.audio.downloadNow(id)
            await b.audio.drain()
            #expect(await b.transfer?.downloads == 1)
            #expect(b.audio.state(of: r) == .failed(bytes: bytes))
            #expect(DeviceCopy(platform: .mac, syncOn: true, audioSyncOn: true).audioBanner(b.audio.state(of: r))?.action
                    == .tryAgain)
            #expect(!b.audio.forced.contains(id))
            #expect(b.audio.failures[id] == 1)
            // Past the backoff, still on mobile data: nothing by itself.
            clock.advance(61)
            await b.sync.syncNow()
            await b.audio.drain()
            #expect(await b.transfer?.downloads == 1)

            // Try Again: it fails once more and stops again; the next Try Again downloads it.
            b.audio.downloadNow(id)
            await b.audio.drain()
            #expect(await b.transfer?.downloads == 2)
            #expect(b.audio.state(of: r) == .failed(bytes: bytes))
            b.audio.downloadNow(id)
            await b.audio.drain()
            await cloud.setAudioHook(nil)
            #expect(await b.transfer?.downloads == 3)
            #expect(b.store.hasLocalAudio(r))
            #expect(b.audio.state(of: r) == .local)
            #expect(await b.transfer?.options(.download, id).map(\.userInitiated) == [true, true, true])
        }

        @Test func aMarkerThatDisagreesWithItsBlobStillDownloads() async throws {
            let (cloud, clock, _, b) = try await S.pair()
            defer { b.cleanup() }
            let foreign = try await S.foreign(clock: clock)
            defer { foreign.cleanup() }
            let id = foreign.audio.recordingID
            await cloud.injectAudio(account: account, foreign.audio, data: foreign.data, created: clock.date)
            var wrong = foreign.audio
            wrong.sha256 = String(repeating: "b", count: 64)
            wrong.bytes += 1_000
            await cloud.inject(account: account, AudioMarker.record(wrong))
            for record in foreign.records { await cloud.inject(account: account, record) }
            await b.sync.enable()
            await settleAudio([b])
            let r = try #require(b.recording(id))
            #expect(b.store.hasLocalAudio(r))
            #expect(try Data(contentsOf: b.paths.audioURL(fileName: r.audioFileName)) == foreign.data)
            #expect(S.facts(b, id)?.descriptor == foreign.audio)
            #expect(b.audio.failures[id] == nil)
            #expect(await b.transfer?.downloads == 1)
        }

        // MARK: Uploads that go wrong

        @Test func anOutgoingFileThatChangedIsStagedAgain() async throws {
            let encoder = CountingEncoder()
            let (cloud, clock, a, _) = try await S.pair(aEncoder: encoder)
            defer { a.cleanup() }
            let id = try a.record([], audioSeconds: 2)
            await cloud.failNextAudio(.upload, id, with: .sourceChanged)
            await a.sync.enable()
            await a.audio.drain()
            #expect(await a.transfer?.uploads == 1)
            #expect(encoder.encodes == 1)
            #expect(await S.blobIDs(cloud).isEmpty)
            #expect(try FileManager.default.contentsOfDirectory(atPath: a.paths.audioOutgoingDirectory.path).isEmpty)
            clock.advance(61)
            await a.audio.drain()
            #expect(encoder.encodes == 2)
            #expect(await a.transfer?.uploads == 2)
            #expect(await S.blobIDs(cloud) == [id])
            let stored = try #require(await cloud.audio(account: account)[id])
            #expect(stored.data == (try Data(contentsOf: a.paths.audioURL(fileName: "\(id.uuidString).wav"))))
            #expect(try FileManager.default.contentsOfDirectory(atPath: a.paths.audioOutgoingDirectory.path).isEmpty)
        }

        @Test func aTooLongRecordingIsNotUploaded() async throws {
            let (cloud, _, a, _) = try await S.pair()
            defer { a.cleanup() }
            let long = try a.record([])
            let r = try #require(a.recording(long))
            r.duration = 60_000      // 240 MB at 4 kB/s: over the 200 MB cap
            try a.context.save()
            let short = try a.record([], audioSeconds: 2)
            await a.sync.enable()
            await settleAudio([a])
            #expect(await S.blobIDs(cloud) == [short])
            #expect(await a.transfer?.options(.upload, long).isEmpty == true)
            #expect(a.audio.summary.tooLong == 1)
            #expect(a.audio.summary.uploadsLeft == 0)
            #expect(SyncCopy.audioStatusLine(a.audio.summary, platform: .iPhone)
                    == "Audio up to date\n1 recording is too long to sync its audio")
        }

        @Test func twoDevicesHoldingTheSameAudioKeepOne() async throws {
            let (cloud, _, a, b) = try await S.pair()
            defer { a.cleanup(); b.cleanup() }
            let id = try a.record([], audioSeconds: 2)
            await a.sync.enable()
            await b.sync.enable()
            await settleAudio([a, b])
            #expect(b.store.hasLocalAudio(try #require(b.recording(id))))
            let uploadsBefore = await a.transfer?.options(.upload, id).count ?? 0
            let bytesBefore = await a.transfer?.bytesUp ?? 0
            #expect(uploadsBefore == 1)
            try await a.sync.disable(removeCloudCopy: true)
            await b.sync.syncNow()
            #expect(b.sync.status == .paused(.zoneRemoved))
            #expect(await S.blobIDs(cloud).isEmpty)

            // Both turn sync on again, and both find no audio in iCloud before either uploads.
            a.audio.isInFront = { false }
            b.audio.isInFront = { false }
            await a.sync.enable()
            await b.sync.enable()
            await settle([a, b])
            let hold = AudioHold()
            await cloud.setAudioHook { op, _ in if op == .probe { await hold.wait() } }
            a.audio.isInFront = { true }
            b.audio.isInFront = { true }
            a.audio.pump()
            b.audio.pump()
            await waitUntil("both probes") { await hold.arrived == 2 }
            await hold.release()
            await a.audio.drain()
            await b.audio.drain()
            await cloud.setAudioHook(nil)
            await settleAudio([a, b])
            #expect(await S.blobIDs(cloud) == [id])
            #expect(await S.markerIDs(cloud) == [id])
            // Each tried once after the removal; the blob was stored once: the second upload met it and adopted it.
            #expect(await a.transfer?.options(.upload, id).count == uploadsBefore + 1)
            #expect(await b.transfer?.options(.upload, id).count == 1)
            let up = (await a.transfer?.bytesUp ?? 0) + (await b.transfer?.bytesUp ?? 0)
            #expect(up == bytesBefore + (try S.fileSize(a, id)))
            let fa = try #require(S.facts(a, id)), fb = try #require(S.facts(b, id))
            #expect(fa.descriptor == fb.descriptor)
            #expect(fa.marker == .onServer && fb.marker == .onServer)
            #expect(fa.markerVersion == fb.markerVersion)
            await expectAudioConverged([a, b])
        }

        @Test func unreadableAudioIsReplacedByItsHolder() async throws {
            let (cloud, _, a, b) = try await S.pair()
            defer { a.cleanup(); b.cleanup() }
            b.conditions.network = .metered
            let id = try a.record([], audioSeconds: 2)
            await a.sync.enable()
            await b.sync.enable()
            await settleAudio([a, b])
            #expect(!b.store.hasLocalAudio(try #require(b.recording(id))))
            let ops = Mutex<[FakeCloud.AudioOp]>([])
            await cloud.setAudioHook { op, opID in if opID == id { ops.withLock { $0.append(op) } } }
            await cloud.removeZone(account: account, reason: .encryptedDataReset)
            #expect(await cloud.audio(account: account)[id]?.unreadable == true)

            // Each device's next fetch sees the reset and turns sync on again by itself.
            await a.sync.syncNow()
            await b.sync.syncNow()
            await waitUntil("both to run again") { a.sync.running && b.sync.running }
            b.conditions.network = .unmetered
            await settleAudio([a, b])
            await cloud.setAudioHook(nil)
            let seen = ops.withLock { $0 }
            let full = try #require(seen.firstIndex(of: .probeFully))
            let delete = try #require(seen.firstIndex(of: .delete))
            let upload = try #require(seen.lastIndex(of: .upload))
            #expect(full < delete && delete < upload)
            #expect(await cloud.audio(account: account)[id]?.unreadable == false)
            #expect(await S.markerIDs(cloud) == [id])
            let r = try #require(b.recording(id))
            #expect(b.store.hasLocalAudio(r))
            #expect(try await S.sha(b.paths.audioURL(fileName: r.audioFileName))
                    == S.sha(a.paths.audioURL(fileName: "\(id.uuidString).wav")))
            await expectAudioConverged([a, b])
        }

        @Test func anUnreadableProbeOfAGoodBlobDeletesNothing() async throws {
            let (cloud, clock, a, _) = try await S.pair()
            defer { a.cleanup() }
            let id = try a.record([], audioSeconds: 2)
            let url = a.paths.audioURL(fileName: "\(id.uuidString).wav")
            let d = try await CopyAudioEncoder().describe(url, recordingID: id)
            await cloud.injectAudio(account: account, d, data: try Data(contentsOf: url), created: clock.date)
            await cloud.failProbeAsUnreadable(id)
            await a.sync.enable()
            await settleAudio([a])
            #expect(await a.transfer?.deletes == 0)
            #expect(await a.transfer?.uploads == 0)
            #expect(await a.transfer?.probes == 2)        // the metadata probe, then the full one
            #expect(await S.blobIDs(cloud) == [id])
            #expect(await S.markerIDs(cloud) == [id])
            #expect(S.facts(a, id)?.descriptor == d)
        }

        // MARK: No timer

        @Test func noAudioTimerExists() async throws {
            let (_, _, a, _) = try await S.pair()
            defer { a.cleanup() }
            let plain = SyncCoordinator(store: a.store, transport: FakeTransport(cloud: a.cloud), settings: a.settings,
                                        clock: a.clock.appClock, modelKey: nil)
            let withAudio = SyncCoordinator(
                store: a.store, transport: FakeTransport(cloud: a.cloud), settings: a.settings, clock: a.clock.appClock,
                modelKey: nil, audio: AudioSyncDependencies(transfer: try #require(a.transfer), encoder: CopyAudioEncoder(),
                                                            conditions: FakeDeviceConditions(), platform: .iPhone))
            #expect(withAudio.audio != nil)
            #expect(withAudio.foregroundPollInterval == .seconds(60))
            #expect(withAudio.followUpDelays == [.seconds(3), .seconds(15), .seconds(60), .seconds(300)])
            #expect(withAudio.foregroundPollInterval == plain.foregroundPollInterval)
            #expect(withAudio.followUpDelays == plain.followUpDelays)
            #expect(withAudio.minRefreshGap == plain.minRefreshGap)
            #expect(withAudio.debounce == plain.debounce)
            // Between triggers nothing of audio sync is left running.
            try a.record([], audioSeconds: 2)
            await a.sync.enable()
            await a.audio.drain()
            #expect(a.audio.loopTask == nil)
            #expect(a.audio.current == nil)
        }
    }
}
