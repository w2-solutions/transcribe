import Foundation
import TranscribeCore

/// What the "Working out who said what" panel, its collapsed pill and the Library card show (§6.3).
///
/// A live `ProcessingSnapshot` from the monitor wins while the job is running, finished or failed. Without one
/// (just launched, or still queued) the rows are a placeholder built from the persisted stage:
/// up to `.transcribed` → step 1 active (done once transcribed); `.separating`/`.separated` → step 2 active;
/// `.matching` → step 3 active.
public struct ProcessingViewState: Equatable, Sendable {
    public enum Mode: Equatable, Sendable {
        case running
        case waiting(QueueReason)
        case finished
        case failed(String)
    }

    public static let defaultHeading = "Working out who said what"
    public static func defaultMessage(_ p: DevicePlatform) -> String { DeviceCopy(platform: p).processingDefault }
    public static let modelsHeading = "Waiting for speech models"
    public static func modelsMessage(_ p: DevicePlatform) -> String { DeviceCopy(platform: p).processingModels }
    public static let recordingHeading = "Paused while you record"
    public static let recordingMessage = "Processing picks up again when you stop recording."
    public static let backgroundMessage = "Paused in the background. It picks up again when you come back."
    public static let identifyOffReason = "Identify speakers is off"
    public static let recogniseOffReason = "Recognise voices is off"

    public var mode: Mode
    public var heading: String
    public var message: String
    /// Always three rows, in step order.
    public var steps: [StepStatus]
    /// 0...1; weights 0.45 / 0.45 / 0.10, skipped steps count as done.
    public var overall: Double

    public init(stage: RecordingStage, queueReason: QueueReason?, snapshot: ProcessingSnapshot?,
                savedVoiceNames: [String] = [], identifySpeakers: Bool = true, recogniseVoices: Bool = true,
                platform: DevicePlatform = .current) {
        let reason = Self.queueReason(snapshot: snapshot, stored: queueReason)
        if let snapshot, Self.isLive(snapshot.phase) {
            steps = snapshot.steps.count == ProcessingStep.allCases.count
                ? Self.previewingComparison(snapshot.steps, comparedWith: snapshot.comparedWith, savedVoiceNames: savedVoiceNames)
                : Self.placeholderSteps(stage: stage, savedVoiceNames: snapshot.comparedWith,
                                        identifySpeakers: identifySpeakers, recogniseVoices: recogniseVoices)
            overall = Swift.min(1, Swift.max(0, snapshot.overall))
            switch snapshot.phase {
            case .finished: mode = .finished
            case .failed(let message): mode = .failed(message)
            default: mode = .running
            }
        } else if stage >= .ready && stage != .failed {
            steps = Self.doneSteps(voicesFound: snapshot?.voicesFound, comparedWith: snapshot?.comparedWith ?? savedVoiceNames)
            overall = 1
            mode = .finished
        } else {
            steps = Self.placeholderSteps(stage: stage, savedVoiceNames: snapshot?.comparedWith ?? savedVoiceNames,
                                          identifySpeakers: identifySpeakers, recogniseVoices: recogniseVoices)
            overall = Self.overall(steps)
            if stage == .failed {
                mode = .failed("Couldn't finish processing")
            } else if let reason {
                mode = .waiting(reason)
            } else {
                mode = .running
            }
        }
        switch mode {
        case .waiting(.modelsNotReady):
            heading = Self.modelsHeading; message = Self.modelsMessage(platform)
        case .waiting(.pausedForRecording):
            heading = Self.recordingHeading; message = Self.recordingMessage
        case .waiting(.pausedByBackgroundExpiry):
            heading = Self.defaultHeading; message = Self.backgroundMessage
        case .failed(let text):
            heading = "Couldn't finish processing"; message = text
        default:
            heading = Self.defaultHeading; message = Self.defaultMessage(platform)
        }
    }

    // MARK: Derived text

    /// The step in progress, else the first one not yet done.
    public var activeStep: ProcessingStep? {
        if let active = steps.first(where: { if case .active = $0.state { true } else { false } }) { return active.step }
        return steps.first(where: { $0.state == .waiting })?.step
    }

    /// Steps that will run (not skipped).
    public var enabledSteps: [StepStatus] {
        steps.filter { if case .skipped = $0.state { false } else { true } }
    }

    /// 1-based position of the current step among the enabled steps.
    public var stepNumber: Int {
        let enabled = enabledSteps
        guard !enabled.isEmpty else { return 1 }
        if let step = activeStep, let i = enabled.firstIndex(where: { $0.step == step }) { return i + 1 }
        return enabled.count
    }

    /// "Step 2 of 3".
    public var stepCounterText: String { "Step \(stepNumber) of \(Swift.max(1, enabledSteps.count))" }

    /// 0...100 for the progress bar's accessibility value.
    public var percent: Int { Int((overall * 100).rounded()) }

    /// The progress bar's accessibility value, "60%".
    public var progressValueText: String { "\(percent)%" }

    public var isWaitingForModels: Bool { mode == .waiting(.modelsNotReady) }

    /// The collapsed pill: "Separating speakers · 60%", or "Waiting for speech models".
    public var collapsedText: String {
        switch mode {
        case .waiting(.modelsNotReady): return Self.modelsHeading
        case .waiting(.pausedForRecording): return Self.recordingHeading
        case .finished: return "Done · 100%"
        case .failed: return "Couldn't finish processing"
        default: return "\((activeStep ?? .transcribing).activeTitle) · \(percent)%"
        }
    }

    /// The Library card's status pill: "Separating speakers… 2/3", or "Waiting for speech models".
    public var cardText: String {
        switch mode {
        case .waiting(.modelsNotReady): return Self.modelsHeading
        case .waiting(.pausedForRecording): return Self.recordingHeading
        default: return "\((activeStep ?? .matching).activeTitle)… \(stepNumber)/\(Swift.max(1, enabledSteps.count))"
        }
    }

    /// The panel's row title for a step: done → `title`, active → `activeTitle`, waiting → `title`.
    public static func rowTitle(_ status: StepStatus) -> String {
        if case .active = status.state { return status.step.activeTitle }
        return status.step.title
    }

    /// The `AX.Processing.step(_:)` slug.
    public static func slug(_ step: ProcessingStep) -> String {
        switch step {
        case .transcribing: "transcribing"
        case .separating: "separating"
        case .matching: "matching"
        }
    }

    // MARK: Building blocks

    static func isLive(_ phase: ProcessingPhase) -> Bool {
        if case .queued = phase { return false }
        return true
    }

    static func queueReason(snapshot: ProcessingSnapshot?, stored: QueueReason?) -> QueueReason? {
        if let snapshot, case .queued(let reason) = snapshot.phase { return reason }
        return stored
    }

    static func placeholderSteps(stage: RecordingStage, savedVoiceNames: [String],
                                 identifySpeakers: Bool, recogniseVoices: Bool) -> [StepStatus] {
        let states: [StepState]
        switch stage {
        case .capturing, .queued, .transcribing:
            states = [.active(fraction: nil), .waiting, .waiting]
        case .transcribed:
            states = [.done, .waiting, .waiting]
        case .separating, .separated:
            states = [.done, .active(fraction: nil), .waiting]
        case .matching:
            states = [.done, .done, .active(fraction: nil)]
        case .ready, .failed:
            states = [.done, .done, .done]
        }
        return zip(ProcessingStep.allCases, states).map { step, state in
            var state = state
            if step == .separating, !identifySpeakers, state != .done {
                state = .skipped(identifyOffReason)
            } else if step == .matching, state != .done, !identifySpeakers || !recogniseVoices {
                state = .skipped(identifySpeakers ? recogniseOffReason : identifyOffReason)
            }
            return StepStatus(step: step, state: state,
                              subtitle: ProcessingCopy.subtitle(step: step, state: state, voicesFound: nil,
                                                                comparedWith: savedVoiceNames))
        }
    }

    /// Before step 3 starts the pipeline may not have named the voices it will compare with yet; a waiting
    /// matching row then previews the saved voices ("Compared with Liam and Karan") instead of "No saved voices yet".
    static func previewingComparison(_ steps: [StepStatus], comparedWith: [String], savedVoiceNames: [String]) -> [StepStatus] {
        guard comparedWith.isEmpty, !savedVoiceNames.isEmpty else { return steps }
        return steps.map { status in
            guard status.step == .matching, status.state == .waiting else { return status }
            var status = status
            status.subtitle = ProcessingCopy.subtitle(step: .matching, state: .waiting, voicesFound: nil,
                                                      comparedWith: savedVoiceNames)
            return status
        }
    }

    static func doneSteps(voicesFound: Int?, comparedWith: [String]) -> [StepStatus] {
        ProcessingStep.allCases.map { step in
            StepStatus(step: step, state: .done,
                       subtitle: ProcessingCopy.subtitle(step: step, state: .done, voicesFound: voicesFound,
                                                         comparedWith: comparedWith))
        }
    }

    static func overall(_ steps: [StepStatus]) -> Double {
        var total = 0.0
        for status in steps {
            let weight = ProcessingCopy.weights[status.step] ?? 0
            switch status.state {
            case .done, .skipped: total += weight
            case .active(let fraction): total += weight * (fraction ?? 0)
            case .waiting: break
            }
        }
        return Swift.min(1, Swift.max(0, total))
    }
}
