import XCTest

/// In-app updates (Sparkle) are off in UI-test runs, which are Debug builds: the app menu still holds Check for
/// Updates…, disabled, and Settings → Updates shows the switch off and disabled, why, and the version. Never starts an
/// update check.
final class MacUpdatesTests: FlowTestCase {
    @MainActor func testUpdatesAreOffInTestRuns() {
        let app = UITestApp.launch(seed: "library")
        app.waitFor(AX.Mac.main, timeout: 20)

        // The app menu, right after About Transcribe.
        app.menuBars.menuBarItems["Transcribe"].click()
        let check = app.menuBars.menuItems["Check for Updates…"]
        XCTAssertTrue(check.waitForExistence(timeout: 5), "No Check for Updates… in the app menu")
        Wait.enabled(check, false)
        app.typeKey(.escape, modifierFlags: [])

        app.shortcut(",")
        app.waitFor(AX.Settings.screen)
        let automatic = app.scrollTo(AX.Updates.automatic)
        Wait.switchState(automatic, on: false)
        XCTAssertFalse(automatic.toggleControl.isEnabled, "The switch is disabled while updates are off")
        Wait.enabled(app.element(AX.Updates.checkNow), false)
        Wait.label(app.scrollTo(AX.Updates.note), equals: "Updates are off in Debug builds.")
        app.scrollTo(AX.Settings.versionRow)
    }
}
