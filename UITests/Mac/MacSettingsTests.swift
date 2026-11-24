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

    /// Voices opened from the Settings window names a waiting voice there (the Settings window has its own sheet), and
    /// "Speaker settings" goes back to Settings instead of stacking a second one.
    @MainActor func testNamingAWaitingVoiceFromTheSettingsWindow() {
        let app = UITestApp.launch(seed: "askKaran")
        app.waitFor(AX.Mac.main, timeout: 20)
        app.shortcut(",")
        app.waitFor(AX.Settings.screen)
        app.scrollTo(AX.Settings.voicesRow).click()
        app.waitFor(AX.Voices.screen)
        app.waitFor(AX.Voices.waitingName(0)).click()
        app.waitFor(AX.NameSpeaker.sheet)
        Wait.label(app.waitFor(AX.NameSpeaker.subtitle), contains: "Speaker 2")
        app.element(AX.NameSpeaker.closeButton).click()
        app.waitForGone(AX.NameSpeaker.sheet)
        app.scrollTo(AX.Voices.speakerSettingsLink).click()
        app.waitForGone(AX.Voices.screen)
        app.waitFor(AX.Settings.voicesRow)
    }
}
