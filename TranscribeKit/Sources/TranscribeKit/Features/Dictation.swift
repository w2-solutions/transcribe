import Foundation
import TranscribeCore

// Dictation (Mac only): the pure rules behind `DictationController`, the HUD's wording and the paste decisions. Nothing
// here touches the engine, the microphone, the clipboard or a window.

public enum DictationMode: Sendable, Equatable {
    /// Hold the shortcut while speaking; letting go pastes.
    case hold
    /// Press to start, press again to paste.
    case handsFree
}

/// Why the text was left on the clipboard instead of pasted.
public enum CopyReason: Equatable, Sendable {
    /// Accessibility (posting events) is not allowed.
    case noPermission
    /// A password field has Secure Event Input on.
    case secureInput
    /// The frontmost app changed between the end of the dictation and the paste.
    case appChanged
    /// Pasting was not attempted (the Mac slept or locked, or a simulated run).
    case notPasting
}

public enum DeliveryOutcome: Equatable, Sendable {
    case pasted
    case copied(CopyReason)
}

public enum DictationLimits {
    /// A hold shorter than this is a tap: no audio is kept, no job is pre-empted, and a hint shows.
    public static let minimumHold: TimeInterval = 0.3
    public static let holdMax: TimeInterval = 300
    public static let handsFreeMax: TimeInterval = 1200
    /// How long a finished dictation waits for setup to finish (setup after an update takes about a minute; slower
    /// Macs are unmeasured).
    public static let modelsWaitCap: TimeInterval = 300
    /// After this much listening, Esc must be pressed twice: a stray Esc should not throw away a long dictation.
    public static let escapeConfirmAfter: TimeInterval = 10
    /// How long the second Esc may take.
    public static let escapeConfirmWindow: TimeInterval = 2
    /// How long Copy Last Dictation keeps the text (memory only).
    public static let lastTextLifetime: TimeInterval = 600
    /// Input levels the HUD keeps.
    public static let levelHistory = 24
}

/// The dictation state machine. `reduce` decides; `DictationController` runs the effects and feeds their results
/// back as events, each tagged with its attempt so a late result from an earlier attempt is cleaned up rather than
/// fed in.
///
/// Leaving `starting` waits for the capture: Esc, a release or a second toggle while the microphone is still opening
/// only sets `Pending`, so a session that arrives later is always stopped or discarded, never leaked.
public enum DictationMachine {
    public enum Pending: Sendable, Equatable { case none, stop, cancel }

    public enum State: Sendable, Equatable {
        case idle
        case starting(DictationMode, Pending)
        case listening(DictationMode)
        case finishing
        case waitingForModels
        case transcribing
        case delivering
    }

    public enum Event: Sendable, Equatable {
        case holdPressed, holdReleased, togglePressed, escape, systemSleep
        /// `prompted`: macOS asked the user just now (the first dictation), so the key was likely let go during the
        /// prompt.
        case micGranted(prompted: Bool)
        case micDenied
        case captureStarted
        case captureFailed(String)
        case maxDurationReached
        case stopped(duration: TimeInterval)
        case modelsReady
        case modelsUnavailable
        case transcribed(String?)
        case transcribeFailed(String)
        case delivered(DeliveryOutcome)
    }

    public enum Effect: Sendable, Equatable {
        case claimAndCheckMic, startCapture, scheduleHold, stopCapture, discardCapture, awaitModels, transcribe
        case deliver(String)
        case copyOnly(String, CopyReason)
        case releaseHold, releaseGate, deleteFile, askEscapeAgain
        case finish(Outcome)
    }

    public enum Outcome: Sendable, Equatable {
        case refusedMeeting, refusedBusy, refusedModelsFailed, micDenied, micJustGranted
        case tooShortHint(DictationMode)
        case cancelled, noSpeech, pasted
        case copied(CopyReason)
        case failed(String)
    }

    /// What the controller knows besides the state.
    public struct Context: Sendable, Equatable {
        public var meetingActive: Bool
        public var modelsReady: Bool
        public var modelsFailed: Bool
        /// Paste is off for this dictation (the Mac slept or locked): the text is only copied.
        public var copyOnly: Bool
        /// Seconds since the capture started.
        public var elapsed: TimeInterval
        /// The first Esc after `escapeConfirmAfter` was pressed less than `escapeConfirmWindow` ago.
        public var escapeConfirmPending: Bool

        public init(meetingActive: Bool = false, modelsReady: Bool = true, modelsFailed: Bool = false,
                    copyOnly: Bool = false, elapsed: TimeInterval = 0, escapeConfirmPending: Bool = false) {
            self.meetingActive = meetingActive; self.modelsReady = modelsReady; self.modelsFailed = modelsFailed
            self.copyOnly = copyOnly; self.elapsed = elapsed; self.escapeConfirmPending = escapeConfirmPending
        }
    }

    public static let modelsUnavailableMessage = "Speech models aren't ready yet."

    /// Every way back to idle from a dictation that started releases what it may hold (each effect is idempotent),
    /// then reports the outcome.
    static func toIdle(_ outcome: Outcome, after before: [Effect] = []) -> (State, [Effect]) {
        (.idle, before + [.releaseHold, .releaseGate, .deleteFile, .finish(outcome)])
    }

    public static func reduce(_ state: State, _ event: Event, _ context: Context) -> (State, [Effect]) {
        switch state {
        case .idle:
            let mode: DictationMode
            switch event {
            case .holdPressed: mode = .hold
            case .togglePressed: mode = .handsFree
            default: return (state, [])
            }
            // Nothing is claimed yet, so a refusal releases nothing.
            if context.meetingActive { return (.idle, [.finish(.refusedMeeting)]) }
            if context.modelsFailed { return (.idle, [.finish(.refusedModelsFailed)]) }
            return (.starting(mode, .none), [.claimAndCheckMic])

        case .starting(let mode, let pending):
            switch event {
            case .holdReleased where mode == .hold, .togglePressed where mode == .handsFree:
                return (.starting(mode, pending == .cancel ? .cancel : .stop), [])
            case .escape, .systemSleep:
                // Nothing has been captured yet, so sleep simply cancels.
                return (.starting(mode, .cancel), [])
            case .micDenied:
                return toIdle(.micDenied)
            case .micGranted(let prompted):
                switch pending {
                case .none: return (state, [.startCapture])
                case .stop: return toIdle(prompted ? .micJustGranted : .tooShortHint(mode))
                case .cancel: return toIdle(prompted ? .micJustGranted : .cancelled)
                }
            case .captureStarted:
                switch pending {
                case .none: return (.listening(mode), [.scheduleHold])
                case .stop: return toIdle(.tooShortHint(mode), after: [.discardCapture])
                case .cancel: return toIdle(.cancelled, after: [.discardCapture])
                }
            case .captureFailed(let message):
                return toIdle(.failed(message))
            default:
                return (state, [])
            }

        case .listening(let mode):
            switch event {
            case .escape:
                if context.elapsed < DictationLimits.escapeConfirmAfter || context.escapeConfirmPending {
                    return toIdle(.cancelled, after: [.discardCapture])
                }
                return (state, [.askEscapeAgain])
            case .holdReleased where mode == .hold:
                if context.elapsed < DictationLimits.minimumHold { return toIdle(.tooShortHint(.hold), after: [.discardCapture]) }
                return (.finishing, [.stopCapture])
            case .togglePressed where mode == .handsFree, .holdPressed where mode == .handsFree:
                return (.finishing, [.stopCapture])
            case .maxDurationReached, .systemSleep:
                return (.finishing, [.stopCapture])
            default:
                return (state, [])
            }

        case .finishing:
            switch event {
            case .stopped:
                return context.modelsReady ? (.transcribing, [.transcribe]) : (.waitingForModels, [.awaitModels])
            case .transcribeFailed(let message):
                // `session.stop()` threw.
                return toIdle(.failed(message))
            case .escape:
                return toIdle(.cancelled)
            default:
                return (state, [])
            }

        case .waitingForModels:
            switch event {
            case .modelsReady: return (.transcribing, [.transcribe])
            case .modelsUnavailable: return toIdle(.failed(modelsUnavailableMessage))
            case .escape: return toIdle(.cancelled)
            default: return (state, [])
            }

        case .transcribing:
            switch event {
            case .transcribed(let text):
                guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return toIdle(.noSpeech) }
                // The audio and the engine are no longer needed: give them back before the paste.
                let output: Effect = context.copyOnly ? .copyOnly(text, .notPasting) : .deliver(text)
                return (.delivering, [.releaseHold, .deleteFile, output])
            case .transcribeFailed(let message):
                return toIdle(.failed(message))
            case .modelsUnavailable:
                // `EngineError.modelsMissing` from `transcribe`.
                return toIdle(.failed(modelsUnavailableMessage))
            case .escape:
                return toIdle(.cancelled)
            default:
                return (state, [])
            }

        case .delivering:
            guard case .delivered(let outcome) = event else { return (state, []) }
            switch outcome {
            case .pasted: return toIdle(.pasted)
            case .copied(let reason): return toIdle(.copied(reason))
            }
        }
    }
}

/// The text a dictation pastes: one line, single spaces, no trailing space.
public enum DictationText {
    public static func format(_ words: [TimedWord], removeFillers: Bool) -> String? {
        let ordered = words.enumerated()
            .sorted { ($0.element.range.start, $0.offset) < ($1.element.range.start, $1.offset) }
            .map(\.element.text)
        var text = ordered.joined(separator: " ")
        if removeFillers { text = FillerWordFilter.filter(text) }
        let collapsed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return collapsed.isEmpty ? nil : collapsed
    }
}

/// One notice in the HUD.
public struct HUDMessage: Equatable, Sendable {
    public enum Tone: Sendable, Equatable { case neutral, accent, record, problem }
    /// What a click on the HUD does; a HUD without one lets clicks through.
    public enum Action: Sendable, Equatable { case openMicSettings, openApp, openShortcutSettings }

    /// An SF Symbol name.
    public var symbol: String
    public var title: String
    public var detail: String?
    public var tone: Tone
    /// How long it stays before hiding itself.
    public var seconds: Double
    public var action: Action?

    public init(symbol: String, title: String, detail: String? = nil, tone: Tone = .neutral, seconds: Double,
                action: Action? = nil) {
        self.symbol = symbol; self.title = title; self.detail = detail; self.tone = tone
        self.seconds = seconds; self.action = action
    }
}

/// What the HUD says. A clause that names a shortcut set to Off is left out.
public enum DictationHUD {
    /// The title and detail while a dictation runs (the view adds the level bars and the live text).
    public struct Live: Equatable, Sendable {
        public var title: String
        public var detail: String?
        public init(title: String, detail: String?) { self.title = title; self.detail = detail }
    }

    public static let listeningTitle = "Listening…"
    public static let transcribingTitle = "Transcribing…"
    public static let copiedTitle = "Copied — press ⌘V"

    /// nil at idle.
    public static func live(state: DictationMachine.State, escapeConfirmPending: Bool, modelsReady: Bool,
                            bindings: ShortcutBindings) -> Live? {
        let mode: DictationMode
        switch state {
        case .idle:
            return nil
        case .finishing, .transcribing, .delivering:
            return Live(title: transcribingTitle, detail: nil)
        case .waitingForModels:
            return Live(title: "Finishing setup…", detail: "This can take a minute or two after an update.")
        case .starting(let m, _), .listening(let m):
            mode = m
        }
        if escapeConfirmPending { return Live(title: listeningTitle, detail: "Press esc again to discard") }
        if !modelsReady { return Live(title: listeningTitle, detail: "Setup is finishing. Your words are pasted when it's done.") }
        switch mode {
        case .hold:
            return Live(title: listeningTitle, detail: "Let go to paste · esc cancels")
        case .handsFree:
            guard let toggle = bindings.dictateToggle else { return Live(title: listeningTitle, detail: "esc cancels") }
            return Live(title: listeningTitle, detail: "Press \(toggle.display) to paste · esc cancels")
        }
    }

    public static func message(for outcome: DictationMachine.Outcome, bindings: ShortcutBindings) -> HUDMessage {
        switch outcome {
        case .pasted:
            return HUDMessage(symbol: "checkmark", title: "Pasted", tone: .accent, seconds: 0.9)
        case .copied(.noPermission):
            return HUDMessage(symbol: "doc.on.clipboard", title: copiedTitle,
                              detail: "Click to turn on pasting: one switch in System Settings.",
                              seconds: 4, action: .openShortcutSettings)
        case .copied(.secureInput):
            return HUDMessage(symbol: "doc.on.clipboard", title: copiedTitle,
                              detail: "A password field is active, so Transcribe can't paste.", seconds: 3)
        case .copied(.appChanged):
            return HUDMessage(symbol: "doc.on.clipboard", title: copiedTitle,
                              detail: "You switched apps, so Transcribe didn't paste.", seconds: 3)
        case .copied(.notPasting):
            return HUDMessage(symbol: "doc.on.clipboard", title: copiedTitle, seconds: 3)
        case .noSpeech:
            return HUDMessage(symbol: "waveform.slash", title: "No speech heard", seconds: 1.5)
        case .cancelled:
            return HUDMessage(symbol: "xmark", title: "Cancelled", seconds: 1)
        case .tooShortHint(.hold):
            let hold = bindings.dictateHold.map { "Hold \($0.display) while you speak" } ?? "Hold the shortcut while you speak"
            return HUDMessage(symbol: "hand.raised", title: hold,
                              detail: bindings.dictateToggle.map { "Or press \($0.display) for hands-free." }, seconds: 2.5)
        case .tooShortHint(.handsFree):
            return HUDMessage(symbol: "mic.slash", title: "Dictation stopped", seconds: 1.5)
        case .refusedMeeting:
            return HUDMessage(symbol: "record.circle", title: "Dictation is off while recording", tone: .record, seconds: 2.5)
        case .refusedBusy:
            return HUDMessage(symbol: "mic.fill", title: "Finish dictating first.", seconds: 2)
        case .refusedModelsFailed:
            return HUDMessage(symbol: "exclamationmark.triangle", title: "Speech models aren't ready",
                              detail: "Open Transcribe to finish setup.", tone: .problem, seconds: 3, action: .openApp)
        case .micDenied:
            return micDenied
        case .micJustGranted:
            return HUDMessage(symbol: "mic.fill", title: "Microphone is on",
                              detail: bindings.dictateHold.map { "Hold \($0.display) and speak." }, tone: .accent, seconds: 2.5)
        case .failed(let message):
            return HUDMessage(symbol: "exclamationmark.triangle", title: "Couldn't dictate", detail: message,
                              tone: .problem, seconds: 3)
        }
    }

    /// Also used when the meeting shortcut cannot open the microphone.
    public static let micDenied = HUDMessage(symbol: "mic.slash", title: "Microphone access is off",
                                             detail: "Click to open System Settings.", tone: .problem, seconds: 4,
                                             action: .openMicSettings)

    /// A shortcut pressed before the app has finished launching.
    public static let notReady = HUDMessage(symbol: "hourglass", title: "Transcribe is starting…", seconds: 1.5)

    /// The meeting shortcut started a recording while another app was in front.
    public static func meetingStarted(bindings: ShortcutBindings) -> HUDMessage {
        HUDMessage(symbol: "record.circle.fill", title: "Recording started",
                   detail: bindings.toggleRecording.map { "Press \($0.display) again to stop" }, tone: .record, seconds: 2.5)
    }

    public static let meetingSaved = HUDMessage(symbol: "checkmark.circle", title: "Recording saved",
                                                detail: "Transcribing on this Mac", seconds: 2.5)

    /// The meeting shortcut pressed during a dictation.
    public static let meetingRefusedBusy = HUDMessage(symbol: "mic.fill", title: "Finish dictating first.", seconds: 2)

    /// The meeting shortcut could not start a recording; a click opens the app.
    public static func meetingFailed(_ message: String) -> HUDMessage {
        HUDMessage(symbol: "exclamationmark.triangle", title: "Can't record", detail: message, tone: .problem,
                   seconds: 3, action: .openApp)
    }
}

/// Whether to paste or only copy. Pure: `PasteService` passes in what it read from the system.
public enum PasteDecision {
    public enum Plan: Equatable, Sendable {
        case paste(restoreClipboard: Bool)
        case copyOnly(CopyReason)
    }

    /// Permission first, then secure input, then the frontmost app; the clipboard is restored only when macOS lets
    /// Transcribe read it.
    public static func plan(postEventAllowed: Bool, secureInput: Bool, targetUnchanged: Bool,
                            clipboardReadable: Bool) -> Plan {
        if !postEventAllowed { return .copyOnly(.noPermission) }
        if secureInput { return .copyOnly(.secureInput) }
        if !targetUnchanged { return .copyOnly(.appChanged) }
        return .paste(restoreClipboard: clipboardReadable)
    }

    /// How long to wait for the user to let go of the shortcut's modifiers (⌘V with fn or ⌥ still down is another key).
    public static let modifierWait: Duration = .milliseconds(600)
    public static let modifierPoll: Duration = .milliseconds(15)
    /// Between writing the clipboard and posting ⌘V.
    public static let prePasteDelay: Duration = .milliseconds(40)
    /// Between ⌘V and putting the user's clipboard back (the target app reads the clipboard in this time).
    public static let restoreDelay: Duration = .milliseconds(1500)
    /// A clipboard larger than this (all items and types together) is not snapshotted, so it is not put back.
    public static let snapshotLimitBytes = 8 * 1024 * 1024
}

/// Which clipboard snapshot a paste puts back.
public enum RestorePlan {
    public enum Source: Sendable, Equatable {
        /// A restore from the previous paste is still waiting and the clipboard still holds that paste's dictation:
        /// cancel the restore and keep its snapshot, which holds the user's clipboard.
        case carryPending
        /// Read the clipboard now. Any waiting restore is cancelled: if something wrote the clipboard since its paste,
        /// that is the user's clipboard now.
        case takeNew
        /// Nothing to put back (any waiting restore is cancelled).
        case none
    }

    /// `pendingChangeCount` is the change count right after the waiting restore's paste wrote the clipboard, nil when
    /// no restore waits. Its snapshot is carried forward only while nothing else has written the clipboard since: a
    /// copy the user made in between is theirs, and it is what must come back.
    public static func snapshotSource(pendingChangeCount: Int?, changeCountNow: Int, clipboardReadable: Bool) -> Source {
        if let pendingChangeCount, pendingChangeCount == changeCountNow { return .carryPending }
        return clipboardReadable ? .takeNew : .none
    }

    /// Put the snapshot back only if nothing has written the clipboard since the paste did (the user copying
    /// something in the target app must win).
    public static func shouldRestore(changeCountNow: Int, changeCountAfterWrite: Int, hasSnapshot: Bool) -> Bool {
        hasSnapshot && changeCountNow == changeCountAfterWrite
    }
}
