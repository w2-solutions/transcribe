import Foundation
import Synchronization

/// Whether the app is in front or in the background (iPhone only), and whether this build may use the Neural Engine
/// in the background. The speech-model prepare reads it to decide whether a stage may start and whether a finished
/// stage counts (`FluidSpeechEngine`); `ModelManager` reads it to hold the prepare's short background task and to
/// fire `onReady` only in front.
///
/// - `backgroundInference` is true only in builds signed with the Background Inference entitlement
///   (`com.apple.developer.background-tasks.continued-processing.inference`, iOS 27). There is no public runtime check
///   for it on iOS, so the app mirrors the build setting into Info.plist (`TranscribeBackgroundInference`) and reads
///   that (`Composition`). Without it, iOS refuses the Neural Engine in the background. CPU work (Nemotron 3's
///   stage) needs no entitlement there, only the short background task.
/// - The iPhone app follows the scene phase (`AppEnvironment.onPhase`) and seeds the launch state. The Mac app never
///   changes it: a Mac app is never suspended, so it always reads as in front.
/// - `grace` is the short background task the prepare holds (`ModelManager`): set when one is begun, cleared when the
///   system ends it (`graceExpired`) or the prepare ends it. In the background a stage may start only while one is held.
///
/// Thread-safe: the expiry handler calls it from a system queue.
public final class AppActivity: Sendable {
    public enum TransitionKind: String, Sendable, Codable, Equatable {
        /// The app left the screen.
        case background
        /// The app came back to the front.
        case active
        /// The system ended the short background task (about 30 s after leaving).
        case expired
    }

    public struct Transition: Sendable, Equatable, Codable {
        public var kind: TransitionKind
        public var at: Date
        public init(kind: TransitionKind, at: Date) { self.kind = kind; self.at = at }
    }

    /// Where a stage started: the background period (epoch) and whether the app was in the background.
    public struct Window: Sendable, Equatable {
        public let epoch: Int
        public let inBackground: Bool
        public init(epoch: Int, inBackground: Bool) { self.epoch = epoch; self.inBackground = inBackground }
    }

    /// Transitions kept (the oldest are dropped).
    public static let keptTransitions = 20

    private struct State {
        var inBackground = false
        /// Background periods begun so far: a stage that saw it change spanned a trip to the background.
        var epoch = 0
        /// The short background task held now.
        var grace: UUID?
        var transitions: [Transition] = []
    }

    /// The build carries the Background Inference entitlement (fixed for the process).
    public let backgroundInference: Bool
    /// DEBUG measurement only (`-startStagesInBackground`): stages may start in the background even without the
    /// entitlement, so one run of a build without it shows what a background Neural Engine load does. The keep
    /// rules are unchanged: such a stage is still dropped or paused, never kept.
    public let ignoresStartRule: Bool
    private let state = Mutex(State())
    private let now: @Sendable () -> Date

    public init(backgroundInference: Bool = false, ignoresStartRule: Bool = false,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.backgroundInference = backgroundInference
        self.ignoresStartRule = ignoresStartRule
        self.now = now
    }

    // MARK: Changes

    /// The app left the screen. Repeating it without `becomeActive` in between changes nothing.
    public func enterBackground() {
        let at = now()
        state.withLock { s in
            guard !s.inBackground else { return }
            s.inBackground = true
            s.epoch += 1
            Self.append(&s, .background, at)
        }
    }

    /// The app is in front again. Repeating it changes nothing.
    public func becomeActive() {
        let at = now()
        state.withLock { s in
            guard s.inBackground else { return }
            s.inBackground = false
            Self.append(&s, .active, at)
        }
    }

    /// A short background task `id` is about to be begun (call before asking the system, so an early expiry cannot
    /// be lost).
    public func armGrace(_ id: UUID) {
        state.withLock { $0.grace = id }
    }

    /// The system ended the short background task `id`. Recorded as `expired` only if it is the one held now.
    public func graceExpired(_ id: UUID) {
        let at = now()
        state.withLock { s in
            guard s.grace == id else { return }
            s.grace = nil
            Self.append(&s, .expired, at)
        }
    }

    /// The prepare ended (or the system refused) the short background task `id`.
    public func graceEnded(_ id: UUID) {
        state.withLock { s in
            if s.grace == id { s.grace = nil }
        }
    }

    private static func append(_ s: inout State, _ kind: TransitionKind, _ at: Date) {
        s.transitions.append(Transition(kind: kind, at: at))
        if s.transitions.count > keptTransitions { s.transitions.removeFirst(s.transitions.count - keptTransitions) }
    }

    // MARK: Reads

    public var inBackground: Bool { state.withLock { $0.inBackground } }
    public var epoch: Int { state.withLock { $0.epoch } }
    /// A short background task is held now.
    public var hasGrace: Bool { state.withLock { $0.grace != nil } }

    /// Whether a Neural Engine stage may start now: always in front; in the background only with the entitlement
    /// and while the short background task is held (after it expires the app is about to be suspended, and a new
    /// stage would only freeze half-done).
    public var mayStartStage: Bool { mayStartStage(usesNeuralEngine: true) }

    /// Whether a stage may start now. A CPU-only stage (`usesNeuralEngine` false) needs no entitlement: in the
    /// background it may start while the short background task is held.
    public func mayStartStage(usesNeuralEngine: Bool) -> Bool {
        state.withLock { Self.mayStart(self, $0, usesNeuralEngine: usesNeuralEngine) }
    }

    /// The window a stage starting now runs in, or nil when it may not start (`mayStartStage(usesNeuralEngine:)`).
    public func stageWindow(usesNeuralEngine: Bool = true) -> Window? {
        state.withLock { s in
            Self.mayStart(self, s, usesNeuralEngine: usesNeuralEngine)
                ? Window(epoch: s.epoch, inBackground: s.inBackground) : nil
        }
    }

    /// The stage that started in `window` ran wholly in front: in front at its start and now, with no trip to the
    /// background in between.
    public func isForegroundClean(_ window: Window) -> Bool {
        state.withLock { !window.inBackground && !$0.inBackground && $0.epoch == window.epoch }
    }

    /// The transitions at or after `date`, oldest first (at most `keptTransitions`).
    public func transitions(since date: Date = .distantPast) -> [Transition] {
        state.withLock { $0.transitions.filter { $0.at >= date } }
    }

    private static func mayStart(_ activity: AppActivity, _ s: State, usesNeuralEngine: Bool) -> Bool {
        !s.inBackground || activity.ignoresStartRule
            || ((activity.backgroundInference || !usesNeuralEngine) && s.grace != nil)
    }
}
