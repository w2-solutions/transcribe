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
    /// iCloud sync (§8.4); nil when the app was built without a transport.
    public let sync: SyncCoordinator?
    /// The launch's sync start (fetch, scan, send). It runs beside the rest of the launch, so a slow network never
    /// delays the library or the models.
    public private(set) var syncLaunch: Task<Void, Never>?
    public private(set) var isLaunched = false
    public private(set) var launchError: String?

    @ObservationIgnored private let seeder: Seeder?

    public init(config: LaunchConfig, engine: any SpeechEngine, background: any BackgroundTaskBridge,
                deviceIdentity: any DeviceIdentity, seeder: Seeder?, syncTransport: (any SyncTransport)? = nil) throws {
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
        let store = LibraryStore(context: container.mainContext, paths: paths, deviceIdentity: deviceIdentity, clock: config.clock,
                                 localChannel: config.channel ?? CaptureChannel.current)
        self.store = store
        let coordinator = ProcessingCoordinator(engine: engine, store: store, monitor: monitor, settings: settings,
                                                paths: paths, background: background)
        self.coordinator = coordinator
        let models = ModelManager(engine: engine, onReady: { Task { await coordinator.modelsBecameReady() } })
        self.models = models
        let recorder = RecorderController(engine: engine, store: store, coordinator: coordinator, models: models,
                                          paths: paths, settings: settings, clock: config.clock)
        self.recorder = recorder
        let player = PlaybackController()
        player.isCaptureActive = { [weak recorder] in recorder?.isActive ?? false }
        self.player = player
        let modelKey = engine.info.embeddingModel.key
        self.sync = syncTransport.map {
            SyncCoordinator(store: store, transport: $0, settings: settings, clock: config.clock, modelKey: modelKey)
        }
        // Real iCloud only: UI tests and fake-engine runs use a fake iCloud, which has no environment to change.
        if !config.uiTesting && !config.useFakeEngine {
            sync?.cloudEnvironment = Bundle.main.object(forInfoDictionaryKey: "TranscribeICloudEnvironment") as? String
        }
    }

    /// Order: paths.prepare (+ detached removal of the old downloaded models) → seed (if config.seed) → store.stampCaptureChannels →
    /// store.sweepOrphanAudio → models.refresh →
    /// coordinator.recoverOnLaunch → sync.start (its own task, when the switch is on) → models.prepareIfInstalled (detached)
    /// → isLaunched = true.
    public func onLaunch() async {
        guard !isLaunched else { return }
        do { try paths.prepare() } catch { launchError = "Couldn't prepare storage: \(error.localizedDescription)" }
        // Builds before bundling downloaded ~704 MB of models into Models/; they now ship in the app.
        let paths = self.paths
        Task.detached(priority: .utility) { paths.removeLegacyModels() }
        if let seed = config.seed, let seeder {
            do { try seeder(seed, container.mainContext, paths, clock) } catch { launchError = "Seed \(seed.rawValue) failed: \(error)" }
        }
        do { _ = try store.stampCaptureChannels() } catch { launchError = "Capture channel stamping failed: \(error)" }
        // Audio files no row names (a delete synced from another device after a crash, say), older than an hour.
        _ = try? store.sweepOrphanAudio(minimumAge: 3_600, now: Date())
        await models.refresh()
        await coordinator.recoverOnLaunch()
        if settings.syncEnabled, let sync { syncLaunch = Task { await sync.start() } }
        let models = self.models
        Task { await models.prepareIfInstalled() }
        isLaunched = true
    }

    /// background: sync leaves the front, recorder.appDidEnterBackground; active: sync comes to the front (it fetches
    /// now and then every couple of minutes, in case an iCloud push was missed), models.prepareIfInstalled + recorder
    /// foreground. The Mac also follows the app becoming and resigning active (`syncForeground`).
    public func onPhase(_ phase: AppPhase) async {
        switch phase {
        case .background:
            sync?.setForeground(false)
            await recorder.appDidEnterBackground()
        case .active:
            if !config.uiTesting { sync?.setForeground(true) }
            guard isLaunched else { return }
            await models.prepareIfInstalled()
            await recorder.appWillEnterForeground()
        case .inactive:
            break
        }
    }

    /// The Mac app became (true) or resigned (false) active: sync fetches in front only.
    public func syncForeground(_ active: Bool) {
        guard !config.uiTesting else { return }
        sync?.setForeground(active)
    }
}
