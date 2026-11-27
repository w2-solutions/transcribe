import AVFoundation
import Foundation
import Observation
import SwiftData
import Synchronization
import Testing
import TranscribeCore
@testable import TranscribeFakes
@testable import TranscribeKit

/// Holds audio requests in the fake cloud's hook until the test releases them (`FakeCloud.setAudioHook`).
actor AudioHold {
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var released = false
    private(set) var arrived = 0

    func wait() async {
        arrived += 1
        guard !released else { return }
        await withCheckedContinuation { waiting.append($0) }
    }

    func release() {
        released = true
        for c in waiting { c.resume() }
        waiting = []
    }
}

/// Like `AudioHold`, but a waiter whose task is cancelled stops waiting, as a cancelled CloudKit operation ends.
actor CancellableHold {
    private var released = false
    private(set) var arrived = 0

    func wait() async {
        arrived += 1
        while !released && !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(1))
        }
    }

    func release() { released = true }
}

/// `CopyAudioEncoder` that, once armed, holds the next encode until the test releases it: an upload caught while its
/// transfer copy is staged, before anything reaches the cloud.
final class HeldEncoder: AudioEncoding, Sendable {
    private let inner = CopyAudioEncoder()
    private let armed = Mutex<AudioHold?>(nil)

    /// The next encode waits on the returned hold.
    func arm() -> AudioHold {
        let hold = AudioHold()
        armed.withLock { $0 = hold }
        return hold
    }

    func encode(wav: URL, to destination: URL, recordingID: UUID) async throws -> AudioDescriptor {
        if let hold = armed.withLock({ h -> AudioHold? in defer { h = nil }; return h }) { await hold.wait() }
        return try await inner.encode(wav: wav, to: destination, recordingID: recordingID)
    }

    func describe(_ file: URL, recordingID: UUID) async throws -> AudioDescriptor {
        try await inner.describe(file, recordingID: recordingID)
    }
}

/// Polls (5 ms apart, up to 10 s) until `condition` holds.
@MainActor
func waitUntil(_ what: String = "condition", sourceLocation: SourceLocation = #_sourceLocation,
               _ condition: @MainActor () async -> Bool) async {
    for _ in 0..<2_000 {
        if await condition() { return }
        try? await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("Timed out waiting for \(what)", sourceLocation: sourceLocation)
}

/// Audio sync scenarios on fake devices (§5.1 "Sync: audio").
@MainActor
enum AudioScenario {
    /// A (an iPhone) and B (a Mac), both with audio sync, on one cloud whose blobs are dated by the test clock.
    static func pair(bPlatform: DevicePlatform = .mac, aEncoder: any AudioEncoding = CopyAudioEncoder()) async throws
        -> (cloud: FakeCloud, clock: TestClock, a: FakeDevice, b: FakeDevice) {
        let cloud = FakeCloud()
        let clock = TestClock()
        await cloud.setNow { clock.date }
        let a = try FakeDevice("A", cloud: cloud, channel: CaptureChannel.iphone, clock: clock, audio: true,
                               platform: .iPhone, encoder: aEncoder)
        let b = try FakeDevice("B", cloud: cloud, channel: bPlatform == .mac ? CaptureChannel.mac : CaptureChannel.iphone,
                               clock: clock, audio: true, platform: bPlatform)
        return (cloud, clock, a, b)
    }

    static func blobIDs(_ cloud: FakeCloud) async -> Set<UUID> { Set(await cloud.audio(account: "account-1").keys) }

    static func markerIDs(_ cloud: FakeCloud) async -> Set<UUID> {
        Set(await cloud.records(account: "account-1").keys.compactMap { name in
            guard let id = SyncRecordID(recordName: name), id.type == .audio else { return nil }
            return id.entityID
        })
    }

    static func sha(_ url: URL) async throws -> String { try await FileDigest.sha256(of: url) }
}

extension SyncSuites {
    @Suite("Sync: audio")
    @MainActor
    struct SyncAudioTests {
        typealias S = AudioScenario

        // MARK: Moving audio

        @Test func audioReachesTheOtherDeviceByteForByte() async throws {
            let (cloud, _, a, b) = try await S.pair()
            defer { a.cleanup(); b.cleanup() }
            let id = try a.record([], audioSeconds: 3)
            await a.sync.enable()
            await b.sync.enable()
            let before = b.audio.revision
            await settleAudio([a, b])
            #expect(await cloud.records(account: "account-1")["au.\(id.uuidString)"] != nil)
            #expect(await S.blobIDs(cloud) == [id])
            let copy = b.paths.audioURL(fileName: "\(id.uuidString).wav")
            #expect(FileManager.default.fileExists(atPath: copy.path))
            let original = a.paths.audioURL(fileName: "\(id.uuidString).wav")
            #expect(try await S.sha(copy) == S.sha(original))
            #expect(b.store.hasLocalAudio(try #require(b.recording(id))))
            #expect(b.audio.revision > before)
            #expect(b.audio.state(of: try #require(b.recording(id))) == .local)
            expectConverged([a, b])
            await expectAudioConverged([a, b], complete: true)
            let seq = await cloud.sequence(account: "account-1")
            await settleAudio([a, b])
            #expect(await cloud.sequence(account: "account-1") == seq)
            #expect(await a.transfer?.uploads == 1)
            #expect(await b.transfer?.downloads == 1)
        }

        @Test func aacEndToEndRenamesTheRow() async throws {
            let (_, _, a, b) = try await S.pair(aEncoder: AACAudioEncoder())
            defer { a.cleanup(); b.cleanup() }
            let id = try a.record([], audioSeconds: 3)
            await a.sync.enable()
            await b.sync.enable()
            await settleAudio([a, b])
            let r = try #require(b.recording(id))
            #expect(r.audioFileName == "\(id.uuidString).m4a")
            let file = try AVAudioFile(forReading: b.paths.audioURL(fileName: r.audioFileName))
            #expect(file.fileFormat.sampleRate == 16_000)
            #expect(file.fileFormat.channelCount == 1)
            #expect(abs(Double(file.length) / file.fileFormat.sampleRate - 3) < 0.2)
            // The recording device keeps its WAV.
            let mine = try #require(a.recording(id))
            #expect(mine.audioFileName == "\(id.uuidString).wav")
            #expect(a.store.hasLocalAudio(mine))
            #expect(!FileManager.default.fileExists(atPath: b.paths.audioURL(fileName: "\(id.uuidString).wav").path))
        }

        /// A transcript whose audio is here does not redraw for other recordings' download progress or revisions: its
        /// `state(of:)` reads nothing audio sync changes while it transfers.
        @Test func aLocalRecordingsStateIgnoresOtherDownloads() async throws {
            let (_, _, a, b) = try await S.pair()
            defer { a.cleanup(); b.cleanup() }
            let theirs = try a.record([], audioSeconds: 2)
            let mine = try b.record([], audioSeconds: 2)
            b.conditions.network = .metered          // B's automatic transfers wait
            await a.sync.enable()
            await b.sync.enable()
            await settleAudio([a, b])
            let r = try #require(b.recording(mine))
            let fired = Mutex(false)
            withObservationTracking {
                #expect(b.audio.state(of: r) == .local)
            } onChange: {
                fired.withLock { $0 = true }
            }
            b.audio.progress[theirs] = 0.5
            b.audio.revision += 1
            #expect(!fired.withLock { $0 })
            b.audio.progress[theirs] = nil
            // A recording still waiting for its audio does follow audio sync.
            let waiting = try #require(b.recording(theirs))
            let followed = Mutex(false)
            withObservationTracking {
                _ = b.audio.state(of: waiting)
            } onChange: {
                followed.withLock { $0 = true }
            }
            b.audio.revision += 1
            #expect(followed.withLock { $0 })
        }

        @Test func downloadedAudioNeverStartsProcessing() async throws {
            let (_, _, a, b) = try await S.pair()
            defer { a.cleanup(); b.cleanup() }
            let id = try a.record([SyncVoices.karan(1)], audioSeconds: 3)
            await a.sync.enable()
            await b.sync.enable()
            await settleAudio([a, b])
            let r = try #require(b.recording(id))
            #expect(b.store.hasLocalAudio(r))
            #expect(r.stage == .ready)
            #expect(r.attemptCount == 0)
            #expect(try b.store.recoveryCandidates().isEmpty)
        }

        @Test func clipsPlayFromTheDownloadedFile() async throws {
            let (_, _, a, b) = try await S.pair(aEncoder: AACAudioEncoder())
            defer { a.cleanup(); b.cleanup() }
            let id = try a.record([SyncVoices.karan(40)], audioSeconds: 3)
            let karan = try #require(try a.store.nameSpeaker(recordingID: id, key: "S1", as: .newPerson(name: "Karan"),
                                                             remember: true).profileID)
            await a.sync.enable()
            await b.sync.enable()
            await settleAudio([a, b])
            let profile = try #require(try b.context.fetch(FetchDescriptor<VoiceProfile>()).first { $0.id == karan })
            let sample = try #require(profile.samples.first { $0.sourceRecordingID == id })
            let clip = try #require(sample.clipRange)
            let r = try #require(b.recording(id))
            let state = VoiceSampleGroups.clipState(sample, recordingsByID: [id: r], paths: b.paths,
                                                    audioState: { _ in b.audio.state(of: r) })
            #expect(state == .playable(fileName: "\(id.uuidString).m4a", range: clip))
        }

        // MARK: Upgrading and the one-time notice

        /// A synced on a build without audio sync (no `settings.syncAudio` key, acknowledged `rec.` rows, no audio
        /// rows), then updates. Three recordings a minute apart; returns them oldest first.
        func upgradedDevice() async throws -> (cloud: FakeCloud, a: FakeDevice, ids: [UUID], defaults: UserDefaults) {
            let cloud = FakeCloud()
            let clock = TestClock()
            await cloud.setNow { clock.date }
            let defaults = UserDefaults(suiteName: "sync-audio-upgrade-\(UUID().uuidString)")!
            let a = try FakeDevice("A", cloud: cloud, clock: clock, audio: false, defaults: defaults)
            var ids: [UUID] = []
            for _ in 0..<3 {
                ids.append(try a.record([], audioSeconds: 2))
                clock.advance(60)
            }
            await a.sync.enable()
            await settle([a])
            #expect(defaults.object(forKey: "settings.syncAudio") == nil)
            #expect(!a.settings.syncAudioIntroShown)
            #expect(a.stateRows().filter(\.isAudioRow).isEmpty)
            #expect(ids.allSatisfy { a.stateRow(SyncRecordID(type: .recording, entityID: $0))?.systemFields != nil })
            return (cloud, a, ids, defaults)
        }

        @Test func upgradeFromAnAudioLessBuildUploadsTheBacklogOnce() async throws {
            let (_, a, ids, defaults) = try await upgradedDevice()
            defer { a.cleanup() }
            await a.relaunch(audio: true)
            await a.sync.start()
            await a.audio.drain()
            let transfer = try #require(a.transfer)
            #expect(await transfer.uploads == 3)
            #expect(await transfer.calls.filter { $0.op == .upload }.map(\.id) == ids.reversed())
            var bytes: Int64 = 0
            for id in ids {
                bytes += Int64(try Data(contentsOf: a.paths.audioURL(fileName: "\(id.uuidString).wav")).count)
            }
            #expect(await transfer.bytesUp == bytes)
            #expect(defaults.object(forKey: "settings.syncAudio") == nil)

            await a.relaunch()
            await a.sync.start()
            await a.audio.drain()
            #expect(await a.transfer?.uploads == 0)
        }

        @Test func theIntroShowsOnceForAnExistingSyncUser() async throws {
            let (_, a, _, _) = try await upgradedDevice()
            defer { a.cleanup() }
            await a.relaunch(audio: true)
            await a.sync.start()
            #expect(a.audio.introPending)
            #expect(a.audio.summary.uploadsLeft == 3)
            a.audio.dismissIntro(turnOff: false)
            #expect(!a.audio.introPending)
            #expect(a.settings.syncAudioIntroShown)
            await a.audio.drain()
            #expect(await a.transfer?.uploads == 3)
            await a.relaunch()
            await a.sync.start()
            await a.audio.drain()
            #expect(!a.audio.introPending)
        }

        @Test func introTurnOffStopsAudio() async throws {
            let (_, a, _, _) = try await upgradedDevice()
            defer { a.cleanup() }
            await a.relaunch(audio: true)
            await a.sync.start()
            #expect(a.audio.introPending)
            a.audio.dismissIntro(turnOff: true)
            #expect(!a.settings.syncAudio)
            #expect(a.settings.syncAudioIntroShown)
            #expect(!a.audio.introPending)
            await a.audio.drain()
            await a.sync.syncNow()
            await a.audio.drain()
            #expect(await a.transfer?.uploads == 0)
        }

        /// The notice shows only while sync and Sync audio are on: switching either off in Settings (instead of
        /// Turn Off on the notice) takes it away, without marking it seen.
        @Test func theIntroGoesWhenSyncOrSyncAudioIsTurnedOff() async throws {
            for keepSync in [true, false] {
                let (_, a, _, _) = try await upgradedDevice()
                defer { a.cleanup() }
                await a.relaunch(audio: true)
                await a.sync.start()
                #expect(a.audio.introPending)
                if keepSync {
                    a.settings.syncAudio = false
                    a.audio.settingChanged()
                } else {
                    try await a.sync.disable(removeCloudCopy: false)
                }
                #expect(!a.audio.introPending)
                #expect(!a.settings.syncAudioIntroShown)
            }
        }

        @Test func turningSyncOnNeverShowsTheIntro() async throws {
            let (_, _, a, _) = try await S.pair()
            defer { a.cleanup() }
            try a.record([], audioSeconds: 2)
            #expect(!a.settings.syncAudioIntroShown)
            await a.sync.enable()
            #expect(a.settings.syncAudioIntroShown)
            #expect(!a.audio.introPending)
            await a.audio.drain()
            #expect(!a.audio.introPending)
            #expect(await a.transfer?.uploads == 1)
        }

        // MARK: When uploads run

        @Test func theSwitchActsOnlyWhileSyncIsOn() async throws {
            let (_, _, a, _) = try await S.pair()
            defer { a.cleanup() }
            try a.record([], audioSeconds: 2)
            #expect(a.settings.syncAudio)
            #expect(!a.settings.syncEnabled)
            a.audio.settingChanged()
            await a.audio.drain()
            await a.sync.syncNow()
            await a.audio.drain()
            let t = try #require(a.transfer)
            #expect(await t.probes == 0)
            #expect(await t.uploads == 0)
            #expect(await t.downloads == 0)
            #expect(await t.listings == 0)
        }

        @Test func uploadWaitsForTheRecordingRecord() async throws {
            let (cloud, _, a, _) = try await S.pair()
            defer { a.cleanup() }
            await a.sync.enable()
            let id = try a.record([], audioSeconds: 2)
            let recName = "rec.\(id.uuidString)"
            // The recording's state row exists but the server has not acknowledged it: no upload.
            await cloud.failOnce(recName)
            await a.sync.flushAndEnqueue()
            #expect(a.stateRow(SyncRecordID(type: .recording, entityID: id))?.systemFields == nil)
            await a.audio.drain()
            #expect(await a.transfer?.uploads == 0)
            #expect(await S.blobIDs(cloud).isEmpty)
            // Every upload finds its recording record already on the server.
            let seen = Mutex<[Bool]>([])
            await cloud.setAudioHook { op, _ in
                guard op == .upload else { return }
                let there = await cloud.record(account: "account-1", recordName: recName) != nil
                seen.withLock { $0.append(there) }
            }
            await a.sync.syncNow()
            await a.audio.drain()
            #expect(await S.blobIDs(cloud) == [id])
            #expect(seen.withLock { $0 } == [true])
        }

        @Test func onlyReadyRecordingsUpload() async throws {
            let (cloud, _, a, _) = try await S.pair()
            defer { a.cleanup() }
            let id = try a.record([], audioSeconds: 2)
            try a.store.setStage(.separating, queueReason: nil, for: id)
            await a.sync.enable()
            await settleAudio([a])
            #expect(await S.blobIDs(cloud).isEmpty)
            #expect(await a.transfer?.uploads == 0)
            try a.store.setStage(.ready, queueReason: nil, for: id)
            await settleAudio([a])
            #expect(await S.blobIDs(cloud) == [id])
        }

        @Test func newestFirst() async throws {
            let (_, clock, a, _) = try await S.pair()
            defer { a.cleanup() }
            a.settings.syncAudio = false
            var ids: [UUID] = []
            for _ in 0..<3 {
                ids.append(try a.record([], at: clock.date, audioSeconds: 2))
                clock.advance(3_600)
            }
            await a.sync.enable()
            await settleAudio([a])
            #expect(await a.transfer?.uploads == 0)
            a.settings.syncAudio = true
            a.audio.settingChanged()
            await a.audio.drain()
            #expect(await a.transfer?.calls.filter { $0.op == .upload }.map(\.id) == ids.reversed())
        }

        @Test func recordingsFromBeforeTheSwitchUploadLater() async throws {
            let (cloud, _, a, _) = try await S.pair()
            defer { a.cleanup() }
            a.settings.syncAudio = false
            let ids = [try a.record([], audioSeconds: 2), try a.record([], audioSeconds: 2)]
            await a.sync.enable()
            await settleAudio([a])
            #expect(await a.transfer?.uploads == 0)
            #expect(a.audio.summary.uploadsLeft == 2)   // what turning it on would upload
            a.settings.syncAudio = true
            a.audio.settingChanged()
            await settleAudio([a])
            #expect(await a.transfer?.uploads == 2)
            #expect(await S.blobIDs(cloud) == Set(ids))
            #expect(await S.markerIDs(cloud) == Set(ids))
        }

        @Test func switchOffOnTheSenderUploadsNothing() async throws {
            let (_, _, a, b) = try await S.pair()
            defer { a.cleanup(); b.cleanup() }
            a.settings.syncAudio = false
            let id = try a.record([], audioSeconds: 2)
            await a.sync.enable()
            await b.sync.enable()
            await settleAudio([a, b])
            #expect(await a.transfer?.uploads == 0)
            #expect(b.audio.state(of: try #require(b.recording(id))) == .notInICloud(channel: CaptureChannel.iphone))
        }

        @Test func switchOffOnTheReceiverDownloadsNothingButKnowsTheMarker() async throws {
            let (_, _, a, b) = try await S.pair()
            defer { a.cleanup(); b.cleanup() }
            b.settings.syncAudio = false
            let id = try a.record([], audioSeconds: 2)
            await a.sync.enable()
            await b.sync.enable()
            await settleAudio([a, b])
            let r = try #require(b.recording(id))
            #expect(b.audio.state(of: r) == .syncAudioOffHere(inICloud: true, channel: CaptureChannel.iphone))
            #expect(await b.transfer?.downloads == 0)
            b.settings.syncAudio = true
            b.audio.settingChanged()
            await b.audio.drain()
            #expect(await b.transfer?.downloads == 1)
            #expect(b.store.hasLocalAudio(r))
        }

        @Test func switchOffCancelsATransferInFlightAndDeletesNothing() async throws {
            let (cloud, _, a, b) = try await S.pair()
            defer { a.cleanup(); b.cleanup() }
            let first = try a.record([], audioSeconds: 2)
            await a.sync.enable()
            await b.sync.enable()
            await settleAudio([a, b])
            #expect(b.store.hasLocalAudio(try #require(b.recording(first))))

            // A download in flight on B: Sync audio off cancels it, and nothing lands.
            let second = try a.record([], audioSeconds: 2)
            await settleAudio([a])
            let hold = AudioHold()
            await cloud.setAudioHook { op, _ in if op == .download { await hold.wait() } }
            await b.sync.syncNow()
            await waitUntil("B's download to start") { await hold.arrived == 1 }
            b.settings.syncAudio = false
            b.audio.settingChanged()
            await hold.release()
            await b.audio.drain()
            await cloud.setAudioHook(nil)
            let r = try #require(b.recording(second))
            #expect(!b.store.hasLocalAudio(r))
            #expect(b.audio.state(of: r) == .syncAudioOffHere(inICloud: true, channel: CaptureChannel.iphone))
            #expect(try FileManager.default.contentsOfDirectory(atPath: b.paths.audioIncomingDirectory.path).isEmpty)
            #expect(b.audio.progress.isEmpty)
            // Nothing was deleted: B's earlier copy, A's files and both blobs stay.
            #expect(b.store.hasLocalAudio(try #require(b.recording(first))))
            #expect(a.store.hasLocalAudio(try #require(a.recording(first))))
            #expect(a.store.hasLocalAudio(try #require(a.recording(second))))
            #expect(await S.blobIDs(cloud) == [first, second])
            await settleAudio([a, b])
            #expect(await b.transfer?.downloads == 2)
            #expect(await a.transfer?.deletes == 0)
            #expect(await b.transfer?.deletes == 0)
        }

        /// The upload half: an upload held before anything is stored (while its copy is staged) is cancelled by the
        /// switch, sends nothing, and deletes nothing; switched on again, it goes.
        @Test func switchOffCancelsAnUploadBeforeItIsStored() async throws {
            let encoder = HeldEncoder()
            let (cloud, _, a, _) = try await S.pair(aEncoder: encoder)
            defer { a.cleanup() }
            let first = try a.record([], audioSeconds: 2)
            await a.sync.enable()
            await settleAudio([a])
            #expect(await S.blobIDs(cloud) == [first])

            let hold = encoder.arm()
            let second = try a.record([], audioSeconds: 2)
            await a.sync.syncNow()
            await waitUntil("A's upload to start staging") { await hold.arrived == 1 }
            #expect(a.audio.current?.job == .upload(second, userInitiated: false))
            a.settings.syncAudio = false
            a.audio.settingChanged()
            #expect(a.audio.current?.reason == .switchOff)
            await hold.release()
            await a.audio.drain()
            #expect(a.audio.current == nil)
            #expect(await a.transfer?.options(.upload, second).isEmpty == true)
            #expect(await a.transfer?.uploads == 1)
            #expect(await S.blobIDs(cloud) == [first])
            #expect(await S.markerIDs(cloud) == [first])
            #expect(a.stateRows().first { $0.isAudioRow && $0.entityID == second } == nil)
            #expect(a.audio.failures[second] == nil)
            // Nothing was deleted: both recordings keep their audio, and the first keeps its blob and marker.
            #expect(a.store.hasLocalAudio(try #require(a.recording(first))))
            #expect(a.store.hasLocalAudio(try #require(a.recording(second))))
            #expect(await a.transfer?.deletes == 0)

            a.settings.syncAudio = true
            a.audio.settingChanged()
            await settleAudio([a])
            #expect(await S.blobIDs(cloud) == [first, second])
            #expect(await S.markerIDs(cloud) == [first, second])
            #expect(await a.transfer?.options(.upload, second).count == 1)
        }

        @Test func anUploadThatFinishedStillWritesItsMarker() async throws {
            let (cloud, _, a, _) = try await S.pair()
            defer { a.cleanup() }
            let id = try a.record([], audioSeconds: 2)
            let hold = AudioHold()
            await cloud.setAudioHook { op, _ in if op == .upload { await hold.wait() } }
            await a.sync.enable()
            await waitUntil("the upload to be stored") { await hold.arrived == 1 }
            #expect(await S.blobIDs(cloud) == [id])
            a.settings.syncAudio = false
            a.audio.settingChanged()
            await hold.release()
            await a.audio.drain()
            await cloud.setAudioHook(nil)
            // No blob without a marker.
            await a.sync.syncNow()
            #expect(await S.markerIDs(cloud) == [id])
            #expect(a.audio.state(of: try #require(a.recording(id))) == .local)
            #expect(a.stateRows().first { $0.isAudioRow }?.audioFacts?.marker == .onServer)
            #expect(await a.transfer?.uploads == 1)
        }

        @Test func anUploadAbandonedByAResetIsAdoptedByTheNextProbe() async throws {
            let (cloud, _, a, _) = try await S.pair()
            defer { a.cleanup() }
            let id = try a.record([], audioSeconds: 2)
            let hold = AudioHold()
            await cloud.setAudioHook { op, _ in if op == .upload { await hold.wait() } }
            await a.sync.enable()
            await waitUntil("the upload to be stored") { await hold.arrived == 1 }
            let loop = a.audio.loopTask
            a.audio.isInFront = { false }    // nothing new starts until the test says
            a.audio.reset()
            await hold.release()
            await loop?.value
            await cloud.setAudioHook(nil)
            #expect(a.stateRows().filter(\.isAudioRow).isEmpty)
            #expect(await S.markerIDs(cloud).isEmpty)
            #expect(await S.blobIDs(cloud) == [id])
            a.audio.isInFront = { true }
            await settleAudio([a])
            #expect(await S.markerIDs(cloud) == [id])
            #expect(await a.transfer?.uploads == 1)
            #expect(await a.transfer?.bytesUp == Int64(try Data(contentsOf: a.paths.audioURL(fileName: "\(id.uuidString).wav")).count))
        }

        // MARK: Downloads and the network

        @Test func macDownloadsEverythingIPhoneTheLast30Days() async throws {
            let (cloud, clock, a, b) = try await S.pair()
            let c = try FakeDevice("C", cloud: cloud, channel: CaptureChannel.iphone, clock: clock, audio: true, platform: .iPhone)
            defer { a.cleanup(); b.cleanup(); c.cleanup() }
            let old = try a.record([], at: clock.date.addingTimeInterval(-40 * 86_400), audioSeconds: 2)
            let recent = try a.record([], audioSeconds: 2)
            await a.sync.enable()
            await b.sync.enable()
            await c.sync.enable()
            await settleAudio([a, b, c])
            #expect(b.store.hasLocalAudio(try #require(b.recording(old))))
            #expect(b.store.hasLocalAudio(try #require(b.recording(recent))))
            #expect(c.store.hasLocalAudio(try #require(c.recording(recent))))
            let r = try #require(c.recording(old))
            #expect(!c.store.hasLocalAudio(r))
            #expect(c.audio.state(of: r) == .inICloud(bytes: Int64(try Data(contentsOf: a.paths.audioURL(fileName: "\(old.uuidString).wav")).count), wait: .queued))
            #expect(c.audio.summary.downloadsLeft == 0)
            c.audio.transcriptOpened(old)
            await c.audio.drain()
            #expect(c.store.hasLocalAudio(r))
            #expect(await c.transfer?.options(.download, old).map(\.userInitiated) == [false])
        }

        @Test func automaticTransfersWaitForAnUnmeteredNetwork() async throws {
            let (cloud, _, a, _) = try await S.pair()
            defer { a.cleanup() }
            a.conditions.network = .metered
            let id = try a.record([], audioSeconds: 2)
            await a.sync.enable()
            await settleAudio([a])
            #expect(await a.transfer?.uploads == 0)
            #expect(a.audio.summary.wait == .network)
            #expect(a.audio.summary.uploadsLeft == 1)
            a.conditions.network = .unmetered
            a.conditions.change()
            await waitUntil("the upload") { await S.blobIDs(cloud) == [id] }
            await a.audio.drain()
            #expect(a.audio.summary.wait == nil)
            #expect(await a.transfer?.options(.upload, id).map(\.userInitiated) == [false])
            #expect(await a.transfer?.options(.upload, id).map(\.allowsMetered) == [false])
        }

        @Test func downloadNowGoesOverMobileData() async throws {
            let (_, _, a, b) = try await S.pair()
            defer { a.cleanup(); b.cleanup() }
            b.conditions.network = .metered
            let id = try a.record([], audioSeconds: 2)
            await a.sync.enable()
            await b.sync.enable()
            await settleAudio([a, b])
            let r = try #require(b.recording(id))
            #expect(!b.store.hasLocalAudio(r))
            guard case .inICloud(_, .network) = b.audio.state(of: r) else {
                Issue.record("expected .inICloud(.network), got \(b.audio.state(of: r))")
                return
            }
            #expect(b.audio.summary.wait == .network)
            b.audio.downloadNow(id)
            guard case .inICloud(_, .queued) = b.audio.state(of: r) else {
                Issue.record("Download Now should queue it, got \(b.audio.state(of: r))")
                return
            }
            await b.audio.drain()
            #expect(b.store.hasLocalAudio(r))
            #expect(await b.transfer?.options(.download, id).map(\.userInitiated) == [true])
            #expect(await b.transfer?.options(.download, id).map(\.allowsMetered) == [true])
            #expect(await a.transfer?.options(.upload, id).map(\.userInitiated) == [false])
        }

        @Test func syncAudioNowUploadsOverMobileDataOnce() async throws {
            let (cloud, _, a, _) = try await S.pair()
            defer { a.cleanup() }
            a.conditions.network = .metered
            let ids = [try a.record([], audioSeconds: 2), try a.record([], audioSeconds: 2)]
            await a.sync.enable()
            await settleAudio([a])
            #expect(await a.transfer?.uploads == 0)
            a.audio.syncAudioNow()
            await a.audio.drain()
            #expect(await S.blobIDs(cloud) == Set(ids))
            for id in ids { #expect(await a.transfer?.options(.upload, id).map(\.userInitiated) == [true]) }
            // Once: a later recording waits for Wi-Fi again.
            let later = try a.record([], audioSeconds: 2)
            await settleAudio([a])
            #expect(await a.transfer?.options(.upload, later).isEmpty == true)
            #expect(a.audio.summary.wait == .network)
        }

        @Test func lowPowerModeHoldsAutomaticTransfers() async throws {
            let (cloud, _, a, _) = try await S.pair()
            defer { a.cleanup() }
            a.conditions.lowPowerMode = true
            let id = try a.record([], audioSeconds: 2)
            await a.sync.enable()
            await settleAudio([a])
            #expect(await a.transfer?.uploads == 0)
            #expect(a.audio.summary.wait == .lowPower)
            a.conditions.lowPowerMode = false
            a.conditions.change()
            await waitUntil("the upload") { await S.blobIDs(cloud) == [id] }
        }

        @Test func syncAudioNowRunsInLowPowerMode() async throws {
            let (cloud, _, a, _) = try await S.pair()
            defer { a.cleanup() }
            a.conditions.lowPowerMode = true
            let id = try a.record([], audioSeconds: 2)
            await a.sync.enable()
            await settleAudio([a])
            #expect(await a.transfer?.uploads == 0)
            a.audio.syncAudioNow()
            await a.audio.drain()
            #expect(await S.blobIDs(cloud) == [id])
            #expect(await a.transfer?.options(.upload, id).map(\.userInitiated) == [true])
        }

        @Test func downloadNowPreemptsAnAutomaticTransfer() async throws {
            // B is an iPhone: A's 40-day-old recording downloads only when asked.
            let (cloud, clock, a, b) = try await S.pair(bPlatform: .iPhone)
            defer { a.cleanup(); b.cleanup() }
            let old = try a.record([], at: clock.date.addingTimeInterval(-40 * 86_400), audioSeconds: 2)
            await a.sync.enable()
            await b.sync.enable()
            await settleAudio([a, b])
            #expect(!b.store.hasLocalAudio(try #require(b.recording(old))))

            let mine = try b.record([], audioSeconds: 2)
            let hold = AudioHold()
            await cloud.setAudioHook { op, id in if op == .upload && id == mine { await hold.wait() } }
            await b.sync.syncNow()
            await waitUntil("B's automatic upload") { await hold.arrived == 1 }
            #expect(b.audio.current?.job == .upload(mine, userInitiated: false))
            let probes = try #require(await b.transfer?.probes)
            b.audio.downloadNow(old)
            #expect(b.audio.current?.reason == .preempted)
            await cloud.setAudioHook(nil)
            await hold.release()
            await b.audio.drain()
            let calls = try #require(await b.transfer?.calls)
            #expect(calls.map(\.op) == [.upload, .download])
            #expect(calls.map(\.id) == [mine, old])
            // The pre-empted upload asked again whether its blob was stored (a finished upload would not).
            #expect(await b.transfer?.probes == probes + 1)
            #expect(b.store.hasLocalAudio(try #require(b.recording(old))))
            #expect(b.audio.failures[mine] == nil && b.audio.retryAt[mine] == nil)
            // The upload ran again: its blob was already stored, so it was adopted and its marker written.
            #expect(b.stateRows().first { $0.isAudioRow && $0.entityID == mine } != nil)
            await settleAudio([a, b])
            #expect(await S.markerIDs(cloud) == [old, mine])
            #expect(await b.transfer?.bytesUp == Int64(try Data(contentsOf: b.paths.audioURL(fileName: "\(mine.uuidString).wav")).count))
        }

        /// Download Now does not wait behind a probe in flight (the launch probe of hundreds of recordings, say): the
        /// probe is cancelled, the download goes first, and the probe asks again afterwards.
        @Test func downloadNowPreemptsAProbe() async throws {
            let (cloud, clock, a, b) = try await S.pair(bPlatform: .iPhone)
            defer { a.cleanup(); b.cleanup() }
            let old = try a.record([], at: clock.date.addingTimeInterval(-40 * 86_400), audioSeconds: 2)
            await a.sync.enable()
            await b.sync.enable()
            await settleAudio([a, b])
            #expect(!b.store.hasLocalAudio(try #require(b.recording(old))))

            a.settings.syncAudio = false
            a.audio.settingChanged()
            let other = try a.record([], audioSeconds: 2)                  // no audio in iCloud: B's launch probe asks
            let hold = CancellableHold()
            await cloud.setAudioHook { op, id in if op == .probe && id == other { await hold.wait() } }
            await settle([a, b])
            await waitUntil("B's probe") { await hold.arrived == 1 }
            #expect(b.audio.current?.job == .launchProbe([other]))
            b.audio.downloadNow(old)
            #expect(b.audio.current?.reason == .preempted)
            await waitUntil("the download Download Now asked for") { b.store.hasLocalAudio(try! #require(b.recording(old))) }
            #expect(!b.audio.probed.contains(other))                         // the probe had not answered: no wait
            await hold.release()
            await b.audio.drain()
            await cloud.setAudioHook(nil)
            #expect(b.audio.state(of: try #require(b.recording(other))) == .notInICloud(channel: CaptureChannel.iphone))
        }

        /// Sync Audio Now and Download Audio First pre-empt an automatic transfer too; a delete is never pre-empted.
        @Test func syncAudioNowAndDownloadAudioFirstPreemptAnAutomaticTransfer() async throws {
            let (cloud, clock, a, b) = try await S.pair(bPlatform: .iPhone)
            defer { a.cleanup(); b.cleanup() }
            let old = try a.record([], at: clock.date.addingTimeInterval(-40 * 86_400), audioSeconds: 2)
            await a.sync.enable()
            await b.sync.enable()
            await settleAudio([a, b])
            #expect(b.audio.cloudOnlyCount == 1)

            for user in 0..<2 {
                let mine = try b.record([], audioSeconds: 2)
                let hold = AudioHold()
                await cloud.setAudioHook { op, id in if op == .upload && id == mine { await hold.wait() } }
                await b.sync.syncNow()
                await waitUntil("B's automatic upload") { await hold.arrived == 1 }
                #expect(b.audio.current?.job == .upload(mine, userInitiated: false))
                if user == 0 { b.audio.syncAudioNow() } else { b.audio.downloadCloudOnlyAudio() }
                #expect(b.audio.current?.reason == .preempted)
                await cloud.setAudioHook(nil)
                await hold.release()
                await b.audio.drain()
                #expect(b.audio.failures[mine] == nil && b.audio.retryAt[mine] == nil)
                #expect(await S.blobIDs(cloud).contains(mine))
            }
            #expect(b.store.hasLocalAudio(try #require(b.recording(old))))

            // A delete in flight is not pre-empted.
            try b.store.delete(id: old)
            let hold = AudioHold()
            await cloud.setAudioHook { op, _ in if op == .delete { await hold.wait() } }
            await b.sync.syncNow()
            await settle([b])
            await waitUntil("B's audio delete") { await hold.arrived >= 1 }
            b.audio.syncAudioNow()
            #expect(b.audio.current?.reason == nil)
            await cloud.setAudioHook(nil)
            await hold.release()
            await b.audio.drain()
        }

        @Test func lowStorageStopsAutomaticDownloadsButNotDownloadNowWithRoom() async throws {
            let (_, _, a, b) = try await S.pair()
            defer { a.cleanup(); b.cleanup() }
            b.conditions.free = 500_000_000   // under file + 1 GB, over file + 300 MB
            let id = try a.record([], audioSeconds: 2)
            await a.sync.enable()
            await b.sync.enable()
            await settleAudio([a, b])
            let r = try #require(b.recording(id))
            #expect(!b.store.hasLocalAudio(r))
            #expect(await b.transfer?.downloads == 0)
            guard case .inICloud(_, .lowStorage) = b.audio.state(of: r) else {
                Issue.record("expected .inICloud(.lowStorage), got \(b.audio.state(of: r))")
                return
            }
            #expect(b.audio.summary.wait == .lowStorage)
            b.audio.downloadNow(id)
            await b.audio.drain()
            #expect(b.store.hasLocalAudio(r))

            // Without room even for Download Now: it says so and downloads nothing.
            let second = try a.record([], audioSeconds: 2)
            await settleAudio([a, b])
            b.conditions.free = 100_000_000
            b.audio.downloadNow(second)
            await b.audio.drain()
            let r2 = try #require(b.recording(second))
            #expect(!b.store.hasLocalAudio(r2))
            guard case .inICloud(_, .lowStorage) = b.audio.state(of: r2) else {
                Issue.record("expected .inICloud(.lowStorage), got \(b.audio.state(of: r2))")
                return
            }
        }

        @Test func nothingStartsInTheBackground() async throws {
            let (cloud, _, a, _) = try await S.pair()
            defer { a.cleanup() }
            a.audio.isInFront = { false }
            let id = try a.record([], audioSeconds: 2)
            await a.sync.enable()
            await settleAudio([a])
            await a.sync.syncNow()
            let t = try #require(a.transfer)
            #expect(await t.probes == 0)
            #expect(await t.uploads == 0)
            #expect(await cloud.records(account: "account-1")["rec.\(id.uuidString)"] != nil)   // records still sync
            a.audio.isInFront = { true }
            a.audio.setForeground(true)
            await a.audio.drain()
            #expect(await S.blobIDs(cloud) == [id])
        }

        /// The iPhone leaves with a transfer in flight: it holds a short background task; when that ends, the
        /// transfer is cancelled (nothing lands) and runs again next time in front. A transfer that finishes first ends
        /// its task. The Mac begins none.
        @Test func aTransferInFlightWhenTheIPhoneLeavesHoldsAShortTask() async throws {
            let (cloud, _, a, b) = try await S.pair(bPlatform: .iPhone)
            defer { a.cleanup(); b.cleanup() }
            let spy = ShortTaskSpy()
            b.audio.background = spy
            await a.sync.enable()
            await b.sync.enable()
            let first = try a.record([], audioSeconds: 2)
            await settleAudio([a])
            let hold = AudioHold()
            await cloud.setAudioHook { op, _ in if op == .download { await hold.wait() } }
            await b.sync.syncNow()
            await waitUntil("B's download") { await hold.arrived == 1 }
            b.audio.isInFront = { false }
            b.audio.setForeground(false)
            await waitUntil("the short task") { spy.shortNames.count == 1 }
            spy.expireLatestShort()
            await waitUntil("the expiry to reach the job") { b.audio.current?.reason == .background }
            await hold.release()
            await b.audio.drain()
            let r = try #require(b.recording(first))
            #expect(!b.store.hasLocalAudio(r))
            #expect(b.audio.failures[first] == nil)
            #expect(spy.shortEnds.isEmpty)   // the system ended it; the bridge releases it itself

            // Back in front: it runs again. Leaving during the next one, which finishes in time, ends its task.
            let second = AudioHold()
            await cloud.setAudioHook { op, _ in if op == .download { await second.wait() } }
            b.audio.isInFront = { true }
            b.audio.setForeground(true)
            await waitUntil("B's second download") { await second.arrived == 1 }
            b.audio.isInFront = { false }
            b.audio.setForeground(false)
            await waitUntil("the second short task") { spy.shortNames.count == 2 }
            await waitUntil("the token to be held") { b.audio.backgroundToken != nil }
            await second.release()
            await b.audio.drain()
            await cloud.setAudioHook(nil)
            #expect(b.store.hasLocalAudio(r))
            await waitUntil("the short task to end") { spy.shortEnds == [true] }
            #expect(spy.everyShortTaskEnded == false)   // the expired one was never ended by the app

            // The Mac never begins one (it always counts as in front).
            let mac = try FakeDevice("M", cloud: cloud, channel: CaptureChannel.mac, clock: b.clock, audio: true, platform: .mac)
            defer { mac.cleanup() }
            let macSpy = ShortTaskSpy()
            mac.audio.background = macSpy
            let third = AudioHold()
            await cloud.setAudioHook { op, _ in if op == .download { await third.wait() } }
            await mac.sync.enable()
            await waitUntil("the Mac's download") { await third.arrived == 1 }
            #expect(mac.audio.current?.job.isTransfer == true)
            mac.audio.setForeground(false)
            for _ in 0..<20 { await Task.yield() }
            #expect(macSpy.shortNames.isEmpty)
            await third.release()
            await mac.audio.drain()
            await cloud.setAudioHook(nil)
            #expect(mac.store.hasLocalAudio(try #require(mac.recording(first))))
        }

        @Test func busyHoldsUploadsNotDownloads() async throws {
            let (cloud, _, a, b) = try await S.pair()
            defer { a.cleanup(); b.cleanup() }
            b.audio.isBusy = { true }
            let fromA = try a.record([], audioSeconds: 2)
            let fromB = try b.record([], audioSeconds: 2)
            await a.sync.enable()
            await b.sync.enable()
            await settleAudio([a, b])
            #expect(b.store.hasLocalAudio(try #require(b.recording(fromA))))
            #expect(await S.blobIDs(cloud) == [fromA])
            #expect(b.audio.summary.wait == .busy)
            b.audio.isBusy = { false }
            await settleAudio([a, b])
            #expect(await S.blobIDs(cloud) == [fromA, fromB])
            #expect(a.store.hasLocalAudio(try #require(a.recording(fromB))))
        }

        // MARK: Markers

        /// A recording made on a device that never syncs, its records and its audio as another device would upload them.
        func foreignRecording(clock: TestClock) async throws -> (records: [SyncRecord], audio: AudioDescriptor, data: Data, cleanup: () -> Void) {
            let maker = try FakeDevice("maker", cloud: FakeCloud(), clock: clock)
            let id = try maker.record([], audioSeconds: 2)
            let url = maker.paths.audioURL(fileName: "\(id.uuidString).wav")
            let d = try await CopyAudioEncoder().describe(url, recordingID: id)
            let records = try SyncSnapshot.records(maker.context).filter { $0.id.entityID == id || $0.id.type == .speaker }
            return (records, d, try Data(contentsOf: url), { maker.cleanup() })
        }

        @Test func aMarkerBeforeItsRecordingWaits() async throws {
            let (cloud, clock, _, b) = try await S.pair()
            defer { b.cleanup() }
            let foreign = try await foreignRecording(clock: clock)
            defer { foreign.cleanup() }
            let id = foreign.audio.recordingID
            await cloud.injectAudio(account: "account-1", foreign.audio, data: foreign.data, created: clock.date)
            await cloud.inject(account: "account-1", AudioMarker.record(foreign.audio))
            await b.sync.enable()
            await settleAudio([b])
            let row = try #require(b.stateRows().first { $0.isAudioRow && $0.entityID == id })
            #expect(row.audioFacts?.recordingSeen == false)
            #expect(await S.blobIDs(cloud) == [id])
            #expect(await S.markerIDs(cloud) == [id])
            #expect(await b.transfer?.downloads == 0)
            #expect(await b.transfer?.deletes == 0)

            for record in foreign.records { await cloud.inject(account: "account-1", record) }
            await settleAudio([b])
            let r = try #require(b.recording(id))
            #expect(b.store.hasLocalAudio(r))
            #expect(b.stateRows().first { $0.isAudioRow && $0.entityID == id }?.audioFacts?.recordingSeen == true)
        }

        @Test func anUnseenMarkerIsKeptForever() async throws {
            let (cloud, clock, _, b) = try await S.pair()
            defer { b.cleanup() }
            let foreign = try await foreignRecording(clock: clock)
            defer { foreign.cleanup() }
            let id = foreign.audio.recordingID
            await cloud.injectAudio(account: "account-1", foreign.audio, data: foreign.data, created: clock.date)
            await cloud.inject(account: "account-1", AudioMarker.record(foreign.audio))
            await b.sync.enable()
            await settleAudio([b])
            let seq = await cloud.sequence(account: "account-1")
            clock.advance(30 * 86_400)
            // Rows are never forgotten for age. (The weekly sweep would delete this blob and marker, since the server
            // has no rec. record for them: that is server truth, covered in "Sync: audio deletes".)
            b.settings.syncAudioLastSweep = clock.date
            await b.sync.syncNow()
            await settleAudio([b])
            #expect(b.stateRows().first { $0.isAudioRow && $0.entityID == id }?.audioFacts?.recordingSeen == false)
            #expect(await cloud.sequence(account: "account-1") == seq)
            #expect(await S.blobIDs(cloud) == [id])
            #expect(await b.transfer?.deletes == 0)
        }

        @Test func aDeviceThatDroppedMarkersOnAnOlderBuildLearnsThemAfterUpdating() async throws {
            let (cloud, clock, a, _) = try await S.pair()
            let mac = try FakeDevice("C", cloud: cloud, channel: CaptureChannel.mac, clock: clock, audio: false, platform: .mac)
            let phone = try FakeDevice("D", cloud: cloud, channel: CaptureChannel.iphone, clock: clock, audio: false, platform: .iPhone)
            defer { a.cleanup(); mac.cleanup(); phone.cleanup() }
            let old = try a.record([], at: clock.date.addingTimeInterval(-40 * 86_400), audioSeconds: 2)
            let recent = try a.record([], audioSeconds: 2)
            await a.sync.enable()
            await mac.sync.enable()
            await phone.sync.enable()
            await settleAudio([a, mac, phone])
            #expect(await S.markerIDs(cloud) == [old, recent])
            #expect(mac.stateRows().filter(\.isAudioRow).isEmpty)     // dropped, as 0.3.3 does

            for device in [mac, phone] {
                await device.relaunch(audio: true)
                for id in [old, recent] {
                    #expect(device.audio.state(of: try #require(device.recording(id))) == .checking)
                }
                await device.sync.start()
                await device.audio.drain()
            }
            #expect(await mac.transfer?.probes == 1)
            for id in [old, recent] {
                #expect(mac.store.hasLocalAudio(try #require(mac.recording(id))))
            }
            #expect(phone.store.hasLocalAudio(try #require(phone.recording(recent))))
            let r = try #require(phone.recording(old))
            guard case .inICloud = phone.audio.state(of: r) else {
                Issue.record("expected .inICloud, got \(phone.audio.state(of: r))")
                return
            }
            #expect(phone.stateRows().first { $0.isAudioRow && $0.entityID == old }?.audioFacts?.marker == .onServer)

            // A sweep on the updated device deletes nothing.
            clock.advance(8 * 86_400)
            await mac.sync.syncNow()
            await mac.audio.drain()
            #expect(await mac.transfer?.listings == 1)
            #expect(await mac.transfer?.deletes == 0)
            #expect(await S.blobIDs(cloud) == [old, recent])
        }

        /// A transient CloudKit error on the launch probe (an intermittent network, rate limiting, a busy server) is not
        /// an answer: the recordings stay "checking", the probe runs again after its backoff, and their audio then
        /// downloads. Only after three such failures in a row are they read as absent for the launch.
        @Test func aTransientLaunchProbeErrorIsAskedAgain() async throws {
            let (cloud, clock, a, _) = try await S.pair()
            let mac = try FakeDevice("C", cloud: cloud, channel: CaptureChannel.mac, clock: clock, audio: false, platform: .mac)
            defer { a.cleanup(); mac.cleanup() }
            let id = try a.record([], audioSeconds: 2)
            await a.sync.enable()
            await mac.sync.enable()
            await settleAudio([a, mac])
            #expect(await S.markerIDs(cloud) == [id])
            #expect(mac.stateRows().filter(\.isAudioRow).isEmpty)     // dropped, as 0.3.3 does

            await mac.relaunch(audio: true)
            await cloud.failNextAudio(.probe, id, with: .retryable(retryAfter: nil))
            await mac.sync.start()
            await mac.audio.drain()
            #expect(await mac.transfer?.probes == 1)
            let r = try #require(mac.recording(id))
            #expect(mac.audio.state(of: r) == .checking)
            await mac.sync.syncNow()                                     // clears the backoff, like Sync Now
            await mac.audio.drain()
            #expect(await mac.transfer?.probes == 2)
            #expect(mac.store.hasLocalAudio(r))
            #expect(mac.audio.state(of: r) == .local)

            // A probe that keeps failing is read as absent after the third failure, and other work still runs.
            let other = try a.record([], audioSeconds: 2)
            await settleAudio([a])
            await mac.relaunch(audio: false)
            await mac.sync.start()
            await settle([mac])
            await mac.relaunch(audio: true)
            let mine = try mac.record([], audioSeconds: 2)
            await cloud.failNextAudio(.probe, other, with: .retryable(retryAfter: 30))
            await mac.sync.start()
            await mac.audio.drain()
            let o = try #require(mac.recording(other))
            #expect(mac.audio.state(of: o) == .checking)
            #expect(await S.blobIDs(cloud).contains(mine))                 // the upload did not wait for the probe
            let probes = try #require(await mac.transfer?.probes)
            for _ in 0..<2 {
                await cloud.failNextAudio(.probe, other, with: .retryable(retryAfter: 30))
                clock.advance(3_600)
                mac.audio.pump()
                await mac.audio.drain()
            }
            #expect(await mac.transfer?.probes == probes + 2)
            #expect(mac.audio.state(of: o) == .notInICloud(channel: CaptureChannel.iphone))
        }

        @Test func theLaunchProbeIsOneRequestPer200() async throws {
            let (_, clock, _, b) = try await S.pair()
            defer { b.cleanup() }
            let turns = SeedContent.conversationB
            let data = try TranscriptDocument(words: SeedContent.allWords(turns), turns: SeedContent.paragraphs(turns),
                                              asrModelID: SeedBuilder.asrModelID).encoded()
            for i in 0..<450 {
                let id = UUID()
                let r = Recording(id: id, createdAt: clock.date.addingTimeInterval(-Double(i) * 60),
                                  audioFileName: "\(id.uuidString).wav", source: .microphone)
                b.context.insert(r)
                r.duration = 60
                r.stage = .ready
                r.transcriptData = data
                r.asrModelID = SeedBuilder.asrModelID
                r.captureChannel = CaptureChannel.iphone
            }
            try b.context.save()
            await b.sync.enable()
            await b.audio.drain()
            #expect(await b.transfer?.probes == 3)
            await b.sync.syncNow()
            await b.audio.drain()
            #expect(await b.transfer?.probes == 3)
            b.audio.reset()
            await b.audio.drain()
            #expect(await b.transfer?.probes == 6)
            let some = try #require(try b.context.fetch(FetchDescriptor<Recording>()).first)
            #expect(b.audio.state(of: some) == .notInICloud(channel: CaptureChannel.iphone))
        }

        @Test func rowsFromANewerBuildAreKept() async throws {
            let (cloud, clock, a, _) = try await S.pair()
            defer { a.cleanup() }
            let newer = try a.record([], audioSeconds: 2)
            let broken = try a.record([], audioSeconds: 2)
            try FileManager.default.removeItem(at: a.paths.audioURL(fileName: "\(newer.uuidString).wav"))
            let facts = AudioRowFacts(descriptor: AudioScenario.descriptor(newer), marker: .onServer, recordingSeen: true,
                                      firstSeenAt: clock.date)
            let row = SyncRecordState.audioRow(facts, now: clock.date)
            let json = String(decoding: try JSONEncoder().encode(facts), as: UTF8.self)
                .replacingOccurrences(of: "\"v\":1", with: "\"v\":2")
            row.baseHashesJSON = SyncSchema.sortedJSON([AudioRows.factsKey: json])
            a.context.insert(row)
            let bad = SyncRecordState.audioRow(AudioRowFacts(descriptor: AudioScenario.descriptor(broken), marker: .onServer,
                                                             recordingSeen: true, firstSeenAt: clock.date), now: clock.date)
            bad.baseHashesJSON = Data("not json".utf8)
            a.context.insert(bad)
            try a.context.save()
            guard case .newer = row.audioRead else { Issue.record("the row should read .newer"); return }

            await a.sync.enable()
            await settleAudio([a])
            let rows = a.stateRows().filter(\.isAudioRow)
            let kept = try #require(rows.first { $0.entityID == newer })
            guard case .newer = kept.audioRead else { Issue.record("the newer row changed"); return }
            #expect(a.audio.state(of: try #require(a.recording(newer))) == .needsUpdate)
            #expect(await a.transfer?.calls.contains { $0.id == newer } == false)
            #expect(await S.blobIDs(cloud) == [broken])          // its unreadable row went; it then uploaded
            #expect(rows.first { $0.entityID == broken }?.audioFacts != nil)
        }

        @Test func markersFromANewerBuildNeverPauseSync() async throws {
            let (cloud, _, a, b) = try await S.pair()
            defer { a.cleanup(); b.cleanup() }
            a.settings.syncAudio = false
            let id = try a.record([], audioSeconds: 2)
            await a.sync.enable()
            await b.sync.enable()
            await settleAudio([a, b])
            var marker = AudioMarker.record(AudioScenario.descriptor(id))
            marker.fields[SyncSchema.versionField] = .int(2)
            await cloud.inject(account: "account-1", marker)
            try a.store.rename(id: id, title: "After the marker")
            await settleAudio([a, b])
            #expect(!b.sync.status.isPaused)
            #expect(!b.sync.otherDeviceNeedsUpdate)
            let r = try #require(b.recording(id))
            #expect(b.audio.state(of: r) == .needsUpdate)
            #expect(r.title == "After the marker")
            #expect(await b.transfer?.downloads == 0)
        }
    }
}

extension AudioScenario {
    /// A made-up descriptor for rows and markers that are never downloaded.
    static func descriptor(_ id: UUID, bytes: Int64 = 64_044) -> AudioDescriptor {
        AudioDescriptor(recordingID: id, format: .pcm16kMono, bytes: bytes, sha256: String(repeating: "a", count: 64),
                        duration: 2)
    }
}
