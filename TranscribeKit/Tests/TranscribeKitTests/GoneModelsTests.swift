import Foundation
import SwiftData
import Testing
import TranscribeCore
@testable import TranscribeFakes
@testable import TranscribeKit

extension SyncSuites {
    /// A model a screen still holds when sync deletes it (§8.4). Reading it does not trap; it reads stale values, so
    /// views ask `GoneModels.isGone` and the router drops screens and sheets of gone recordings and voices.
    @Suite("Gone models")
    @MainActor
    struct GoneModelsTests {
        /// The reported crash: B shows r1 (a card, the transcript, a speaker chip) when A deletes it and B syncs.
        @Test func aRecordingDeletedBySyncIsGoneAndReadsWithoutTrapping() async throws {
            let t = try await TwoDevices.make()
            defer { t.cleanup() }
            let held = try #require(t.b.recording(t.r1))
            let heldSpeaker = try #require(held.sortedSpeakers.first)
            let title = held.displayTitle
            let other = try #require(t.b.recording(t.r2))
            #expect(!GoneModels.isGone(held) && !GoneModels.isGone(heldSpeaker))

            try t.a.store.delete(id: t.r1)
            await t.settleBoth()

            #expect(t.b.recording(t.r1) == nil)
            #expect(GoneModels.isGone(held) && GoneModels.isGone(heldSpeaker))
            #expect(!GoneModels.isGone(other))
            #expect(held.modelContext == nil)
            // What RecordingCard and TranscriptView read: no trap, but stale attributes and emptied relationships.
            #expect(held.id == t.r1 && held.displayTitle == title && held.stage == .ready)
            #expect(held.transcriptData != nil)
            #expect(held.speakers.isEmpty && held.speakersNeedingName.isEmpty)
            #expect(heldSpeaker.modelContext == nil && heldSpeaker.label == .named && heldSpeaker.ordinal == 1)
            _ = heldSpeaker.displayName   // follows its stale profile link: no trap either
        }

        @Test func aVoiceForgottenBySyncIsGone() async throws {
            let t = try await TwoDevices.make()
            defer { t.cleanup() }
            let karan = try #require(t.b.profile(named: "Karan"))
            let liam = try #require(t.b.profile(named: "Liam"))
            try t.a.store.forgetProfile(t.karan)
            await t.settleBoth()
            #expect(GoneModels.isGone(karan) && !GoneModels.isGone(liam))
            #expect(karan.name == "Karan" && karan.samples.isEmpty)
        }

        /// The app's library after a relaunch: the held recording comes from a fresh fetch, then the remote delete
        /// path (`remoteDelete`, as the applier calls it) removes it in the same main context and saves.
        @Test func aRelaunchedLibraryRowDeletedRemotelyIsGone() throws {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("gone-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            let url = dir.appendingPathComponent("Library.store")
            let paths = AppPaths(root: dir.appendingPathComponent("app", isDirectory: true))
            do {
                let first = try WP3Harness(container: ModelContainerFactory.make(inMemory: false, url: url), paths: paths)
                try first.seed(.library)
                try first.context.save()
            }
            let h = try WP3Harness(container: ModelContainerFactory.make(inMemory: false, url: url), paths: paths)
            let held = try #require(try h.context.fetch(FetchDescriptor<Recording>(sortBy: [SortDescriptor(\.createdAt)])).first)
            let speakers = held.speakers
            #expect(!speakers.isEmpty)
            h.store.remoteDelete(.recording(held))
            #expect(GoneModels.isGone(held))   // before the save too
            try h.context.save()
            #expect(GoneModels.isGone(held) && speakers.allSatisfy(GoneModels.isGone))
            #expect(!held.displayTitle.isEmpty && held.speakers.isEmpty)
            #expect(throws: StoreError.self) { try h.store.recording(held.id) }
        }

        @Test func anUnsavedDeleteIsAlreadyGone() throws {
            let h = try WP3Harness()
            defer { h.cleanup() }
            try h.seed(.library)
            let all = try h.context.fetch(FetchDescriptor<Recording>())
            let doomed = try #require(all.first)
            h.context.delete(doomed)
            #expect(GoneModels.isGone(doomed))
            #expect(all.dropFirst().allSatisfy { !GoneModels.isGone($0) })
        }

        @Test func removedIDs() {
            let a = UUID(), b = UUID(), c = UUID()
            #expect(GoneModels.removed(before: [a, b, c], after: [c, a]) == [b])
            #expect(GoneModels.removed(before: [a], after: [a, b]).isEmpty)
            #expect(GoneModels.removed(before: [], after: [a]).isEmpty)
        }

        @Test func prunePopsBackToTheScreenBeforeTheGoneOne() {
            #expect(GoneModels.prune(["voices", "voice", "transcript", "settings"], where: { $0 == "voice" }) == ["voices"])
            #expect(GoneModels.prune(["transcript"], where: { $0 == "transcript" }).isEmpty)
            #expect(GoneModels.prune(["voices", "settings"], where: { $0 == "voice" }) == ["voices", "settings"])
            #expect(GoneModels.prune([String](), where: { _ in true }).isEmpty)
        }
    }
}
