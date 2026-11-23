import Foundation
import Observation
import SwiftData
import TranscribeCore

public enum AppPhase: Sendable { case active, inactive, background }

/// The composition root object, injected with `.environment(env)`.
@MainActor @Observable
public final class AppEnvironment {
    public typealias Seeder = @MainActor (_ seed: SeedName, _ context: ModelContext, _ paths: AppPaths, _ clock: AppClock) throws -> Void

    public let config: LaunchConfig
    public let clock: AppClock
    public let paths: AppPaths
    public let engine: any SpeechEngine
    public let container: ModelContainer
    public let store: any LibraryStoring
    public let settings: AppSettings
    public let monitor: ProcessingMonitor
    public let coordinator: ProcessingCoordinator
    public let models: ModelManager
    public let recorder: RecorderController
    public let player: PlaybackController
    public private(set) var isLaunched = false
    public private(set) var launchError: String?

    @ObservationIgnored private let seeder: Seeder?

    public init(config: LaunchConfig, engine: any SpeechEngine, background: any BackgroundTaskBridge,
                deviceIdentity: any DeviceIdentity, seeder: Seeder?) throws {
        self.config = config
        self.clock = config.clock
        let paths = AppPaths(config: config)
        self.paths = paths
        self.engine = engine
        self.seeder = seeder
        if !config.uiTesting {
            // The on-disk store needs its folder before the container opens; onLaunch → paths.prepare() does the rest.
            try FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
        }
        let container = try ModelContainerFactory.make(inMemory: config.uiTesting, url: paths.storeURL)
        self.container = container
        let defaults = config.uiTesting
            ? (UserDefaults(suiteName: "uitest-\(ProcessInfo.processInfo.processIdentifier)") ?? .standard)
            : .standard
        let settings = AppSettings(defaults: defaults)
        self.settings = settings
        let monitor = ProcessingMonitor()
        self.monitor = monitor
        let store = LibraryStore(context: container.mainContext, paths: paths, deviceIdentity: deviceIdentity, clock: config.clock)
        self.store = store
        let coordinator = ProcessingCoordinator(engine: engine, store: store, monitor: monitor, settings: settings,
                                                paths: paths, background: background)
        self.coordinator = coordinator
        // UI tests must not depend on the host's network: a tethered or Low Data Mode Mac reports an
        // "expensive" path, which puts the mobile-data confirmation in front of every download.
        let models = ModelManager(engine: engine, monitorsNetwork: !config.uiTesting,
                                  freeSpace: { ModelManager.systemFreeBytes() },
                                  onReady: { Task { await coordinator.modelsBecameReady() } })
        models.beforeRemove = { await coordinator.suspendForModelRemoval() }
        self.models = models
        let recorder = RecorderController(engine: engine, store: store, coordinator: coordinator, models: models,
                                          paths: paths, settings: settings, clock: config.clock)
        self.recorder = recorder
        let player = PlaybackController()
        player.isCaptureActive = { [weak recorder] in recorder?.isActive ?? false }
        self.player = player
    }

    /// Order: paths.prepare → seed (if config.seed) → store.reconcileDevice → models.refresh →
    /// coordinator.recoverOnLaunch → models.prepareIfInstalled (detached) → isLaunched = true.
    public func onLaunch() async {
        guard !isLaunched else { return }
        do { try paths.prepare() } catch { launchError = "Couldn't prepare storage: \(error.localizedDescription)" }
        if let seed = config.seed, let seeder {
            do { try seeder(seed, container.mainContext, paths, clock) } catch { launchError = "Seed \(seed.rawValue) failed: \(error)" }
        }
        do { _ = try store.reconcileDevice() } catch { launchError = "Device check failed: \(error)" }
        await models.refresh()
        await coordinator.recoverOnLaunch()
        let models = self.models
        Task { await models.prepareIfInstalled() }
        isLaunched = true
    }

    /// background: recorder.appDidEnterBackground; active: models.prepareIfInstalled + recorder foreground
    public func onPhase(_ phase: AppPhase) async {
        switch phase {
        case .background:
            await recorder.appDidEnterBackground()
        case .active:
            guard isLaunched else { return }
            await models.prepareIfInstalled()
            await recorder.appWillEnterForeground()
        case .inactive:
            break
        }
    }
}
