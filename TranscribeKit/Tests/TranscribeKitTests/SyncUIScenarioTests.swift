import Foundation
import SwiftData
import Testing
import TranscribeCore
@testable import TranscribeFakes
@testable import TranscribeKit

extension SyncSuites {
    /// The UI-test sync scenarios (`TRANSCRIBE_SYNC=fake:<scenario>`, §8.6), run the way the app runs them: seed, prepare
    /// the store, switch on as the scenario says, then `start()` as `onLaunch` does. The UI tests then only check what
    /// the screens show.
    @Suite("Sync: UI-test scenarios")
    @MainActor
    struct SyncUIScenarioTests {
        /// One app launch on a Mac with a scenario and a seed.
        @MainActor
        final class Launch {
            let setup: FakeSyncSetup
            let container: ModelContainer
            let paths: AppPaths
            let store: LibraryStore
            let settings: AppSettings
            let sync: SyncCoordinator
            var context: ModelContext { container.mainContext }
            let account = FakeCloud.uiTestAccount

            init(_ scenario: FakeSyncScenario, seed: SeedName) throws {
                let clock = AppClock.frozen(Seeds.Dates.d)
                setup = FakeCloud.scenario(scenario, clock: clock)
                container = try ModelContainerFactory.make(inMemory: true, url: nil)
                paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent("sync-ui-\(UUID().uuidString)"))
                try Seeds.apply(seed, context: container.mainContext, paths: paths, clock: clock)
                store = LibraryStore(context: container.mainContext, paths: paths, deviceIdentity: FixedDeviceIdentity("mac"),
                                     clock: clock, localChannel: CaptureChannel.mac)
                _ = try store.stampCaptureChannels()
                try setup.prepare(container.mainContext, now: clock.now)
                settings = AppSettings(defaults: UserDefaults(suiteName: "sync-ui-\(UUID().uuidString)")!)
                settings.syncEnabled = setup.startsOn
                sync = SyncCoordinator(store: store, transport: setup.transport, settings: settings, clock: clock,
                                       modelKey: EmbeddingModelID.fake.key)
                sync.debounce = .seconds(3600)
            }

            func cleanup() { try? FileManager.default.removeItem(at: paths.root) }
            func count<T: PersistentModel>(_ type: T.Type) -> Int { (try? context.fetchCount(FetchDescriptor<T>())) ?? -1 }
            func recordings() -> [Recording] { (try? context.fetch(FetchDescriptor<Recording>())) ?? [] }
            func cloudRecords() async -> [String: [String: SyncValue]] { await setup.transport.cloud.records(account: account) }
        }

        @Test func freshStartsOffAndJoinsWhenSwitchedOn() async throws {
            let l = try Launch(.fresh, seed: .library)
            defer { l.cleanup() }
            #expect(!l.setup.startsOn)
            await l.sync.start()
            #expect(l.sync.status == .off)
            await l.sync.enable()
            #expect(l.sync.status == .idle(lastSync: Seeds.Dates.d))
            #expect(await l.cloudRecords().keys.filter { $0.hasPrefix("rec.") }.count == 3)
        }

        @Test func remoteLibraryArrivesWithoutAudio() async throws {
            let l = try Launch(.remoteLibrary, seed: .empty)
            defer { l.cleanup() }
            await l.sync.start()
            #expect(l.sync.status == .idle(lastSync: Seeds.Dates.d))
            let recordings = l.recordings()
            #expect(recordings.count == 3)
            #expect(recordings.allSatisfy { $0.captureChannel == CaptureChannel.iphone && $0.stage == .ready })
            #expect(recordings.allSatisfy { !l.store.hasLocalAudio($0) })
            #expect(l.count(VoiceProfile.self) == 2 && l.count(VoiceSample.self) == 5)
            // Karan's voice was learned on the iPhone only: a Mac recording of him can only be asked about.
            let karan = try #require((try l.context.fetch(FetchDescriptor<VoiceProfile>())).first { $0.name == "Karan" })
            #expect(NameSpeakerModel.askPrompt(suggested: karan, recordingChannel: CaptureChannel.mac, copy: DeviceCopy(platform: .mac))?
                .hasPrefix("Karan was named on your iPhone") == true)
        }

        @Test func signedOutPauses() async throws {
            let l = try Launch(.signedOut, seed: .library)
            defer { l.cleanup() }
            await l.sync.start()
            #expect(l.sync.status == .paused(.noAccount))
            #expect(SyncCopy.statusLine(l.sync.status, now: Seeds.Dates.d) == "Not signed in to iCloud")
        }

        @Test func accountSwitchedAsksBeforeUploading() async throws {
            let l = try Launch(.accountSwitched, seed: .library)
            defer { l.cleanup() }
            await l.sync.start()
            #expect(l.sync.status == .paused(.accountChanged))
            #expect(await l.cloudRecords().isEmpty)
            await l.sync.resolveAccountChange(merge: true)
            #expect(l.sync.status == .idle(lastSync: Seeds.Dates.d))
            #expect(await l.cloudRecords().keys.filter { $0.hasPrefix("rec.") }.count == 3)
        }

        @Test func zoneRemovedPausesThenReuploads() async throws {
            let l = try Launch(.zoneRemoved, seed: .library)
            defer { l.cleanup() }
            await l.sync.start()
            #expect(l.sync.status == .paused(.zoneRemoved))
            #expect(l.count(Recording.self) == 3)   // local data stays
            #expect(SyncCopy.statusLine(l.sync.status, now: Seeds.Dates.d) == SyncCopy.zoneRemoved)
            await l.sync.enable()
            #expect(l.sync.status == .idle(lastSync: Seeds.Dates.d))
            #expect(await l.cloudRecords().keys.filter { $0.hasPrefix("rec.") }.count == 3)
        }

        @Test func duplicateKaranGivesABannerNotAMerge() async throws {
            let l = try Launch(.duplicateKaran, seed: .library)
            defer { l.cleanup() }
            await l.sync.start()
            #expect(l.sync.duplicateNames == ["Karan"])
            let karans = try l.context.fetch(FetchDescriptor<VoiceProfile>()).filter { $0.name == "Karan" }
            #expect(karans.count == 2)
            #expect(karans.contains { $0.id == FakeCloud.iPhoneKaranID })
        }

        @Test func massDeleteHoldsTheDeletesThenRestores() async throws {
            let l = try Launch(.massDelete, seed: .library)
            defer { l.cleanup() }
            await l.sync.start()
            #expect(l.sync.status == .paused(.massDelete))
            #expect(l.sync.heldDeleteCount == FakeCloud.massDeleteCount)
            #expect(await l.cloudRecords().count == FakeCloud.massDeleteCount)
            await l.sync.resolveMassDelete(confirm: false)
            #expect(!l.sync.status.isPaused)
            #expect(l.count(Recording.self) == 3 + FakeCloud.massDeleteCount)
        }

        @Test func massDeleteConfirmRemovesThemFromICloud() async throws {
            let l = try Launch(.massDelete, seed: .library)
            defer { l.cleanup() }
            await l.sync.start()
            await l.sync.resolveMassDelete(confirm: true)
            #expect(!l.sync.status.isPaused)
            let names = await l.cloudRecords().keys
            #expect(!names.contains { $0.hasPrefix("rec.C0000000") })
            #expect(names.filter { $0.hasPrefix("rec.") }.count == 3)   // this device's own library went up instead
            #expect(l.count(Recording.self) == 3)
        }
    }
}
