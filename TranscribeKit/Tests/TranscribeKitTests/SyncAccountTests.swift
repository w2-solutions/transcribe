import Foundation
import SwiftData
import Testing
import TranscribeCore
@testable import TranscribeFakes
@testable import TranscribeKit

extension SyncSuites {
    /// Account changes and zones removed elsewhere (§8.4 flows 7 and 8).
    @Suite("Sync: accounts and zones")
    @MainActor
    struct SyncAccountTests {
        @Test func signOutPausesAndKeepsEverything() async throws {
            let t = try await TwoDevices.make()
            defer { t.cleanup() }
            let rows = t.b.stateRows().count
            await t.b.transport.signOut()
            #expect(t.b.sync.status == .paused(.noAccount))
            #expect(t.b.stateRows().count == rows && t.b.count(Recording.self) == 2)
            try t.b.store.rename(id: t.r1, title: "Signed out")
            await t.b.sync.syncNow()
            #expect(await t.cloud.record(account: "account-1", recordName: SyncRecordID(type: .recording, entityID: t.r1).recordName)?
                .fields["title"] == .null)
        }

        @Test func signingBackInToTheSameAccountResumes() async throws {
            let t = try await TwoDevices.make()
            defer { t.cleanup() }
            await t.b.transport.signOut()
            try t.b.store.rename(id: t.r1, title: "While signed out")
            await t.b.transport.signIn("account-1")
            await t.settleBoth()
            #expect(!t.b.sync.status.isPaused)
            #expect(t.a.recording(t.r1)?.title == "While signed out")
            expectConverged(t.devices)
        }

        @Test func switchingAccountsNeedsConsent() async throws {
            let t = try await TwoDevices.make()
            defer { t.cleanup() }
            await t.b.transport.signIn("account-2")   // from account-1: a switch
            #expect(t.b.sync.status == .paused(.accountChanged))
            await t.b.sync.syncNow()
            await t.b.relaunch()
            await t.b.sync.start()
            #expect(t.b.sync.status == .paused(.accountChanged))
            #expect(await t.cloud.records(account: "account-2").isEmpty)   // nothing uploaded without consent

            await t.b.sync.resolveAccountChange(merge: false)
            #expect(t.b.sync.status == .paused(.accountChanged))
            #expect(await t.cloud.records(account: "account-2").isEmpty)

            await t.b.sync.resolveAccountChange(merge: true)
            #expect(!t.b.sync.status.isPaused)
            let uploaded = await t.cloud.records(account: "account-2")
            #expect(uploaded.count == t.b.projections().count && !uploaded.isEmpty)
            #expect(SyncCoordinator.accountRow(t.b.context, create: false)?.accountHash == "account-2")
        }

        @Test func zoneDeletedElsewhereKeepsLocalData() async throws {
            let t = try await TwoDevices.make()
            defer { t.cleanup() }
            try await t.a.sync.disable(removeCloudCopy: true)
            await t.b.sync.syncNow()
            #expect(t.b.sync.status == .paused(.zoneRemoved))
            #expect(t.b.stateRows().isEmpty)
            #expect(t.b.count(Recording.self) == 2 && t.b.count(VoiceProfile.self) == 2 && t.b.count(VoiceSample.self) == 2)
            // It stays paused across a relaunch until the switch is turned on again, which re-uploads.
            await t.b.relaunch()
            await t.b.sync.start()
            #expect(t.b.sync.status == .paused(.zoneRemoved))
            await t.b.sync.enable()
            #expect(!t.b.sync.status.isPaused)
            #expect(await t.cloud.records(account: "account-1").count == t.b.projections().count)
        }

        /// A send that meets a missing zone (removed elsewhere, not yet fetched) pauses the same way.
        @Test func zoneNotFoundOnSendPauses() async throws {
            let t = try await TwoDevices.make()
            defer { t.cleanup() }
            await t.cloud.removeZone(account: "account-1", reason: .deleted)
            try t.b.store.rename(id: t.r1, title: "Too late")
            await t.b.sync.flushAndEnqueue()
            try await t.b.transport.sendChanges()
            #expect(t.b.sync.status == .paused(.zoneRemoved))
            #expect(t.b.stateRows().isEmpty && t.b.recording(t.r1)?.title == "Too late")
        }

        @Test func encryptedDataResetReuploadsAutomatically() async throws {
            let t = try await TwoDevices.make()
            defer { t.cleanup() }
            await t.cloud.removeZone(account: "account-1", reason: .encryptedDataReset)
            await t.a.sync.syncNow()
            #expect(await waitUntil { await t.cloud.records(account: "account-1").count == t.a.projections().count })
            #expect(!t.a.sync.status.isPaused)
            await t.b.sync.syncNow()
            #expect(await waitUntil { !t.b.sync.status.isPaused && t.b.sync.running })
            await t.settleBoth()
            expectConverged(t.devices)
            #expect(t.b.count(Recording.self) == 2)
        }

        @Test func quotaFullPausesAndRetriesOnSyncNow() async throws {
            let t = try await TwoDevices.make()
            defer { t.cleanup() }
            await t.cloud.setQuotaFull(true)
            try t.a.store.rename(id: t.r1, title: "Big")
            await t.a.sync.syncNow()
            #expect(t.a.sync.status == .paused(.quotaFull))
            await t.cloud.setQuotaFull(false)
            await t.a.sync.syncNow()
            #expect(!t.a.sync.status.isPaused)
            await t.settleBoth()
            #expect(t.b.recording(t.r1)?.title == "Big")
            expectConverged(t.devices)
        }

        @Test func aRecordFromANewerBuildPausesAndAppliesNothing() async throws {
            let t = try await TwoDevices.make()
            defer { t.cleanup() }
            let id = SyncRecordID(type: .recording, entityID: t.r1)
            var record = try #require(await t.cloud.record(account: "account-1", recordName: id.recordName))
            record.fields["sv"] = .int(2)
            record.fields["title"] = .string("From the future")
            await t.cloud.inject(account: "account-1", record)
            await t.b.sync.syncNow()
            #expect(t.b.sync.status == .paused(.needsUpdate) && t.b.sync.otherDeviceNeedsUpdate)
            #expect(t.b.recording(t.r1)?.title == nil)
        }
    }
}

extension SyncSuites.SyncAccountTests {
    /// A voice from another device's build (a different embedding model key) raises the update banner, and applies.
    @Test func aVoiceOnAnotherModelKeyFlagsTheOtherDevice() async throws {
        let t = try await TwoDevices.make()
        defer { t.cleanup() }
        #expect(!t.b.sync.otherDeviceNeedsUpdate)
        let id = SyncRecordID(type: .profile, entityID: UUID())
        var fields = try #require(await t.cloud.record(account: "account-1",
                                                       recordName: SyncRecordID(type: .profile, entityID: t.karan).recordName)).fields
        fields["name"] = .string("Newer build")
        fields["embeddingModelKey"] = .string("some-other-model@2#256")
        await t.cloud.inject(account: "account-1", SyncRecord(id: id, fields: fields))
        await t.b.sync.syncNow()
        #expect(t.b.sync.otherDeviceNeedsUpdate && !t.b.sync.status.isPaused)
        #expect(t.b.profile(named: "Newer build")?.embeddingModelKey == "some-other-model@2#256")
    }
}

/// Polls on the main actor (for work the coordinator starts in its own task).
@MainActor
func waitUntil(_ timeout: Duration = .seconds(5), _ condition: @MainActor () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return await condition()
}
