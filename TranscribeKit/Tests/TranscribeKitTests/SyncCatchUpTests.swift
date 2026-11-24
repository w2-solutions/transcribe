import Foundation
import SwiftData
import Testing
import TranscribeCore
@testable import TranscribeFakes
@testable import TranscribeKit

extension SyncSuites {
    /// What the first run against real iCloud showed (2026-11-24): pushes go missing, the engine's automatic send does
    /// not fetch first and does not retry a merged conflict, and naming a saved voice rewrote the shared profile.
    /// These tests use a transport that, like `CKSyncEngine`, tries each record once per send.
    @Suite("Sync: catching up without pushes")
    @MainActor
    struct SyncCatchUpTests {
        /// A conflict merged after an automatic send (no fetch first) goes out again by itself, without another edit.
        @Test func aMergedConflictIsSentAgainWithoutAnotherEdit() async throws {
            let t = try await TwoDevices.make()
            defer { t.cleanup() }
            await t.b.transport.setMaxAttemptsPerSend(1)
            t.b.sync.followUpDelays = [.milliseconds(1)]
            try t.a.store.rename(id: t.r1, title: "From A")
            await t.a.sync.syncNow()
            // B has not fetched A's title. Its favourite goes out in the engine's own send, which meets the conflict.
            try t.b.store.setFavourite(id: t.r1, true)
            await t.b.sync.flushAndEnqueue()
            try await t.b.transport.sendChanges()
            await t.b.sync.followUpTask?.value
            #expect(t.b.pending == 0)
            await t.a.sync.syncNow()
            #expect(t.a.recording(t.r1)?.isFavourite == true && t.a.recording(t.r1)?.title == "From A")
            expectConverged(t.devices)
        }

        /// A record the server asked to retry is queued again and sent by the coordinator's follow-up.
        @Test func aRetryableFailureIsSentAgain() async throws {
            let t = try await TwoDevices.make()
            defer { t.cleanup() }
            await t.b.transport.setMaxAttemptsPerSend(1)
            t.b.sync.followUpDelays = [.milliseconds(1)]
            try t.b.store.rename(id: t.r1, title: "Busy server")
            await t.cloud.failOnce(SyncRecordID(type: .recording, entityID: t.r1).recordName)
            await t.b.sync.flushAndEnqueue()
            try await t.b.transport.sendChanges()
            #expect(t.b.sync.lastError != nil)
            await t.b.sync.followUpTask?.value
            #expect(t.b.pending == 0)
            #expect(t.b.sync.lastError == nil)
            await t.a.sync.syncNow()
            #expect(t.a.recording(t.r1)?.title == "Busy server")
        }

        /// Confirming a saved voice changes the speaker and adds a sample, never the shared profile record, so two
        /// devices naming the same person do not conflict on it.
        @Test func confirmingASavedVoiceLeavesTheProfileRecordAlone() async throws {
            let t = try await TwoDevices.make()
            defer { t.cleanup() }
            let karan = try #require(t.b.profile(named: "Karan"))
            let namedAt = karan.namedAt
            t.b.clock.advance(600)
            _ = try t.b.store.confirmSuggestion(recordingID: t.r2, key: "S1")
            await t.b.sync.flushAndEnqueue()
            #expect(karan.namedAt == namedAt)
            #expect(t.b.stateRow(SyncRecordID(type: .profile, entityID: t.karan))?.pending == SyncPending.none)
            #expect(t.b.stateRow(SyncRecordID(type: .speaker, entityID: try #require(t.b.recording(t.r2)?.speaker("S1")?.id)))?
                .pending == .save)
        }

        /// The owner's run: the iPhone names Liam on its own recording; the Mac, which has not fetched since, confirms
        /// "Is this Liam?" on its recording and its engine sends without fetching. The iPhone, in front, shows the name.
        @Test func aNameConfirmedOnTheMacReachesTheIPhoneInFront() async throws {
            let t = try await TwoDevices.make()
            defer { t.cleanup() }
            await t.a.transport.setMaxAttemptsPerSend(1)
            await t.b.transport.setMaxAttemptsPerSend(1)
            t.b.sync.followUpDelays = [.milliseconds(1)]
            t.a.sync.minRefreshGap = .zero
            t.a.clock.advance(60)
            let onMac = try t.b.record([SyncVoices.liam(50)])
            #expect(t.b.recording(onMac)?.speaker("S1")?.label == .suggested)
            await t.b.sync.syncNow()
            await t.a.sync.syncNow()
            #expect(t.a.recording(onMac)?.speaker("S1")?.label == .suggested)

            t.a.clock.advance(30)
            let onPhone = try t.a.record([SyncVoices.liam(51, 0.5)])
            _ = try t.a.store.nameSpeaker(recordingID: onPhone, key: "S1", as: .existing(profileID: t.liam), remember: true)
            await t.a.sync.syncNow()

            _ = try t.b.store.confirmSuggestion(recordingID: onMac, key: "S1")
            await t.b.sync.flushAndEnqueue()
            try await t.b.transport.sendChanges()
            await t.b.sync.followUpTask?.value

            t.a.sync.setForeground(true)
            try await eventually { t.a.recording(onMac)?.speaker("S1")?.label == .named }
            t.a.sync.setForeground(false)
            #expect(t.a.recording(onMac)?.speaker("S1")?.profile?.id == t.liam)
            await t.settleBoth()
            expectConverged(t.devices)
        }

        /// Coming to the front fetches at once, without a push; nothing fetches on a timer afterwards.
        @Test func comingToTheFrontFetchesOnceAndNothingPolls() async throws {
            let t = try await TwoDevices.make()
            defer { t.cleanup() }
            t.a.sync.minRefreshGap = .zero
            try t.b.store.rename(id: t.r1, title: "Renamed on the Mac")
            await t.b.sync.syncNow()
            t.a.sync.setForeground(true)
            try await eventually { t.a.recording(t.r1)?.title == "Renamed on the Mac" }
            try await Task.sleep(for: .milliseconds(50))
            let fetches = await t.a.transport.fetchCount
            try await Task.sleep(for: .milliseconds(250))
            #expect(await t.a.transport.fetchCount == fetches)
        }

        /// A push fetches at once, even right after another refresh.
        @Test func aPushFetchesAtOnce() async throws {
            let t = try await TwoDevices.make()
            defer { t.cleanup() }
            t.a.sync.minRefreshGap = .seconds(3600)
            await t.a.sync.refresh(fullScan: true)
            try t.b.store.rename(id: t.r1, title: "Renamed on the iPhone")
            await t.b.sync.syncNow()
            await t.a.sync.remoteChangeNotified()
            #expect(t.a.recording(t.r1)?.title == "Renamed on the iPhone")
        }

        /// A build for the other iCloud environment forgets the sync state and joins again; nothing local is deleted,
        /// and the library uploads to the (empty) other environment.
        @Test func changingTheCloudEnvironmentRejoinsWithoutDeletingAnything() async throws {
            let t = try await TwoDevices.make()
            defer { t.cleanup() }
            let before = try t.a.context.fetch(FetchDescriptor<Recording>()).count
            #expect(before > 0)
            // The Production database: another, empty server.
            let production = FakeCloud()
            t.a.context.rollback()
            let transport = FakeTransport(cloud: production, account: "account-1")
            let sync = SyncCoordinator(store: t.a.store, transport: transport, settings: t.a.settings, clock: t.a.clock.appClock,
                                       modelKey: EmbeddingModelID.fake.key)
            sync.debounce = .seconds(3600)
            sync.followUpDelays = [.seconds(3600)]
            sync.cloudEnvironment = "Production"
            await sync.start()
            await sync.syncNow()
            #expect(try t.a.context.fetch(FetchDescriptor<Recording>()).count == before)
            #expect(await production.records(account: "account-1").keys.filter { $0.hasPrefix("rec.") }.count == before)
            #expect(t.a.settings.syncCloudEnvironment == "Production")
        }

        /// Coming to the front twice within the minimum gap fetches once.
        @Test func comingToTheFrontAgainSoonDoesNotFetchAgain() async throws {
            let t = try await TwoDevices.make()
            defer { t.cleanup() }
            t.a.sync.minRefreshGap = .seconds(3600)
            let before = await t.a.transport.fetchCount
            await t.a.sync.refresh(fullScan: true)
            await t.a.sync.refresh(fullScan: true)
            #expect(await t.a.transport.fetchCount == before + 1)
        }

        /// A failed send or fetch is shown until a later sync goes through.
        @Test func theLastErrorIsKeptUntilASyncSucceeds() async throws {
            let t = try await TwoDevices.make()
            defer { t.cleanup() }
            #expect(t.a.sync.lastError == nil)
            try t.a.store.rename(id: t.r1, title: "Offline edit")
            await t.cloud.setNetworkDown(true)
            await t.a.sync.syncNow()
            let problem = try #require(t.a.sync.lastError)
            #expect(!problem.message.isEmpty)
            await t.cloud.setNetworkDown(false)
            await t.a.sync.syncNow()
            #expect(t.a.sync.lastError == nil)
        }

        @Test func theStatusLineShowsTheLastError() {
            let now = Seeds.Dates.d
            let problem = SyncProblem(message: "1 item was not saved: try again later", at: now.addingTimeInterval(-120))
            let line = SyncCopy.statusLine(.syncing(pending: 1), now: now, problem: problem)
            #expect(line == "Waiting to upload 1 item\nLast problem 2 min ago: 1 item was not saved: try again later")
            #expect(SyncCopy.statusLine(.idle(lastSync: nil), now: now, problem: nil) == "Up to date")
        }
    }
}

/// Waits (up to `timeout`) for a condition the main actor sees change asynchronously.
@MainActor
func eventually(timeout: Duration = .seconds(5), _ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        guard ContinuousClock.now < deadline else {
            Issue.record("condition not met within \(timeout)")
            return
        }
        try await Task.sleep(for: .milliseconds(10))
    }
}
