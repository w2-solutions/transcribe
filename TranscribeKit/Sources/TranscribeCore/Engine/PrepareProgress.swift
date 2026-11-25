import Foundation

/// One step of the speech-model prepare, in the order the engines run them (`FluidSpeechEngine.loadStages`,
/// `allCases`): the short ones first (decided by Liam on 2026-11-25), so they are done before the long Parakeet
/// compile, which may still be running when the user leaves the app and iOS's short background allowance (about
/// 27 s) runs out. The warm-up needs the loaded Parakeet, so it comes right after it. The raw values are the stage
/// names the prepare log uses (`PrepareRecord.Stage.name`).
public enum PrepareStage: String, Sendable, Codable, CaseIterable, Hashable {
    /// community-1: the voice embedder and the fallback speaker separator (Neural Engine, about 1–2 s cold).
    case diarizer
    /// Nemotron 3: the speaker separator. A load on the CPU (about 1 s) that checks it loads on this device.
    case nemotron
    /// Parakeet: loaded and compiled for this device's Neural Engine (about 20 s cold on an iPhone 15).
    case asr
    /// A 1 s silent transcription through the loaded Parakeet.
    case warmup

    /// Whether the stage loads models for the Neural Engine. Every stage but Nemotron 3 does; Nemotron runs on the
    /// CPU (`NemotronSeparation.computeUnits`, a test keeps the two in step). A CPU stage needs neither the
    /// Neural Engine nor the Background Inference entitlement in the background, so the background rules
    /// (`AppActivity.stageWindow(usesNeuralEngine:)`, `FluidSpeechEngine`) let it start while the short background
    /// task is held and keep it whenever it returns.
    public var usesNeuralEngine: Bool { self != .nemotron }
}

/// What a prepare is about to run, sent before its first stage (`PrepareEvent.planned`). Each stage is one opaque
/// Core ML load with no progress of its own, so the app shows progress from these expected durations.
public struct PreparePlan: Sendable, Equatable {
    public struct Step: Sendable, Equatable {
        public var stage: PrepareStage
        /// How long the stage is expected to take now: cold or warm, measured on this device or a built-in guess.
        public var expectedSeconds: Double
        /// An earlier prepare in this process already kept this stage, so this prepare skips it.
        public var isDone: Bool
        /// The stage's compile is already cached (in this process, or kept earlier under this install and OS build),
        /// so it loads in about a second. A setup whose every step is warm is not the once-after-an-update setup.
        public var isWarm: Bool
        public init(stage: PrepareStage, expectedSeconds: Double, isDone: Bool = false, isWarm: Bool = false) {
            self.stage = stage; self.expectedSeconds = expectedSeconds; self.isDone = isDone; self.isWarm = isWarm
        }
    }

    /// In run order.
    public var steps: [Step]
    /// Every step still to run has an estimate measured on this device (or is warm in this process). Only then may
    /// the app say how long is left; built-in guesses move the bar but never produce a time.
    public var timesFromThisDevice: Bool

    public init(steps: [Step], timesFromThisDevice: Bool) {
        self.steps = steps; self.timesFromThisDevice = timesFromThisDevice
    }

    public func step(_ stage: PrepareStage) -> Step? { steps.first { $0.stage == stage } }
}

/// What a running prepare reports (`SpeechEngine.prepareModels(onEvent:)`): a plan, then a started/finished pair per
/// stage. A stage that throws or is refused sends no `stageFinished`.
public enum PrepareEvent: Sendable, Equatable {
    case planned(PreparePlan)
    case stageStarted(PrepareStage)
    /// The stage's work returned: its compile is done, whether or not its models were kept.
    case stageFinished(PrepareStage)
}
