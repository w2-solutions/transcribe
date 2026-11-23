import Foundation
import Testing
import TranscribeCore
@testable import TranscribeKit

@Suite("ProcessingViewState: placeholders, snapshots and step texts")
struct ProcessingViewStateTests {
    static let id = UUID()

    func states(_ s: ProcessingViewState) -> [String] { s.steps.map(\.axValue) }

    // MARK: Placeholder from the persisted stage

    @Test(arguments: [
        (RecordingStage.capturing, ["inProgress", "waiting", "waiting"], "Step 1 of 3"),
        (.queued, ["inProgress", "waiting", "waiting"], "Step 1 of 3"),
        (.transcribing, ["inProgress", "waiting", "waiting"], "Step 1 of 3"),
        (.transcribed, ["done", "waiting", "waiting"], "Step 2 of 3"),
        (.separating, ["done", "inProgress", "waiting"], "Step 2 of 3"),
        (.separated, ["done", "inProgress", "waiting"], "Step 2 of 3"),
        (.matching, ["done", "done", "inProgress"], "Step 3 of 3"),
        (.ready, ["done", "done", "done"], "Step 3 of 3"),
    ])
    func placeholderFollowsTheStage(_ stage: RecordingStage, _ expected: [String], _ counter: String) {
        let s = ProcessingViewState(stage: stage, queueReason: nil, snapshot: nil)
        #expect(states(s) == expected)
        #expect(s.stepCounterText == counter)
    }

    @Test func separatingPlaceholderTextsMatchTheMockup() {
        let s = ProcessingViewState(stage: .separating, queueReason: nil, snapshot: nil, savedVoiceNames: ["Liam", "Karan"],
                                    platform: .iPhone)
        #expect(s.heading == "Working out who said what")
        #expect(s.message == "This happens on your iPhone. You can leave and come back.")
        #expect(s.steps.map(ProcessingViewState.rowTitle) == ["Transcribed", "Separating speakers", "Matching saved voices"])
        #expect(s.steps.map(\.subtitle) == ["Parakeet, on device", "Listening for different voices", "Compared with Liam and Karan"])
        #expect(s.stepCounterText == "Step 2 of 3")
        #expect(s.activeStep == .separating)
        #expect(abs(s.overall - 0.45) < 1e-9)
        #expect(s.progressValueText == "45%")
        #expect(s.collapsedText == "Separating speakers · 45%")
        #expect(s.cardText == "Separating speakers… 2/3")
        #expect(s.mode == .running)
    }

    @Test func activeTitleOnlyWhileActive() {
        let s = ProcessingViewState(stage: .queued, queueReason: nil, snapshot: nil)
        #expect(ProcessingViewState.rowTitle(s.steps[0]) == "Transcribing")
        #expect(s.steps[0].subtitle == "Turning speech into text")
        #expect(ProcessingViewState.rowTitle(s.steps[1]) == "Separating speakers")
        #expect(s.steps[1].subtitle == "Finds who spoke when")
        #expect(s.steps[2].subtitle == "No saved voices yet")
    }

    @Test func waitingForModels() {
        let s = ProcessingViewState(stage: .queued, queueReason: .modelsNotReady, snapshot: nil, platform: .iPhone)
        #expect(s.mode == .waiting(.modelsNotReady))
        #expect(s.heading == "Waiting for speech models")
        #expect(s.message == "Processing starts once the speech models are ready on this iPhone.")
        #expect(s.isWaitingForModels)
        #expect(s.collapsedText == "Waiting for speech models")
        #expect(s.cardText == "Waiting for speech models")
    }

    @Test func macWording() {
        let running = ProcessingViewState(stage: .separating, queueReason: nil, snapshot: nil, platform: .mac)
        #expect(running.message == "This happens on your Mac. You can keep working.")
        let waiting = ProcessingViewState(stage: .queued, queueReason: .modelsNotReady, snapshot: nil, platform: .mac)
        #expect(waiting.message == "Processing starts once the speech models are ready on this Mac.")
    }

    @Test func queuedSnapshotReasonWinsOverTheStoredOne() {
        let snapshot = ProcessingSnapshot(recordingID: Self.id, steps: [], overall: 0, voicesFound: nil,
                                          comparedWith: [], phase: .queued(.pausedForRecording))
        let s = ProcessingViewState(stage: .transcribed, queueReason: nil, snapshot: snapshot)
        #expect(s.heading == "Paused while you record")
        #expect(states(s) == ["done", "waiting", "waiting"])
        #expect(s.cardText == "Paused while you record")
    }

    @Test func queuedSnapshotWithAllWaitingStillUsesTheStage() {
        // The coordinator publishes `.queued` snapshots with three waiting rows; the stage knows better.
        let waiting = ProcessingStep.allCases.map {
            StepStatus(step: $0, state: .waiting, subtitle: ProcessingCopy.subtitle(step: $0, state: .waiting, voicesFound: nil, comparedWith: []))
        }
        let snapshot = ProcessingSnapshot(recordingID: Self.id, steps: waiting, overall: 0, voicesFound: nil,
                                          comparedWith: [], phase: .queued(.waitingForTurn))
        let s = ProcessingViewState(stage: .separating, queueReason: nil, snapshot: snapshot)
        #expect(states(s) == ["done", "inProgress", "waiting"])
        #expect(s.heading == ProcessingViewState.defaultHeading)
    }

    // MARK: Live snapshots

    @Test func runningSnapshotWins() {
        let steps = [
            StepStatus(step: .transcribing, state: .done, subtitle: "Parakeet, on device"),
            StepStatus(step: .separating, state: .active(fraction: 0.6), subtitle: "Listening for different voices · 60%"),
            StepStatus(step: .matching, state: .waiting, subtitle: "Compared with Liam and Karan"),
        ]
        let snapshot = ProcessingSnapshot(recordingID: Self.id, steps: steps, overall: 0.72, voicesFound: nil,
                                          comparedWith: ["Liam", "Karan"], phase: .running)
        let s = ProcessingViewState(stage: .transcribed, queueReason: nil, snapshot: snapshot)
        #expect(s.steps == steps)
        #expect(s.overall == 0.72)
        #expect(s.percent == 72)
        #expect(s.stepCounterText == "Step 2 of 3")
        #expect(s.collapsedText == "Separating speakers · 72%")
    }

    @Test func waitingMatchingRowPreviewsTheSavedVoices() {
        let steps = [
            StepStatus(step: .transcribing, state: .done, subtitle: "Parakeet, on device"),
            StepStatus(step: .separating, state: .active(fraction: 0), subtitle: "Listening for different voices · 0%"),
            StepStatus(step: .matching, state: .waiting, subtitle: "No saved voices yet"),
        ]
        let snapshot = ProcessingSnapshot(recordingID: Self.id, steps: steps, overall: 0.45, voicesFound: nil,
                                          comparedWith: [], phase: .running)
        let s = ProcessingViewState(stage: .separating, queueReason: nil, snapshot: snapshot, savedVoiceNames: ["Liam", "Karan"])
        #expect(s.steps[2].subtitle == "Compared with Liam and Karan")
        #expect(s.steps[1].subtitle == "Listening for different voices · 0%")
        // Without saved voices the pipeline's text stays.
        #expect(ProcessingViewState(stage: .separating, queueReason: nil, snapshot: snapshot).steps[2].subtitle == "No saved voices yet")
    }

    @Test func skippedStepsAreLeftOutOfTheCounter() {
        let steps = [
            StepStatus(step: .transcribing, state: .active(fraction: 0.5), subtitle: "Turning speech into text · 50%"),
            StepStatus(step: .separating, state: .skipped("Identify speakers is off"), subtitle: "Identify speakers is off"),
            StepStatus(step: .matching, state: .skipped("Identify speakers is off"), subtitle: "Identify speakers is off"),
        ]
        let snapshot = ProcessingSnapshot(recordingID: Self.id, steps: steps, overall: 0.775, voicesFound: nil,
                                          comparedWith: [], phase: .running)
        let s = ProcessingViewState(stage: .transcribing, queueReason: nil, snapshot: snapshot)
        #expect(s.stepCounterText == "Step 1 of 1")
        #expect(s.cardText == "Transcribing… 1/1")
    }

    @Test func placeholderSkipsFollowTheSettings() {
        let off = ProcessingViewState(stage: .queued, queueReason: nil, snapshot: nil, identifySpeakers: false)
        #expect(states(off) == ["inProgress", "skipped", "skipped"])
        #expect(off.steps[1].subtitle == "Identify speakers is off")
        #expect(off.stepCounterText == "Step 1 of 1")
        #expect(abs(off.overall - 0.55) < 1e-9)

        let noMatch = ProcessingViewState(stage: .separating, queueReason: nil, snapshot: nil, recogniseVoices: false)
        #expect(states(noMatch) == ["done", "inProgress", "skipped"])
        #expect(noMatch.steps[2].subtitle == "Recognise voices is off")
        #expect(noMatch.stepCounterText == "Step 2 of 2")
    }

    @Test func finishedShowsThreeTicks() {
        let snapshot = ProcessingSnapshot(recordingID: Self.id, steps: ProcessingViewState.doneSteps(voicesFound: 2, comparedWith: ["Liam"]),
                                          overall: 1, voicesFound: 2, comparedWith: ["Liam"],
                                          phase: .finished(ProcessingOutcome(autoLabelled: 1, unnamed: 1)))
        let s = ProcessingViewState(stage: .ready, queueReason: nil, snapshot: snapshot)
        #expect(s.mode == .finished)
        #expect(states(s) == ["done", "done", "done"])
        #expect(s.steps[1].subtitle == "2 voices found")
        #expect(s.overall == 1)

        let fromStage = ProcessingViewState(stage: .ready, queueReason: nil, snapshot: nil)
        #expect(fromStage.mode == .finished)
        #expect(fromStage.percent == 100)
    }

    @Test func failedPhaseShowsTheMessage() {
        let snapshot = ProcessingSnapshot(recordingID: Self.id, steps: ProcessingViewState.doneSteps(voicesFound: nil, comparedWith: []),
                                          overall: 0.45, voicesFound: nil, comparedWith: [], phase: .failed("Simulated failure"))
        let s = ProcessingViewState(stage: .separating, queueReason: nil, snapshot: snapshot)
        #expect(s.mode == .failed("Simulated failure"))
        #expect(s.message == "Simulated failure")
        #expect(ProcessingViewState(stage: .failed, queueReason: nil, snapshot: nil).mode == .failed("Couldn't finish processing"))
    }

    @Test func slugsMatchTheAccessibilityCatalogue() {
        #expect(ProcessingStep.allCases.map(ProcessingViewState.slug) == ["transcribing", "separating", "matching"])
    }
}
