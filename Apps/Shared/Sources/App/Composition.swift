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
        #else
        let transport = Self.syncTransport(config: config)
        #endif
        let env = try! AppEnvironment(config: config, engine: engine, background: background, deviceIdentity: identity, seeder: seeder,
                                      syncTransport: transport, activity: activity,
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
        }
        #endif
        return env
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
