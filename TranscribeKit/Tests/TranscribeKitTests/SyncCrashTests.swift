import Foundation
import SwiftData
import Testing
import TranscribeCore
@testable import TranscribeFakes
@testable import TranscribeKit

extension SyncSuites {
    /// Crash points (§8.7): everything since the last save is lost, and a relaunch reaches the same end state.
    @Suite("Sync: crashes")
    @MainActor
    struct SyncCrashTests {
        /// A library of 40 two-speaker recordings: more than one chunk of 100 records.
        static func bigLibrary(on d: FakeDevice) async throws {
            for i in 0..<40 {
                try d.record([SyncVoices.stranger(i % 50, 0.6), SyncVoices.liam((i + 7) % 50, 0.6)])
                d.clock.advance(30)
                await Task.yield()   // other tests share the main actor
            }
        }

        /// B joins a 120-record library and crashes before saving the n-th fetched chunk. Its relaunch fetches from the
        /// last saved engine state and ends equal to A.
        @Test(arguments: [1, 2])
        func crashBetweenChunkApplyAndSave(chunk: Int) async throws {
            let cloud = FakeCloud()
            let a = try FakeDevice("A", cloud: cloud), b = try FakeDevice("B", cloud: cloud, channel: CaptureChannel.mac)
            defer { a.cleanup(); b.cleanup() }
            try await Self.bigLibrary(on: a)
            await a.sync.enable()
            #expect(await cloud.records(account: "account-1").count == 120)

            var seen = 0
            b.sync.fault = { point in
                guard point == .beforeChunkSave else { return }
                seen += 1
                if seen == chunk { throw SyncCrash() }
            }
            await b.sync.enable()
            #expect(b.sync.crashed)
            let applied = b.count(Recording.self)
            #expect(chunk == 1 ? applied == 0 : applied == 40)   // folders/profiles/recordings sort first: chunk 1 is the 40 recordings + 60 speakers

            await b.relaunch()
            await b.sync.start()
            await settle([a, b])
            #expect(b.count(Recording.self) == 40 && b.count(RecordingSpeaker.self) == 80)
            #expect(b.stateRows().count == 120)
            expectConverged([a, b])
        }

        /// A sends, the server accepts, and A crashes before saving the result (no system fields, no base). Its relaunch
        /// sends again, meets `serverRecordChanged`, merges to the same values and ends with nothing pending.
        @Test func crashBetweenSendResultAndSave() async throws {
            let t = try await TwoDevices.make()
            defer { t.cleanup() }
            let r3 = try t.a.record([SyncVoices.stranger(43)])
            try t.a.store.rename(id: t.r1, title: "Sent before the crash")
            t.a.sync.fault = { point in if point == .beforeSendResultSave { throw SyncCrash() } }
            await t.a.sync.syncNow()
            #expect(t.a.sync.crashed)
            let name = SyncRecordID(type: .recording, entityID: r3).recordName
            #expect(await t.cloud.record(account: "account-1", recordName: name) != nil)   // the server has it
            #expect(t.a.stateRow(SyncRecordID(type: .recording, entityID: r3))?.systemFields == nil)   // A never saved the ack

            await t.a.relaunch()
            await t.a.sync.start()
            await t.settleBoth()
            #expect(t.a.stateRow(SyncRecordID(type: .recording, entityID: r3))?.systemFields != nil)
            #expect(t.b.recording(r3) != nil && t.b.recording(t.r1)?.title == "Sent before the crash")
            #expect(await t.cloud.records(account: "account-1").count == t.a.projections().count)
            expectConverged(t.devices)
        }

        /// A crash while merging a conflict result is replayed the same way.
        @Test func crashWhileMergingAConflictReplays() async throws {
            let t = try await TwoDevices.make()
            defer { t.cleanup() }
            try t.b.store.rename(id: t.r1, title: "From B")
            await t.b.sync.syncNow()
            try t.a.store.setFavourite(id: t.r1, true)
            t.a.sync.fault = { point in if point == .beforeSendResultSave { throw SyncCrash() } }
            await t.a.sync.flushAndEnqueue()
            try await t.a.transport.sendChanges()
            #expect(t.a.sync.crashed && t.a.recording(t.r1)?.title == nil)   // the merge was rolled back
            await t.a.relaunch()
            await t.a.sync.start()
            await t.settleBoth()
            for d in t.devices { #expect(d.recording(t.r1)?.title == "From B" && d.recording(t.r1)?.isFavourite == true) }
            expectConverged(t.devices)
        }
    }
}
