import XCTest

/// A voice learned on the iPhone, heard for the first time on the Mac (§7). Seed `karanFromIPhone`: the `library`
/// seed with Karan's samples (and the recordings they came from) heard on an iPhone; this store's channel is "mac".
/// Script `newVoices`: conversation B, Liam and Karan near their saved voices (0.90), Karan for 11.5 s of clean
/// speech. (The spec names `knownVoices`, but Karan speaks only 4.6 s in conversation A, under the 5 s needed to add
/// a sample, so confirming there teaches the Mac nothing.) `ChannelAwareStoreTests.macCrossDeviceFlowThroughTheFakeEngine`
/// runs the same flow in `swift test`.
final class MacCrossDeviceTests: FlowTestCase {
    @MainActor private func record(_ app: XCUIApplication, cards: Int) {
        app.shortcut("n")
        app.waitFor(AX.Mac.recordingWindow)
        let elapsed = app.waitFor(AX.Recording.elapsed)
        Wait.label(elapsed, changesFrom: elapsed.textValue, timeout: 5)
        app.element(AX.Recording.stopButton).click()
        app.waitForGone(AX.Mac.recordingWindow)
        app.waitFor(AX.Transcript.screen, timeout: 15)
        app.assertCount(cards, of: AX.Library.card)
    }

    @MainActor func testVoiceFromTheIPhoneIsAskedOnceThenLearned() {
        let app = UITestApp.launch(seed: "karanFromIPhone", script: "newVoices", channel: "mac")
        app.waitFor(AX.Mac.main, timeout: 20)
        app.assertCount(3, of: AX.Library.card)

        // First Mac recording: Liam (learned on this Mac too) is recognised; Karan, learned only on the iPhone, is
        // asked about and not auto-labelled.
        record(app, cards: 4)
        Wait.label(app.waitFor(AX.Transcript.askBanner, timeout: 15), contains: "Karan")
        Wait.label(app.element(AX.Transcript.turnChip(0)), equals: "Liam")
        XCTAssertEqual(app.element(AX.Transcript.turnChip(1)).textValue, "Karan?")

        // The name sheet says why it asks: Karan was named on the iPhone.
        app.element(AX.Transcript.turnChip(1)).click()
        app.waitFor(AX.NameSpeaker.sheet)
        Wait.label(app.waitFor(AX.NameSpeaker.askPrompt), contains: "Karan was named on your iPhone")
        app.element(AX.NameSpeaker.closeButton).click()
        app.waitForGone(AX.NameSpeaker.sheet)

        // Confirm: this stores a Mac sample for Karan.
        app.element(AX.Transcript.askYes).click()
        app.waitForGone(AX.Transcript.askBanner)
        Wait.label(app.element(AX.Transcript.turnChip(1)), equals: "Karan")

        // Second Mac recording: Karan is now auto-labelled.
        record(app, cards: 5)
        let banner = app.waitFor(AX.Transcript.recognisedBanner, timeout: 15)
        Wait.label(banner, contains: "Liam", timeout: 10)
        Wait.label(banner, contains: "Karan")
        XCTAssertFalse(app.element(AX.Transcript.askBanner).exists)
        Wait.label(app.element(AX.Transcript.turnChip(0)), equals: "Liam")
        Wait.label(app.element(AX.Transcript.turnChip(1)), equals: "Karan")
    }
}
