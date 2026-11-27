import Foundation
import Testing
import TranscribeCore
@testable import TranscribeFakes
@testable import TranscribeKit

extension SyncSuites {
    /// Audio sync's settings, launch hooks and wiring (§3.2, §3.3, decision 25).
    @Suite("Sync: audio settings")
    @MainActor
    struct AudioSettingsTests {
        func defaults() -> UserDefaults { UserDefaults(suiteName: "audio-settings-\(UUID().uuidString)")! }

        @Test func syncAudioDefaultsOnAndPersists() {
            let d = defaults()
            #expect(AppSettings(defaults: d).syncAudio == true)
            #expect(d.object(forKey: "settings.syncAudio") == nil)        // reading never writes the key
            AppSettings(defaults: d).syncAudio = false
            #expect(d.object(forKey: "settings.syncAudio") as? Bool == false)
            #expect(AppSettings(defaults: d).syncAudio == false)
            #expect(AppSettings(defaults: d, syncAudioDefault: true).syncAudio == false)   // the written value wins

            // Debug real-engine runs default it off; once the user flips it, the key decides.
            let debug = defaults()
            #expect(AppSettings(defaults: debug, syncAudioDefault: false).syncAudio == false)
            #expect(debug.object(forKey: "settings.syncAudio") == nil)
            AppSettings(defaults: debug, syncAudioDefault: false).syncAudio = true
            #expect(AppSettings(defaults: debug, syncAudioDefault: false).syncAudio == true)
        }

        @Test func theSweepDateAndTheIntroFlagAreKeptButAreNoSettings() {
            let d = defaults()
            let settings = AppSettings(defaults: d)
            #expect(settings.syncAudioLastSweep == nil)
            #expect(settings.syncAudioIntroShown == false)
            let when = Date(timeIntervalSince1970: 1_763_500_000.5)
            settings.syncAudioLastSweep = when
            settings.syncAudioIntroShown = true
            #expect(d.object(forKey: "sync.audio.lastSweep") as? Date == when)
            #expect(d.bool(forKey: "sync.audio.introShown"))
            let again = AppSettings(defaults: d)
            #expect(again.syncAudioLastSweep == when)
            #expect(again.syncAudioIntroShown)
            again.syncAudioLastSweep = nil
            #expect(AppSettings(defaults: d).syncAudioLastSweep == nil)
        }

        @Test func launchConfigParsesNetworkAndSyncAudio() {
            let fake = [LaunchConfig.argUseFakeEngine], ui = [LaunchConfig.argUITesting]
            for raw in ["wifi", "cellular", "lowData", "offline"] {
                #expect(LaunchConfig(arguments: fake, environment: [LaunchConfig.envNetwork: raw]).network?.rawValue == raw)
                #expect(LaunchConfig(arguments: ui, environment: [LaunchConfig.envNetwork: " \(raw) "]).network?.rawValue == raw)
            }
            #expect(LaunchConfig(arguments: fake, environment: [LaunchConfig.envNetwork: "5g"]).network == nil)
            #expect(LaunchConfig(arguments: fake, environment: [:]).network == nil)
            #expect(LaunchConfig(arguments: [], environment: [LaunchConfig.envNetwork: "cellular"]).network == nil)   // real engine

            let off = LaunchConfig(arguments: fake, environment: [LaunchConfig.envSyncAudio: "off"])
            #expect(off.syncAudioOff && !off.syncAudioIntro)
            let intro = LaunchConfig(arguments: ui, environment: [LaunchConfig.envSyncAudio: "Intro"])
            #expect(intro.syncAudioIntro && !intro.syncAudioOff)
            let neither = LaunchConfig(arguments: fake, environment: [LaunchConfig.envSyncAudio: "on"])
            #expect(!neither.syncAudioOff && !neither.syncAudioIntro)
            let real = LaunchConfig(arguments: [], environment: [LaunchConfig.envSyncAudio: "off"])
            #expect(!real.syncAudioOff && !real.syncAudioIntro)                                          // real engine: ignored
            #expect(LaunchConfig.envNetwork == "TRANSCRIBE_NETWORK")
            #expect(LaunchConfig.envSyncAudio == "TRANSCRIBE_SYNC_AUDIO")

            #expect(LaunchConfig(arguments: fake, environment: [LaunchConfig.envSync: "fake:remoteLibraryWithAudio"]).sync
                    == .remoteLibraryWithAudio)
        }

        func app(syncTransport: (any SyncTransport)?, audio: AudioSyncDependencies?, syncAudioDefault: Bool = true) throws -> AppEnvironment {
            let config = LaunchConfig(arguments: [LaunchConfig.argUseFakeEngine, LaunchConfig.argUITesting], environment: [:])
            // UI-test runs share one defaults suite per process: start it without the key.
            UserDefaults(suiteName: "uitest-\(ProcessInfo.processInfo.processIdentifier)")?.removeObject(forKey: "settings.syncAudio")
            return try AppEnvironment(config: config, engine: FakeSpeechEngine(config: config, script: FakeScript.named(config.script)),
                                      background: NoopBackgroundTaskBridge(), deviceIdentity: FixedDeviceIdentity("ui-test"),
                                      seeder: Seeds.apply, syncTransport: syncTransport, audio: audio,
                                      syncAudioDefault: syncAudioDefault)
        }

        @Test func launchBuildsAudioSyncOnlyWithDependencies() async throws {
            let cloud = FakeCloud()
            let transport = FakeTransport(cloud: cloud)
            let deps = AudioSyncDependencies(transfer: FakeAudioTransfer(cloud: cloud, transport: transport),
                                             encoder: CopyAudioEncoder(), conditions: FakeDeviceConditions(), platform: .mac)
            let with = try app(syncTransport: transport, audio: deps)
            defer { try? FileManager.default.removeItem(at: with.paths.root) }
            let sync = try #require(with.sync)
            let audio = try #require(sync.audio)
            #expect(audio.coordinator === sync)
            #expect(audio.dependencies.platform == .mac)

            let without = try app(syncTransport: FakeTransport(cloud: cloud), audio: nil)
            defer { try? FileManager.default.removeItem(at: without.paths.root) }
            #expect(without.sync != nil)
            #expect(without.sync?.audio == nil)
        }

        @Test func syncAudioDefaultReachesSettings() throws {
            let off = try app(syncTransport: nil, audio: nil, syncAudioDefault: false)
            defer { try? FileManager.default.removeItem(at: off.paths.root) }
            #expect(off.settings.syncAudio == false)
            let on = try app(syncTransport: nil, audio: nil)
            defer { try? FileManager.default.removeItem(at: on.paths.root) }
            #expect(on.settings.syncAudio == true)
        }

        @Test func theCoordinatorKnowsTheAccountAndWhenAudioMayRun() async throws {
            let cloud = FakeCloud()
            let device = try FakeDevice("audio-settings", cloud: cloud)
            defer { device.cleanup() }
            let sync = device.sync
            #expect(sync.audio == nil)
            #expect(!sync.audioMayRun)
            #expect(!sync.fetchSucceededSinceReset)
            #expect(await !sync.currentAccountMatches())                   // nothing stored yet
            await sync.enable()
            #expect(sync.audioMayRun)
            #expect(sync.fetchSucceededSinceReset)
            #expect(await sync.currentAccountMatches())
            await device.transport.signIn("account-2")                     // the coordinator pauses for the switch
            #expect(await !sync.currentAccountMatches())
            #expect(!sync.audioMayRun)
            await sync.sendAudioMarkers()                                  // without AudioSync: nothing to send
            try await sync.disable(removeCloudCopy: true)
            #expect(!sync.audioMayRun)
            #expect(!sync.fetchSucceededSinceReset)
        }

        /// Uploads wait only while a job is queued or running: the snapshot a finished or failed job leaves for the
        /// views (it stays until the app quits) must not hold audio uploads for the rest of the launch.
        @Test func onlyProcessingThatIsQueuedOrRunningHoldsUploads() throws {
            let cloud = FakeCloud()
            let transport = FakeTransport(cloud: cloud)
            let deps = AudioSyncDependencies(transfer: FakeAudioTransfer(cloud: cloud, transport: transport),
                                             encoder: CopyAudioEncoder(), conditions: FakeDeviceConditions(), platform: .mac)
            let env = try app(syncTransport: transport, audio: deps)
            defer { try? FileManager.default.removeItem(at: env.paths.root) }
            let audio = try #require(env.sync?.audio)
            let first = UUID(), second = UUID()
            func snapshot(_ id: UUID, _ phase: ProcessingPhase) -> ProcessingSnapshot {
                ProcessingSnapshot(recordingID: id, steps: [], overall: 0, voicesFound: nil, comparedWith: [], phase: phase)
            }
            #expect(!audio.isBusy())
            env.monitor.update(snapshot(first, .queued(.modelsNotReady)))
            #expect(audio.isBusy())
            env.monitor.update(snapshot(first, .running))
            #expect(audio.isBusy())
            env.monitor.update(snapshot(first, .finished(ProcessingOutcome(autoLabelled: 1))))
            #expect(!audio.isBusy())
            env.monitor.update(snapshot(second, .failed("Transcription failed")))
            #expect(!audio.isBusy())
            #expect(env.monitor.snapshots.count == 2)   // the views keep both
            env.monitor.update(snapshot(second, .queued(.waitingForTurn)))
            #expect(audio.isBusy())
        }
    }
}
