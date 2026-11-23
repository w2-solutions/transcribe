import XCTest

/// The Settings window (⌘,) with the `library` seed.
final class MacSettingsTests: FlowTestCase {
    @MainActor func testCommandCommaOpensSettingsWithItsToggles() {
        let app = UITestApp.launch(seed: "library")
        app.waitFor(AX.Mac.main, timeout: 20)
        app.shortcut(",")
        app.waitFor(AX.Settings.screen)

        let identify = app.waitFor(AX.Settings.identifySpeakers)
        let recognise = app.waitFor(AX.Settings.recogniseVoices)
        app.waitFor(AX.Settings.removeFillers)
        Wait.switchState(identify, on: true)
        Wait.switchState(recognise, on: true)
        XCTAssertTrue(recognise.toggleControl.isEnabled)

        // Identify speakers off turns Recognise off and disables it; on again brings the saved setting back.
        identify.flipSwitch()
        Wait.switchState(identify, on: false)
        Wait.check(recognise, "Recognise disabled") { !$0.toggleControl.isEnabled }
        XCTAssertFalse(recognise.isOn, "Recognise reads off while Identify is off")
        identify.flipSwitch()
        Wait.switchState(identify, on: true)
        Wait.switchState(recognise, on: true)
    }
}
