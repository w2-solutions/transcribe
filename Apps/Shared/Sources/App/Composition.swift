import Foundation
import SwiftUI
import TranscribeCore
import TranscribeKit
import TranscribeFluid
import TranscribeCloudKit
#if DEBUG
import TranscribeFakes
#endif

@MainActor enum Composition {
    static func makeEnvironment() -> AppEnvironment {
        let config = LaunchConfig.current
        let paths = AppPaths(config: config)
        let activity = Self.appActivity()
        // The prepare log is the real library's: never for UI tests or the fake engine.
        let prepareLog = config.uiTesting || config.useFakeEngine ? nil : paths.prepareLogURL
        var engine: any SpeechEngine = FluidSpeechEngine(modelsRoot: Self.modelsRoot(), prepareLog: prepareLog,
                                                         activity: activity)
        var seeder: AppEnvironment.Seeder? = nil
        #if DEBUG
        if config.useFakeEngine {
            // The same start rule as the real engine, so leaving the app mid-setup pauses it here too.
            engine = FakeSpeechEngine(config: config, paths: paths, activity: activity)
            seeder = { seed, context, paths, clock in try Seeds.apply(seed, context: context, paths: paths, clock: clock) }
        }
        #endif
        let identity = PlatformServices.deviceIdentity(uiTesting: config.uiTesting)
        let background = PlatformServices.backgroundBridge(uiTesting: config.uiTesting)
        #if DEBUG
        let fakeSync = (config.uiTesting || config.useFakeEngine) ? FakeCloud.scenario(config.sync, clock: config.clock) : nil
        let transport: (any SyncTransport)? = fakeSync?.transport ?? Self.syncTransport(config: config)
        let audio = fakeSync.map { Self.fakeAudioSync($0, config: config) } ?? Self.audioSync(config: config)
        #else
        let transport = Self.syncTransport(config: config)
        let audio = Self.audioSync(config: config)
        #endif
        let env = try! AppEnvironment(config: config, engine: engine, background: background, deviceIdentity: identity, seeder: seeder,
                                      syncTransport: transport, audio: audio,
                                      syncAudioDefault: Self.syncAudioDefault(config: config), activity: activity,
                                      activityPhase: PlatformServices.activityPhase)
        // VoiceOver hears "Transcribe is ready." once, when a shown setup card turns to ready.
        env.models.announce = { AccessibilityNotification.Announcement($0).post() }
        #if DEBUG
        // UI tests only (§8.6): the scenario's sync bookkeeping goes into the in-memory store, and `fake:*` scenarios
        // other than `fresh` start with the switch on, in this run's own defaults suite. Seeding never touches sync
        // rows, so this can run before `onLaunch` seeds. Plain fake-engine runs keep the switch and store as they are.
        if config.uiTesting, let fakeSync {
            do { try fakeSync.prepare(env.container.mainContext, now: config.clock.now) } catch {
                assertionFailure("Preparing the fake sync scenario failed: \(error)")
            }
            if fakeSync.startsOn { env.settings.syncEnabled = true }
            // Sync audio starts on (fresh defaults) unless the test says otherwise, and the one-time "Audio now syncs
            // with iCloud" notice shows only in the tests that ask for it.
            if config.syncAudioOff { env.settings.syncAudio = false }
            env.settings.syncAudioIntroShown = !config.syncAudioIntro
        }
        // Mac audio test hooks. The output route the headphones hint reads (`TRANSCRIBE_OUTPUT_ROUTE`) with the fake
        // engine or UI tests; the recording source (`TRANSCRIBE_SOURCE`) and whether the explainer was already seen
        // (`TRANSCRIBE_MAC_AUDIO_EXPLAINED`) in UI tests only, whose settings are a fresh suite of their own (a plain
        // fake-engine run uses this Mac's defaults, which a hook must never change).
        if config.uiTesting || config.useFakeEngine {
            let environment = ProcessInfo.processInfo.environment
            Platform.outputRouteOverride = environment["TRANSCRIBE_OUTPUT_ROUTE"].flatMap { $0.isEmpty ? nil : $0 }
            if config.uiTesting {
                if let source = config.source { env.settings.recordingSource = source }
                if let explained = environment["TRANSCRIBE_MAC_AUDIO_EXPLAINED"] {
                    env.settings.macAudioExplained = ["1", "yes", "true", "on"].contains(explained.lowercased())
                }
            }
        }
        #endif
        return env
    }

    /// Audio sync's dependencies beside the real transport: the audio of finished recordings moves through the private
    /// database's default zone (`CloudKitAudioTransfer`), encoded to AAC, on the real network, power and storage. Like
    /// the transport, nothing touches iCloud until the user turns sync on. Nil for UI tests and fake-engine runs.
    static func audioSync(config: LaunchConfig) -> AudioSyncDependencies? {
        if config.uiTesting || config.useFakeEngine { return nil }
        return AudioSyncDependencies(transfer: CloudKitAudioTransfer(), encoder: AACAudioEncoder(),
                                     conditions: LiveDeviceConditions())
    }

    #if DEBUG
    /// Fake-engine and UI-test runs: the scenario's fake iCloud holds the audio too, on the network the run names
    /// (`TRANSCRIBE_NETWORK`, Wi-Fi by default). UI tests copy WAVs instead of encoding AAC, so the existing
    /// timing-sensitive tests keep their pace.
    static func fakeAudioSync(_ fakeSync: FakeSyncSetup, config: LaunchConfig) -> AudioSyncDependencies {
        let encoder: any AudioEncoding = config.uiTesting ? CopyAudioEncoder() : AACAudioEncoder()
        return AudioSyncDependencies(transfer: fakeSync.audioTransfer, encoder: encoder,
                                     conditions: FakeDeviceConditions(network: networkKind(config.network) ?? .unmetered))
    }

    static func networkKind(_ network: FakeNetwork?) -> NetworkKind? {
        switch network {
        case .wifi?: .unmetered
        case .cellular?: .metered
        case .lowData?: .constrained
        case .offline?: .offline
        case nil: nil
        }
    }
    #endif

    /// "Sync audio" is on by default, except in a Debug build running the real engine outside UI tests (decision 25):
    /// such a build on the Mac shares its container and defaults with /Applications/Transcribe.app and uses the
    /// Development database, so a default-on switch would upload the real library's audio there. The key is only
    /// written when the user flips the switch, so Release builds still read the absent key as on.
    static func syncAudioDefault(config: LaunchConfig) -> Bool {
        #if DEBUG
        return config.useFakeEngine || config.uiTesting
        #else
        return true
        #endif
    }

    /// iCloud sync's transport (§8.3). The real app always gets `CloudKitTransport`, which touches nothing in iCloud
    /// until the "Sync with iCloud" switch is on. UI tests and fake-engine runs get a `FakeTransport` on an in-memory
    /// `FakeCloud` seeded for `TRANSCRIBE_SYNC=fake:<scenario>` (`FakeCloud+Scenarios.swift`), so they never reach
    /// CloudKit or the user's iCloud (§8.6); a Release build has no fakes and so no sync in those modes.
    static func syncTransport(config: LaunchConfig) -> (any SyncTransport)? {
        if config.uiTesting || config.useFakeEngine { return nil }
        return CloudKitTransport()
    }

    /// The speech models ship read-only in the app bundle (`BundledModels/`). DEBUG builds may point the real
    /// engine at a complete folder on the Mac instead (`TRANSCRIBE_MODELS_DIR`, set by the Run scheme), because
    /// simulator builds leave the models out.
    static func modelsRoot() -> URL {
        #if DEBUG
        if let dir = ProcessInfo.processInfo.environment["TRANSCRIBE_MODELS_DIR"], !dir.isEmpty {
            let url = URL(fileURLWithPath: dir, isDirectory: true)
            if FluidModelPaths(root: url).allInstalled { return url }   // simulator real-engine runs
        }
        #endif
        return FluidModelPaths.bundledRoot()
    }

    /// Whether the speech-model prepare may use the Neural Engine in the background (`AppActivity`). Only a build
    /// signed with the Background Inference entitlement may: there is no public runtime check for it on iOS, so the
    /// build setting `TRANSCRIBE_BACKGROUND_INFERENCE` is mirrored into Info.plist (`TranscribeBackgroundInference`;
    /// a missing or other value means no). It is YES only where Transcribe.entitlements carries the key, which a
    /// provisioning profile without it refuses to sign (`BackgroundInferenceConfigTests` pins the pairing). Never in
    /// the simulator, and never on the Mac, whose Info.plist has no such key. DEBUG only, for device measurements:
    /// `-assumeNoBackgroundInference` forces no (one build tries both gates), and `-startStagesInBackground` lets
    /// stages start in the background anyway (with a build without the entitlement: what does a background load do?).
    static func appActivity() -> AppActivity {
        let flag = (Bundle.main.object(forInfoDictionaryKey: "TranscribeBackgroundInference") as? String) == "YES"
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        let assumeNo = arguments.contains("-assumeNoBackgroundInference")
        let ignoresStartRule = arguments.contains("-startStagesInBackground")
        #else
        let assumeNo = false
        let ignoresStartRule = false
        #endif
        #if targetEnvironment(simulator)
        let entitled = false
        #else
        let entitled = flag && !assumeNo
        #endif
        return AppActivity(backgroundInference: entitled, ignoresStartRule: ignoresStartRule)
    }
}
