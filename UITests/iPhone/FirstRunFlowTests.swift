import XCTest

/// First run: no models yet (`firstRun`, models `missing`).
final class FirstRunFlowTests: FlowTestCase {
    /// `demo` speed makes the fake install last about 6 s, so the progress state is observable.
    @MainActor func testModelsCardDownloads() {
        let app = UITestApp.launch(seed: "firstRun", speed: "demo", models: "missing")
        app.waitFor(AX.Library.modelsCard, timeout: 20)
        app.waitFor(AX.Library.emptyState)
        app.waitFor(AX.Library.modelsDownloadButton).press()
        app.waitFor(AX.Library.modelsProgress, timeout: 5)
        app.waitForGone(AX.Library.modelsCard, timeout: 20)
        app.waitFor(AX.Library.emptyState)
    }

    /// A recording made before the models are ready waits, then finishes once they are installed.
    @MainActor func testRecordingWaitsForModels() {
        let app = UITestApp.launch(seed: "firstRun", script: "newVoices", models: "missing")
        app.waitFor(AX.Library.modelsCard, timeout: 20)
        app.waitFor(AX.Library.recordButton).press()
        app.waitFor(AX.Recording.screen)
        let elapsed = app.waitFor(AX.Recording.elapsed)
        Wait.label(elapsed, changesFrom: elapsed.label, timeout: 5)
        app.element(AX.Recording.stopButton).press()

        app.waitFor(AX.Transcript.screen)
        Wait.label(app.waitFor(AX.Processing.heading), contains: "Waiting for speech models")

        // Back on the Library the card waits too; download from the models card.
        app.goBack()
        Wait.label(app.waitFor(AX.Library.cardStatus(0)), contains: "Waiting for speech models")
        app.waitFor(AX.Library.modelsDownloadButton).press()
        app.waitForGone(AX.Library.modelsCard, timeout: 10)
        // The waiting recording then finishes on its own with two unnamed speakers.
        app.waitFor(AX.Library.cardNameLink(0), timeout: 15)
        app.openCard(0)
        app.waitFor(AX.Transcript.screen)
        Wait.label(app.waitFor(AX.Transcript.newVoicesBanner), contains: "2 new voices", timeout: 10)
    }
}
