import XCTest

/// First launch: models ship in the app; only the on-device prepare runs (`firstRun`, fake models `missing`
/// means a slow first prepare, 20 s at `demo` speed, and no download).
final class FirstRunFlowTests: FlowTestCase {
    /// No models card and no download button: the models become ready on their own.
    @MainActor func testFirstLaunchNeedsNoDownload() {
        let app = UITestApp.launch(seed: "firstRun", speed: "demo")
        app.waitFor(AX.Library.emptyState, timeout: 20)
        XCTAssertFalse(app.element(AX.Library.modelsCard).exists, "No models card on first launch")
        XCTAssertFalse(app.element(AX.Library.modelsDownloadButton).exists, "Nothing to download")

        app.waitFor(AX.Library.settingsButton).press()
        app.waitFor(AX.Settings.screen)
        Wait.label(app.waitFor(AX.Settings.modelRow), contains: "Parakeet", timeout: 35)
    }

    /// A recording made during the first prepare waits, then finishes on its own once the models are ready.
    @MainActor func testRecordingWaitsForFirstPrepare() {
        let app = UITestApp.launch(seed: "firstRun", script: "newVoices", speed: "demo")
        app.waitFor(AX.Library.recordButton, timeout: 20).press()
        app.waitFor(AX.Recording.screen)
        let elapsed = app.waitFor(AX.Recording.elapsed)
        Wait.label(elapsed, changesFrom: elapsed.label, timeout: 5)
        app.element(AX.Recording.stopButton).press()

        app.waitFor(AX.Transcript.screen)
        Wait.label(app.waitFor(AX.Processing.heading), contains: "Waiting for speech models")

        // Back on the Library the card waits too, with no models card and nothing to tap.
        app.goBack()
        Wait.label(app.waitFor(AX.Library.cardStatus(0)), contains: "Waiting for speech models")
        XCTAssertFalse(app.element(AX.Library.modelsCard).exists, "No models card while preparing")

        // The waiting recording then finishes on its own with two unnamed speakers.
        app.waitFor(AX.Library.cardNameLink(0), timeout: 45)
        XCTAssertFalse(app.element(AX.Library.modelsCard).exists, "The models card never appears")
        app.openCard(0)
        app.waitFor(AX.Transcript.screen)
        Wait.label(app.waitFor(AX.Transcript.newVoicesBanner), contains: "2 new voices", timeout: 10)
    }
}
