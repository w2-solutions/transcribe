import XCTest

/// In-app updates (Sparkle) are off in UI-test runs, which are Debug builds: the app menu still holds Check for
/// Updates…, disabled, and Settings → Updates shows the switch off and disabled, why, and the version. Never starts an
/// update check. The "Update available" reminder (D23) is put up by the launch hook TRANSCRIBE_UPDATE_AVAILABLE, as if
/// a scheduled check had found that version; it starts nothing either.
final class MacUpdatesTests: FlowTestCase {
    @MainActor func testUpdatesAreOffInTestRuns() {
        let app = UITestApp.launch(seed: "library")
        app.waitFor(AX.Mac.main, timeout: 20)
        // The footer the reminder would sit above has drawn, so its absence means something.
        app.waitFor(AX.Mac.sidebarFooter)
        XCTAssertFalse(app.element(AX.Mac.sidebarUpdate).exists, "No update reminder without an update")

        // The app menu, right after About Transcribe.
        app.menuBars.menuBarItems["Transcribe"].click()
        let check = app.menuBars.menuItems["Check for Updates…"]
        XCTAssertTrue(check.waitForExistence(timeout: 5), "No Check for Updates… in the app menu")
        Wait.enabled(check, false)
        XCTAssertFalse(app.menuBars.menuItems["Update Available…"].exists)
        app.typeKey(.escape, modifierFlags: [])

        app.shortcut(",")
        app.waitFor(AX.Settings.screen)
        let automatic = app.scrollTo(AX.Updates.automatic)
        Wait.switchState(automatic, on: false)
        XCTAssertFalse(automatic.toggleControl.isEnabled, "The switch is disabled while updates are off")
        let checkNow = app.element(AX.Updates.checkNow)
        Wait.enabled(checkNow, false)
        Wait.check(checkNow, "label “Check for Updates…”") { $0.label == "Check for Updates…" }
        Wait.label(app.scrollTo(AX.Updates.note), equals: "Updates are off in Debug builds.")
        app.scrollTo(AX.Settings.versionRow)
    }

    /// A waiting update shows only as the sidebar chip, "Update Available…" in the app menu and on Settings → Updates;
    /// no window of its own.
    @MainActor func testUpdateAvailableReminder() {
        let app = UITestApp.launch(seed: "library", extraEnvironment: ["TRANSCRIBE_UPDATE_AVAILABLE": "9.9.9"])
        app.waitFor(AX.Mac.main, timeout: 20)

        let reminder = app.waitFor(AX.Mac.sidebarUpdate)
        Wait.check(reminder, "label “Update available: Transcribe 9.9.9”") { $0.label == "Update available: Transcribe 9.9.9" }
        XCTAssertTrue(reminder.isEnabled)
        let shot = XCTAttachment(screenshot: reminder.screenshot())
        shot.name = "sidebar-update-reminder"
        shot.lifetime = .keepAlways
        add(shot)
        let main = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        main.name = "main-window-update-reminder"
        main.lifetime = .keepAlways
        add(main)
        XCTAssertEqual(app.windows.count, 1, "Only the main window: no update window of its own")

        app.menuBars.menuBarItems["Transcribe"].click()
        XCTAssertTrue(app.menuBars.menuItems["Update Available…"].waitForExistence(timeout: 5),
                      "The app menu reads Update Available…")
        XCTAssertFalse(app.menuBars.menuItems["Check for Updates…"].exists)
        app.typeKey(.escape, modifierFlags: [])

        app.shortcut(",")
        app.waitFor(AX.Settings.screen)
        let checkNow = app.scrollTo(AX.Updates.checkNow)
        Wait.check(checkNow, "label “Update Available…”") { $0.label == "Update Available…" }
        Wait.value(checkNow, equals: "9.9.9")
    }
}
