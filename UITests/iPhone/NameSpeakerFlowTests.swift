import XCTest

/// Screens 4 and 5: `twoSpeakersUnnamed` (recording B′ with Speaker 1 and Speaker 2 unnamed; only Liam is saved).
final class NameSpeakerFlowTests: FlowTestCase {
    @MainActor private func launchUnnamed() -> XCUIApplication {
        let app = UITestApp.launch(seed: "twoSpeakersUnnamed", route: "transcript:latest")
        app.waitFor(AX.Transcript.screen, timeout: 20)
        app.waitFor(AX.Transcript.turnChip(1))
        return app
    }

    @MainActor func testNameSpeakerTwoAsKaran() {
        let app = launchUnnamed()
        XCTAssertEqual(app.element(AX.Transcript.turnChip(1)).textValue, "Speaker 2")
        Wait.label(app.element(AX.Transcript.newVoicesBanner), contains: "2 new voices")

        app.element(AX.Transcript.turnChip(1)).press()
        app.waitFor(AX.NameSpeaker.sheet)
        Wait.label(app.waitFor(AX.NameSpeaker.subtitle), contains: "spoke for 0:13")

        let field = app.waitFor(AX.NameSpeaker.nameField)
        field.press()
        field.typeText("Karan")
        Wait.label(app.element(AX.NameSpeaker.saveButton), equals: "Save and label 2 turns")
        XCTAssertEqual(field.value as? String, "Karan", "The name field must not autocorrect")
        app.element(AX.NameSpeaker.saveButton).press()

        app.waitForGone(AX.NameSpeaker.sheet)
        Wait.label(app.element(AX.Transcript.turnChip(1)), equals: "Karan")
        Wait.label(app.element(AX.Transcript.turnChip(3)), equals: "Karan")
        Wait.label(app.element(AX.Transcript.newVoicesBanner), contains: "1 new voice")

        // The new voice is saved on this device.
        app.goBack()
        app.waitFor(AX.Library.voicesButton).press()
        app.waitFor(AX.Voices.screen)
        app.waitFor(AX.Voices.profile("karan"))
        app.waitFor(AX.Voices.profile("liam"))
    }

    @MainActor func testNameSpeakersWalksEverySpeaker() {
        let app = launchUnnamed()
        app.waitFor(AX.Transcript.nameSpeakersButton).press()
        app.waitFor(AX.NameSpeaker.sheet)
        Wait.label(app.waitFor(AX.NameSpeaker.subtitle), contains: "Speaker 1")

        app.element(AX.NameSpeaker.notNowButton).press()
        // The follow-up sheet is for Speaker 2.
        Wait.label(app.element(AX.NameSpeaker.subtitle), contains: "Speaker 2")
        app.element(AX.NameSpeaker.notNowButton).press()
        app.waitForGone(AX.NameSpeaker.sheet)
        XCTAssertEqual(app.element(AX.Transcript.turnChip(0)).textValue, "Speaker 1")
        XCTAssertEqual(app.element(AX.Transcript.turnChip(1)).textValue, "Speaker 2")
    }

    /// `shortKaran`: recording G's Speaker 2 spoke for 6.2 s. Too little for a new voice (10 s), enough to add to a
    /// saved one (5 s), so choosing Karan turns Remember on.
    @MainActor func testShortSpeakerToSavedVoiceKeepsRemember() {
        let app = UITestApp.launch(seed: "shortKaran", route: "name:latest:S2")
        app.waitFor(AX.NameSpeaker.sheet, timeout: 20)
        app.waitFor(AX.NameSpeaker.savedVoice("karan")).press()

        let toggle = app.waitFor(AX.NameSpeaker.rememberToggle)
        Wait.enabled(toggle, true)
        Wait.until(toggle, "value == %@", "1", timeout: 5, "Remember should be on for a saved voice")
        Wait.label(app.waitFor(AX.NameSpeaker.rememberHelp), equals: "Adds this recording to Karan's voice.")

        app.element(AX.NameSpeaker.saveButton).press()
        app.waitForGone(AX.NameSpeaker.sheet)
        Wait.label(app.waitFor(AX.Transcript.turnChip(1)), equals: "Karan")
    }
}
