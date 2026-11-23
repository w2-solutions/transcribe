import XCTest

/// People → Voices on the Mac with the `askKaran` seed (Liam and Karan saved; recording C's Speaker 2 waiting for a
/// name): the list, a profile in the detail column, rename and merge.
final class MacVoicesTests: FlowTestCase {
    @MainActor private func launchVoices() -> XCUIApplication {
        let app = UITestApp.launch(seed: "askKaran", route: "voices")
        app.waitFor(AX.Mac.voiceList, timeout: 20)
        return app
    }

    @MainActor func testListShowsSavedAndWaitingVoices() {
        let app = launchVoices()
        app.waitFor(AX.Voices.profile("liam"))
        app.waitFor(AX.Voices.profile("karan"))
        app.waitFor(AX.Voices.waiting(0))
        Wait.label(app.waitFor(AX.Voices.privacyCard), contains: "this Mac only")
        // The sidebar's dashed badge counts the voices waiting for a name (the row reads it out with its title).
        Wait.label(app.element(AX.Mac.sidebarVoices), contains: "waiting for a name")
        app.waitFor(AX.Mac.detailEmpty)

        // "Name…" on a waiting voice opens the name sheet over the main window.
        app.element(AX.Voices.waitingName(0)).click()
        app.waitFor(AX.NameSpeaker.sheet)
        Wait.label(app.waitFor(AX.NameSpeaker.subtitle), contains: "Speaker 2")
        app.element(AX.NameSpeaker.closeButton).click()
        app.waitForGone(AX.NameSpeaker.sheet)
    }

    @MainActor func testSelectingAVoiceShowsItsProfile() {
        let app = launchVoices()
        app.waitFor(AX.Voices.profile("karan")).click()
        app.waitFor(AX.VoiceDetail.screen)
        Wait.label(app.waitFor(AX.VoiceDetail.name), equals: "Karan")
        app.waitFor(AX.VoiceDetail.sample(0))

        app.element(AX.Voices.profile("liam")).click()
        Wait.label(app.element(AX.VoiceDetail.name), equals: "Liam")
    }

    @MainActor func testRename() {
        let app = launchVoices()
        app.waitFor(AX.Voices.profile("karan")).click()
        Wait.label(app.waitFor(AX.VoiceDetail.name), equals: "Karan")

        app.waitFor(AX.VoiceDetail.editButton).click()
        // A Mac sheet does not carry the sheet's own identifier; its controls do.
        let field = app.waitFor(AX.VoiceDetail.Edit.nameField)
        field.click()
        field.typeKey(.rightArrow, modifierFlags: .command)     // the end of the name
        field.typeText(" S")
        Wait.check(field, "the name field to read Karan S") { ($0.value as? String) == "Karan S" }
        app.element(AX.VoiceDetail.Edit.saveButton).click()
        app.waitForGone(AX.VoiceDetail.Edit.nameField)

        Wait.label(app.element(AX.VoiceDetail.name), equals: "Karan S")
        app.waitFor(AX.Voices.profile("karan-s"))
        app.waitForGone(AX.Voices.profile("karan"))
    }

    @MainActor func testMergeIntoAnotherVoice() {
        let app = launchVoices()
        app.waitFor(AX.Voices.profile("karan")).click()
        app.waitFor(AX.VoiceDetail.screen)
        app.scrollTo(AX.VoiceDetail.mergeButton).click()

        app.waitFor(AX.VoiceDetail.Merge.target("liam")).click()
        app.button(AX.VoiceDetail.Merge.confirm, title: "Merge").click()

        // Karan is merged into Liam: one saved voice is left and the detail column is empty again.
        app.waitForGone(AX.VoiceDetail.Merge.target("liam"))
        app.waitForGone(AX.Voices.profile("karan"))
        app.waitFor(AX.Voices.profile("liam"))
        app.waitFor(AX.Mac.detailEmpty)
    }
}
