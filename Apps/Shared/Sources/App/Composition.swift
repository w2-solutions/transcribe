import Foundation
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
        var engine: any SpeechEngine = FluidSpeechEngine(modelsRoot: Self.modelsRoot())
        var seeder: AppEnvironment.Seeder? = nil
        #if DEBUG
        if config.useFakeEngine {
            engine = FakeSpeechEngine(config: config, paths: paths)
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
                                      syncTransport: transport)
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
}
