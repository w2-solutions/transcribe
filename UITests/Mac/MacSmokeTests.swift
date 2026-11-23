import XCTest

/// The Mac main window with the `library` seed: sidebar, recordings list, and a card opening its transcript.
final class MacSmokeTests: FlowTestCase {
    @MainActor func testMainWindowSidebarAndTranscript() {
        let app = UITestApp.launch(seed: "library")
        app.waitFor(AX.Mac.main, timeout: 20)
        app.waitFor(AX.Mac.sidebarAll)
        app.waitFor(AX.Mac.sidebarFavourites)
        app.waitFor(AX.Mac.sidebarUnnamed)
        app.waitFor(AX.Mac.sidebarVoices)
        app.waitFor(AX.Mac.sidebarNewRecording)
        Wait.label(app.waitFor(AX.Mac.sidebarFooter), contains: "Nothing is uploaded")
        app.waitFor(AX.Mac.recordingList)
        app.assertCount(3, of: AX.Library.card)
        app.waitFor(AX.Mac.detailEmpty)

        app.openCard(1)
        app.waitFor(AX.Transcript.screen)
        app.waitFor(AX.Transcript.turn(0))
        Wait.label(app.element(AX.Transcript.turnChip(1)), equals: "Karan")
        app.waitForGone(AX.Mac.detailEmpty)
    }
}
