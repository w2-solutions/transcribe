import XCTest

/// Screen 9 and the screens it opens: Settings with the `library` seed.
final class SettingsFlowTests: FlowTestCase {
    @MainActor private func launchSettings() -> XCUIApplication {
        let app = UITestApp.launch(seed: "library", route: "settings")
        app.waitFor(AX.Settings.screen, timeout: 20)
        return app
    }

    @MainActor func testIdentifySpeakersOffDisablesRecognise() {
        let app = launchSettings()
        let identify = app.waitFor(AX.Settings.identifySpeakers)
        let recognise = app.waitFor(AX.Settings.recogniseVoices)
        XCTAssertTrue(identify.isOn)
        XCTAssertTrue(recognise.isOn)
        XCTAssertTrue(recognise.isEnabled)

        identify.flipSwitch()
        Wait.until(identify, "value == %@", "0", timeout: 5, "Identify speakers should switch off")
        Wait.enabled(recognise, false)
        XCTAssertFalse(recognise.isOn, "Recognise reads off while Identify is off")

        identify.flipSwitch()
        Wait.enabled(recognise, true)
        XCTAssertTrue(recognise.isOn, "The saved Recognise setting comes back")
    }

    /// Only the toast is checked: reading the pasteboard would show the paste prompt. A failure shows
    /// "Couldn't copy the log" on the same toast, so its text is checked too.
    @MainActor func testCopyMatchLog() {
        let app = launchSettings()
        app.scrollTo(AX.Settings.copyMatchLogRow).press()
        let toast = app.waitFor(AX.Settings.copiedToast)
        XCTAssertTrue(toast.label.contains("Log copied"), "Expected the success toast, got \"\(toast.label)\"")
    }

    @MainActor func testAppearanceDark() {
        let app = launchSettings()
        let row = app.scrollTo(AX.Settings.appearanceRow)
        row.press()
        let dark = app.buttons["Dark"].firstMatch
        XCTAssertTrue(dark.waitForExistence(timeout: 5), "The Appearance menu lists Dark")
        dark.press()
        Wait.label(app.element(AX.Settings.appearanceRow), contains: "Dark")
        XCTAssertTrue(app.element(AX.Settings.screen).exists)
    }

    @MainActor func testAcknowledgements() {
        let app = launchSettings()
        app.scrollTo(AX.Settings.acknowledgementsRow).press()
        app.waitFor(AX.Attributions.screen)
        app.waitFor(AX.Attributions.entry("parakeet"))
        app.waitFor(AX.Attributions.entry("community-1"))
        app.scrollTo(AX.Attributions.entry("nemotron-3-diarization"))
        app.scrollTo(AX.Attributions.entry("fluidaudio"))
    }

    @MainActor func testModelRowOpensModelSettings() {
        let app = launchSettings()
        app.scrollTo(AX.Settings.modelRow).press()
        app.waitFor(AX.ModelSettings.screen)
        Wait.label(app.waitFor(AX.ModelSettings.speechRow), contains: "Included")
        app.waitFor(AX.ModelSettings.speakersRow)
        // The models ship in the app: nothing to download or remove.
        XCTAssertFalse(app.element(AX.ModelSettings.downloadButton).exists, "No download button")
        XCTAssertFalse(app.element(AX.ModelSettings.removeButton).exists, "No remove button")
    }

    @MainActor func testLanguagePicker() {
        let app = launchSettings()
        app.scrollTo(AX.Settings.languageRow).press()
        app.waitFor(AX.Language.screen)
        app.waitFor(AX.Language.option("en")).press()
        if app.element(AX.Language.screen).exists { app.goBack() }
        app.waitFor(AX.Settings.screen)
        Wait.label(app.waitFor(AX.Settings.languageRow), contains: "English")
    }
}
