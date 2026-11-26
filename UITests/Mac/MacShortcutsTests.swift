import XCTest

/// Settings → Shortcuts and the global shortcuts (Mac only). UI-test runs never register real shortcuts (XCUITest can
/// neither press fn nor grant Accessibility), so the recorder field and validation are tested here, and the shortcuts
/// themselves through the DEBUG Shortcut Simulation menu (`TRANSCRIBE_SHORTCUTS=sim`), which feeds the same events a
/// key press would. A simulated dictation delivers to a named test pasteboard and the hidden `AX.Dictation.lastDelivered`
/// element: no test here reads or writes the general pasteboard.
final class MacShortcutsTests: FlowTestCase {
    /// What the fake engine transcribes for any dictation (`FakeScript.dictationSentence`).
    private static let dictationSentence = "Let's move the stand-up to ten tomorrow."
    private static let privacy = "Shortcuts work while Transcribe is open, even behind other apps. Transcribe watches only for these key combinations; it never records, stores or sends anything else you type. Dictation stays on this Mac: it is transcribed here, its audio is deleted straight away, and it is never added to your recordings or synced. The text goes only to the app you are typing in, through the clipboard, which Transcribe puts back afterwards when macOS allows it."
    private static let offInTestRuns = "Shortcuts are off in test runs."

    // MARK: Settings

    @MainActor func testShortcutsSettingsShowDefaults() {
        let app = UITestApp.launch(seed: "library")
        app.waitFor(AX.Mac.main, timeout: 20)

        // The app menu's Shortcuts…, after Settings, opens Settings at the section.
        app.menuBars.menuBarItems["Transcribe"].click()
        let item = app.menuBars.menuItems["Shortcuts…"]
        XCTAssertTrue(item.waitForExistence(timeout: 5), "No Shortcuts… in the app menu")
        item.click()
        app.waitFor(AX.Settings.screen)
        app.waitFor(AX.Shortcuts.section)

        Wait.value(app.scrollTo(recorder(.toggleRecording)), equals: "Function Z")
        Wait.value(app.scrollTo(recorder(.dictateHold)), equals: "Function X")
        Wait.value(app.scrollTo(recorder(.dictateToggle)), equals: "Function Shift X")
        for action in Action.allCases {
            Wait.label(app.scrollTo(AX.Shortcuts.status(action.rawValue)), equals: Self.offInTestRuns)
        }
        // Defaults already: nothing to reset.
        Wait.enabled(app.scrollTo(AX.Shortcuts.reset), false)
        // A dictation shortcut is set, so the permissions show; nothing is allowed in a test run.
        app.scrollTo(AX.Shortcuts.accessibility)
        app.scrollTo(AX.Shortcuts.clipboard)
        Wait.label(app.scrollTo(AX.Shortcuts.privacy), equals: Self.privacy)
        app.scrollTo(AX.Shortcuts.keyboardNote)
    }

    @MainActor func testRecordClearAndReset() {
        let app = openShortcutsSettings()

        let hold = app.scrollTo(recorder(.dictateHold))
        hold.click()
        Wait.value(hold, equals: "Type shortcut…")
        app.typeKey("d", modifierFlags: [.control, .option])
        Wait.value(hold, equals: "Control Option D")
        XCTAssertFalse(app.element(AX.Shortcuts.problem).exists, "A good shortcut shows no problem")

        // Esc while listening keeps the old value.
        hold.click()
        Wait.value(hold, equals: "Type shortcut…")
        app.typeKey(.escape, modifierFlags: [])
        Wait.value(hold, equals: "Control Option D")

        let toggle = app.scrollTo(recorder(.dictateToggle))
        app.element(AX.Shortcuts.clear(Action.dictateToggle.rawValue)).click()
        Wait.value(toggle, equals: "Off")
        XCTAssertFalse(app.element(AX.Shortcuts.clear(Action.dictateToggle.rawValue)).exists, "Off has no clear button")

        let reset = app.scrollTo(AX.Shortcuts.reset)
        Wait.enabled(reset, true)
        reset.click()
        Wait.value(app.scrollTo(recorder(.dictateToggle)), equals: "Function Shift X")
        Wait.value(app.scrollTo(recorder(.dictateHold)), equals: "Function X")
        Wait.enabled(app.scrollTo(AX.Shortcuts.reset), false)
    }

    @MainActor func testConflictsAreRejected() {
        let app = openShortcutsSettings()

        // ⌘N alone has too few modifiers (and is New Recording): refused, and it starts no recording.
        let meeting = app.scrollTo(recorder(.toggleRecording))
        meeting.click()
        app.typeKey("n", modifierFlags: .command)
        Wait.label(app.waitFor(AX.Shortcuts.problem), equals: "Use fn, or two of ⌃ ⌥ ⌘, with the key.")
        Wait.value(meeting, equals: "Function Z")
        XCTAssertFalse(app.element(AX.Mac.recordingWindow).exists, "⌘N went to the recorder field, not the menu")

        // The same combo on both dictation shortcuts.
        let hold = app.scrollTo(recorder(.dictateHold))
        hold.click()
        app.typeKey("d", modifierFlags: [.control, .option])
        Wait.value(hold, equals: "Control Option D")
        let toggle = app.scrollTo(recorder(.dictateToggle))
        toggle.click()
        app.typeKey("d", modifierFlags: [.control, .option])
        Wait.label(app.waitFor(AX.Shortcuts.problem), equals: "Already used for “Dictate (hold to talk)”.")
        Wait.value(toggle, equals: "Function Shift X")

        // One of Transcribe's own menu shortcuts.
        toggle.click()
        app.typeKey("h", modifierFlags: [.option, .command])
        Wait.label(app.waitFor(AX.Shortcuts.problem), equals: "Transcribe uses this shortcut for Hide Others.")
        Wait.value(toggle, equals: "Function Shift X")
    }

    // MARK: Simulated shortcuts

    @MainActor func testSimulatedDictationCopiesText() {
        let app = UITestApp.launch(seed: "empty", extraEnvironment: Self.simulated)
        app.waitFor(AX.Mac.main, timeout: 20)
        app.waitFor(AX.Library.emptyState)

        simulate(app, "Dictate: Press")
        Wait.label(app.waitFor(AX.Dictation.hudTitle), equals: "Listening…")
        simulate(app, "Dictate: Release")
        Wait.label(app.element(AX.Dictation.hudTitle), equals: "Copied — press ⌘V", timeout: 15)
        Wait.value(app.element(AX.Dictation.lastDelivered), equals: Self.dictationSentence)

        // Dictation never adds a recording.
        app.waitFor(AX.Library.emptyState)
        app.assertCount(0, of: AX.Library.card)
    }

    @MainActor func testSimulatedMeetingShortcutStartsAndStops() {
        let app = UITestApp.launch(seed: "empty", script: "newVoices", extraEnvironment: Self.simulated)
        app.waitFor(AX.Mac.main, timeout: 20)
        app.waitFor(AX.Library.emptyState)

        simulate(app, "Start or Stop Recording")
        app.waitFor(AX.Mac.recordingWindow)
        let elapsed = app.waitFor(AX.Recording.elapsed)
        Wait.label(elapsed, changesFrom: elapsed.textValue, timeout: 5)

        simulate(app, "Start or Stop Recording")
        app.waitForGone(AX.Mac.recordingWindow)
        app.waitFor(AX.Transcript.screen, timeout: 15)
        app.assertCount(1, of: AX.Library.card)
    }

    @MainActor func testDictationRefusedWhileRecording() {
        let app = UITestApp.launch(seed: "empty", script: "newVoices", extraEnvironment: Self.simulated)
        app.waitFor(AX.Mac.main, timeout: 20)
        app.waitFor(AX.Library.emptyState)
        app.shortcut("n")
        app.waitFor(AX.Mac.recordingWindow)

        simulate(app, "Dictate: Press")
        Wait.label(app.waitFor(AX.Dictation.hudTitle), equals: "Dictation is off while recording")
        simulate(app, "Dictate: Release")
        Wait.check(app.element(AX.Dictation.lastDelivered), "nothing delivered") { ($0.value as? String ?? "").isEmpty }

        // The recording carries on and stops as usual.
        app.shortcut(".")
        app.waitForGone(AX.Mac.recordingWindow, timeout: 15)
        app.waitFor(AX.Transcript.screen, timeout: 15)
    }

    @MainActor func testEscCancelsDictation() {
        let app = UITestApp.launch(seed: "empty", extraEnvironment: Self.simulated)
        app.waitFor(AX.Mac.main, timeout: 20)

        simulate(app, "Dictate Hands-free")
        Wait.label(app.waitFor(AX.Dictation.hudTitle), equals: "Listening…")
        simulate(app, "Cancel Dictation (Esc)")
        Wait.label(app.element(AX.Dictation.hudTitle), equals: "Cancelled")
        Wait.check(app.element(AX.Dictation.lastDelivered), "nothing delivered") { ($0.value as? String ?? "").isEmpty }
    }

    /// A test run never needs a permission (nothing is registered), so the sidebar's note never shows.
    @MainActor func testSidebarShortcutsNoteHiddenInTestRuns() {
        let app = UITestApp.launch(seed: "library")
        app.waitFor(AX.Mac.main, timeout: 20)
        // The footer the note would sit above has drawn, so its absence means something.
        app.waitFor(AX.Mac.sidebarFooter)
        XCTAssertFalse(app.element(AX.Mac.sidebarShortcuts).exists, "No shortcuts note in a test run")
    }

    // MARK: Helpers

    /// `ShortcutAction`'s raw values (the UI-test target does not link TranscribeKit).
    private enum Action: String, CaseIterable { case toggleRecording, dictateHold, dictateToggle }

    private static let simulated = ["TRANSCRIBE_SHORTCUTS": "sim"]

    private func recorder(_ action: Action) -> String { AX.Shortcuts.recorder(action.rawValue) }

    @MainActor private func openShortcutsSettings() -> XCUIApplication {
        let app = UITestApp.launch(seed: "library")
        app.waitFor(AX.Mac.main, timeout: 20)
        app.shortcut(",")
        app.waitFor(AX.Settings.screen)
        app.waitFor(AX.Shortcuts.section)
        return app
    }

    /// Chooses an item of the DEBUG Shortcut Simulation menu.
    @MainActor private func simulate(_ app: XCUIApplication, _ title: String,
                                     file: StaticString = #filePath, line: UInt = #line) {
        app.menuBars.menuBarItems["Shortcut Simulation"].click()
        let item = app.menuBars.menuItems[title]
        XCTAssertTrue(item.waitForExistence(timeout: 5), "No Shortcut Simulation item “\(title)”", file: file, line: line)
        item.click()
    }
}
