import XCTest

/// The name sheet on the Mac: `twoSpeakersUnnamed` (recording B′ with Speaker 1 and Speaker 2 unnamed; only Liam
/// is saved, and Speaker 1 is Liam's voice).
final class MacNameSpeakerTests: FlowTestCase {
    @MainActor private func launchUnnamed() -> XCUIApplication {
        let app = UITestApp.launch(seed: "twoSpeakersUnnamed", route: "transcript:latest")
        app.waitFor(AX.Transcript.screen, timeout: 20)
        Wait.label(app.waitFor(AX.Transcript.turnChip(0)), equals: "Speaker 1")
        Wait.label(app.waitFor(AX.Transcript.turnChip(1)), equals: "Speaker 2")
        Wait.label(app.element(AX.Transcript.newVoicesBanner), contains: "2 new voices")
        return app
    }

    @MainActor func testNameSpeakerOneAsSavedVoice() {
        let app = launchUnnamed()
        app.element(AX.Transcript.turnChip(0)).click()
        app.waitFor(AX.NameSpeaker.sheet)
        Wait.label(app.waitFor(AX.NameSpeaker.subtitle), contains: "Speaker 1")

        app.waitFor(AX.NameSpeaker.savedVoice("liam")).click()
        Wait.label(app.element(AX.NameSpeaker.saveButton), contains: "Save and label")
        app.element(AX.NameSpeaker.saveButton).click()

        app.waitForGone(AX.NameSpeaker.sheet)
        Wait.label(app.element(AX.Transcript.turnChip(0)), equals: "Liam")
        Wait.label(app.element(AX.Transcript.newVoicesBanner), contains: "1 new voice")
    }

    @MainActor func testTypeANewNameForSpeakerTwo() {
        let app = launchUnnamed()
        app.element(AX.Transcript.turnChip(1)).click()
        app.waitFor(AX.NameSpeaker.sheet)
        Wait.label(app.waitFor(AX.NameSpeaker.subtitle), contains: "spoke for 0:13")

        let field = app.waitFor(AX.NameSpeaker.nameField)
        field.click()
        field.typeText("Karan")
        Wait.check(field, "the name field to read Karan") { ($0.value as? String) == "Karan" }
        Wait.label(app.element(AX.NameSpeaker.saveButton), equals: "Save and label 2 turns")
        app.element(AX.NameSpeaker.saveButton).click()

        app.waitForGone(AX.NameSpeaker.sheet)
        Wait.label(app.element(AX.Transcript.turnChip(1)), equals: "Karan")
        Wait.label(app.element(AX.Transcript.turnChip(3)), equals: "Karan")

        // The new voice is saved on this Mac.
        app.element(AX.Mac.sidebarVoices).click()
        app.waitFor(AX.Mac.voiceList)
        app.waitFor(AX.Voices.profile("karan"))
        app.waitFor(AX.Voices.profile("liam"))
    }
}
