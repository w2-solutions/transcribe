import Foundation

public enum ProcessingStep: Int, Sendable, Codable, CaseIterable, Comparable {
    case transcribing = 1, separating = 2, matching = 3
    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
    public var title: String {
        switch self {
        case .transcribing: "Transcribed"              // done-state title; active title below
        case .separating: "Separating speakers"
        case .matching: "Matching saved voices"
        }
    }
    public var activeTitle: String {
        switch self {
        case .transcribing: "Transcribing"
        case .separating: "Separating speakers"
        case .matching: "Matching saved voices"
        }
    }
}

public enum StepState: Sendable, Equatable {
    case waiting
    case active(fraction: Double?)
    case done
    case skipped(String)      // reason, e.g. "Identify speakers is off"
}

public struct StepStatus: Sendable, Equatable, Identifiable {
    public var step: ProcessingStep
    public var state: StepState
    public var subtitle: String
    public var id: ProcessingStep { step }
    public init(step: ProcessingStep, state: StepState, subtitle: String) {
        self.step = step; self.state = state; self.subtitle = subtitle
    }
    /// accessibilityValue used by UI tests.
    public var axValue: String {
        switch state { case .waiting: "waiting"; case .active: "inProgress"; case .done: "done"; case .skipped: "skipped" }
    }
}

public enum QueueReason: String, Sendable, Codable, Equatable {
    case waitingForTurn, modelsNotReady, pausedForRecording, pausedByBackgroundExpiry
}

public struct ProcessingOutcome: Sendable, Equatable {
    public var autoLabelled: Int
    public var suggested: Int
    public var unnamed: Int
    public var noSpeech: Bool
    public init(autoLabelled: Int = 0, suggested: Int = 0, unnamed: Int = 0, noSpeech: Bool = false) {
        self.autoLabelled = autoLabelled; self.suggested = suggested; self.unnamed = unnamed; self.noSpeech = noSpeech
    }
}

public enum ProcessingPhase: Sendable, Equatable {
    case queued(QueueReason)
    case running
    case finished(ProcessingOutcome)
    case failed(String)
}

public struct ProcessingSnapshot: Sendable, Equatable {
    public var recordingID: UUID
    public var steps: [StepStatus]          // always 3, in step order
    public var overall: Double              // weights 0.45 / 0.45 / 0.10; skipped steps count as done
    public var voicesFound: Int?            // set only after separation finishes
    public var comparedWith: [String]       // saved profile names used in step 3
    public var phase: ProcessingPhase
    public init(recordingID: UUID, steps: [StepStatus], overall: Double, voicesFound: Int?,
                comparedWith: [String], phase: ProcessingPhase) {
        self.recordingID = recordingID; self.steps = steps; self.overall = overall
        self.voicesFound = voicesFound; self.comparedWith = comparedWith; self.phase = phase
    }
    public var currentStep: ProcessingStep? {
        steps.first(where: { if case .active = $0.state { true } else { false } })?.step
    }
    /// "Step 2 of 3" (counts only non-skipped steps).
    public var stepCounterText: String {
        let enabled = steps.filter { if case .skipped = $0.state { false } else { true } }
        let n = (enabled.firstIndex(where: { $0.step == currentStep }) ?? Swift.max(0, enabled.count - 1)) + 1
        return "Step \(n) of \(enabled.count)"
    }
}
