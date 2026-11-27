import Foundation
import Testing
@testable import TranscribeKit

/// What the dictation HUD says, for every outcome, with clauses for shortcuts set to Off left out.
@Suite struct DictationHUDTests {
    static let defaults = ShortcutBindings.defaults
    static let allOff = ShortcutBindings(toggleRecording: nil, dictateHold: nil, dictateToggle: nil)

    static func message(_ outcome: DictationMachine.Outcome, _ bindings: ShortcutBindings = defaults) -> HUDMessage {
        DictationHUD.message(for: outcome, bindings: bindings)
    }

    @Test func pastedAndCopied() {
        let pasted = Self.message(.pasted)
        #expect(pasted.title == "Pasted")
        #expect(pasted.seconds == 0.9)
        #expect(pasted.action == nil)

        let noPermission = Self.message(.copied(.noPermission))
        #expect(noPermission.title == "Copied — press ⌘V")
        #expect(noPermission.detail == "Click to turn on pasting: one switch in System Settings.")
        #expect(noPermission.seconds == 4)
        #expect(noPermission.action == .openShortcutSettings)

        let secure = Self.message(.copied(.secureInput))
        #expect(secure.title == "Copied — press ⌘V")
        #expect(secure.detail == "A password field is active, so Transcribe can't paste.")
        #expect(secure.seconds == 3)
        #expect(secure.action == nil)

        let changed = Self.message(.copied(.appChanged))
        #expect(changed.detail == "You switched apps, so Transcribe didn't paste.")
        #expect(changed.seconds == 3)

        let notPasting = Self.message(.copied(.notPasting))
        #expect(notPasting.title == "Copied — press ⌘V")
        #expect(notPasting.detail == nil)
        #expect(notPasting.seconds == 3)
    }

    @Test func shortOutcomes() {
        #expect(Self.message(.noSpeech) == HUDMessage(symbol: Self.message(.noSpeech).symbol, title: "No speech heard", seconds: 1.5))
        #expect(Self.message(.cancelled).title == "Cancelled")
        #expect(Self.message(.cancelled).seconds == 1)
        #expect(Self.message(.tooShortHint(.handsFree)).title == "Dictation stopped")
        #expect(Self.message(.tooShortHint(.handsFree)).seconds == 1.5)
        #expect(Self.message(.refusedMeeting).title == "Dictation is off while recording")
        #expect(Self.message(.refusedMeeting).seconds == 2.5)
        #expect(Self.message(.refusedBusy).title == "Finish dictating first.")
        #expect(Self.message(.refusedBusy).seconds == 2)
    }

    @Test func problemsWithActions() {
        let models = Self.message(.refusedModelsFailed)
        #expect(models.title == "Speech models aren't ready")
        #expect(models.detail == "Open Transcribe to finish setup.")
        #expect(models.seconds == 3)
        #expect(models.action == .openApp)
        #expect(models.tone == .problem)

        let mic = Self.message(.micDenied)
        #expect(mic.title == "Microphone access is off")
        #expect(mic.detail == "Click to open System Settings.")
        #expect(mic.seconds == 4)
        #expect(mic.action == .openMicSettings)
        #expect(mic == DictationHUD.micDenied)

        let failed = Self.message(.failed("Speech models aren't ready yet."))
        #expect(failed.title == "Couldn't dictate")
        #expect(failed.detail == "Speech models aren't ready yet.")
        #expect(failed.seconds == 3)
        #expect(failed.action == nil)
    }

    @Test func hintsNameTheShortcuts() {
        let hint = Self.message(.tooShortHint(.hold))
        #expect(hint.title == "Hold fn X while you speak")
        #expect(hint.detail == "Or press fn ⇧ X for hands-free.")
        #expect(hint.seconds == 2.5)
        let granted = Self.message(.micJustGranted)
        #expect(granted.title == "Microphone is on")
        #expect(granted.detail == "Hold fn X and speak.")
        #expect(granted.seconds == 2.5)
        #expect(DictationHUD.meetingStarted(bindings: Self.defaults).title == "Recording started")
        #expect(DictationHUD.meetingStarted(bindings: Self.defaults).detail == "Press fn Z again to stop")
        #expect(DictationHUD.meetingSaved.title == "Recording saved")
        #expect(DictationHUD.meetingSaved.detail == "Transcribing on this Mac")
        #expect(DictationHUD.notReady.title == "Transcribe is starting…")
        #expect(DictationHUD.notReady.seconds == 1.5)
    }

    @Test func clausesForShortcutsSetToOffAreLeftOut() {
        let hint = Self.message(.tooShortHint(.hold), Self.allOff)
        #expect(hint.detail == nil)
        #expect(!hint.title.contains("fn"))
        var holdOnly = Self.defaults
        holdOnly.dictateToggle = nil
        #expect(Self.message(.tooShortHint(.hold), holdOnly).title == "Hold fn X while you speak")
        #expect(Self.message(.tooShortHint(.hold), holdOnly).detail == nil)
        #expect(Self.message(.micJustGranted, Self.allOff).detail == nil)
        #expect(DictationHUD.meetingStarted(bindings: Self.allOff).detail == nil)
        let live = DictationHUD.live(state: .listening(.handsFree), escapeConfirmPending: false, modelsReady: true, bindings: Self.allOff)
        #expect(live?.detail == "esc cancels")
    }

    @Test func liveStates() {
        func live(_ state: DictationMachine.State, escape: Bool = false, ready: Bool = true) -> DictationHUD.Live? {
            DictationHUD.live(state: state, escapeConfirmPending: escape, modelsReady: ready, bindings: Self.defaults)
        }
        #expect(live(.idle) == nil)
        #expect(live(.starting(.hold, .none)) == DictationHUD.Live(title: "Listening…", detail: "Let go to paste · esc cancels"))
        #expect(live(.listening(.hold)) == DictationHUD.Live(title: "Listening…", detail: "Let go to paste · esc cancels"))
        #expect(live(.listening(.handsFree)) == DictationHUD.Live(title: "Listening…", detail: "Press fn ⇧ X to paste · esc cancels"))
        #expect(live(.listening(.hold), ready: false)?.detail == "Setup is finishing. Your words are pasted when it's done.")
        #expect(live(.listening(.handsFree), escape: true)?.detail == "Press esc again to discard")
        #expect(live(.listening(.handsFree), escape: true, ready: false)?.detail == "Press esc again to discard")
        #expect(live(.finishing)?.title == "Transcribing…")
        #expect(live(.transcribing)?.title == "Transcribing…")
        #expect(live(.delivering)?.title == "Transcribing…")
        #expect(live(.waitingForModels) == DictationHUD.Live(title: "Finishing setup…", detail: "This can take a minute or two after an update."))
    }

    @Test func meetingMessages() {
        let failed = DictationHUD.meetingFailed("The microphone is in use.")
        #expect(failed.title == "Can't record")
        #expect(failed.detail == "The microphone is in use.")
        #expect(failed.action == .openApp)
        #expect(DictationHUD.meetingRefusedBusy.title == "Finish dictating first.")
    }
}

/// Paste or only copy: all 16 combinations of what `PasteService` reads.
@Suite struct PasteDecisionTests {
    @Test func everyCombination() {
        for post in [false, true] {
            for secure in [false, true] {
                for unchanged in [false, true] {
                    for readable in [false, true] {
                        let plan = PasteDecision.plan(postEventAllowed: post, secureInput: secure,
                                                      targetUnchanged: unchanged, clipboardReadable: readable)
                        let expected: PasteDecision.Plan =
                            !post ? .copyOnly(.noPermission)
                            : secure ? .copyOnly(.secureInput)
                            : !unchanged ? .copyOnly(.appChanged)
                            : .paste(restoreClipboard: readable)
                        #expect(plan == expected, "post \(post) secure \(secure) unchanged \(unchanged) readable \(readable)")
                    }
                }
            }
        }
        #expect(PasteDecision.plan(postEventAllowed: true, secureInput: false, targetUnchanged: true, clipboardReadable: true)
                == .paste(restoreClipboard: true))
        #expect(PasteDecision.plan(postEventAllowed: true, secureInput: false, targetUnchanged: true, clipboardReadable: false)
                == .paste(restoreClipboard: false))
    }

    @Test func timings() {
        #expect(PasteDecision.modifierWait == .milliseconds(600))
        #expect(PasteDecision.modifierPoll == .milliseconds(15))
        #expect(PasteDecision.prePasteDelay == .milliseconds(40))
        #expect(PasteDecision.restoreDelay == .milliseconds(1500))
        #expect(PasteDecision.snapshotLimitBytes == 8_388_608)
    }
}

/// Which clipboard a paste puts back. A small model of the clipboard checks the back-to-back case: the second paste
/// must put back the user's clipboard, not the first dictation.
@Suite struct RestorePlanTests {
    @Test func sources() {
        #expect(RestorePlan.snapshotSource(pendingChangeCount: 4, changeCountNow: 4, clipboardReadable: true) == .carryPending)
        #expect(RestorePlan.snapshotSource(pendingChangeCount: 4, changeCountNow: 4, clipboardReadable: false) == .carryPending)
        #expect(RestorePlan.snapshotSource(pendingChangeCount: 4, changeCountNow: 5, clipboardReadable: true) == .takeNew)
        #expect(RestorePlan.snapshotSource(pendingChangeCount: 4, changeCountNow: 5, clipboardReadable: false) == .none)
        #expect(RestorePlan.snapshotSource(pendingChangeCount: nil, changeCountNow: 4, clipboardReadable: true) == .takeNew)
        #expect(RestorePlan.snapshotSource(pendingChangeCount: nil, changeCountNow: 4, clipboardReadable: false) == .none)
    }

    @Test func restoreOnlyIfNothingWroteSince() {
        #expect(RestorePlan.shouldRestore(changeCountNow: 5, changeCountAfterWrite: 5, hasSnapshot: true))
        #expect(!RestorePlan.shouldRestore(changeCountNow: 6, changeCountAfterWrite: 5, hasSnapshot: true))
        #expect(!RestorePlan.shouldRestore(changeCountNow: 5, changeCountAfterWrite: 5, hasSnapshot: false))
    }

    /// A clipboard with a change count, and a paster that follows `RestorePlan` as `PasteService` does.
    struct Model {
        var contents = "user's text"
        var changeCount = 1
        var pending: String?? = nil       // .some(snapshot) while a restore waits
        var pendingWrittenAt = 0

        mutating func write(_ text: String) { contents = text; changeCount += 1 }

        mutating func paste(_ text: String, readable: Bool = true) {
            let snapshot: String?
            switch RestorePlan.snapshotSource(pendingChangeCount: pending == nil ? nil : pendingWrittenAt,
                                              changeCountNow: changeCount, clipboardReadable: readable) {
            case .carryPending: snapshot = pending!   // the pending task is cancelled; its snapshot carries on
            case .takeNew: snapshot = contents
            case .none: snapshot = nil
            }
            write(text)
            pending = .some(snapshot)
            pendingWrittenAt = changeCount
        }

        mutating func restoreFires() {
            guard let snapshot = pending else { return }
            pending = nil
            if RestorePlan.shouldRestore(changeCountNow: changeCount, changeCountAfterWrite: pendingWrittenAt,
                                         hasSnapshot: snapshot != nil), let snapshot {
                write(snapshot)
            }
        }
    }

    @Test func aPendingRestoreCarriesTheOriginalSnapshot() {
        var m = Model()
        m.paste("first dictation")
        m.paste("second dictation")     // within 1.5 s: the first restore has not fired
        #expect(m.contents == "second dictation")
        m.restoreFires()
        #expect(m.contents == "user's text")
    }

    @Test func singlePasteRestores() {
        var m = Model()
        m.paste("dictation")
        m.restoreFires()
        #expect(m.contents == "user's text")
    }

    @Test func userCopyAfterThePasteWins() {
        var m = Model()
        m.paste("dictation")
        m.write("copied in the target app")
        m.restoreFires()
        #expect(m.contents == "copied in the target app")
    }

    /// The user copies something while the first restore waits, then dictates again: their new copy is what comes
    /// back, not the clipboard from before the first dictation.
    @Test func aCopyBetweenTwoPastesIsTheOneRestored() {
        var m = Model()
        m.paste("first dictation")
        m.write("copied between")       // within 1.5 s of the first paste
        m.paste("second dictation")
        #expect(m.contents == "second dictation")
        m.restoreFires()
        #expect(m.contents == "copied between")
    }

    @Test func unreadableClipboardIsNotRestoredEvenLater() {
        var m = Model()
        m.paste("first", readable: false)
        m.paste("second", readable: true)   // must not snapshot "first" as if it were the user's
        m.restoreFires()
        #expect(m.contents == "second")
    }
}
