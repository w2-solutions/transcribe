import XCTest

/// Skeleton smoke test: launches with the fake engine and the `library` seed and finds the Library.
final class SmokeTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor func testLibraryLaunchesWithFakeEngine() {
        let app = UITestApp.launch(seed: "library")
        app.waitFor(AX.Library.screen, timeout: 20)
        XCTAssertTrue(app.navigationBars["Recordings"].waitForExistence(timeout: 5), "Library title missing")
        XCTAssertTrue(app.element(AX.Library.recordButton).exists)
        XCTAssertTrue(app.element(AX.Library.voicesButton).exists)
        XCTAssertTrue(app.element(AX.Library.settingsButton).exists)
        // The library seed has three recordings, newest first.
        app.waitFor(AX.Library.card(0))
        app.waitFor(AX.Library.card(2))
        XCTAssertFalse(app.element(AX.Library.card(3)).exists)
    }

    @MainActor func testCardOpensTranscript() {
        let app = UITestApp.launch(seed: "library")
        app.waitFor(AX.Library.card(1), timeout: 20).press()
        app.waitFor(AX.Transcript.screen)
        app.waitFor(AX.Transcript.turn(0))
        XCTAssertEqual(app.element(AX.Transcript.turnChip(1)).textValue, "Karan")
    }
}
