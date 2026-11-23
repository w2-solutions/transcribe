import XCTest

/// Screen 3: `processingHeld` seed with the `holdAtSeparating` script — separation reports 60% and then waits.
final class ProcessingFlowTests: FlowTestCase {
    @MainActor private func launchHeld() -> XCUIApplication {
        let app = UITestApp.launch(seed: "processingHeld", script: "holdAtSeparating", route: "transcript:latest")
        app.waitFor(AX.Transcript.screen, timeout: 20)
        app.waitFor(AX.Processing.panel)
        return app
    }

    @MainActor func testPanelStepsAndCounter() {
        let app = launchHeld()
        Wait.value(app.element(AX.Processing.step("transcribing")), equals: "done")
        Wait.value(app.element(AX.Processing.step("separating")), equals: "inProgress")
        Wait.value(app.element(AX.Processing.step("matching")), equals: "waiting")
        Wait.label(app.element(AX.Processing.stepCounter), equals: "Step 2 of 3")
        // The transcript is readable while speakers are pending.
        XCTAssertTrue(app.element(AX.Transcript.speakersPendingPill).exists)
    }

    @MainActor func testShowTranscriptNowCollapsesThePanel() {
        let app = launchHeld()
        app.waitFor(AX.Processing.showTranscriptNow).press()
        app.waitForGone(AX.Processing.panel)
        app.waitFor(AX.Processing.collapsedPill)
        app.waitFor(AX.Transcript.speakersPendingPill)
    }

    @MainActor func testContinueInBackgroundReturnsToLibrary() {
        let app = launchHeld()
        app.waitFor(AX.Processing.continueInBackground).press()
        app.waitFor(AX.Library.screen)
        Wait.label(app.waitFor(AX.Library.cardStatus(0)), contains: "Separating")
    }
}
