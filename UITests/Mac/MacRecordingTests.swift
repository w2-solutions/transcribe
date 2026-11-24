import XCTest

/// The Mac Recording window: `empty` seed with the `newVoices` script (conversation B, two new voices).
/// Closing or minimising the window keeps the recording running; the main window's toolbar pill brings it back.
/// On the Mac the recording screen carries `AX.Mac.recordingWindow` (it replaces the shared `AX.Recording.screen`).
final class MacRecordingTests: FlowTestCase {
    @MainActor private func startRecording() -> XCUIApplication {
        let app = UITestApp.launch(seed: "empty", script: "newVoices")
        app.waitFor(AX.Mac.main, timeout: 20)
        app.waitFor(AX.Library.emptyState)
        app.shortcut("n")
        app.waitFor(AX.Mac.recordingWindow)
        // Live text (display-only) runs at 10× under `instant`.
        Wait.label(app.element(AX.Recording.liveTranscript), contains: "Karan", timeout: 5)
        return app
    }

    @MainActor private func recordingWindow(_ app: XCUIApplication) -> XCUIElement {
        app.windows["recording"]
    }

    @MainActor func testCloseWindowThenPillReopensThenStop() {
        let app = startRecording()
        let window = recordingWindow(app)
        XCTAssertTrue(window.exists, "The recording opens in its own window")
        window.buttons[XCUIIdentifierCloseWindow].click()
        app.waitForGone(AX.Mac.recordingWindow)

        // The recording keeps running: the main window shows the pill and the list shows it as recording.
        app.waitFor(AX.Mac.toolbarRecordingPill).click()
        app.waitFor(AX.Mac.recordingWindow)
        let elapsed = app.waitFor(AX.Recording.elapsed)
        Wait.label(elapsed, changesFrom: elapsed.textValue, timeout: 5)

        app.element(AX.Recording.stopButton).click()
        app.waitForGone(AX.Mac.recordingWindow)
        app.waitForGone(AX.Mac.toolbarRecordingPill)

        // Processing runs, then the new recording's transcript is selected in the main window.
        app.waitFor(AX.Transcript.screen, timeout: 15)
        Wait.label(app.element(AX.Transcript.newVoicesBanner), contains: "2 new voices", timeout: 15)
        Wait.label(app.element(AX.Transcript.turnChip(0)), equals: "Speaker 1")
        Wait.label(app.element(AX.Transcript.turnChip(1)), equals: "Speaker 2")
        app.assertCount(1, of: AX.Library.card)
    }

    @MainActor func testMinimiseThenStopFromTheMenu() {
        let app = startRecording()
        app.element(AX.Recording.minimiseButton).click()
        app.waitForGone(AX.Mac.recordingWindow)
        app.waitFor(AX.Mac.toolbarRecordingPill)

        // Stop Recording (⌘.) works with the window closed.
        app.shortcut(".")
        app.waitForGone(AX.Mac.toolbarRecordingPill, timeout: 15)
        app.waitFor(AX.Transcript.screen, timeout: 15)
        Wait.label(app.element(AX.Transcript.newVoicesBanner), contains: "2 new voices", timeout: 15)
    }
}
