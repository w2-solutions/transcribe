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
        var engine: any SpeechEngine = FluidSpeechEngine(modelsRoot: paths.modelsDirectory)
        var seeder: AppEnvironment.Seeder? = nil
        #if DEBUG
        if config.useFakeEngine {
            engine = FakeSpeechEngine(config: config, paths: paths)
            seeder = { seed, context, paths, clock in try Seeds.apply(seed, context: context, paths: paths, clock: clock) }
        }
        #endif
        let identity: any DeviceIdentity = config.uiTesting ? FixedDeviceIdentity("test-device") : KeychainDeviceIdentity()
        let background: any BackgroundTaskBridge = config.uiTesting ? NoopBackgroundTaskBridge() : ContinuedProcessingBridge()
        return try! AppEnvironment(config: config, engine: engine, background: background, deviceIdentity: identity, seeder: seeder)
    }
}
