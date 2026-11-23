import XCTest

/// Screen 2 and the hand-off to screens 3–4: `empty` seed with the `newVoices` script (conversation B).
final class RecordingFlowTests: FlowTestCase {
    @MainActor func testRecordPauseMarkMinimiseStop() {
        let app = UITestApp.launch(seed: "empty", script: "newVoices")
        app.waitFor(AX.Library.recordButton, timeout: 20).press()
        app.waitFor(AX.Recording.screen)

        // Live text (display-only) runs at 10× under `instant`.
        Wait.label(app.element(AX.Recording.liveTranscript), contains: "Karan", timeout: 5)

        let elapsed = app.waitFor(AX.Recording.elapsed)
        let start = elapsed.label
        Wait.label(elapsed, changesFrom: start, timeout: 5)

        let pause = app.element(AX.Recording.pauseButton)
        Wait.label(pause, equals: "Pause recording")
        pause.press()
        Wait.label(pause, equals: "Resume recording")
        pause.press()
        Wait.label(pause, equals: "Pause recording")

        app.element(AX.Recording.markButton).press()
        app.waitFor(AX.Recording.markToast, timeout: 5)

        app.element(AX.Recording.minimiseButton).press()
        app.waitFor(AX.Library.recordingPill).press()
        app.waitFor(AX.Recording.screen)

        app.element(AX.Recording.stopButton).press()
        app.waitFor(AX.Transcript.screen)
        Wait.label(app.element(AX.Transcript.newVoicesBanner), contains: "2 new voices", timeout: 10)
        XCTAssertEqual(app.element(AX.Transcript.turnChip(0)).textValue, "Speaker 1")
        XCTAssertEqual(app.element(AX.Transcript.turnChip(1)).textValue, "Speaker 2")
    }

    /// A long recording: the live transcript keeps to the room above the controls and shows the newest words.
    @MainActor func testLongLiveTextStaysAboveTheControls() {
        let app = UITestApp.launch(seed: "empty", script: "longTalk")
        app.waitFor(AX.Library.recordButton, timeout: 20).press()
        app.waitFor(AX.Recording.screen)

        // The 90 s script plays at 10× under `instant`. Once the text outgrows the card, the title makes way.
        let card = app.element(AX.Recording.liveTranscript)
        Wait.label(card, contains: "review meeting to Thursday?", timeout: 20)
        app.waitForGone(AX.Recording.title, timeout: 20)

        let stop = app.element(AX.Recording.stopButton)
        let pause = app.element(AX.Recording.pauseButton)
        XCTAssertLessThanOrEqual(card.frame.maxY, stop.frame.minY, "The live transcript runs under the stop button")
        XCTAssertLessThanOrEqual(card.frame.maxY, pause.frame.minY, "The live transcript runs under the pause button")
        XCTAssertGreaterThan(card.frame.height, 300, "The live transcript did not grow to use the screen")
        XCTAssertTrue(stop.isHittable)

        stop.press()
        app.waitFor(AX.Transcript.screen)
    }

    @MainActor func testMicDeniedShowsSheet() {
        let app = UITestApp.launch(seed: "empty", mic: "denied")
        app.waitFor(AX.Library.recordButton, timeout: 20).press()
        app.waitFor(AX.Library.MicDenied.sheet)
        XCTAssertTrue(app.element(AX.Library.MicDenied.openSettings).exists)
        XCTAssertTrue(app.element(AX.Library.MicDenied.importInstead).exists)
        app.element(AX.Library.MicDenied.close).press()
        app.waitForGone(AX.Library.MicDenied.sheet)
        XCTAssertFalse(app.element(AX.Recording.screen).exists)
    }
}
