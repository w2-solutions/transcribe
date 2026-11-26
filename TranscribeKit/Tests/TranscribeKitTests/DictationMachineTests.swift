import Foundation
import Testing
import TranscribeCore
@testable import TranscribeKit

/// The dictation state machine, row by row.
@Suite struct DictationMachineTests {
    typealias M = DictationMachine
    typealias C = DictationMachine.Context

    static func run(_ s: M.State, _ e: M.Event, _ c: C = C()) -> (M.State, [M.Effect]) { M.reduce(s, e, c) }

    /// What every return to idle from a started dictation ends with.
    static func idle(_ outcome: M.Outcome, after: [M.Effect] = []) -> (M.State, [M.Effect]) {
        (.idle, after + [.releaseHold, .releaseGate, .deleteFile, .finish(outcome)])
    }

    static let allStates: [M.State] = [
        .idle, .starting(.hold, .none), .starting(.hold, .stop), .starting(.hold, .cancel),
        .starting(.handsFree, .none), .starting(.handsFree, .stop), .starting(.handsFree, .cancel),
        .listening(.hold), .listening(.handsFree), .finishing, .waitingForModels, .transcribing, .delivering,
    ]

    static let allEvents: [M.Event] = [
        .holdPressed, .holdReleased, .togglePressed, .escape, .systemSleep, .micGranted(prompted: true),
        .micGranted(prompted: false), .micDenied, .captureStarted, .captureFailed("x"), .maxDurationReached,
        .stopped(duration: 3), .modelsReady, .modelsUnavailable, .transcribed("Hi."), .transcribed(nil), .transcribed(""),
        .transcribeFailed("y"), .delivered(.pasted), .delivered(.copied(.appChanged)),
    ]

    // MARK: idle

    @Test func idleStartsOrRefuses() {
        #expect(Self.run(.idle, .holdPressed) == (.starting(.hold, .none), [.claimAndCheckMic]))
        #expect(Self.run(.idle, .togglePressed) == (.starting(.handsFree, .none), [.claimAndCheckMic]))
        // Nothing was claimed, so a refusal releases nothing.
        #expect(Self.run(.idle, .holdPressed, C(meetingActive: true)) == (.idle, [.finish(.refusedMeeting)]))
        #expect(Self.run(.idle, .togglePressed, C(meetingActive: true)) == (.idle, [.finish(.refusedMeeting)]))
        #expect(Self.run(.idle, .holdPressed, C(modelsFailed: true)) == (.idle, [.finish(.refusedModelsFailed)]))
        #expect(Self.run(.idle, .togglePressed, C(modelsFailed: true)) == (.idle, [.finish(.refusedModelsFailed)]))
        #expect(Self.run(.idle, .holdPressed, C(meetingActive: true, modelsFailed: true)) == (.idle, [.finish(.refusedMeeting)]))
        // Models still setting up do not refuse: the dictation waits for them at the end.
        #expect(Self.run(.idle, .holdPressed, C(modelsReady: false)) == (.starting(.hold, .none), [.claimAndCheckMic]))
    }

    @Test func idleIgnoresEverythingElse() {
        for event in Self.allEvents where event != .holdPressed && event != .togglePressed {
            #expect(Self.run(.idle, event) == (.idle, []), "\(event)")
        }
    }

    // MARK: starting

    @Test func stopOrCancelDuringStartingOnlySetsPending() {
        #expect(Self.run(.starting(.hold, .none), .holdReleased) == (.starting(.hold, .stop), []))
        #expect(Self.run(.starting(.handsFree, .none), .togglePressed) == (.starting(.handsFree, .stop), []))
        #expect(Self.run(.starting(.hold, .none), .escape) == (.starting(.hold, .cancel), []))
        #expect(Self.run(.starting(.handsFree, .stop), .escape) == (.starting(.handsFree, .cancel), []))
        // A cancel is never downgraded to a stop.
        #expect(Self.run(.starting(.hold, .cancel), .holdReleased) == (.starting(.hold, .cancel), []))
        #expect(Self.run(.starting(.handsFree, .cancel), .togglePressed) == (.starting(.handsFree, .cancel), []))
        // Sleep before the capture has started cancels.
        #expect(Self.run(.starting(.hold, .none), .systemSleep) == (.starting(.hold, .cancel), []))
        // The other mode's key, and a second press, are ignored.
        #expect(Self.run(.starting(.hold, .none), .togglePressed) == (.starting(.hold, .none), []))
        #expect(Self.run(.starting(.hold, .none), .holdPressed) == (.starting(.hold, .none), []))
        #expect(Self.run(.starting(.handsFree, .none), .holdReleased) == (.starting(.handsFree, .none), []))
        #expect(Self.run(.starting(.handsFree, .none), .holdPressed) == (.starting(.handsFree, .none), []))
    }

    @Test func microphoneAnswers() {
        for mode in [DictationMode.hold, .handsFree] {
            #expect(Self.run(.starting(mode, .none), .micDenied) == Self.idle(.micDenied))
            #expect(Self.run(.starting(mode, .stop), .micDenied) == Self.idle(.micDenied))
            #expect(Self.run(.starting(mode, .none), .micGranted(prompted: false)) == (.starting(mode, .none), [.startCapture]))
            #expect(Self.run(.starting(mode, .none), .micGranted(prompted: true)) == (.starting(mode, .none), [.startCapture]))
            // The key was let go during macOS's prompt: say the microphone is on, without the too-short hint.
            #expect(Self.run(.starting(mode, .stop), .micGranted(prompted: true)) == Self.idle(.micJustGranted))
            #expect(Self.run(.starting(mode, .cancel), .micGranted(prompted: true)) == Self.idle(.micJustGranted))
            #expect(Self.run(.starting(mode, .stop), .micGranted(prompted: false)) == Self.idle(.tooShortHint(mode)))
            #expect(Self.run(.starting(mode, .cancel), .micGranted(prompted: false)) == Self.idle(.cancelled))
        }
    }

    @Test func onlyCaptureStartedFinishesAPendingStopOrCancel() {
        for mode in [DictationMode.hold, .handsFree] {
            #expect(Self.run(.starting(mode, .none), .captureStarted) == (.listening(mode), [.scheduleHold]))
            #expect(Self.run(.starting(mode, .stop), .captureStarted) == Self.idle(.tooShortHint(mode), after: [.discardCapture]))
            #expect(Self.run(.starting(mode, .cancel), .captureStarted) == Self.idle(.cancelled, after: [.discardCapture]))
            for pending in [M.Pending.none, .stop, .cancel] {
                #expect(Self.run(.starting(mode, pending), .captureFailed("No input")) == Self.idle(.failed("No input")))
            }
        }
        // Escape then release while the microphone opens: still waiting for the session, which is then discarded.
        var state: M.State = .idle
        var effects: [M.Effect]
        (state, effects) = Self.run(state, .holdPressed)
        #expect(effects == [.claimAndCheckMic])
        (state, effects) = Self.run(state, .micGranted(prompted: false))
        #expect(effects == [.startCapture])
        (state, effects) = Self.run(state, .escape)
        (state, effects) = Self.run(state, .holdReleased)
        #expect(state == .starting(.hold, .cancel))
        #expect(effects.isEmpty)
        (state, effects) = Self.run(state, .captureStarted)
        #expect(state == .idle)
        #expect(effects.first == .discardCapture)
        #expect(effects.last == .finish(.cancelled))
    }

    @Test func startingIgnoresLaterStageEvents() {
        for event: M.Event in [.maxDurationReached, .stopped(duration: 1), .modelsReady, .modelsUnavailable,
                               .transcribed("x"), .transcribeFailed("x"), .delivered(.pasted)] {
            #expect(Self.run(.starting(.hold, .none), event) == (.starting(.hold, .none), []), "\(event)")
        }
    }

    // MARK: listening

    @Test func singleEscapeBeforeTenSeconds() {
        #expect(Self.run(.listening(.hold), .escape, C(elapsed: 9.9)) == Self.idle(.cancelled, after: [.discardCapture]))
        #expect(Self.run(.listening(.handsFree), .escape, C(elapsed: 0)) == Self.idle(.cancelled, after: [.discardCapture]))
    }

    @Test func twoStepEscapeAfterTenSeconds() {
        #expect(Self.run(.listening(.handsFree), .escape, C(elapsed: 10)) == (.listening(.handsFree), [.askEscapeAgain]))
        #expect(Self.run(.listening(.hold), .escape, C(elapsed: 600)) == (.listening(.hold), [.askEscapeAgain]))
        #expect(Self.run(.listening(.handsFree), .escape, C(elapsed: 12, escapeConfirmPending: true))
                == Self.idle(.cancelled, after: [.discardCapture]))
    }

    @Test func holdRelease() {
        #expect(Self.run(.listening(.hold), .holdReleased, C(elapsed: 0.29)) == Self.idle(.tooShortHint(.hold), after: [.discardCapture]))
        #expect(Self.run(.listening(.hold), .holdReleased, C(elapsed: 0.3)) == (.finishing, [.stopCapture]))
        #expect(Self.run(.listening(.hold), .holdReleased, C(elapsed: 42)) == (.finishing, [.stopCapture]))
        #expect(Self.run(.listening(.hold), .togglePressed) == (.listening(.hold), []))
        #expect(Self.run(.listening(.hold), .holdPressed) == (.listening(.hold), []))
    }

    @Test func handsFreeStopsOnEitherKey() {
        #expect(Self.run(.listening(.handsFree), .togglePressed, C(elapsed: 5)) == (.finishing, [.stopCapture]))
        #expect(Self.run(.listening(.handsFree), .holdPressed, C(elapsed: 5)) == (.finishing, [.stopCapture]))
        #expect(Self.run(.listening(.handsFree), .holdReleased, C(elapsed: 5)) == (.listening(.handsFree), []))
    }

    @Test func maxDurationAndSleepStop() {
        for mode in [DictationMode.hold, .handsFree] {
            #expect(Self.run(.listening(mode), .maxDurationReached) == (.finishing, [.stopCapture]))
            #expect(Self.run(.listening(mode), .systemSleep) == (.finishing, [.stopCapture]))
        }
    }

    // MARK: finishing, waiting, transcribing, delivering

    @Test func finishingGoesToTranscribeOrWaits() {
        #expect(Self.run(.finishing, .stopped(duration: 4)) == (.transcribing, [.transcribe]))
        #expect(Self.run(.finishing, .stopped(duration: 4), C(modelsReady: false)) == (.waitingForModels, [.awaitModels]))
        #expect(Self.run(.finishing, .transcribeFailed("Couldn't finish the recording."))
                == Self.idle(.failed("Couldn't finish the recording.")))
        #expect(Self.run(.waitingForModels, .modelsReady) == (.transcribing, [.transcribe]))
        #expect(Self.run(.waitingForModels, .modelsUnavailable) == Self.idle(.failed("Speech models aren't ready yet.")))
    }

    @Test func escapeAfterTheCaptureDropsTheResult() {
        for state: M.State in [.finishing, .waitingForModels, .transcribing] {
            #expect(Self.run(state, .escape, C(elapsed: 30)) == Self.idle(.cancelled), "\(state)")
        }
        #expect(Self.run(.delivering, .escape) == (.delivering, []), "too late to cancel a paste")
    }

    @Test func transcribedResults() {
        #expect(Self.run(.transcribing, .transcribed(nil)) == Self.idle(.noSpeech))
        #expect(Self.run(.transcribing, .transcribed("")) == Self.idle(.noSpeech))
        #expect(Self.run(.transcribing, .transcribed("  ")) == Self.idle(.noSpeech))
        #expect(Self.run(.transcribing, .transcribed("Hello there.")) == (.delivering, [.releaseHold, .deleteFile, .deliver("Hello there.")]))
        #expect(Self.run(.transcribing, .transcribed("Hello there."), C(copyOnly: true))
                == (.delivering, [.releaseHold, .deleteFile, .copyOnly("Hello there.", .notPasting)]))
        #expect(Self.run(.transcribing, .transcribeFailed("Engine broke")) == Self.idle(.failed("Engine broke")))
        #expect(Self.run(.transcribing, .modelsUnavailable) == Self.idle(.failed("Speech models aren't ready yet.")))
    }

    @Test func deliveredOutcomes() {
        #expect(Self.run(.delivering, .delivered(.pasted)) == Self.idle(.pasted))
        for reason in [CopyReason.noPermission, .secureInput, .appChanged, .notPasting] {
            #expect(Self.run(.delivering, .delivered(.copied(reason))) == Self.idle(.copied(reason)))
        }
    }

    @Test func busyStatesIgnoreKeys() {
        for state: M.State in [.finishing, .waitingForModels, .transcribing, .delivering] {
            for event: M.Event in [.holdPressed, .holdReleased, .togglePressed, .systemSleep, .maxDurationReached,
                                   .captureStarted, .micDenied, .micGranted(prompted: false)] {
                #expect(Self.run(state, event) == (state, []), "\(state) \(event)")
            }
        }
    }

    // MARK: Invariants

    /// Every path from a started dictation back to idle releases the hold, the gate and the file, then finishes.
    @Test func everyPathToIdleReleasesEverything() {
        let contexts = [C(), C(modelsReady: false), C(copyOnly: true), C(elapsed: 0.1), C(elapsed: 11),
                        C(elapsed: 11, escapeConfirmPending: true)]
        var checked = 0
        for state in Self.allStates where state != .idle {
            for event in Self.allEvents {
                for context in contexts {
                    let (next, effects) = Self.run(state, event, context)
                    guard next == .idle else {
                        #expect(!effects.contains { if case .finish = $0 { true } else { false } }, "\(state) \(event)")
                        continue
                    }
                    checked += 1
                    let tail = Array(effects.suffix(4))
                    #expect(tail.count == 4 && Array(tail.prefix(3)) == [.releaseHold, .releaseGate, .deleteFile],
                            "\(state) \(event) → \(effects)")
                    if case .finish = tail.last {} else { Issue.record("no finish: \(state) \(event)") }
                }
            }
        }
        #expect(checked > 50)
    }

    /// The machine never leaves `starting` before the capture has answered, so a session is never orphaned.
    @Test func startingLeavesOnlyOnACaptureOrMicrophoneAnswer() {
        for state in Self.allStates {
            guard case .starting = state else { continue }
            for event in Self.allEvents {
                let (next, _) = Self.run(state, event, C())
                if case .starting = next { continue }
                switch event {
                case .captureStarted, .captureFailed, .micDenied, .micGranted: break
                default: Issue.record("left \(state) on \(event)")
                }
            }
        }
    }
}

@Suite struct DictationTextTests {
    static func word(_ text: String, _ start: TimeInterval) -> TimedWord {
        TimedWord(text: text, range: TimeRange(start: start, end: start + 0.2))
    }

    @Test func joinsInTimeOrder() {
        let words = [Self.word("tomorrow.", 2.2), Self.word("Let's", 0.2), Self.word("move", 0.5), Self.word("it", 0.9)]
        #expect(DictationText.format(words, removeFillers: false) == "Let's move it tomorrow.")
    }

    @Test func equalStartsKeepTheirOrder() {
        let words = [Self.word("a", 1), Self.word("b", 1), Self.word("c", 1)]
        #expect(DictationText.format(words, removeFillers: false) == "a b c")
    }

    @Test func fillersAreRemovedOnlyWhenAsked() {
        let words = [Self.word("Um", 0), Self.word("yes,", 0.3), Self.word("uh", 0.6), Self.word("ten.", 0.9)]
        #expect(DictationText.format(words, removeFillers: false) == "Um yes, uh ten.")
        #expect(DictationText.format(words, removeFillers: true) == "Yes, ten.")
    }

    @Test func whitespaceIsCollapsedAndTrimmed() {
        let words = [Self.word("  Hello ", 0), Self.word("\tthere\n", 1), Self.word("", 2)]
        #expect(DictationText.format(words, removeFillers: false) == "Hello there")
    }

    @Test func nothingLeftIsNil() {
        #expect(DictationText.format([], removeFillers: false) == nil)
        #expect(DictationText.format([Self.word(" ", 0)], removeFillers: false) == nil)
        #expect(DictationText.format([Self.word("um", 0), Self.word("uh.", 1)], removeFillers: true) == nil)
    }
}
