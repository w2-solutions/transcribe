import Foundation
import SwiftData
import Testing
import TranscribeCore
@testable import TranscribeFakes
@testable import TranscribeKit

extension SyncSuites {
    /// The mass-delete breaker (§8.4 flow 1): a full scan that would send more than 25 deletes of one type, and more
    /// than 20% of that type's synced rows, pauses and queues nothing.
    @Suite("Sync: mass delete")
    @MainActor
    struct SyncMassDeleteTests {
        /// A and B share `count` one-speaker recordings. Then A deletes `deleting` of them while not running (as a store
        /// restored from an old backup would look), and relaunches: the launch full scan sees the deletes.
        func setUp(count: Int, deleting: Int) async throws -> (FakeDevice, FakeDevice, [UUID]) {
            let cloud = FakeCloud()
            let clock = TestClock()
            let a = try FakeDevice("A", cloud: cloud, clock: clock), b = try FakeDevice("B", cloud: cloud, channel: CaptureChannel.mac, clock: clock)
            var ids: [UUID] = []
            for i in 0..<count {
                ids.append(try a.record([SyncVoices.stranger(i % 50, 0.6)]))
                clock.advance(10)
                await Task.yield()   // other tests share the main actor
            }
            await a.sync.enable()
            await b.sync.enable()
            await settle([a, b])
            try await a.sync.disable(removeCloudCopy: false)
            a.settings.syncEnabled = true
            for id in ids.prefix(deleting) {
                try a.store.delete(id: id)
                await Task.yield()
            }
            await a.relaunch()
            await a.sync.start()
            return (a, b, ids)
        }

        @Test func tripsAt26DeletesAndMoreThan20Percent() async throws {
            let (a, b, ids) = try await setUp(count: 100, deleting: 26)
            defer { a.cleanup(); b.cleanup() }
            #expect(a.sync.status == .paused(.massDelete))
            #expect(a.sync.heldDeleteCount == 52)   // 26 recordings and their 26 speakers
            #expect(await a.cloud.records(account: "account-1").count == 200)   // nothing was sent
            await b.sync.syncNow()
            #expect(b.recording(ids[0]) != nil)
            // It stays paused through Sync Now.
            await a.sync.syncNow()
            #expect(a.sync.status == .paused(.massDelete))
        }

        @Test func twentyFiveDeletesDoNotTrip() async throws {
            let (a, b, ids) = try await setUp(count: 100, deleting: 25)
            defer { a.cleanup(); b.cleanup() }
            #expect(!a.sync.status.isPaused)
            await settle([a, b])
            #expect(b.recording(ids[0]) == nil && b.count(Recording.self) == 75)
            expectConverged([a, b])
        }

        @Test func twentySixOf200DoNotTrip() async throws {
            let (a, b, ids) = try await setUp(count: 200, deleting: 26)
            defer { a.cleanup(); b.cleanup() }
            #expect(!a.sync.status.isPaused)   // 13%
            await settle([a, b])
            #expect(b.recording(ids[25]) == nil && b.count(Recording.self) == 174)
            expectConverged([a, b])
        }

        @Test func confirmSendsTheDeletes() async throws {
            let (a, b, ids) = try await setUp(count: 100, deleting: 26)
            defer { a.cleanup(); b.cleanup() }
            await a.sync.resolveMassDelete(confirm: true)
            #expect(!a.sync.status.isPaused)
            #expect(await a.cloud.records(account: "account-1").count == 148)
            await settle([a, b])
            #expect(b.count(Recording.self) == 74 && b.recording(ids[0]) == nil && b.recording(ids[26]) != nil)
            expectConverged([a, b])
        }

        @Test func restoreBringsThemBack() async throws {
            let (a, b, ids) = try await setUp(count: 100, deleting: 26)
            defer { a.cleanup(); b.cleanup() }
            await a.sync.resolveMassDelete(confirm: false)
            #expect(!a.sync.status.isPaused)
            #expect(a.count(Recording.self) == 100 && a.count(RecordingSpeaker.self) == 100)
            #expect(a.recording(ids[0])?.speakers.count == 1)
            #expect(await a.cloud.records(account: "account-1").count == 200)
            await settle([a, b])
            expectConverged([a, b])
        }
    }
}

extension SyncSuites.SyncMassDeleteTests {
    /// "Restore them from iCloud" also restores the deleted items another device edited meanwhile: a fetched edit of
    /// an item deleted here goes through the breaker like every other delete, and is not sent ahead of it.
    @Test func restoreKeepsItemsEditedElsewhere() async throws {
        let cloud = FakeCloud()
        let clock = TestClock()
        let a = try FakeDevice("A", cloud: cloud, clock: clock), b = try FakeDevice("B", cloud: cloud, channel: CaptureChannel.mac, clock: clock)
        defer { a.cleanup(); b.cleanup() }
        var ids: [UUID] = []
        for i in 0..<40 {
            ids.append(try a.record([SyncVoices.stranger(i % 50, 0.6)]))
            clock.advance(10)
            await Task.yield()
        }
        await a.sync.enable()
        await b.sync.enable()
        await settle([a, b])
        try await a.sync.disable(removeCloudCopy: false)
        for id in ids.prefix(35) {
            try a.store.delete(id: id)
            await Task.yield()
        }
        for (i, id) in ids.prefix(5).enumerated() {   // B names the speaker in 5 of them
            _ = try b.store.nameSpeaker(recordingID: id, key: "S1", as: .newPerson(name: "P\(i)"), remember: true)
            clock.advance(10)
        }
        await b.sync.syncNow()
        await a.sync.enable()
        #expect(a.sync.status == .paused(.massDelete))
        #expect(a.sync.heldDeleteCount == 70)   // 35 recordings and their 35 speakers, the edited ones included
        await a.sync.resolveMassDelete(confirm: false)
        await settle([a, b])
        #expect(a.count(Recording.self) == 40 && b.count(Recording.self) == 40)
        for (i, id) in ids.prefix(5).enumerated() {
            for d in [a, b] {
                #expect(d.recording(id)?.speakers.count == 1, "\(d.name) \(i)")
                #expect(d.recording(id)?.speaker("S1")?.displayName == "P\(i)", "\(d.name) \(i)")
            }
        }
        expectConverged([a, b])
    }
}
