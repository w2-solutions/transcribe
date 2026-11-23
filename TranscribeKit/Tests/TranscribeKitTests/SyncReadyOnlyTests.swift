import Foundation
import SwiftData
import Testing
import TranscribeCore
@testable import TranscribeFakes
@testable import TranscribeKit

extension SyncSuites {
    /// Only ready recordings sync (§8.2, D7).
    @Suite("Sync: ready only")
    @MainActor
    struct SyncReadyOnlyTests {
        @Test func aRecordingBelowReadyIsNeverSent() async throws {
            let t = try await TwoDevices.make()
            defer { t.cleanup() }
            let id = UUID()
            try t.a.store.createRecording(id: id, createdAt: t.a.clock.date, audioFileName: "\(id).wav", source: .microphone)
            await t.a.sync.syncNow()
            try t.a.store.finishCapture(id: id, audio: CapturedAudio(url: t.a.paths.audioURL(fileName: "\(id).wav"), duration: 5,
                                                                     marks: [], peaks: []), language: .automatic)
            try t.a.store.checkpointTranscript(id: id, document: WP3Docs.paragraphs(SeedContent.conversationB))
            try t.a.store.checkpointSeparation(id: id, document: WP3Docs.speakers(SeedContent.conversationB),
                                               speakers: [WP3Docs.draft("S1", 1, clean: 12, vector: SyncVoices.stranger(39))])
            await t.settleBoth()
            let names = Set(await t.cloud.records(account: "account-1").keys)
            #expect(!names.contains(SyncRecordID(type: .recording, entityID: id).recordName))
            for s in try #require(t.a.recording(id)).speakers {
                #expect(!names.contains(SyncRecordID(type: .speaker, entityID: s.id).recordName))
            }
            #expect(t.b.recording(id) == nil)
            #expect(t.a.stateRow(SyncRecordID(type: .recording, entityID: id)) == nil)

            try t.a.matchLikeThePipeline(id)   // ready: now it syncs
            await t.settleBoth()
            #expect(t.b.recording(id)?.speakers.count == 1)
            expectConverged(t.devices)
        }

        @Test func remoteRowsNeverAppearInRecovery() async throws {
            let t = try await TwoDevices.make()
            defer { t.cleanup() }
            #expect(t.b.count(Recording.self) == 2)
            #expect(try t.b.store.recoveryCandidates().isEmpty)
            let r = try #require(t.b.recording(t.r1))
            #expect(r.stage == .ready && r.attemptCount == 0 && !r.hasUnseenResult && r.audioFileName == "\(t.r1.uuidString).wav")
            #expect(r.previewText == t.a.recording(t.r1)?.previewText && !r.previewText.isEmpty)
            #expect(r.searchText == t.a.recording(t.r1)?.searchText)
        }

        /// A change skipped while the recording was processed here is still merged when processing changed nothing
        /// (the fetch token has moved on, so the row must send and meet `serverRecordChanged`).
        @Test func aChangeSkippedWhileProcessingIsMergedEvenWhenProcessingChangedNothing() async throws {
            let t = try await TwoDevices.make()
            defer { t.cleanup() }
            let rid = SyncRecordID(type: .recording, entityID: t.r1)
            try t.b.store.setStage(.matching, queueReason: nil, for: t.r1)
            try t.a.store.rename(id: t.r1, title: "Renamed on A")
            try t.a.store.setFavourite(id: t.r1, true)
            await t.settleBoth()
            #expect(t.b.recording(t.r1)?.title == nil)
            #expect(t.b.stateRow(rid)?.mustMergeWithServer == true && t.b.stateRow(rid)?.pending == .save)
            try t.b.matchLikeThePipeline(t.r1)   // ready again, with the same result
            await t.settleBoth()
            for d in t.devices { #expect(d.recording(t.r1)?.title == "Renamed on A" && d.recording(t.r1)?.isFavourite == true) }
            #expect(t.b.stateRow(rid)?.mustMergeWithServer == false && t.b.stateRow(rid)?.pending == SyncPending.none)
            expectConverged(t.devices)
        }

        /// B re-runs separation on a synced recording: nothing of it is sent while it processes, remote edits to it wait,
        /// and once it is ready its new result merges with the edits made elsewhere.
        @Test func localReSeparationFreezesUploadsThenMergesOnReady() async throws {
            let t = try await TwoDevices.make()
            defer { t.cleanup() }
            let rid = SyncRecordID(type: .recording, entityID: t.r1)
            let oldSpeakers = try #require(t.b.recording(t.r1)?.speakers.map(\.id))
            try t.b.store.setStage(.queued, queueReason: nil, for: t.r1)
            try t.b.store.setStage(.separating, queueReason: nil, for: t.r1)
            let turns = SeedContent.conversationB
            try t.b.store.checkpointSeparation(id: t.r1, document: WP3Docs.speakers(turns),
                                               speakers: [WP3Docs.draft("S1", 1, clean: 12, vector: SyncVoices.karan(41)),
                                                          WP3Docs.draft("S2", 2, clean: 12, vector: SyncVoices.liam(42))])
            try t.a.store.rename(id: t.r1, title: "Renamed on A")
            let cloudBefore = await t.cloud.records(account: "account-1")
            await t.settleBoth()
            // Frozen: B sent nothing for the recording or its speakers, old or new.
            let cloudDuring = await t.cloud.records(account: "account-1")
            #expect(cloudDuring[rid.recordName]?["title"] == .string("Renamed on A"))
            #expect(cloudDuring[rid.recordName]?["transcript"] == cloudBefore[rid.recordName]?["transcript"])
            for id in oldSpeakers { #expect(cloudDuring[SyncRecordID(type: .speaker, entityID: id).recordName] != nil) }
            #expect(t.b.recording(t.r1)?.title == nil)   // A's edit waits while B processes

            try t.b.matchLikeThePipeline(t.r1)   // ready
            await t.settleBoth()
            let a = try #require(t.a.recording(t.r1)), b = try #require(t.b.recording(t.r1))
            #expect(a.title == "Renamed on A" && b.title == "Renamed on A")
            #expect(Set(a.speakers.map(\.id)) == Set(b.speakers.map(\.id)))
            #expect(Set(a.speakers.map(\.id)).isDisjoint(with: oldSpeakers))
            #expect(a.transcriptData == b.transcriptData)
            expectConverged(t.devices)
        }
    }
}
