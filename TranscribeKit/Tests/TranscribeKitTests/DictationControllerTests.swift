import Foundation
import SwiftData
import Testing
import TranscribeCore
@testable import TranscribeFakes
@testable import TranscribeKit

@Suite("DictationController")
@MainActor
struct DictationControllerTests {
    let sentence = FakeScript.dictationSentence

    // MARK: Flows

    @Test func holdFlowPastesTheSentenceAndLeavesNoTrace() async throws {
        let r = try await DictationRig()
        defer { r.cleanup() }
        #expect(await r.pressAndListen())
        #expect(r.controller.isBusy && r.controller.acceptsEscape && r.controller.mode == .hold)
        #expect(r.gate.owner == .dictation)
        r.controller.handle(.holdReleased)
        #expect(await r.settled())
        #expect(r.controller.lastOutcome == .pasted)
        #expect(r.output.delivered.map(\.text) == [sentence])
        #expect(r.output.delivered.first?.target == 100)
        #expect(r.controller.lastText == sentence)
        #expect(!r.controller.isBusy && r.controller.mode == nil)
        // Never the library: no row, nothing in Audio/, and the dictation audio is gone.
        #expect(try r.h.count(Recording.self) == 0)
        #expect(r.dictationFiles.isEmpty)
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: r.h.paths.audioDirectory.path)) ?? []).isEmpty)
        #expect(await r.base.callCount("transcribe") == 1)
        #expect(await r.base.callCount("startRecording") == 1)
        #expect(await r.session?.stopCalls == 1)
        #expect(await r.coordinator.exclusiveAcquisitions == 1)
    }

    @Test func handsFreeFlowStoppedAtOnceStillTakesTheHoldAndPastes() async throws {
        let r = try await DictationRig()
        defer { r.cleanup() }
        r.controller.handle(.togglePressed)
        #expect(await dictationWait { r.controller.phase == .listening(.handsFree) })
        #expect(r.controller.mode == .handsFree)
        // Pressed again before 0.3 s: hands-free has no "too short"; the hold is taken at the stop instead.
        r.controller.handle(.togglePressed)
        #expect(await r.settled())
        #expect(r.controller.lastOutcome == .pasted)
        #expect(r.output.delivered.map(\.text) == [sentence])
        #expect(await r.coordinator.exclusiveAcquisitions == 1)
        #expect(r.dictationFiles.isEmpty)
    }

    @Test func noSpeech() async throws {
        let r = try await DictationRig(script: .noSpeech)
        defer { r.cleanup() }
        #expect(await r.pressAndListen())
        r.controller.handle(.holdReleased)
        #expect(await r.settled())
        #expect(r.controller.lastOutcome == .noSpeech)
        #expect(r.output.delivered.isEmpty && r.output.copied.isEmpty)
        #expect(r.controller.lastText == nil)
        #expect(r.dictationFiles.isEmpty)
    }

    @Test func microphoneDenied() async throws {
        let r = try await DictationRig(mic: .denied)
        defer { r.cleanup() }
        r.controller.handle(.holdPressed)
        #expect(await r.settled())
        #expect(r.controller.lastOutcome == .micDenied)
        #expect(await r.base.callCount("startRecording") == 0)
        #expect(await r.coordinator.exclusiveAcquisitions == 0)
    }

    @Test func undeterminedMicrophoneAskedDuringAHoldShowsMicrophoneIsOn() async throws {
        let gate = AsyncGate()
        let r = try await DictationRig(mic: .undetermined, startGate: gate)
        defer { r.cleanup() }
        r.controller.handle(.holdPressed)
        r.controller.handle(.holdReleased)   // let go while macOS asked
        #expect(await r.settled())
        #expect(r.controller.lastOutcome == .micJustGranted)
        #expect(gate.arrivals == 0, "no capture was started")
    }

    @Test func refusedWhileAMeetingRecords() async throws {
        let r = try await DictationRig()
        defer { r.cleanup() }
        r.meeting.active = true
        #expect(r.gate.claim(.meeting))
        r.controller.handle(.holdPressed)
        #expect(r.controller.phase == .idle && r.controller.lastOutcome == .refusedMeeting)
        #expect(r.gate.owner == .meeting, "a refusal releases nothing")
        r.controller.handle(.togglePressed)
        #expect(r.controller.lastOutcome == .refusedMeeting)
        #expect(await r.base.callCount("startRecording") == 0)
    }

    @Test func refusedWhileTheGateIsTaken() async throws {
        let r = try await DictationRig()
        defer { r.cleanup() }
        #expect(r.gate.claim(.meeting))   // a recording starting (not yet active)
        r.controller.handle(.holdPressed)
        #expect(r.controller.phase == .idle && r.controller.lastOutcome == .refusedBusy)
        #expect(r.gate.owner == .meeting)
    }

    @Test func refusedWhenSetupFailed() async throws {
        let r = try await DictationRig(modelsReady: false, failPrepare: true)
        defer { r.cleanup() }
        await r.models.prepareIfInstalled()
        #expect(r.models.hasFailed)
        r.controller.handle(.holdPressed)
        #expect(r.controller.lastOutcome == .refusedModelsFailed && r.controller.phase == .idle)
        #expect(r.gate.owner == nil)
    }

    @Test func theSameOutcomeTwiceGetsANewID() async throws {
        let r = try await DictationRig()
        defer { r.cleanup() }
        r.meeting.active = true
        r.controller.handle(.holdPressed)
        let first = r.controller.lastOutcomeID
        r.controller.handle(.holdPressed)
        #expect(r.controller.lastOutcome == .refusedMeeting && r.controller.lastOutcomeID != first)
    }

    // MARK: Esc

    @Test func escWhileListeningDiscardsWithoutTakingTheHold() async throws {
        let r = try await DictationRig()
        defer { r.cleanup() }
        #expect(await r.pressAndListen(for: 0.1))
        r.controller.handle(.escape)
        #expect(await r.settled())
        #expect(r.controller.lastOutcome == .cancelled)
        #expect(await dictationWait { await r.session?.discardCalls == 1 })
        #expect(await r.session?.stopCalls == 0)
        #expect(await dictationWait { r.dictationFiles.isEmpty })
        r.clock.advance(5)
        try await Task.sleep(for: .milliseconds(50))
        #expect(await r.coordinator.exclusiveAcquisitions == 0)
        #expect(r.output.delivered.isEmpty)
    }

    @Test func escAfterTenSecondsNeedsASecondPress() async throws {
        let r = try await DictationRig()
        defer { r.cleanup() }
        #expect(await r.pressAndListen(for: 11))
        r.controller.handle(.escape)
        #expect(r.controller.phase == .listening(.hold) && r.controller.escapeConfirmPending)
        // The window passes: the next Esc asks again.
        #expect(await dictationWait { r.clock.hasSleeper(seconds: DictationLimits.escapeConfirmWindow) })
        r.clock.advance(2.1)
        #expect(await dictationWait { !r.controller.escapeConfirmPending })
        r.controller.handle(.escape)
        #expect(r.controller.escapeConfirmPending && r.controller.phase == .listening(.hold))
        r.controller.handle(.escape)
        #expect(await r.settled())
        #expect(r.controller.lastOutcome == .cancelled && !r.controller.escapeConfirmPending)
        #expect(r.output.delivered.isEmpty)
    }

    /// Esc while Parakeet runs: the dictation is over at once, but the hold and the gate wait for the call to end, so
    /// a job or a meeting's live text can never overlap it.
    @Test func escWhileTranscribingDropsTheResultAndWaitsForTheCall() async throws {
        let door = AsyncGate()
        let r = try await DictationRig(transcribeGate: door)
        defer { r.cleanup() }
        #expect(await r.pressAndListen())
        r.controller.handle(.holdReleased)
        #expect(await dictationWait { r.controller.phase == .transcribing && door.arrivals == 1 })
        r.controller.handle(.escape)
        #expect(r.controller.phase == .idle && r.controller.lastOutcome == .cancelled)
        #expect(!r.controller.isBusy)
        try await Task.sleep(for: .milliseconds(100))
        #expect(r.gate.owner == .dictation, "the gate waits for the transcription to end")
        #expect(await r.coordinator.exclusiveHoldCount == 1, "so does the hold")
        r.controller.handle(.holdPressed)
        #expect(r.controller.lastOutcome == .refusedBusy)
        door.open()
        #expect(await r.settled())
        #expect(r.output.delivered.isEmpty && r.output.copied.isEmpty)
        #expect(r.dictationFiles.isEmpty)
    }

    // MARK: Taps and late results

    @Test func aTapUnderMinimumHoldHintsAndNeverPreempts() async throws {
        let r = try await DictationRig()
        defer { r.cleanup() }
        #expect(await r.pressAndListen(for: 0.1))
        r.controller.handle(.holdReleased)
        #expect(await r.settled())
        #expect(r.controller.lastOutcome == .tooShortHint(.hold))
        // The hold task has ended without the hold; once ended it can never acquire, whatever the clock does next.
        #expect(await dictationWait { r.controller.resolvedHolds.count == 1 })
        #expect(r.controller.resolvedHolds == [false])
        r.clock.advance(1)
        #expect(await r.coordinator.exclusiveAcquisitions == 0)
        #expect(await dictationWait { await r.session?.discardCalls == 1 })
        #expect(await r.base.callCount("transcribe") == 0)
    }

    /// Esc while the microphone is still opening: the session that arrives later is discarded, its file deleted and
    /// the gate freed. Nothing is left recording.
    @Test func aLateStartAfterEscIsDiscarded() async throws {
        let door = AsyncGate()
        let r = try await DictationRig(startGate: door)
        defer { r.cleanup() }
        r.controller.handle(.holdPressed)
        #expect(await dictationWait { door.arrivals == 1 })
        r.controller.handle(.escape)
        #expect(r.controller.phase == .starting(.hold, .cancel))
        #expect(r.gate.owner == .dictation)
        door.open()
        #expect(await r.settled())
        #expect(r.controller.lastOutcome == .cancelled)
        #expect(await dictationWait { await r.session?.discardCalls == 1 })
        #expect(await r.session?.stopCalls == 0)
        #expect(await dictationWait { r.dictationFiles.isEmpty })
        #expect(await r.coordinator.exclusiveAcquisitions == 0)
    }

    @Test func aReleaseWhileStartingEndsAsTooShort() async throws {
        let door = AsyncGate()
        let r = try await DictationRig(startGate: door)
        defer { r.cleanup() }
        r.controller.handle(.holdPressed)
        #expect(await dictationWait { door.arrivals == 1 })
        r.controller.handle(.holdReleased)
        #expect(r.controller.phase == .starting(.hold, .stop))
        r.controller.handle(.escape)   // a cancel wins over a stop
        #expect(r.controller.phase == .starting(.hold, .cancel))
        door.open()
        #expect(await r.settled())
        #expect(r.controller.lastOutcome == .cancelled)
        #expect(await dictationWait { await r.session?.discardCalls == 1 })
    }

    @Test func aSecondToggleWhileStartingStopsHandsFree() async throws {
        let door = AsyncGate()
        let r = try await DictationRig(startGate: door)
        defer { r.cleanup() }
        r.controller.handle(.togglePressed)
        #expect(await dictationWait { door.arrivals == 1 })
        r.controller.handle(.togglePressed)
        #expect(r.controller.phase == .starting(.handsFree, .stop))
        door.open()
        #expect(await r.settled())
        #expect(r.controller.lastOutcome == .tooShortHint(.handsFree))
        #expect(await dictationWait { await r.session?.discardCalls == 1 })
        #expect(await r.coordinator.exclusiveAcquisitions == 0)
    }

    // MARK: Models

    @Test func waitsForSetupWithNoTimeLimitButTheCap() async throws {
        let door = AsyncGate()
        let r = try await DictationRig(modelsReady: false, prepareGate: door)
        defer { r.cleanup() }
        #expect(await r.pressAndListen())
        #expect(r.models.isSettingUp)
        r.controller.handle(.holdReleased)
        #expect(await dictationWait { r.controller.phase == .waitingForModels })
        #expect(await dictationWait { r.clock.hasSleeper(seconds: DictationLimits.modelsWaitCap) })
        r.clock.advance(61)   // past the old 60 s limit: still waiting
        try await Task.sleep(for: .milliseconds(100))
        #expect(r.controller.phase == .waitingForModels)
        door.open()
        #expect(await r.settled())
        #expect(r.controller.lastOutcome == .pasted)
        #expect(r.output.delivered.map(\.text) == [sentence])
    }

    @Test func givesUpAtTheCap() async throws {
        let door = AsyncGate()
        let r = try await DictationRig(modelsReady: false, prepareGate: door)
        defer { r.cleanup(); door.open() }
        #expect(await r.pressAndListen())
        r.controller.handle(.holdReleased)
        #expect(await dictationWait { r.controller.phase == .waitingForModels && r.clock.hasSleeper(seconds: DictationLimits.modelsWaitCap) })
        r.clock.advance(DictationLimits.modelsWaitCap + 1)
        #expect(await r.settled())
        #expect(r.controller.lastOutcome == .failed(DictationMachine.modelsUnavailableMessage))
        #expect(r.dictationFiles.isEmpty)
        #expect(await r.base.callCount("transcribe") == 0)
    }

    @Test func givesUpWhenSetupFails() async throws {
        let door = AsyncGate()
        let r = try await DictationRig(modelsReady: false, prepareGate: door, failPrepare: true)
        defer { r.cleanup() }
        #expect(await r.pressAndListen())
        r.controller.handle(.holdReleased)
        #expect(await dictationWait { r.controller.phase == .waitingForModels })
        door.open()
        #expect(await r.settled())
        #expect(r.models.hasFailed)
        #expect(r.controller.lastOutcome == .failed(DictationMachine.modelsUnavailableMessage))
    }

    // MARK: Engine sharing

    /// A job in the middle of separating is pre-empted when the hold is taken, waits for its turn (never "Paused for
    /// recording"), and resumes after the dictation; the engine never sees two model calls at once.
    @Test func aRunningJobIsPreemptedAndResumes() async throws {
        let r = try await DictationRig(script: .holdAtSeparating)
        defer { r.cleanup() }
        let id = try r.h.queuedRecording(script: r.base.script, writeAudio: true)
        await r.coordinator.enqueue(id)
        #expect(await dictationWait { await r.base.callCount("separateSpeakers") == 1 })

        #expect(await r.pressAndListen())
        #expect(await r.coordinator.runningID == nil)
        #expect(await r.coordinator.queuedIDs == [id])
        #expect(await dictationWait { (try? r.h.recording(id).queueReason) == .waitingForTurn })
        #expect(try r.h.recording(id).attemptCount == 0, "the attempt was given back")

        r.controller.handle(.holdReleased)
        #expect(await r.settled())
        #expect(r.controller.lastOutcome == .pasted)
        // The job comes back at its checkpoint (separating), without transcribing again.
        #expect(await dictationWait { await r.base.callCount("separateSpeakers") == 2 })
        #expect(await r.coordinator.runningID == id)
        #expect(await r.base.callCount("transcribe") == 2)   // the job's once, the dictation's once
        #expect(await r.base.maxConcurrentCalls == 1)
        #expect(try r.h.recording(id).queueReason != .pausedForRecording)
        await r.coordinator.cancel(id)
    }

    @Test func liveTextStartsOnlyUnderTheHold() async throws {
        let r = try await DictationRig()
        defer { r.cleanup() }
        r.controller.handle(.holdPressed)
        #expect(await dictationWait { r.controller.phase == .listening(.hold) && r.clock.hasSleeper(seconds: DictationLimits.minimumHold) })
        try await Task.sleep(for: .milliseconds(100))
        #expect(await r.session?.liveTextCalls == [])
        r.clock.advance(0.3)
        #expect(await dictationWait { await r.session?.liveTextCalls == [true] })
        #expect(await r.coordinator.exclusiveHoldCount == 1)
        r.controller.handle(.holdReleased)
        #expect(await r.settled())
    }

    // MARK: Limits and system events

    @Test func theMaximumDurationStopsAndPastes() async throws {
        let r = try await DictationRig()
        defer { r.cleanup() }
        #expect(await r.pressAndListen())
        #expect(await dictationWait { r.clock.hasSleeper(seconds: DictationLimits.holdMax) })
        r.clock.advance(DictationLimits.holdMax)
        #expect(await r.settled())
        #expect(r.controller.lastOutcome == .pasted)
        r.controller.handle(.holdReleased)   // the key let go later: nothing happens
        #expect(r.controller.phase == .idle && r.output.delivered.count == 1)
    }

    @Test func sleepCopiesInsteadOfPasting() async throws {
        let r = try await DictationRig()
        defer { r.cleanup() }
        #expect(await r.pressAndListen())
        r.controller.handle(.systemSleep)
        #expect(await r.settled())
        #expect(r.controller.lastOutcome == .copied(.notPasting))
        #expect(r.output.delivered.isEmpty)
        #expect(r.output.copied.map(\.text) == [sentence] && r.output.copied.first?.reason == .notPasting)
        #expect(r.controller.lastText == sentence)
    }

    @Test func aChangedFrontmostAppCopiesOnly() async throws {
        let r = try await DictationRig()
        defer { r.cleanup() }
        #expect(await r.pressAndListen())
        r.controller.handle(.holdReleased)   // the target is noted now
        r.output.pid = 200                   // the user switched apps during transcription
        #expect(await r.settled())
        #expect(r.output.delivered.first?.target == 100)
        #expect(r.controller.lastOutcome == .copied(.appChanged))
    }

    @Test func lastTextExpiresAfterTenMinutes() async throws {
        let r = try await DictationRig()
        defer { r.cleanup() }
        #expect(await r.pressAndListen())
        r.controller.handle(.holdReleased)
        #expect(await r.settled())
        #expect(r.controller.lastText == sentence)
        #expect(await dictationWait { r.clock.hasSleeper(seconds: DictationLimits.lastTextLifetime) })
        r.clock.advance(DictationLimits.lastTextLifetime - 1)
        #expect(r.controller.lastText == sentence)
        r.clock.advance(2)
        #expect(r.controller.lastText == nil)
    }

    @Test func busyAndEscapeFollowThePhase() async throws {
        let r = try await DictationRig()
        defer { r.cleanup() }
        #expect(!r.controller.isBusy && !r.controller.acceptsEscape)
        r.controller.handle(.holdPressed)
        #expect(r.controller.isBusy && r.controller.acceptsEscape)
        #expect(await dictationWait { r.controller.phase == .listening(.hold) })
        #expect(r.controller.isBusy && r.controller.acceptsEscape)
        r.controller.handle(.escape)
        #expect(!r.controller.isBusy && !r.controller.acceptsEscape)
        #expect(await r.settled())
    }

    /// A second dictation right after the first works, with a fresh attempt.
    @Test func backToBackDictations() async throws {
        let r = try await DictationRig()
        defer { r.cleanup() }
        for _ in 0..<2 {
            #expect(await r.pressAndListen())
            r.controller.handle(.holdReleased)
            #expect(await r.settled())
        }
        #expect(r.output.delivered.count == 2)
        #expect(await r.coordinator.exclusiveAcquisitions == 2)
        #expect(r.dictationFiles.isEmpty)
    }
}

@Suite("Fake engine: dictation files")
struct FakeDictationTranscriptionTests {
    @Test func aDictationFileGetsTheDictationSentence() async throws {
        let config = LaunchConfig(arguments: ["-useFakeEngine", "-uiTesting"], environment: [:])
        let engine = FakeSpeechEngine(config: config, script: .named(.newVoices))
        try await engine.prepareModels()
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        let dictation = try await engine.transcribe(dir.appendingPathComponent("\(DictationFiles.prefix)x.wav"),
                                                    language: .automatic, progress: { _ in })
        #expect(dictation == FakeScript.dictationWords)
        #expect(dictation.count == 7 && dictation.first?.range.start == 0.2)
        #expect(abs((dictation.last?.range.end ?? 0) - 2.4) < 0.0001)
        #expect(DictationText.format(dictation, removeFillers: false) == FakeScript.dictationSentence)
        let recording = try await engine.transcribe(dir.appendingPathComponent("abc.wav"), language: .automatic, progress: { _ in })
        #expect(recording == FakeScript.named(.newVoices).words)

        let silent = FakeSpeechEngine(config: config, script: .named(.noSpeech))
        try await silent.prepareModels()
        #expect(try await silent.transcribe(dir.appendingPathComponent("\(DictationFiles.prefix)y.wav"),
                                            language: .automatic, progress: { _ in }).isEmpty)
    }
}
