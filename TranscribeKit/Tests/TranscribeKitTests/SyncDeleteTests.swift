import Foundation
import SwiftData
import Testing
import TranscribeCore
@testable import TranscribeFakes
@testable import TranscribeKit

extension SyncSuites {
    /// Delete wins (§8.4, D6): explicit child deletes, the same side effects as a local delete, and parked deletes.
    @Suite("Sync: deletes")
    @MainActor
    struct SyncDeleteTests {
        func names(_ cloud: FakeCloud) async -> Set<String> { Set(await cloud.records(account: "account-1").keys) }

        @Test func localDeleteRemovesTheRecordingAndItsSpeakersEverywhere() async throws {
            let t = try await TwoDevices.make()
            defer { t.cleanup() }
            let speakers = try #require(t.a.recording(t.r1)?.speakers.map(\.id))
            try t.a.store.delete(id: t.r1)
            await t.settleBoth()
            #expect(t.b.recording(t.r1) == nil)
            let cloud = await names(t.cloud)
            #expect(!cloud.contains(SyncRecordID(type: .recording, entityID: t.r1).recordName))
            // Speaker deletes are sent explicitly: nothing relies on a server-side cascade.
            for id in speakers { #expect(!cloud.contains(SyncRecordID(type: .speaker, entityID: id).recordName)) }
            #expect(t.b.count(VoiceSample.self) == 2)
            #expect(t.a.stateRows().count == t.b.stateRows().count)
            expectConverged(t.devices)
        }

        @Test func remoteDeleteHasTheLocalSideEffects() async throws {
            let t = try await TwoDevices.make()
            defer { t.cleanup() }
            // A recording made on B has its audio on B; deleting it on A removes B's audio file.
            let r3 = try t.b.record([SyncVoices.stranger(34)])
            let audio = t.b.paths.audioURL(fileName: try #require(t.b.recording(r3)).audioFileName)
            #expect(FileManager.default.fileExists(atPath: audio.path))
            await t.settleBoth()
            try t.a.store.delete(id: r3)
            // Forgetting Karan on A clears B's suggestion of him and keeps his name on the speakers he labelled.
            try t.a.store.forgetProfile(t.karan)
            await t.settleBoth()
            #expect(t.b.recording(r3) == nil)
            #expect(!FileManager.default.fileExists(atPath: audio.path))
            let suggested = try #require(t.b.recording(t.r2)?.speaker("S1"))
            #expect(suggested.suggestedProfileID == nil && suggested.label == .unnamed && suggested.matchScore == nil)
            let named = try #require(t.b.recording(t.r1)?.speaker("S1"))
            #expect(named.nameSnapshot == "Karan" && named.profile == nil)
            expectConverged(t.devices)
        }

        /// B renames a recording while offline; A deletes it. Delete wins whether B fetches first or sends first.
        @Test(arguments: [true, false])
        func deleteBeatsAnOfflineEdit(fetchFirst: Bool) async throws {
            let t = try await TwoDevices.make()
            defer { t.cleanup() }
            try t.b.store.rename(id: t.r1, title: "Offline edit")
            try t.b.store.setFavourite(id: t.r1, true)
            try t.a.store.delete(id: t.r1)
            await t.a.sync.syncNow()
            if fetchFirst {
                await t.b.sync.syncNow()
            } else {
                await t.b.sync.flushAndEnqueue()
                try await t.b.transport.sendChanges()   // meets unknownItem: the server no longer has it
                #expect(t.b.recording(t.r1) == nil)
            }
            await t.settleBoth()
            #expect(t.b.recording(t.r1) == nil && t.a.recording(t.r1) == nil)
            #expect(!(await names(t.cloud)).contains(SyncRecordID(type: .recording, entityID: t.r1).recordName))
            expectConverged(t.devices)
        }

        /// A locally deleted record that a fetch brings back (edited elsewhere) stays deleted and its delete is sent.
        @Test func aFetchedEditNeverResurrectsALocalDelete() async throws {
            let t = try await TwoDevices.make()
            defer { t.cleanup() }
            try t.a.store.rename(id: t.r1, title: "Edited on A")
            await t.a.sync.syncNow()
            try t.b.store.delete(id: t.r1)
            await t.b.sync.flushAndEnqueue()
            // B fetches A's edit before sending its delete.
            try await t.b.transport.fetchChanges()
            #expect(t.b.recording(t.r1) == nil)
            #expect(t.b.stateRow(SyncRecordID(type: .recording, entityID: t.r1))?.pending == .delete)
            await t.settleBoth()
            #expect(t.a.recording(t.r1) == nil)
            expectConverged(t.devices)
        }

        @Test func speakerDeletesFollowARecordingDelete() async throws {
            let t = try await TwoDevices.make()
            defer { t.cleanup() }
            let speakerNames = try #require(t.b.recording(t.r2)?.speakers.map { SyncRecordID(type: .speaker, entityID: $0.id).recordName })
            try t.b.store.delete(id: t.r2)
            await t.b.sync.syncNow()
            let cloud = await names(t.cloud)
            for name in speakerNames { #expect(!cloud.contains(name)) }
            await t.settleBoth()
            #expect(t.a.count(RecordingSpeaker.self) == 2)
            expectConverged(t.devices)
        }

        /// A delete that arrives while the recording is being processed here waits, then applies once it is ready.
        @Test func parkedDeleteWhileProcessing() async throws {
            let t = try await TwoDevices.make()
            defer { t.cleanup() }
            try t.b.store.setStage(.separating, queueReason: nil, for: t.r1)   // B re-runs separation
            try t.a.store.delete(id: t.r1)
            await t.settleBoth()
            let rid = SyncRecordID(type: .recording, entityID: t.r1)
            #expect(t.b.recording(t.r1) != nil)
            #expect(t.b.stateRow(rid)?.pending == .parkedDelete)

            // Processing finishes: the delete applies.
            let turns = SeedContent.conversationB
            try t.b.store.checkpointSeparation(id: t.r1, document: WP3Docs.speakers(turns),
                                               speakers: [WP3Docs.draft("S1", 1, clean: 12, vector: SyncVoices.karan(35))])
            try t.b.matchLikeThePipeline(t.r1)
            await t.settleBoth()
            #expect(t.b.recording(t.r1) == nil && t.b.stateRow(rid) == nil)
            #expect(!(await names(t.cloud)).contains(rid.recordName))
            expectConverged(t.devices)
        }
    }
}
