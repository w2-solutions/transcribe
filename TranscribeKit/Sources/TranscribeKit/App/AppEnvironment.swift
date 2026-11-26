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
    /// One microphone owner at a time: a meeting recording or a dictation (Mac).
    public let captureGate: CaptureGate
    public let player: PlaybackController
    /// iCloud sync (§8.4); nil when the app was built without a transport.
    public let sync: SyncCoordinator?
    /// The launch's sync start (fetch, scan, send). It runs beside the rest of the launch, so a slow network never
    /// delays the library or the models.
    public private(set) var syncLaunch: Task<Void, Never>?
    /// Mac only: "Let Claude read transcripts" is on (set by the Mac app's ClaudeAccess). Always false on iPhone.
    public var claudeAccessOn = false
    /// Mac only: the Sparkle updater runs in this build (set by the Mac app from `UpdateAvailability`). Always false on
    /// iPhone.
    public var updatesAvailable = false
    /// Mac only: another copy of Transcribe is running (set by the Mac app before launch). It shares this container's
    /// `Dictation/` folder and may be dictating into it, so launch then keeps recent dictation files. Always false on
    /// iPhone.
    @ObservationIgnored public var otherCopyRunning: @MainActor () -> Bool = { false }
    public private(set) var isLaunched = false
    public private(set) var launchError: String?

    /// Whether the app is in front, shared with the engine and `ModelManager` (§ background prepare). Only the iPhone
    /// app moves it (`activityPhase`); on the Mac it always reads as in front.
    @ObservationIgnored public let activity: AppActivity
    @ObservationIgnored private let seeder: Seeder?
    /// iPhone only: the app's state now (`UIApplication.applicationState`). When set, `activity` follows the scene
    /// phase and is seeded from this at launch (a launch for an iCloud push starts in the background, and SwiftUI
    /// reports no phase change for the starting state).
    @ObservationIgnored private let activityPhase: (@MainActor () -> AppPhase)?
    @ObservationIgnored private var launchRun: Task<Void, Never>?

    public init(config: LaunchConfig, engine: any SpeechEngine, background: any BackgroundTaskBridge,
                deviceIdentity: any DeviceIdentity, seeder: Seeder?, syncTransport: (any SyncTransport)? = nil,
                activity: AppActivity = AppActivity(), activityPhase: (@MainActor () -> AppPhase)? = nil) throws {
        self.config = config
        self.activity = activity
        self.activityPhase = activityPhase
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
        // The recorder is made after the models (it reads them), so onReady reaches it through this box.
        let readyRecorder = RecorderBox()
        let models = ModelManager(engine: engine, background: background, activity: activity, onReady: {
            Task { await coordinator.modelsBecameReady() }
            // A recording started during setup gets its live text now.
            if let recorder = readyRecorder.recorder { Task { await recorder.modelsBecameReady() } }
        })
        self.models = models
        let captureGate = CaptureGate()
        self.captureGate = captureGate
        let recorder = RecorderController(engine: engine, store: store, coordinator: coordinator, models: models,
                                          paths: paths, settings: settings, clock: config.clock, gate: captureGate)
        readyRecorder.recorder = recorder
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

    /// Order: activity seeded (iPhone) → paths.prepare → clearDictationFiles (+ detached removal of the old downloaded
    /// models) → seed (if
    /// config.seed) → store.stampCaptureChannels → store.sweepOrphanAudio → models.refresh →
    /// coordinator.recoverOnLaunch → sync.start (its own task, when the switch is on) → models.prepareIfInstalled (detached;
    /// it waits for the front when the app launched in the background) → isLaunched = true. Runs once: a second caller
    /// (the Mac app's DEBUG Claude session start, beside the window's task) waits for the same run instead of starting
    /// another.
    public func onLaunch() async {
        if let launchRun { return await launchRun.value }
        let run = Task { await launch() }
        launchRun = run
        await run.value
    }

    private func launch() async {
        guard !isLaunched else { return }
        if activityPhase?() == .background { activity.enterBackground() }
        do { try paths.prepare() } catch { launchError = "Couldn't prepare storage: \(error.localizedDescription)" }
        // Dictation audio left by a crash or a quit mid-dictation. This process cannot dictate before `isLaunched` (the
        // Mac's shortcuts wait for it); another running copy can, into the same folder, so then only old files go.
        paths.clearDictationFiles(otherCopyRunning: otherCopyRunning(), now: Date())
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
    /// On the iPhone (`activityPhase` set) `activity` follows first (`followActivity`), before anything else and
    /// before the launch check, so a trip to the background during launch is never missed; a prepare still running
    /// on return gets a new short background task.
    public func onPhase(_ phase: AppPhase) async {
        followActivity(phase)
        switch phase {
        case .background:
            sync?.setForeground(false)
            await recorder.appDidEnterBackground()
        case .active:
            if !config.uiTesting { sync?.setForeground(true) }
            if activityPhase != nil { await models.appBecameActive() }
            guard isLaunched else { return }
            await models.prepareIfInstalled()
            await recorder.appWillEnterForeground()
        case .inactive:
            break
        }
    }

    /// iPhone only (`activityPhase` set): moves `activity` to `phase` now. The app calls it synchronously in its
    /// scene-phase handler, before the `onPhase` task it spawns, so a prepare stage that ends in that gap is judged
    /// by the new state. Repeating it (`onPhase` calls it again) changes nothing. Does nothing on the Mac.
    public func followActivity(_ phase: AppPhase) {
        guard activityPhase != nil else { return }
        switch phase {
        case .background: activity.enterBackground()
        case .active: activity.becomeActive()
        case .inactive: break
        }
    }

    /// The Mac app became (true) or resigned (false) active: sync fetches in front only.
    public func syncForeground(_ active: Bool) {
        guard !config.uiTesting else { return }
        sync?.setForeground(active)
    }
}

/// Lets `ModelManager.onReady` reach the recorder, which is made after it.
@MainActor private final class RecorderBox {
    weak var recorder: RecorderController?
}
