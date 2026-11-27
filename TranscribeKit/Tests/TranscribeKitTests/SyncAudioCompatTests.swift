import Foundation
import SwiftData
import Testing
import TranscribeCore
@testable import TranscribeFakes
@testable import TranscribeKit

extension SyncSuites {
    /// Audio sync beside builds without it, and the core's blindness to audio state (§5.1 "Sync: audio and other
    /// builds"): an older build never sees audio, audio rows never reach a generic sync path, and every reset forgets
    /// audio state without deleting audio anywhere.
    @Suite("Sync: audio and other builds")
    @MainActor
    struct SyncAudioCompatTests {
        typealias S = AudioScenario
        let account = "account-1"

        /// A and B (iPhone and Mac, audio sync on) share `n` recordings made on A, audio settled on both.
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

        func audioRows(_ d: FakeDevice) -> [SyncRecordState] { d.stateRows().filter(\.isAudioRow) }

        /// Every library state row, counted by type (audio rows left out).
        func libraryRowCounts(_ d: FakeDevice) -> [String: Int] {
            Dictionary(grouping: d.stateRows().filter { !$0.isAudioRow }, by: \.typeRaw).mapValues(\.count)
        }

        // MARK: Older builds

        @Test func anOlderBuildNeverDownloadsAudio() async throws {
            let (cloud, clock, a, b) = try await S.pair()
            let c = try FakeDevice("C", cloud: cloud, channel: CaptureChannel.iphone, clock: clock, audio: false)
            defer { a.cleanup(); b.cleanup(); c.cleanup() }
            let ids = [try a.record([], audioSeconds: 2), try a.record([], audioSeconds: 2), try b.record([], audioSeconds: 2)]
            await a.sync.enable()
            await b.sync.enable()
            await c.sync.enable()
            await settleAudio([a, b, c])
            #expect(await S.markerIDs(cloud) == Set(ids))
            #expect(await S.blobIDs(cloud) == Set(ids))
            // C (a 0.3.3 build) has no audio transfer at all, keeps no audio state and holds no downloaded audio.
            #expect(c.sync.audio == nil && c.transfer == nil)
            #expect(audioRows(c).isEmpty)
            #expect(try FileManager.default.contentsOfDirectory(atPath: c.paths.audioDirectory.path).isEmpty)
            for id in ids { #expect(!c.store.hasLocalAudio(try #require(c.recording(id)))) }
            // It is never paused, never told to update, and its library converges.
            #expect(!c.sync.status.isPaused)
            #expect(!c.sync.otherDeviceNeedsUpdate)
            #expect(c.sync.status == .idle(lastSync: clock.date))
            try a.store.rename(id: ids[0], title: "Seen by the older build")
            await settleAudio([a, b, c])
            #expect(c.recording(ids[0])?.title == "Seen by the older build")
            expectConverged([a, b, c])
            await expectAudioConverged([a, b, c])
        }

        @Test func audioRowsAreInvisibleToTheCore() async throws {
            let (_, clock, a, b, ids) = try await shared(2)
            defer { a.cleanup(); b.cleanup() }
            #expect(audioRows(a).count == 2)
            #expect(a.pending == 0)

            // Rows waiting to go count once each, as markers; settled rows count nothing.
            a.audio.isInFront = { false }   // nothing acts on the rows while they are inspected
            let sending = UUID(), deleting = UUID()
            a.context.insert(SyncRecordState.audioRow(AudioRowFacts(descriptor: S.descriptor(sending), marker: .sending,
                                                                    recordingSeen: true, firstSeenAt: clock.date), now: clock.date))
            a.context.insert(SyncRecordState.audioRow(AudioRowFacts(descriptor: S.descriptor(deleting), marker: .deleting,
                                                                    recordingSeen: true, firstSeenAt: clock.date), now: clock.date))
            // 30 known markers whose recordings this device never saw: as many as would trip the breaker.
            for _ in 0..<30 {
                a.context.insert(SyncRecordState.audioRow(AudioRowFacts(descriptor: S.descriptor(UUID()), marker: .onServer,
                                                                        recordingSeen: false, firstSeenAt: clock.date),
                                                          now: clock.date))
            }
            try a.context.save()
            #expect(a.pending == 2)
            #expect(a.audio.pendingMarkerSaves.map(\.entityID) == [sending])
            #expect(a.audio.pendingMarkerDeletes.map(\.entityID) == [deleting])
            #expect(audioRows(a).allSatisfy { $0.recordID == nil && $0.pending == .none })

            // A full scan sees none of them: no save, no delete, no breaker.
            let before = Dictionary(uniqueKeysWithValues: audioRows(a).map { ($0.recordName, $0.baseHashesJSON) })
            let scan = try await a.sync.detector.fullScan()
            #expect(scan.massDelete == nil)
            #expect(scan.saves.isEmpty && scan.deletes.isEmpty)
            #expect(!(scan.saves + scan.deletes).contains { $0.type == .audio })
            // Finishing a fetch (links, invariants) leaves them alone too.
            _ = try a.sync.applier.finishFetch(touchedProfiles: [])
            try a.context.save()
            let after = Dictionary(uniqueKeysWithValues: audioRows(a).map { ($0.recordName, $0.baseHashesJSON) })
            #expect(after == before)
            #expect(audioRows(a).allSatisfy { $0.pending == .none && $0.systemFields == nil && $0.unresolvedLinksJSON == nil })
            #expect(ids.allSatisfy { a.recording($0) != nil })

            // SyncMassDeleteTests' set-up gives the same breaker count and library state counts with audio sync on.
            let without = try await massDeleteCounts(audio: false)
            let with = try await massDeleteCounts(audio: true)
            #expect(without.held == 52)
            #expect(with.held == without.held)
            #expect(with.records == without.records)
            #expect(with.a == without.a)
            #expect(with.b == without.b)
        }

        /// SyncMassDeleteTests' set-up (100 shared one-speaker recordings, 26 deleted while not running), with or
        /// without audio sync: what the breaker holds and every library state count.
        func massDeleteCounts(audio: Bool) async throws -> (held: Int, records: Int, a: [String: Int], b: [String: Int]) {
            let cloud = FakeCloud()
            let clock = TestClock()
            await cloud.setNow { clock.date }
            let a = try FakeDevice("A", cloud: cloud, clock: clock, audio: audio)
            let b = try FakeDevice("B", cloud: cloud, channel: CaptureChannel.mac, clock: clock, audio: audio, platform: .mac)
            defer { a.cleanup(); b.cleanup() }
            var ids: [UUID] = []
            for i in 0..<100 {
                ids.append(try a.record([SyncVoices.stranger(i % 50, 0.6)]))
                clock.advance(10)
                await Task.yield()
            }
            await a.sync.enable()
            await b.sync.enable()
            if audio { await settleAudio([a, b]) } else { await settle([a, b]) }
            if audio { #expect(await S.blobIDs(cloud).count == 100) }
            try await a.sync.disable(removeCloudCopy: false)
            a.settings.syncEnabled = true
            for id in ids.prefix(26) {
                try a.store.delete(id: id)
                await Task.yield()
            }
            await a.relaunch()
            await a.sync.start()
            if audio { await a.audio.drain() }
            #expect(a.sync.status == .paused(.massDelete))
            let records = await cloud.records(account: account).keys.filter { !$0.hasPrefix("au.") }.count
            return (a.sync.heldDeleteCount, records, libraryRowCounts(a), libraryRowCounts(b))
        }

        @Test func downgradedStoreIgnoresAudioRows() async throws {
            let (cloud, _, a, b, ids) = try await shared(2)
            defer { a.cleanup(); b.cleanup() }
            let rows = Dictionary(uniqueKeysWithValues: audioRows(a).map { ($0.recordName, $0.baseHashesJSON) })
            #expect(rows.count == 2)
            #expect(audioRows(a).allSatisfy { $0.recordID == nil })

            // A build without audio sync opens the same store: it syncs as before and never touches the rows.
            await a.relaunch(audio: false)
            #expect(a.sync.audio == nil)
            await a.sync.start()
            #expect(a.pending == 0)
            try a.store.rename(id: ids[0], title: "On the older build")
            await settle([a, b])
            #expect(b.recording(ids[0])?.title == "On the older build")
            #expect(!a.sync.status.isPaused)
            expectConverged([a, b])
            #expect(Dictionary(uniqueKeysWithValues: audioRows(a).map { ($0.recordName, $0.baseHashesJSON) }) == rows)
            #expect(await S.blobIDs(cloud) == Set(ids))

            // Back on this build: the rows are used again, and nothing is sent twice.
            await a.relaunch(audio: true)
            await a.sync.start()
            await settleAudio([a, b])
            #expect(await a.transfer?.uploads == 0)
            #expect(await a.transfer?.probes == 0)
            await expectAudioConverged([a, b])
        }

        // MARK: Resets forget audio state and delete nothing

        @Test func clearSyncStateForgetsAudioWithoutDeleting() async throws {
            let (cloud, _, a, b, ids) = try await shared(2)
            defer { a.cleanup(); b.cleanup() }
            let blobs = await cloud.audio(account: account)
            #expect(audioRows(a).count == 2)

            // An environment change clears the sync state at start.
            a.settings.syncCloudEnvironment = "Development"
            await a.relaunch()
            a.sync.cloudEnvironment = "Production"
            a.audio.isInFront = { false }
            await cloud.setNetworkDown(true)       // keep the markers from coming straight back
            await a.sync.start()
            #expect(audioRows(a).isEmpty)
            await cloud.setNetworkDown(false)
            a.audio.isInFront = { true }
            await settleAudio([a, b])
            #expect(await cloud.audio(account: account) == blobs)
            #expect(await a.transfer?.bytesUp == 0)
            #expect(await a.transfer?.deletes == 0)
            #expect(audioRows(a).compactMap(\.audioFacts).allSatisfy { $0.marker == .onServer })
            #expect(Set(audioRows(a).map(\.entityID)) == Set(ids))

            // An account merge clears it too: this library's audio joins the new account, and the old one keeps its own.
            await a.transport.signIn("account-2")
            #expect(a.sync.status == .paused(.accountChanged))
            await a.sync.resolveAccountChange(merge: true)
            await settleAudio([a], account: "account-2")
            #expect(Set(await cloud.audio(account: "account-2").keys) == Set(ids))
            #expect(await cloud.audio(account: account) == blobs)
            let joined = await a.transfer?.bytesUp ?? 0
            var total: Int64 = 0
            for id in ids { total += try S.fileSize(a, id) }
            #expect(joined == total)

            // Merging back into the first account adopts the blobs already there: nothing goes up.
            await a.transport.signIn(account)
            #expect(a.sync.status == .paused(.accountChanged))
            await a.sync.resolveAccountChange(merge: true)
            await settleAudio([a, b])
            #expect(await a.transfer?.bytesUp == joined)
            #expect(await a.transfer?.deletes == 0)
            #expect(await cloud.audio(account: account) == blobs)
            #expect(Set(await cloud.audio(account: "account-2").keys) == Set(ids))
            #expect(Set(audioRows(a).map(\.entityID)) == Set(ids))
            await expectAudioConverged([a, b])
        }

        @Test func zoneRemovedElsewhereKeepsLocalAudioAndAdoptsOnRejoin() async throws {
            let (cloud, _, a, b, ids) = try await shared(2)
            defer { a.cleanup(); b.cleanup() }
            let blobs = await cloud.audio(account: account)
            let up = (await a.transfer?.bytesUp ?? 0, await b.transfer?.bytesUp ?? 0)
            // Another device (an older build, which cannot delete audio) removed the iCloud copy.
            await cloud.removeZone(account: account, reason: .deleted)
            await a.sync.syncNow()
            await b.sync.syncNow()
            #expect(a.sync.status == .paused(.zoneRemoved))
            #expect(b.sync.status == .paused(.zoneRemoved))
            #expect(audioRows(a).isEmpty && audioRows(b).isEmpty)
            for id in ids {
                #expect(a.store.hasLocalAudio(try #require(a.recording(id))))
                #expect(b.store.hasLocalAudio(try #require(b.recording(id))))
            }
            #expect(await cloud.audio(account: account) == blobs)

            await a.sync.enable()
            await b.sync.enable()
            await settleAudio([a, b])
            #expect(await a.transfer?.bytesUp == up.0)
            #expect(await b.transfer?.bytesUp == up.1)
            #expect(await cloud.audio(account: account) == blobs)
            #expect(await S.markerIDs(cloud) == Set(ids))
            #expect(await a.transfer?.deletes == 0)
            #expect(await b.transfer?.deletes == 0)
            await expectAudioConverged([a, b])
        }

        @Test func purgeLeavesNothingAndReuploadsAfterRejoin() async throws {
            let (cloud, _, a, b, ids) = try await shared(2)
            defer { a.cleanup(); b.cleanup() }
            let up = (await a.transfer?.bytesUp ?? 0) + (await b.transfer?.bytesUp ?? 0)
            await cloud.removeZone(account: account, reason: .purged)
            #expect(await S.blobIDs(cloud).isEmpty)
            await a.sync.syncNow()
            await b.sync.syncNow()
            #expect(a.sync.status == .paused(.zoneRemoved))
            #expect(b.sync.status == .paused(.zoneRemoved))
            for id in ids {
                #expect(a.store.hasLocalAudio(try #require(a.recording(id))))
                #expect(b.store.hasLocalAudio(try #require(b.recording(id))))
            }

            await a.sync.enable()
            await b.sync.enable()
            await settleAudio([a, b])
            #expect(await S.blobIDs(cloud) == Set(ids))
            #expect(await S.markerIDs(cloud) == Set(ids))
            // Each recording's audio was stored once more, by whichever device got there first.
            var total: Int64 = 0
            for id in ids { total += try S.fileSize(a, id) }
            let after = (await a.transfer?.bytesUp ?? 0) + (await b.transfer?.bytesUp ?? 0)
            #expect(after - up == total)
            #expect(await a.transfer?.deletes == 0)
            #expect(await b.transfer?.deletes == 0)
            await expectAudioConverged([a, b])
        }

        @Test func signOutCancelsTransfersAndDeletesNothing() async throws {
            let (cloud, _, a, b) = try await S.pair()
            defer { a.cleanup(); b.cleanup() }
            await a.sync.enable()
            await b.sync.enable()
            let id = try a.record([], audioSeconds: 2)
            await settleAudio([a])
            let blobs = await cloud.audio(account: account)
            let hold = AudioHold()
            await cloud.setAudioHook { op, _ in if op == .download { await hold.wait() } }
            await b.sync.syncNow()
            await waitUntil("B's download") { await hold.arrived == 1 }
            let loop = b.audio.loopTask
            await b.transport.signOut()
            #expect(b.sync.status == .paused(.noAccount))
            await hold.release()
            await loop?.value
            await b.audio.drain()
            await cloud.setAudioHook(nil)
            let r = try #require(b.recording(id))
            #expect(!b.store.hasLocalAudio(r))
            #expect(try FileManager.default.contentsOfDirectory(atPath: b.paths.audioIncomingDirectory.path).isEmpty)
            #expect(b.audio.progress.isEmpty)
            #expect(b.audio.failures[id] == nil)
            #expect(await cloud.audio(account: account) == blobs)
            #expect(await a.transfer?.deletes == 0)
            #expect(await b.transfer?.deletes == 0)
            #expect(a.store.hasLocalAudio(try #require(a.recording(id))))
            #expect(S.facts(b, id)?.marker == .onServer)   // nothing forgotten either

            // Signed in again: the download runs.
            await b.transport.signIn(account)
            await waitUntil("B to run again") { b.sync.running }
            await settleAudio([a, b])
            #expect(b.store.hasLocalAudio(r))
        }

        @Test func anAccountSwitchStopsJobsBeforeTheCoordinatorKnows() async throws {
            let (cloud, _, a, _) = try await S.pair()
            defer { a.cleanup() }
            let first = try a.record([], audioSeconds: 2)
            a.audio.isInFront = { false }
            await a.sync.enable()
            await settle([a])
            #expect(a.stateRow(SyncRecordID(type: .recording, entityID: first))?.systemFields != nil)

            // The fake transport cannot switch accounts silently, so the stored hash moves instead: the signed-in
            // account is no longer the one this library syncs with, and the coordinator has not heard yet.
            a.sync.account.accountHash = "account-0"
            #expect(!(await a.sync.currentAccountMatches()))
            #expect(a.sync.audioMayRun)
            a.audio.isInFront = { true }
            await a.audio.drain()
            let t = try #require(a.transfer)
            #expect(await [t.probes, t.uploads, t.downloads, t.deletes, t.listings, t.recordingChecks] == [0, 0, 0, 0, 0, 0])
            #expect(await S.blobIDs(cloud).isEmpty)
            #expect(await cloud.audio(account: "account-0").isEmpty)
            // The same library on the same account again: the job runs.
            a.sync.account.accountHash = account
            await a.audio.drain()
            #expect(await S.blobIDs(cloud) == [first])

            // A real switch: whichever comes first, the account check or the coordinator's pause, nothing moves.
            let second = try a.record([], audioSeconds: 2)
            a.audio.isInFront = { false }
            await a.sync.flushAndEnqueue()
            await a.sync.sync(fullScan: false)
            #expect(a.stateRow(SyncRecordID(type: .recording, entityID: second))?.systemFields != nil)
            let before = (await t.probes, await t.uploads)
            a.audio.isInFront = { true }
            a.audio.pump()
            await a.transport.signIn("account-2")
            await a.audio.drain()
            #expect(a.sync.status == .paused(.accountChanged))
            #expect(await t.probes == before.0)
            #expect(await t.uploads == before.1)
            #expect(await S.blobIDs(cloud) == [first])
            #expect(await cloud.audio(account: "account-2").isEmpty)
        }

        @Test func aJobResumingAfterResetWritesNothing() async throws {
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
            let epoch = b.audio.epoch
            // An account merge: B signs in to another account and adds this library to it.
            await b.transport.signIn("account-2")
            await b.sync.resolveAccountChange(merge: true)
            #expect(b.audio.epoch > epoch)
            await hold.release()
            await b.audio.drain()
            await cloud.setAudioHook(nil)
            let audio = try FileManager.default.contentsOfDirectory(atPath: b.paths.audioDirectory.path)
            #expect(!audio.contains { $0.hasPrefix(id.uuidString) })
            #expect(try FileManager.default.contentsOfDirectory(atPath: b.paths.audioIncomingDirectory.path).isEmpty)
            #expect(S.facts(b, id) == nil)
            #expect(!b.store.hasLocalAudio(try #require(b.recording(id))))
            // The other account has no audio for it, so the state says so (no row, probed absent).
            #expect(b.audio.state(of: try #require(b.recording(id))) == .notInICloud(channel: CaptureChannel.iphone))
            #expect(await cloud.audio(account: "account-2").isEmpty)
            #expect(await S.blobIDs(cloud) == [id])
        }

        // MARK: No generic path sees audio

        /// The scenario `noGenericPathSeesAnAudioID` runs with and without audio sync: A records two recordings and
        /// names a voice, both sync, B renames one and A deletes the other. With audio, the audio moves, is deleted
        /// with its recording, and then both devices upload one recording's audio at once (a marker conflict).
        /// Returns both devices' library projections with ids blanked, and the devices for further checks.
        func generalScenario(audio: Bool) async throws -> (projections: [[String]], cloud: FakeCloud, a: FakeDevice,
                                                           b: FakeDevice, ids: [UUID]) {
            let cloud = FakeCloud()
            let clock = TestClock()
            await cloud.setNow { clock.date }
            let a = try FakeDevice("A", cloud: cloud, channel: CaptureChannel.iphone, clock: clock, audio: audio)
            let b = try FakeDevice("B", cloud: cloud, channel: CaptureChannel.mac, clock: clock, audio: audio, platform: .mac)
            let r1 = try a.record([SyncVoices.karan(1), SyncVoices.liam(2)], audioSeconds: 2)
            _ = try a.store.nameSpeaker(recordingID: r1, key: "S1", as: .newPerson(name: "Karan"), remember: true)
            clock.advance(60)
            let r2 = try a.record([SyncVoices.stranger(3)], audioSeconds: 2)
            let settleAll: () async -> Void = { if audio { await settleAudio([a, b]) } else { await settle([a, b]) } }
            await a.sync.enable()
            await b.sync.enable()
            await settleAll()
            try b.store.rename(id: r1, title: "Renamed on B")
            try a.store.delete(id: r2)
            await settleAll()

            if audio {
                // r1's blob and marker vanish; both devices hold its audio and upload it again at the same time.
                try await cloud.audioDelete(account: account, ids: [r1])
                a.audio.isInFront = { false }
                b.audio.isInFront = { false }
                await cloud.injectDelete(account: account, SyncRecordID(type: .audio, entityID: r1))
                await settle([a, b])
                #expect(S.facts(a, r1) == nil && S.facts(b, r1) == nil)
                let uploads = (await a.transfer?.options(.upload, r1).count ?? 0, await b.transfer?.options(.upload, r1).count ?? 0)
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
                #expect(await a.transfer?.options(.upload, r1).count == uploads.0 + 1)
                #expect(await b.transfer?.options(.upload, r1).count == uploads.1 + 1)
                await settleAll()
            }
            return ([Self.blanked(a), Self.blanked(b)], cloud, a, b, [r1, r2])
        }

        /// A device's library projections with every UUID blanked and record names reduced to their type, sorted.
        static func blanked(_ d: FakeDevice) -> [String] {
            let uuid = /[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}/
            return d.projections().map { name, fields in
                let body = fields.keys.sorted().map { "\($0)=\(String(describing: fields[$0]!))" }.joined(separator: ";")
                return "\(name.prefix { $0 != "." })|" + body.replacing(uuid, with: "<id>")
            }.sorted()
        }

        @Test func noGenericPathSeesAnAudioID() async throws {
            let plain = try await generalScenario(audio: false)
            defer { plain.a.cleanup(); plain.b.cleanup() }
            let run = try await generalScenario(audio: true)
            defer { run.a.cleanup(); run.b.cleanup() }
            let (a, b) = (run.a, run.b)
            #expect(await S.markerIDs(run.cloud) == [run.ids[0]])
            #expect(await S.blobIDs(run.cloud) == [run.ids[0]])
            await expectAudioConverged([a, b])

            for d in [a, b] {
                // No generic state row was ever made for a marker.
                #expect(!d.stateRows().contains { $0.typeRaw == SyncRecordType.audio.rawValue })
                #expect(!d.stateRows().contains { !$0.isAudioRow && $0.recordName.hasPrefix("au.") })
                // No entity other than its recording carries a marker's id.
                let projector = RecordProjector(context: d.context)
                let markerIDs = Set(audioRows(d).map(\.entityID)).union(await S.markerIDs(run.cloud))
                for type in SyncRecordType.libraryCases where type != .recording {
                    let ids = Set(try projector.allIDs(type))
                    #expect(ids.isDisjoint(with: markerIDs), "\(d.name): a \(type) has a marker's id")
                }
                #expect(try projector.all(.audio).isEmpty)
                #expect(try projector.allIDs(.audio).isEmpty)
            }
            // The library itself is exactly what the same scenario gives without audio sync.
            #expect(run.projections[0] == run.projections[1])
            #expect(run.projections[0] == plain.projections[0])
            #expect(plain.projections[0] == plain.projections[1])
            expectConverged([a, b])
        }
    }
}
