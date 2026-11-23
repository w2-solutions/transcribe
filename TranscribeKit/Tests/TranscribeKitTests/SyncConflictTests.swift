import Foundation
import SwiftData
import Testing
import TranscribeCore
@testable import TranscribeFakes
@testable import TranscribeKit

extension SyncSuites {
    /// Three-way merges per field group (§8.4, D5).
    @Suite("Sync: conflicts")
    @MainActor
    struct SyncConflictTests {
        /// Different groups of one record edited on two devices: both edits survive.
        @Test func differentGroupsOfOneRecordAreBothKept() async throws {
            let t = try await TwoDevices.make()
            defer { t.cleanup() }
            try t.a.store.rename(id: t.r1, title: "From A")
            try t.b.store.setFavourite(id: t.r1, true)
            await t.settleBoth()
            for d in t.devices {
                #expect(d.recording(t.r1)?.title == "From A" && d.recording(t.r1)?.isFavourite == true)
            }
            expectConverged(t.devices)
        }

        /// Both devices edit the title: the device that saves later wins (no clocks involved).
        @Test func bothEditTheTitleAndTheLaterSaveWins() async throws {
            let t = try await TwoDevices.make()
            defer { t.cleanup() }
            try t.a.store.rename(id: t.r1, title: "Saved first")
            try t.b.store.rename(id: t.r1, title: "Saved second")
            await t.a.sync.syncNow()
            await t.b.sync.syncNow()
            await t.settleBoth()
            for d in t.devices { #expect(d.recording(t.r1)?.title == "Saved second") }
            expectConverged(t.devices)
        }

        /// The label of a speaker on one device and its turn counts (another group of the same record) on the other,
        /// plus the recording's favourite: all kept.
        @Test func labelAgainstStatsAndFavouriteAreAllKept() async throws {
            let t = try await TwoDevices.make()
            defer { t.cleanup() }
            _ = try t.a.store.nameSpeaker(recordingID: t.r2, key: "S2", as: .newPerson(name: "Sam"), remember: true)
            let turn = try #require(t.b.recording(t.r2)?.transcript?.turns.first { $0.speakerKey == "S1" })
            try t.b.store.reassignTurn(recordingID: t.r2, turnID: turn.id, to: .speaker("S2"))
            try t.b.store.setFavourite(id: t.r2, true)
            let s2Turns = try #require(t.b.recording(t.r2)?.speaker("S2")?.turnCount)
            await t.settleBoth()
            for d in t.devices {
                let r = try #require(d.recording(t.r2))
                let s2 = try #require(r.speaker("S2"))
                #expect(s2.profile?.name == "Sam" && s2.label == .named)       // A's label group
                #expect(s2.turnCount == s2Turns)                               // B's stats group
                #expect(r.isFavourite)
                #expect(r.transcript?.turns.first { $0.id == turn.id }?.speakerKeyOverride == "S2")
            }
            expectConverged(t.devices)
        }

        /// Rejections made on both devices for one speaker end as the union.
        @Test func rejectedProfilesTakeTheUnion() async throws {
            let t = try await TwoDevices.make()
            defer { t.cleanup() }
            // A rejects the Karan suggestion; B (offline) had it suggested as Liam and rejects that.
            try t.a.store.rejectSuggestion(recordingID: t.r2, key: "S1")
            let bS1 = try #require(t.b.recording(t.r2)?.speaker("S1"))
            bS1.suggestedProfileID = t.liam
            try t.b.context.save()
            try t.b.store.rejectSuggestion(recordingID: t.r2, key: "S1")
            await t.a.sync.syncNow()
            await t.b.sync.syncNow()
            await t.settleBoth()
            let expected = LibraryStore.sortedIDs([t.karan, t.liam])
            for d in t.devices { #expect(d.recording(t.r2)?.speaker("S1")?.rejectedProfileIDs == expected) }
            expectConverged(t.devices)
        }

        @Test func mergePolicyDecisions() {
            let type = SyncRecordType.speaker
            let base = ["ident": "i0", "stats": "s0", "label": "l0", "rejected": "r0"]
            let local = ["ident": "i0", "stats": "s1", "label": "l1", "rejected": "r1"]
            let server = ["ident": "i2", "stats": "s0", "label": "l2", "rejected": "r2"]
            let d = MergePolicy.decide(type: type, local: local, base: base, server: server)
            #expect(d["ident"] == .takeServer)   // only the server changed it
            #expect(d["stats"] == .keepLocal)    // only this device changed it
            #expect(d["label"] == .keepLocal)    // both: this device wins
            #expect(d["rejected"] == .union)     // both: union
            // Never agreed with the server: every differing group is local.
            let fresh = MergePolicy.decide(type: .recording, local: ["title": "a", "fav": "f"], base: [:],
                                           server: ["title": "b", "fav": "f"])
            #expect(fresh["title"] == .keepLocal && fresh["fav"] == .same)
        }

        /// A stale change tag: the send meets `serverRecordChanged`, the merge keeps this device's group, takes the
        /// other device's group, and re-sends, all before any fetch.
        @Test func serverRecordChangedOnAStaleChangeTag() async throws {
            let t = try await TwoDevices.make()
            defer { t.cleanup() }
            try t.b.store.rename(id: t.r1, title: "From B")
            await t.b.sync.syncNow()
            let name = SyncRecordID(type: .recording, entityID: t.r1).recordName
            let tagAfterB = try #require(await t.cloud.record(account: "account-1", recordName: name)?.systemFields)
            #expect(t.a.stateRow(SyncRecordID(type: .recording, entityID: t.r1))?.systemFields != tagAfterB)   // A's tag is stale

            try t.a.store.setFavourite(id: t.r1, true)
            await t.a.sync.flushAndEnqueue()
            try await t.a.transport.sendChanges()   // no fetch first
            #expect(t.a.recording(t.r1)?.title == "From B")   // merged from the server copy
            let server = try #require(await t.cloud.record(account: "account-1", recordName: name))
            #expect(server.fields["title"] == .string("From B") && server.fields["isFavourite"] == .int(1))
            #expect(t.a.pending == 0)
            await t.settleBoth()
            expectConverged(t.devices)
        }
    }
}
