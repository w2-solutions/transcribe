import Foundation
import TranscribeCore
import TranscribeKit
import TranscribeFluid
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
        return try! AppEnvironment(config: config, engine: engine, background: background, deviceIdentity: identity, seeder: seeder)
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
