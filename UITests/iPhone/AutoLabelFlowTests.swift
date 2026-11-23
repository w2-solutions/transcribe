import XCTest

/// Screen 6: saved voices are recognised, asked about, or corrected.
final class AutoLabelFlowTests: FlowTestCase {
    /// `library` profiles + a new `knownVoices` recording (conversation A) → both speakers auto-labelled.
    @MainActor func testRecordingKnownVoicesIsRecognised() {
        let app = UITestApp.launch(seed: "library", script: "knownVoices")
        app.waitFor(AX.Library.recordButton, timeout: 20).press()
        app.waitFor(AX.Recording.screen)
        let elapsed = app.waitFor(AX.Recording.elapsed)
        Wait.label(elapsed, changesFrom: elapsed.label, timeout: 5)
        app.element(AX.Recording.stopButton).press()

        app.waitFor(AX.Transcript.screen)
        let banner = app.element(AX.Transcript.recognisedBanner)
        Wait.label(banner, contains: "Liam", timeout: 10)
        Wait.label(banner, contains: "Karan")
        XCTAssertEqual(app.element(AX.Transcript.turnChip(0)).textValue, "Liam")
        XCTAssertEqual(app.element(AX.Transcript.turnChip(1)).textValue, "Karan")
    }

    /// `askKaran` seed: recording D's Speaker 2 scored 0.47 against Karan → "Is this Karan?".
    @MainActor func testAskBannerYesLabelsKaran() {
        let app = UITestApp.launch(seed: "askKaran", route: "transcript:latest")
        app.waitFor(AX.Transcript.screen, timeout: 20)
        Wait.label(app.waitFor(AX.Transcript.askBanner), contains: "Karan")
        XCTAssertEqual(app.element(AX.Transcript.turnChip(1)).textValue, "Karan?")
        app.element(AX.Transcript.askYes).press()
        app.waitForGone(AX.Transcript.askBanner)
        Wait.label(app.element(AX.Transcript.turnChip(1)), equals: "Karan")
        Wait.label(app.element(AX.Transcript.turnChip(3)), equals: "Karan")
    }

    @MainActor func testAskBannerNoLeavesSpeakerUnnamed() {
        let app = UITestApp.launch(seed: "askKaran", route: "transcript:latest")
        app.waitFor(AX.Transcript.askBanner, timeout: 20)
        app.element(AX.Transcript.askNo).press()
        app.waitForGone(AX.Transcript.askBanner)
        Wait.label(app.element(AX.Transcript.turnChip(1)), equals: "Speaker 2")
        Wait.label(app.element(AX.Transcript.newVoicesBanner), contains: "1 new voice")
    }

    /// Recording A, Karan's turn moved to Liam with "Just this turn".
    @MainActor func testWrongSpeakerJustThisTurn() {
        let app = UITestApp.launch(seed: "library", route: "transcript:0")
        app.waitFor(AX.Transcript.screen, timeout: 20)
        XCTAssertEqual(app.waitFor(AX.Transcript.turnChip(1)).textValue, "Karan")

        // "Wrong speaker? Change" shows under the last-tapped turn.
        app.element(AX.Transcript.turnText(1)).press()
        app.waitFor(AX.Transcript.changeSpeaker(1)).press()
        app.waitFor(AX.NameSpeaker.sheet)
        app.waitFor(AX.NameSpeaker.savedVoice("liam")).press()
        let scope = app.waitFor(AX.NameSpeaker.scopePicker)
        scope.buttons["Just this turn"].press()
        XCTAssertTrue(scope.buttons["Just this turn"].isSelected)
        app.element(AX.NameSpeaker.saveButton).press()

        app.waitForGone(AX.NameSpeaker.sheet)
        Wait.label(app.element(AX.Transcript.turnChip(1)), equals: "Liam")
        XCTAssertEqual(app.element(AX.Transcript.turnChip(0)).textValue, "Liam")
        // Karan has no turns left, so the banner names Liam only.
        Wait.label(app.element(AX.Transcript.recognisedBanner), equals: "Recognised Liam")
    }

    /// Recording A, the whole Speaker 2 renamed to a new person.
    @MainActor func testWrongSpeakerWholeSpeakerToNewName() {
        let app = UITestApp.launch(seed: "library", route: "transcript:0")
        app.waitFor(AX.Transcript.screen, timeout: 20)
        app.waitFor(AX.Transcript.turnText(1)).press()
        app.waitFor(AX.Transcript.changeSpeaker(1)).press()
        app.waitFor(AX.NameSpeaker.sheet)
        let field = app.waitFor(AX.NameSpeaker.nameField)
        // Correct mode starts with the current name in the field.
        if app.element(AX.NameSpeaker.clearName).waitForExistence(timeout: 2) {
            app.element(AX.NameSpeaker.clearName).press()
        }
        field.press()
        field.typeText("Priya")
        XCTAssertEqual(field.value as? String, "Priya")
        app.element(AX.NameSpeaker.saveButton).press()
        app.waitForGone(AX.NameSpeaker.sheet)
        Wait.label(app.element(AX.Transcript.turnChip(1)), equals: "Priya")
    }
}
