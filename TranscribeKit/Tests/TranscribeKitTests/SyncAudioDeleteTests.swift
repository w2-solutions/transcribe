import Foundation
import SwiftData
import Synchronization
import Testing
import TranscribeCore
@testable import TranscribeFakes
@testable import TranscribeKit

extension SyncSuites {
    /// Deleting audio (§5.1 "Sync: audio deletes"): it follows the recording's settled delete, never mere absence;
    /// Remove iCloud Copy removes it first; the sweep trusts only the server.
    @Suite("Sync: audio deletes")
    @MainActor
    struct SyncAudioDeleteTests {
        typealias S = AudioScenario
        let account = "account-1"

        /// Every file of `id` this device holds: Audio/, AudioOutgoing/ and AudioIncoming/.
        func files(of id: UUID, on d: FakeDevice) -> [String] {
            let fm = FileManager.default
            return [d.paths.audioDirectory, d.paths.audioOutgoingDirectory, d.paths.audioIncomingDirectory].flatMap { dir in
                ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasPrefix(id.uuidString) }
            }
        }

        /// A blob removed behind the app's back (as iCloud losing it would).
        func dropBlob(_ cloud: FakeCloud, _ id: UUID) async throws {
            try await cloud.audioDelete(account: account, ids: [id])
        }

        /// A and B (iPhone and Mac) share `n` recordings made on A, audio settled on both.
        func shared(_ n: Int = 1) async throws -> (cloud: FakeCloud, clock: TestClock, a: FakeDevice, b: FakeDevice, ids: [UUID]) {
            let (cloud, clock, a, b) = try await S.pair()
            var ids: [UUID] = []
            for _ in 0..<n { ids.append(try a.record([], audioSeconds: 2)) }
            await a.sync.enable()
            await b.sync.enable()
            await settleAudio([a, b])
            #expect(await S.blobIDs(cloud) == Set(ids))
            for id in ids { #expect(b.store.hasLocalAudio(try #require(b.recording(id)))) }
            return (cloud, clock, a, b, ids)
        }

        // MARK: Deleting a recording

        @Test func deletingARecordingRemovesItsAudioEverywhere() async throws {
            let (cloud, _, a, b, ids) = try await shared(2)
            defer { a.cleanup(); b.cleanup() }
            let deleted = Mutex<[UUID]>([])
            await cloud.setAudioHook { op, id in if op == .delete { deleted.withLock { $0.append(id) } } }
            // Deleted on the recording device…
            try a.store.delete(id: ids[0])
            await settleAudio([a, b])
            // …and only its audio goes: the other recording keeps its blob, marker, files and rows, uploaded once.
            #expect(Set(deleted.withLock { $0 }) == [ids[0]])
            #expect(await S.blobIDs(cloud) == [ids[1]])
            #expect(await S.markerIDs(cloud) == [ids[1]])
            #expect(await a.transfer?.options(.upload, ids[1]).count == 1)
            #expect(await b.transfer?.options(.upload, ids[1]).isEmpty == true)
            #expect(await b.transfer?.options(.download, ids[1]).count == 1)
            for d in [a, b] {
                #expect(d.store.hasLocalAudio(try #require(d.recording(ids[1]))))
                #expect(S.facts(d, ids[1])?.marker == .onServer)
            }
            // …and on the other one.
            deleted.withLock { $0 = [] }
            try b.store.delete(id: ids[1])
            await settleAudio([a, b])
            #expect(Set(deleted.withLock { $0 }) == [ids[1]])
            await cloud.setAudioHook(nil)
            #expect(await S.blobIDs(cloud).isEmpty)
            #expect(await S.markerIDs(cloud).isEmpty)
            for id in ids {
                #expect(files(of: id, on: a).isEmpty)
                #expect(files(of: id, on: b).isEmpty)
            }
            #expect(a.stateRows().filter(\.isAudioRow).isEmpty)
            #expect(b.stateRows().filter(\.isAudioRow).isEmpty)
            await expectAudioConverged([a, b])
        }

        @Test func audioWaitsForTheRecordingDeleteToReachTheServer() async throws {
            let (cloud, _, a, b, ids) = try await shared()
            defer { a.cleanup(); b.cleanup() }
            let id = ids[0]
            try a.store.delete(id: id)
            // The delete has not reached the server (its rec. row is still here): the blob stays.
            await a.audio.drain()
            #expect(await S.blobIDs(cloud) == [id])
            await cloud.setNetworkDown(true)
            await a.sync.syncNow()
            #expect(a.stateRow(SyncRecordID(type: .recording, entityID: id))?.pending == .delete)
            await cloud.setNetworkDown(false)
            await a.audio.drain()
            #expect(await S.blobIDs(cloud) == [id])
            #expect(await a.transfer?.deletes == 0)
            await settleAudio([a, b])
            #expect(await S.blobIDs(cloud).isEmpty)
            #expect(await S.markerIDs(cloud).isEmpty)
        }

        @Test func theBlobGoesBeforeTheMarker() async throws {
            let (cloud, _, a, b, ids) = try await shared()
            defer { a.cleanup(); b.cleanup() }
            let id = ids[0]
            // Each blob delete request: was the marker still on the server, and was the row still `.onServer`?
            let seen = Mutex<[(marker: Bool, row: AudioRowFacts.Marker?)]>([])
            await cloud.setAudioHook { op, _ in
                guard op == .delete else { return }
                let marker = await cloud.record(account: "account-1", recordName: "au.\(id.uuidString)") != nil
                let row = await MainActor.run { a.stateRows().first { $0.isAudioRow && $0.entityID == id }?.audioFacts?.marker }
                seen.withLock { $0.append((marker, row)) }
            }
            await cloud.failNextAudio(.delete, id, with: .networkUnavailable)
            try a.store.delete(id: id)
            // The recording's delete reaches the server, the blob delete fails (offline), the next trigger retries.
            await a.sync.syncNow()
            await a.audio.drain()
            await cloud.setAudioHook(nil)
            let attempts = seen.withLock { $0 }
            #expect(attempts.count == 2)
            #expect(attempts.allSatisfy { $0.marker && $0.row == .onServer })
            #expect(await S.blobIDs(cloud).isEmpty)
            #expect(await S.markerIDs(cloud).isEmpty)
            #expect(a.stateRows().filter(\.isAudioRow).isEmpty)
        }

        /// 30 recordings synced from A; A deletes all of them while its sync is off and turns it on again.
        func massDeleted() async throws -> (cloud: FakeCloud, a: FakeDevice, b: FakeDevice, ids: [UUID]) {
            let (cloud, _, a, b) = try await S.pair()
            var ids: [UUID] = []
            for _ in 0..<30 { ids.append(try a.record([])) }
            await a.sync.enable()
            await b.sync.enable()
            await settleAudio([a, b])
            #expect(await S.blobIDs(cloud).count == 30)
            try await a.sync.disable(removeCloudCopy: false)
            for id in ids { try a.store.delete(id: id) }
            await a.sync.enable()
            await a.audio.drain()
            #expect(a.sync.status == .paused(.massDelete))
            return (cloud, a, b, ids)
        }

        @Test func massDeleteHoldKeepsAudioAndRestoreBringsItBack() async throws {
            let (cloud, a, b, ids) = try await massDeleted()
            defer { a.cleanup(); b.cleanup() }
            #expect(a.sync.heldDeleteCount == 30)   // the recordings only, as without audio sync
            #expect(await a.transfer?.deletes == 0)
            #expect(await S.blobIDs(cloud).count == 30)
            await a.sync.resolveMassDelete(confirm: false)
            await settleAudio([a, b])
            #expect(a.count(Recording.self) == 30)
            #expect(await S.blobIDs(cloud) == Set(ids))
            #expect(await S.markerIDs(cloud) == Set(ids))
            for id in ids {
                #expect(b.store.hasLocalAudio(try #require(b.recording(id))))
                #expect(a.store.hasLocalAudio(try #require(a.recording(id))))   // downloaded back
            }
            #expect(await a.transfer?.deletes == 0)
        }

        @Test func confirmingTheMassDeleteDeletesTheAudio() async throws {
            let (cloud, a, b, ids) = try await massDeleted()
            defer { a.cleanup(); b.cleanup() }
            await a.sync.resolveMassDelete(confirm: true)
            await settleAudio([a, b])
            #expect(await S.blobIDs(cloud).isEmpty)
            #expect(await S.markerIDs(cloud).isEmpty)
            #expect(b.count(Recording.self) == 0)
            for id in ids { #expect(files(of: id, on: b).isEmpty) }
        }

        @Test func aDeleteFromAnOlderBuildIsCleanedUp() async throws {
            let (cloud, clock, a, _) = try await S.pair()
            let c = try FakeDevice("C", cloud: cloud, channel: CaptureChannel.mac, clock: clock, audio: false, platform: .mac)
            defer { a.cleanup(); c.cleanup() }
            let id = try a.record([], audioSeconds: 2)
            await a.sync.enable()
            await c.sync.enable()
            await settleAudio([a, c])
            #expect(await S.blobIDs(cloud) == [id])
            try c.store.delete(id: id)
            await settleAudio([a, c])
            #expect(await S.blobIDs(cloud).isEmpty)
            #expect(await S.markerIDs(cloud).isEmpty)
            #expect(files(of: id, on: a).isEmpty)
        }

        @Test func deletingOnADeviceWithSyncAudioOffStillRemovesTheAudio() async throws {
            let (cloud, _, a, b, ids) = try await shared()
            defer { a.cleanup(); b.cleanup() }
            b.settings.syncAudio = false
            b.audio.settingChanged()
            try b.store.delete(id: ids[0])
            // B alone: its own delete job runs although Sync audio is off here.
            await b.sync.syncNow()
            await b.audio.drain()
            #expect(await b.transfer?.deletes == 1)
            #expect(await S.blobIDs(cloud).isEmpty)
            #expect(await S.markerIDs(cloud).isEmpty)
            await settleAudio([a, b])
            #expect(files(of: ids[0], on: a).isEmpty)
        }

        @Test func deleteWhileUploadingLeavesNothingBehind() async throws {
            let (cloud, _, a, b) = try await S.pair()
            defer { a.cleanup(); b.cleanup() }
            await a.sync.enable()
            await b.sync.enable()
            let id = try a.record([], audioSeconds: 2)
            let hold = AudioHold()
            await cloud.setAudioHook { op, _ in if op == .upload { await hold.wait() } }
            await a.sync.syncNow()
            await waitUntil("A's upload") { await hold.arrived == 1 }
            await b.sync.syncNow()
            try b.store.delete(id: id)
            await b.sync.syncNow()
            await hold.release()
            await a.audio.drain()
            await cloud.setAudioHook(nil)
            await settleAudio([a, b])
            #expect(await S.blobIDs(cloud).isEmpty)
            #expect(await S.markerIDs(cloud).isEmpty)
            #expect(a.recording(id) == nil)
            #expect(files(of: id, on: a).isEmpty)
            #expect(files(of: id, on: b).isEmpty)
        }

        @Test func aDownloadFinishingAfterADeleteLeavesNoFile() async throws {
            let (cloud, _, a, b) = try await S.pair()
            defer { a.cleanup(); b.cleanup() }
            await a.sync.enable()
            await b.sync.enable()
            let id = try a.record([], audioSeconds: 2)
            await settleAudio([a])
            let hold = AudioHold()
            await cloud.setAudioHook { op, _ in if op == .download { await hold.wait() } }
            await b.sync.syncNow()
            await waitUntil("B's download") { await hold.arrived == 1 }
            try a.store.delete(id: id)
            await a.sync.syncNow()
            await b.sync.syncNow()
            #expect(b.recording(id) == nil)
            await hold.release()
            await b.audio.drain()
            await cloud.setAudioHook(nil)
            #expect(files(of: id, on: b).isEmpty)
            await settleAudio([a, b])
            #expect(await S.blobIDs(cloud).isEmpty)
            #expect(await S.markerIDs(cloud).isEmpty)
            #expect(files(of: id, on: b).isEmpty)
        }

        // MARK: Remove iCloud Copy

        @Test func removeICloudCopyRemovesAudioFirstAndKeepsLocalFiles() async throws {
            let (cloud, clock, a, b, ids) = try await shared()
            defer { a.cleanup(); b.cleanup() }
            let orphan = UUID()
            await cloud.injectAudio(account: account, S.descriptor(orphan), data: Data("RIFF".utf8), created: clock.date)
            try await a.sync.disable(removeCloudCopy: true)
            #expect(await S.blobIDs(cloud).isEmpty)
            #expect(!(await cloud.zoneExists(account: account)))
            #expect(!a.settings.syncEnabled)
            #expect(a.stateRows().isEmpty)
            #expect(a.store.hasLocalAudio(try #require(a.recording(ids[0]))))
            #expect(b.store.hasLocalAudio(try #require(b.recording(ids[0]))))
            await b.sync.syncNow()
            #expect(b.sync.status == .paused(.zoneRemoved))
            #expect(b.store.hasLocalAudio(try #require(b.recording(ids[0]))))
        }

        @Test func removeICloudCopyWithoutTheIndexStillRemovesKnownAudio() async throws {
            let (cloud, _, a, b, ids) = try await shared(2)
            defer { a.cleanup(); b.cleanup() }
            await cloud.setAudioIndexExists(false)
            try await a.sync.disable(removeCloudCopy: true)
            #expect(await S.blobIDs(cloud).isEmpty)
            #expect(!(await cloud.zoneExists(account: account)))
            for id in ids { #expect(a.store.hasLocalAudio(try #require(a.recording(id)))) }
        }

        @Test func removeICloudCopyChangesNothingWhenAudioCannotBeDeleted() async throws {
            let (cloud, _, a, b, ids) = try await shared()
            defer { a.cleanup(); b.cleanup() }
            await cloud.failNextAudio(.delete, ids[0], with: .networkUnavailable)
            let rowsBefore = a.stateRows().count
            await #expect(throws: AudioTransferError.networkUnavailable) {
                try await a.sync.disable(removeCloudCopy: true)
            }
            #expect(await cloud.zoneExists(account: account))
            #expect(await S.markerIDs(cloud) == Set(ids))
            #expect(await S.blobIDs(cloud) == Set(ids))
            #expect(a.stateRows().count == rowsBefore)
            #expect(a.settings.syncEnabled)
            #expect(a.audio.summary.wait == .removalFailed)
            // No upload for the rest of this launch.
            let later = try a.record([], audioSeconds: 2)
            await settleAudio([a, b])
            #expect(await a.transfer?.options(.upload, later).isEmpty == true)
            #expect(a.audio.summary.wait == .removalFailed)
            // After a relaunch, uploads resume.
            await a.relaunch()
            await a.sync.start()
            await settleAudio([a, b])
            #expect(await S.blobIDs(cloud).contains(later))
            #expect(a.audio.summary.wait == nil)
        }

        @Test func removeICloudCopyWaitsForTheTransferInFlight() async throws {
            let (cloud, _, a, _) = try await S.pair()
            defer { a.cleanup() }
            let id = try a.record([], audioSeconds: 2)
            let hold = AudioHold()
            await cloud.setAudioHook { op, _ in if op == .upload { await hold.wait() } }
            await a.sync.enable()
            await waitUntil("A's upload") { await hold.arrived == 1 }
            let removal = Task { try await a.sync.disable(removeCloudCopy: true) }
            await waitUntil("the removal to start") { a.audio.removing }
            let probes = await a.transfer?.probes
            a.audio.pump()
            a.audio.downloadNow(id)
            a.audio.syncAudioNow()
            #expect(a.audio.removing)
            await hold.release()
            try await removal.value
            await cloud.setAudioHook(nil)
            #expect(await S.blobIDs(cloud).isEmpty)
            #expect(await S.markerIDs(cloud).isEmpty)
            #expect(await a.transfer?.uploads == 1)
            #expect(await a.transfer?.probes == probes)
            #expect(!a.settings.syncEnabled)
            #expect(a.store.hasLocalAudio(try #require(a.recording(id))))
        }

        @Test func aDeviceUploadingWhileTheCopyIsRemovedDeletesItsBlob() async throws {
            let (cloud, _, a, b) = try await S.pair()
            defer { a.cleanup(); b.cleanup() }
            await a.sync.enable()
            await b.sync.enable()
            let id = try b.record([], audioSeconds: 2)
            let hold = AudioHold()
            await cloud.setAudioHook { op, _ in if op == .upload { await hold.wait() } }
            await b.sync.syncNow()
            await waitUntil("B's upload") { await hold.arrived == 1 }
            // A has not heard of B's recording, and without the index its removal cannot list B's blob.
            await cloud.setAudioIndexExists(false)
            try await a.sync.disable(removeCloudCopy: true)
            #expect(await S.blobIDs(cloud) == [id])
            await hold.release()
            await b.audio.drain()
            await cloud.setAudioHook(nil)
            await waitUntil("B to delete its blob") { await S.blobIDs(cloud).isEmpty }
            #expect(b.sync.status == .paused(.zoneRemoved))
            #expect(b.stateRows().isEmpty)
            #expect(b.store.hasLocalAudio(try #require(b.recording(id))))
        }

        /// The other order: B learns of the removal (its fetch meets the deleted zone) while its upload's blob is stored
        /// but its row is not yet written. The cancelled upload's blob is deleted by B all the same.
        @Test func aDeviceLearningOfTheRemovalMidUploadDeletesItsBlob() async throws {
            let (cloud, _, a, b) = try await S.pair()
            defer { a.cleanup(); b.cleanup() }
            await a.sync.enable()
            await b.sync.enable()
            let id = try b.record([], audioSeconds: 2)
            let hold = AudioHold()
            await cloud.setAudioHook { op, _ in if op == .upload { await hold.wait() } }
            await b.sync.syncNow()
            await waitUntil("B's upload") { await hold.arrived == 1 }
            await cloud.setAudioIndexExists(false)
            try await a.sync.disable(removeCloudCopy: true)
            #expect(await S.blobIDs(cloud) == [id])
            await b.sync.syncNow()
            #expect(b.sync.status == .paused(.zoneRemoved))
            await cloud.setAudioHook(nil)
            await hold.release()
            await waitUntil("B to delete its blob") { await S.blobIDs(cloud).isEmpty }
            #expect(await S.markerIDs(cloud).isEmpty)
            #expect(b.stateRows().isEmpty)
            #expect(b.store.hasLocalAudio(try #require(b.recording(id))))
        }

        /// B uploads and its marker is acknowledged after A's removal listed the blobs and before A deleted the zone:
        /// A lists once more after the zone is gone, so that blob does not stay in iCloud.
        @Test func anUploadThatLandsDuringTheRemovalIsRemovedToo() async throws {
            let (cloud, _, a, b) = try await S.pair()
            defer { a.cleanup(); b.cleanup() }
            let first = try a.record([], audioSeconds: 2)
            await a.sync.enable()
            await b.sync.enable()
            await settleAudio([a, b])
            #expect(await S.blobIDs(cloud) == [first])
            let hold = AudioHold()
            await cloud.setAudioHook { op, _ in if op == .list { await hold.wait() } }
            let removal = Task { try await a.sync.disable(removeCloudCopy: true) }
            await waitUntil("A's listing") { await hold.arrived == 1 }
            let late = try b.record([], audioSeconds: 2)
            await b.sync.syncNow()
            await b.audio.drain()
            #expect(await S.markerIDs(cloud).contains(late))
            #expect(b.stateRows().first { $0.isAudioRow && $0.entityID == late }?.audioFacts?.marker == .onServer)
            await hold.release()
            try await removal.value
            await cloud.setAudioHook(nil)
            #expect(!(await cloud.zoneExists(account: account)))
            #expect(await S.blobIDs(cloud).isEmpty)
            await b.sync.syncNow()
            #expect(b.sync.status == .paused(.zoneRemoved))
            #expect(b.store.hasLocalAudio(try #require(b.recording(late))))
        }

        @Test func cloudOnlyCountNamesAudioOnlyInICloud() async throws {
            let (cloud, clock, mac, phone) = try await S.pair(bPlatform: .iPhone)
            defer { mac.cleanup(); phone.cleanup() }
            let id = try mac.record([], at: clock.date.addingTimeInterval(-40 * 86_400), audioSeconds: 2)
            await mac.sync.enable()
            await phone.sync.enable()
            await settleAudio([mac, phone])
            #expect(await S.blobIDs(cloud) == [id])
            #expect(phone.audio.cloudOnlyCount == 1)
            #expect(mac.audio.cloudOnlyCount == 0)
            #expect(SyncCopy.removeMessage(cloudOnly: phone.audio.cloudOnlyCount, platform: .iPhone).contains("1 recording"))
            phone.conditions.network = .metered
            phone.audio.downloadCloudOnlyAudio()
            await phone.audio.drain()
            #expect(phone.store.hasLocalAudio(try #require(phone.recording(id))))
            #expect(phone.audio.cloudOnlyCount == 0)
            #expect(await phone.transfer?.options(.download, id).map(\.userInitiated) == [true])
        }

        /// Download Audio First cannot run while Sync audio is off on this device or sync is paused (an iCloud that is
        /// full, say): the dialogs then offer no button that would do nothing, and say why instead.
        @Test func downloadAudioFirstIsOfferedOnlyWhenAudioCanDownload() async throws {
            let (cloud, clock, mac, phone) = try await S.pair(bPlatform: .iPhone)
            defer { mac.cleanup(); phone.cleanup() }
            phone.settings.syncAudio = false
            let id = try mac.record([], at: clock.date.addingTimeInterval(-40 * 86_400), audioSeconds: 2)
            await mac.sync.enable()
            await phone.sync.enable()
            await settleAudio([mac, phone])
            #expect(phone.audio.cloudOnlyCount == 1)
            #expect(phone.audio.downloadAvailability == .syncAudioOff)
            phone.audio.downloadCloudOnlyAudio()
            await phone.audio.drain()
            #expect(await phone.transfer?.downloads == 0)       // it would do nothing: hence no button
            #expect(SyncCopy.removeMessage(cloudOnly: 1, platform: .iPhone, availability: .syncAudioOff)
                    .contains("Turn on Sync audio to download it first."))

            // Paused for a full iCloud: nothing runs until sync resumes.
            await cloud.setQuotaFull(true)
            try phone.store.rename(id: id, title: "Full")
            await phone.sync.syncNow()
            #expect(phone.sync.status == .paused(.quotaFull))
            phone.settings.syncAudio = true
            phone.audio.settingChanged()
            #expect(phone.audio.downloadAvailability == .syncPaused)
            phone.audio.downloadCloudOnlyAudio()
            await phone.audio.drain()
            #expect(await phone.transfer?.downloads == 0)
            #expect(SyncCopy.removeMessage(cloudOnly: 1, platform: .iPhone, availability: .syncPaused)
                    .contains("It can download once sync resumes."))

            await cloud.setQuotaFull(false)
            await phone.sync.syncNow()
            #expect(phone.audio.downloadAvailability == .available)
            phone.audio.downloadCloudOnlyAudio()
            await phone.audio.drain()
            #expect(phone.store.hasLocalAudio(try #require(phone.recording(id))))
        }

        /// A device that dropped markers on an older build and has Sync audio off never runs the launch probe, so it
        /// cannot count the audio only in iCloud: the remove dialog says audio may be there rather than "keeps its
        /// audio" with no warning, while the removal deletes those blobs.
        @Test func withSyncAudioOffTheRemoveDialogWarnsWithoutACount() async throws {
            let (cloud, clock, a, _) = try await S.pair()
            let phone = try FakeDevice("D", cloud: cloud, channel: CaptureChannel.iphone, clock: clock, audio: false, platform: .iPhone)
            defer { a.cleanup(); phone.cleanup() }
            let id = try a.record([], audioSeconds: 2)
            await a.sync.enable()
            await phone.sync.enable()
            await settleAudio([a, phone])
            #expect(await S.markerIDs(cloud) == [id])
            await phone.relaunch(audio: true)
            phone.settings.syncAudio = false
            await phone.sync.start()
            await phone.audio.drain()
            #expect(phone.audio.cloudOnlyCount == 0)                    // never probed: not counted
            #expect(await phone.transfer?.probes == 0)
            #expect(phone.audio.downloadAvailability == .syncAudioOff)
            let message = SyncCopy.removeMessage(cloudOnly: phone.audio.cloudOnlyCount, platform: .iPhone,
                                                 availability: phone.audio.downloadAvailability)
            #expect(message.contains("audio from your other devices may be only in iCloud: removing the iCloud copy deletes it."))
            #expect(!message.hasSuffix("This device keeps its library and its audio. Your other devices keep theirs but stop syncing until sync is turned on there again."))
        }

        @Test func keepTheICloudCopyKeepsAudio() async throws {
            let (cloud, _, a, b, ids) = try await shared()
            defer { a.cleanup(); b.cleanup() }
            try await a.sync.disable(removeCloudCopy: false)
            #expect(await S.blobIDs(cloud) == Set(ids))
            #expect(await S.markerIDs(cloud) == Set(ids))
            #expect(a.store.hasLocalAudio(try #require(a.recording(ids[0]))))
            let later = try a.record([], audioSeconds: 2)
            await a.sync.syncNow()
            await a.audio.drain()
            #expect(await a.transfer?.options(.upload, later).isEmpty == true)
            #expect(await a.transfer?.deletes == 0)
            await settleAudio([b])
            #expect(b.store.hasLocalAudio(try #require(b.recording(ids[0]))))
        }

        // MARK: The orphan sweep

        @Test func theSweepDeletesOnlyBlobsWhoseRecordingIsGoneOnTheServer() async throws {
            let (cloud, clock, a, _) = try await S.pair()
            defer { a.cleanup() }
            await a.sync.enable()
            await settleAudio([a])
            clock.advance(8 * 86_400)
            let gone = UUID(), elsewhere = UUID(), young = UUID()
            let old = clock.date.addingTimeInterval(-25 * 3_600)
            await cloud.injectAudio(account: account, S.descriptor(gone), data: Data("RIFF".utf8), created: old)
            await cloud.inject(account: account, AudioMarker.record(S.descriptor(gone)))
            await cloud.injectAudio(account: account, S.descriptor(elsewhere), data: Data("RIFF".utf8), created: old)
            await cloud.inject(account: account, SyncRecord(id: SyncRecordID(type: .recording, entityID: elsewhere),
                                                            fields: [SyncSchema.versionField: .int(1)]))
            await cloud.injectAudio(account: account, S.descriptor(young), data: Data("RIFF".utf8),
                                    created: clock.date.addingTimeInterval(-3_600))
            await a.audio.drain()   // no fetch since the injections: this device has no row and no recording for them
            #expect(await a.transfer?.listings == 1)
            #expect(await S.blobIDs(cloud) == [elsewhere, young])
            #expect(await S.markerIDs(cloud).isEmpty)
            #expect(a.settings.syncAudioLastSweep == clock.date)
            #expect(a.stateRows().filter(\.isAudioRow).isEmpty)
            clock.advance(6 * 86_400)
            await a.audio.drain()
            #expect(await a.transfer?.listings == 1)   // not again within a week
        }

        @Test func theFirstSweepWaitsAWeek() async throws {
            let (_, clock, a, _) = try await S.pair()
            defer { a.cleanup() }
            #expect(a.settings.syncAudioLastSweep == clock.date)
            await a.sync.enable()
            clock.advance(6 * 86_400)
            await a.sync.syncNow()
            await a.audio.drain()
            #expect(await a.transfer?.listings == 0)
            clock.advance(86_400)
            await a.sync.syncNow()
            await a.audio.drain()
            #expect(await a.transfer?.listings == 1)
        }

        @Test func aSweepOnADeviceWithNoRowsDeletesNothingLive() async throws {
            let (cloud, clock, a, _) = try await S.pair()
            defer { a.cleanup() }
            let ids = [try a.record([], audioSeconds: 2), try a.record([], audioSeconds: 2)]
            await a.sync.enable()
            await settleAudio([a])
            let c = try FakeDevice("C", cloud: cloud, channel: CaptureChannel.mac, clock: clock, audio: true, platform: .mac)
            defer { c.cleanup() }
            clock.advance(8 * 86_400)
            c.settings.syncAudioLastSweep = clock.date.addingTimeInterval(-8 * 86_400)
            await c.sync.enable()
            await c.audio.drain()
            #expect(await c.transfer?.listings == 1)
            #expect(await c.transfer?.deletes == 0)
            #expect(await S.blobIDs(cloud) == Set(ids))
            #expect(await S.markerIDs(cloud) == Set(ids))
        }

        @Test func aSweepNeedsAFetchThatWorked() async throws {
            let (cloud, clock, a, _, _) = try await shared()
            defer { a.cleanup() }
            clock.advance(8 * 86_400)
            a.settings.syncCloudEnvironment = "Development"
            await a.relaunch()
            a.sync.cloudEnvironment = "Production"     // the environment changed: sync state is cleared at start
            await cloud.setNetworkDown(true)
            await a.sync.start()
            #expect(!a.sync.fetchSucceededSinceReset)
            await cloud.setNetworkDown(false)
            await a.audio.drain()
            #expect(await a.transfer?.listings == 0)
            await a.sync.syncNow()
            #expect(a.sync.fetchSucceededSinceReset)
            await a.audio.drain()
            #expect(await a.transfer?.listings == 1)
        }

        @Test func aSweepAbortsWhenTheZoneIsGone() async throws {
            let (cloud, clock, a, _) = try await S.pair()
            defer { a.cleanup() }
            await a.sync.enable()
            await settleAudio([a])
            for _ in 0..<3 {
                await cloud.injectAudio(account: account, S.descriptor(UUID()), data: Data("RIFF".utf8),
                                        created: clock.date.addingTimeInterval(-2 * 86_400))
            }
            await cloud.removeZone(account: account, reason: .deleted)
            clock.advance(8 * 86_400)
            await a.audio.drain()
            #expect(await a.transfer?.listings == 1)
            #expect(await a.transfer?.recordingChecks == 1)
            #expect(await a.transfer?.deletes == 0)
            #expect(await S.blobIDs(cloud).count == 3)
            #expect(a.settings.syncAudioLastSweep != clock.date)
        }

        // MARK: Missing audio

        @Test func aMissingBlobDropsTheMarkerAndTheHolderUploadsAgain() async throws {
            let (cloud, _, a, b) = try await S.pair()
            defer { a.cleanup(); b.cleanup() }
            b.conditions.network = .metered
            let id = try a.record([], audioSeconds: 2)
            await a.sync.enable()
            await b.sync.enable()
            await settleAudio([a, b])
            try await dropBlob(cloud, id)
            b.conditions.network = .unmetered
            await b.audio.drain()
            #expect(await b.transfer?.downloads == 1)
            #expect(await S.markerIDs(cloud).isEmpty)
            await settleAudio([a, b])
            #expect(await a.transfer?.uploads == 2)
            #expect(b.store.hasLocalAudio(try #require(b.recording(id))))
            await expectAudioConverged([a, b])
        }

        @Test func aNotFoundThatTheProbeContradictsChangesNothing() async throws {
            let (cloud, clock, a, b) = try await S.pair()
            defer { a.cleanup(); b.cleanup() }
            b.conditions.network = .metered
            let id = try a.record([], audioSeconds: 2)
            await a.sync.enable()
            await b.sync.enable()
            await settleAudio([a, b])
            await cloud.failNextAudio(.download, id, with: .notFound)
            b.conditions.network = .unmetered
            await b.audio.drain()
            let r = try #require(b.recording(id))
            #expect(!b.store.hasLocalAudio(r))
            #expect(b.audio.state(of: r) == .failed(bytes: try #require(b.stateRows().first { $0.isAudioRow }?.audioFacts).descriptor.bytes))
            #expect(await S.markerIDs(cloud) == [id])
            #expect(await b.transfer?.downloads == 1)
            // Backoff: not before a minute.
            await b.audio.drain()
            #expect(await b.transfer?.downloads == 1)
            clock.advance(61)
            await b.audio.drain()
            #expect(b.store.hasLocalAudio(r))
            #expect(await a.transfer?.uploads == 1)
        }

        @Test func notFoundMarkerDeletesStopAt25() async throws {
            let (cloud, _, a, b) = try await S.pair()
            defer { a.cleanup(); b.cleanup() }
            b.conditions.network = .metered
            var ids: [UUID] = []
            for _ in 0..<30 { ids.append(try a.record([])) }
            await a.sync.enable()
            await b.sync.enable()
            await settleAudio([a, b])
            #expect(await S.markerIDs(cloud).count == 30)
            for id in ids { try await dropBlob(cloud, id) }
            b.conditions.network = .unmetered
            await b.audio.drain()
            #expect(await b.transfer?.downloads == 30)
            #expect(b.audio.notFoundMarkerDeletes == 25)
            #expect(await S.markerIDs(cloud).count == 5)
            #expect(b.sync.lastError?.message == "Some audio in iCloud couldn't be found.")
            await b.audio.drain()
            #expect(await S.markerIDs(cloud).count == 5)
        }

        @Test func aRecordingIsUploadedAtMostThreeTimesPerLaunch() async throws {
            let (cloud, _, a, _) = try await S.pair()
            defer { a.cleanup() }
            let id = try a.record([], audioSeconds: 2)
            await a.sync.enable()
            for _ in 0..<4 {
                await settleAudio([a])
                try await dropBlob(cloud, id)
                await cloud.injectDelete(account: account, SyncRecordID(type: .audio, entityID: id))
            }
            await settleAudio([a])
            #expect(await a.transfer?.uploads == 3)
            #expect(await S.blobIDs(cloud).isEmpty)
            await a.relaunch()
            await a.sync.start()
            await settleAudio([a])
            #expect(await a.transfer?.uploads == 1)
            #expect(await S.blobIDs(cloud) == [id])
        }
    }
}
