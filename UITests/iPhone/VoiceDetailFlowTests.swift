import XCTest

/// Screen 8: Karan's voice profile with the `library` seed (2 samples, recordings A and B).
final class VoiceDetailFlowTests: FlowTestCase {
    @MainActor private func launchKaran() -> XCUIApplication {
        let app = UITestApp.launch(seed: "library", route: "voice:Karan")
        app.waitFor(AX.VoiceDetail.screen, timeout: 20)
        Wait.label(app.waitFor(AX.VoiceDetail.name), equals: "Karan")
        return app
    }

    @MainActor func testSamplesAppearancesAndAutoLabelToggle() {
        let app = launchKaran()
        app.assertCount(2, of: AX.VoiceDetail.sample)
        app.scrollTo(AX.VoiceDetail.appearance(1))
        XCTAssertTrue(app.element(AX.VoiceDetail.appearance(0)).exists)

        let toggle = app.scrollTo(AX.VoiceDetail.autoLabelToggle)
        XCTAssertTrue(toggle.isOn, "Auto-label starts on")
        toggle.flipSwitch()
        Wait.until(toggle, "value == %@", "0", timeout: 5, "Auto-label should switch off")
        app.swipeDown(velocity: .fast)
        app.swipeDown(velocity: .fast)
        Wait.label(app.element(AX.VoiceDetail.status), contains: "Auto-label off")
    }

    @MainActor func testSampleOriginsShown() {
        let app = launchKaran()
        Wait.label(app.waitFor(AX.VoiceDetail.sampleOrigin(0)), equals: "Named by you")
        // The 4.6 s seed sample from recording A.
        Wait.label(app.waitFor(AX.VoiceDetail.sampleOrigin(1)), equals: "Named by you · short sample")
    }

    @MainActor func testRemoveSample() {
        let app = launchKaran()
        app.assertCount(2, of: AX.VoiceDetail.sample)
        app.waitFor(AX.VoiceDetail.samplePlay(1)).press(forDuration: 1.2)
        let byID = app.element(AX.VoiceDetail.sampleRemove(1))
        if byID.waitForExistence(timeout: 3) {
            byID.press()
        } else {
            // The context-menu item's identifier is not always exposed.
            let byLabel = app.buttons["Remove sample"].firstMatch
            XCTAssertTrue(byLabel.waitForExistence(timeout: 5), "The context menu offers Remove sample")
            byLabel.press()
        }
        app.waitFor(AX.VoiceDetail.removeSampleConfirm).press()
        // The toast first: it hides after 2 s, which the row-count waits can outlast.
        app.waitFor(AX.VoiceDetail.toast)
        app.assertCount(1, of: AX.VoiceDetail.sample)
    }

    @MainActor func testForgetKeepsNameInPastTranscripts() {
        let app = launchKaran()
        app.scrollTo(AX.VoiceDetail.forgetButton).press()
        app.waitFor(AX.VoiceDetail.forgetConfirm).press()
        app.waitFor(AX.Voices.screen)
        app.waitForGone(AX.Voices.profile("karan"))
        app.waitFor(AX.Voices.profile("liam"))

        app.goBack()
        app.openCard(0)
        app.waitFor(AX.Transcript.screen)
        Wait.label(app.waitFor(AX.Transcript.turnChip(1)), equals: "Karan")
    }

    @MainActor func testEditRenames() {
        let app = launchKaran()
        app.element(AX.VoiceDetail.editButton).press()
        app.waitFor(AX.VoiceDetail.Edit.sheet)
        let field = app.waitFor(AX.VoiceDetail.Edit.nameField)
        field.press()
        field.typeText(" S")
        Wait.until(field, "value == %@", "Karan S", timeout: 5, "The name field should read Karan S")
        app.element(AX.VoiceDetail.Edit.saveButton).press()
        app.waitForGone(AX.VoiceDetail.Edit.sheet)
        Wait.label(app.element(AX.VoiceDetail.name), equals: "Karan S")

        app.goBack()
        app.waitFor(AX.Voices.profile("karan-s"))
    }
}
