import XCTest

/// Screen 7: Voices with the `library` seed — Liam and Karan saved; C's Speaker 2 is waiting for a name.
final class VoicesFlowTests: FlowTestCase {
    @MainActor func testSavedAndWaitingVoices() {
        let app = UITestApp.launch(seed: "library", route: "voices")
        app.waitFor(AX.Voices.screen, timeout: 20)
        app.waitFor(AX.Voices.profile("liam"))
        app.waitFor(AX.Voices.profile("karan"))
        app.waitFor(AX.Voices.waiting(0))
        XCTAssertTrue(app.element(AX.Voices.privacyCard).exists || app.scrollTo(AX.Voices.privacyCard).exists)
    }

    @MainActor func testWaitingVoiceOpensNameSheet() {
        let app = UITestApp.launch(seed: "library", route: "voices")
        app.waitFor(AX.Voices.waitingName(0), timeout: 20).press()
        app.waitFor(AX.NameSpeaker.sheet)
        Wait.label(app.waitFor(AX.NameSpeaker.subtitle), contains: "Speaker 2")
        app.element(AX.NameSpeaker.closeButton).press()
        app.waitForGone(AX.NameSpeaker.sheet)
    }

    @MainActor func testSavedVoiceOpensProfile() {
        let app = UITestApp.launch(seed: "library", route: "voices")
        app.waitFor(AX.Voices.profile("karan"), timeout: 20).press()
        app.waitFor(AX.VoiceDetail.screen)
        Wait.label(app.waitFor(AX.VoiceDetail.name), equals: "Karan")
    }

    @MainActor func testSpeakerSettingsLinkOpensSettings() {
        let app = UITestApp.launch(seed: "library", route: "voices")
        app.waitFor(AX.Voices.screen, timeout: 20)
        app.scrollTo(AX.Voices.speakerSettingsLink).press()
        app.waitFor(AX.Settings.screen)
    }
}
