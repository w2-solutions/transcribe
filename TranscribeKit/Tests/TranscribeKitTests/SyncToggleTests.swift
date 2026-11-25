import Foundation
import SwiftData
import Testing
import TranscribeCore
@testable import TranscribeFakes
@testable import TranscribeKit

extension SyncSuites {
    /// The "Sync with iCloud" switch (§8.4 flows 5 and 6).
    @Suite("Sync: switch")
    @MainActor
    struct SyncToggleTests {
        @Test func offKeepsTheStateAndTheCloudCopy() async throws {
            let t = try await TwoDevices.make()
            defer { t.cleanup() }
            let rows = t.a.stateRows().count
            let cloudBefore = await t.cloud.records(account: "account-1")
            try await t.a.sync.disable(removeCloudCopy: false)
            #expect(t.a.sync.status == .off && !t.a.settings.syncEnabled)
            #expect(t.a.stateRows().count == rows)
            #expect(SyncCoordinator.accountRow(t.a.context, create: false)?.engineState != nil)
            #expect(await t.cloud.records(account: "account-1") == cloudBefore)
            #expect(t.a.count(Recording.self) == 2 && t.a.count(VoiceProfile.self) == 2)   // local data untouched
            // Edits while off stay local.
            try t.a.store.rename(id: t.r1, title: "While off")
            await t.a.sync.syncNow()
            #expect(await t.cloud.records(account: "account-1") == cloudBefore)
        }

        @Test func onAgainSendsTheDeletesMadeMeanwhile() async throws {
            let t = try await TwoDevices.make()
            defer { t.cleanup() }
            try await t.a.sync.disable(removeCloudCopy: false)
            try t.a.store.delete(id: t.r2)
            try t.a.store.rename(id: t.r1, title: "While off")
            try t.b.store.setFavourite(id: t.r1, true)   // B keeps syncing meanwhile
            await t.b.sync.syncNow()

            await t.a.sync.enable()
            #expect(t.a.sync.status == .idle(lastSync: t.a.clock.date))
            await t.settleBoth()
            #expect(t.b.recording(t.r2) == nil)
            for d in t.devices {
                #expect(d.recording(t.r1)?.title == "While off" && d.recording(t.r1)?.isFavourite == true)
            }
            expectConverged(t.devices)
        }

        @Test func removeICloudCopyClearsTheStateAndTheZone() async throws {
            let t = try await TwoDevices.make()
            defer { t.cleanup() }
            try await t.a.sync.disable(removeCloudCopy: true)
            #expect(t.a.stateRows().isEmpty)
            let account = try #require(SyncCoordinator.accountRow(t.a.context, create: false))
            #expect(account.engineState == nil && account.accountHash == nil && !account.zoneReady)
            #expect(!(await t.cloud.zoneExists(account: "account-1")))
            #expect(await t.cloud.records(account: "account-1").isEmpty)
            #expect(t.a.count(Recording.self) == 2 && t.a.count(VoiceSample.self) == 2 && t.a.count(RecordingSpeaker.self) == 4)
            #expect(t.a.sync.status == .off)
        }

        @Test func joiningShowsTheUploadCountUntilTheFirstSendDrains() async throws {
            let t = try await TwoDevices.make(syncB: false)
            defer { t.cleanup() }
            let local = try t.b.record([SyncVoices.stranger(36)])
            await t.cloud.setNetworkDown(true)   // the first send cannot drain
            await t.b.sync.enable()
            #expect(t.b.sync.status == .joining(SyncStatus.joiningMessage(2)))   // the recording and its speaker
            await t.cloud.setNetworkDown(false)
            await t.b.sync.syncNow()
            await t.settleBoth()
            #expect(t.a.recording(local) != nil && t.b.recording(t.r1) != nil)
            expectConverged(t.devices)
        }

        @Test func settingPersistsAndLaunchStartsSync() async throws {
            let t = try await TwoDevices.make()
            defer { t.cleanup() }
            #expect(t.b.settings.syncEnabled)
            try t.a.store.rename(id: t.r1, title: "Before relaunch")
            await t.a.sync.syncNow()
            await t.b.relaunch()
            await t.b.sync.start()
            #expect(t.b.recording(t.r1)?.title == "Before relaunch")
        }
    }
}

extension SyncSuites {
    @Suite("Sync: app wiring")
    @MainActor
    struct SyncAppWiringTests {
        /// `AppEnvironment` builds a coordinator when given a transport, and `onLaunch` starts it when the switch is on.
        @Test func launchStartsSyncWhenTheSwitchIsOn() async throws {
            let env = [LaunchConfig.envSeed: SeedName.library.rawValue]
            let config = LaunchConfig(arguments: [LaunchConfig.argUseFakeEngine, LaunchConfig.argUITesting], environment: env)
            let cloud = FakeCloud()
            let app = try AppEnvironment(config: config, engine: FakeSpeechEngine(config: config, script: FakeScript.named(config.script)),
                                         background: NoopBackgroundTaskBridge(), deviceIdentity: FixedDeviceIdentity("ui-test"),
                                         seeder: Seeds.apply, syncTransport: FakeTransport(cloud: cloud))
            defer { try? FileManager.default.removeItem(at: app.paths.root) }
            let sync = try #require(app.sync)
            #expect(sync.status == .off)
            app.settings.syncEnabled = true
            defer { app.settings.syncEnabled = false }
            await app.onLaunch()
            #expect(app.launchError == nil && app.isLaunched)
            await app.syncLaunch?.value
            let uploaded = await cloud.records(account: "account-1")
            #expect(uploaded.keys.filter { $0.hasPrefix("rec.") }.count == 3 && uploaded.keys.filter { $0.hasPrefix("vp.") }.count == 2)
            guard case .idle(let last) = sync.status else { Issue.record("status \(sync.status)"); return }
            #expect(last != nil)
        }

        @Test func withoutATransportThereIsNoSync() throws {
            let config = LaunchConfig(arguments: [LaunchConfig.argUseFakeEngine, LaunchConfig.argUITesting], environment: [:])
            let app = try AppEnvironment(config: config, engine: FakeSpeechEngine(config: config, script: FakeScript.named(config.script)),
                                         background: NoopBackgroundTaskBridge(), deviceIdentity: FixedDeviceIdentity("ui-test"),
                                         seeder: Seeds.apply)
            defer { try? FileManager.default.removeItem(at: app.paths.root) }
            #expect(app.sync == nil)
        }

        /// The Mac app's DEBUG Claude session calls onLaunch from App.init while the window's task may call it too: the
        /// launch (and its seed) runs once, and both callers return only once it is done.
        @Test func concurrentOnLaunchRunsOnce() async throws {
            let config = LaunchConfig(arguments: [LaunchConfig.argUseFakeEngine, LaunchConfig.argUITesting],
                                      environment: [LaunchConfig.envSeed: SeedName.library.rawValue])
            var seeded = 0
            let app = try AppEnvironment(config: config, engine: FakeSpeechEngine(config: config, script: FakeScript.named(config.script)),
                                         background: NoopBackgroundTaskBridge(), deviceIdentity: FixedDeviceIdentity("ui-test"),
                                         seeder: { seed, context, paths, clock in
                                             seeded += 1
                                             try Seeds.apply(seed, context: context, paths: paths, clock: clock)
                                         })
            defer { try? FileManager.default.removeItem(at: app.paths.root) }
            async let first: Void = app.onLaunch()
            async let second: Void = app.onLaunch()
            _ = await (first, second)
            #expect(seeded == 1 && app.isLaunched && app.launchError == nil)
            await app.onLaunch()
            #expect(seeded == 1)
        }

        @Test func launchConfigParsesTheFakeSyncScenario() {
            let fake = [LaunchConfig.argUseFakeEngine]
            #expect(LaunchConfig(arguments: fake, environment: [LaunchConfig.envSync: "fake:remoteLibrary"]).sync == .remoteLibrary)
            #expect(LaunchConfig(arguments: fake, environment: [LaunchConfig.envSync: "off"]).sync == nil)
            #expect(LaunchConfig(arguments: fake, environment: [LaunchConfig.envSync: "fake:nope"]).sync == nil)
            #expect(LaunchConfig(arguments: [], environment: [LaunchConfig.envSync: "fake:fresh"]).sync == nil)   // real engine: ignored
            #expect(Set(FakeSyncScenario.allCases.map(\.rawValue)) ==
                    ["fresh", "remoteLibrary", "signedOut", "accountSwitched", "zoneRemoved", "duplicateKaran", "massDelete"])
        }

        @Test func syncEnabledDefaultsOffAndPersists() {
            let defaults = UserDefaults(suiteName: "sync-setting-\(UUID().uuidString)")!
            #expect(AppSettings(defaults: defaults).syncEnabled == false)
            AppSettings(defaults: defaults).syncEnabled = true
            #expect(AppSettings(defaults: defaults).syncEnabled == true)
            #expect(defaults.bool(forKey: "settings.syncEnabled"))
        }
    }
}

extension SyncSuites.SyncToggleTests {
    /// The privacy wording follows whether an iCloud copy was kept when sync was turned off.
    @Test func keepsCloudCopyFollowsTheLeaveChoice() async throws {
        let t = try await TwoDevices.make()
        defer { t.cleanup() }
        #expect(!t.a.sync.keepsCloudCopy)   // on: not "kept", it is syncing
        try await t.a.sync.disable(removeCloudCopy: false)
        #expect(t.a.sync.keepsCloudCopy)
        await t.a.relaunch()
        #expect(t.a.sync.keepsCloudCopy)
        await t.a.sync.enable()
        #expect(!t.a.sync.keepsCloudCopy)
        try await t.a.sync.disable(removeCloudCopy: true)
        #expect(!t.a.sync.keepsCloudCopy)
        // A device that never synced keeps nothing.
        let fresh = try FakeDevice("C", cloud: t.cloud)
        defer { fresh.cleanup() }
        #expect(!fresh.sync.keepsCloudCopy)
    }
}
