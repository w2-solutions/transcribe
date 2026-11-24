import XCTest

/// The Mac recordings list with the `library` seed (recordings A, B, C; A is the only favourite, C has an unnamed
/// speaker): the shared context menu, Find and search, ⌫ with its confirmation, and the sidebar filters and folders.
final class MacLibraryTests: FlowTestCase {
    @MainActor private func launchLibrary() -> XCUIApplication {
        let app = UITestApp.launch(seed: "library")
        app.waitFor(AX.Mac.main, timeout: 20)
        app.waitFor(AX.Library.card(2))
        return app
    }

    @MainActor func testFavouriteFromContextMenu() {
        let app = launchLibrary()
        app.element(AX.Mac.sidebarFavourites).click()
        app.assertCount(1, of: AX.Library.card)

        app.element(AX.Mac.sidebarAll).click()
        app.assertCount(3, of: AX.Library.card)
        // Card 0 (A) is not a favourite yet; B (card 1) is.
        app.contextMenu(on: app.element(AX.Library.card(0)), choose: ["Favourite"])

        app.element(AX.Mac.sidebarFavourites).click()
        app.assertCount(2, of: AX.Library.card)
    }

    @MainActor func testSidebarUnnamedFilter() {
        let app = launchLibrary()
        app.element(AX.Mac.sidebarUnnamed).click()
        app.assertCount(1, of: AX.Library.card)
        XCTAssertTrue(app.element(AX.Library.cardNameLink(0)).exists, "The unnamed card offers to name its speaker")
        app.element(AX.Mac.sidebarAll).click()
        app.assertCount(3, of: AX.Library.card)
    }

    @MainActor func testSearchNarrowsTheList() {
        let app = launchLibrary()
        let field = app.element(AX.Mac.recordingSearch)
        XCTAssertTrue(field.waitForExistence(timeout: 5), "The search field is in the list column")
        // Find (⌘F) focuses the field.
        app.shortcut("f")
        Wait.check(field, "the search field to take focus") { $0.hasKeyboardFocusValue }
        app.typeText("Morning")
        app.assertCount(1, of: AX.Library.card)
        field.typeText("zzz")
        app.waitFor(AX.Library.noResults)
        app.assertCount(0, of: AX.Library.card)
        // Clearing the search brings every card back.
        field.typeKey("a", modifierFlags: .command)
        field.typeKey(.delete, modifierFlags: [])
        app.assertCount(3, of: AX.Library.card)
    }

    @MainActor func testDeleteKeyAsksThenDeletes() {
        let app = launchLibrary()
        app.openCard(1)
        app.waitFor(AX.Transcript.screen)

        app.typeKey(.delete, modifierFlags: [])
        app.button(AX.Library.deleteConfirm, title: "Delete").click()
        app.assertCount(2, of: AX.Library.card)
        // The deleted recording was selected: the detail column is empty again.
        app.waitFor(AX.Mac.detailEmpty)
    }

    @MainActor func testNewFolderAndFolderFilter() {
        let app = launchLibrary()
        app.contextMenu(on: app.element(AX.Library.card(0)), choose: ["Move to folder", "New folder…"])
        let name = app.dialogTextField(AX.Library.Folders.nameField)
        name.click()
        name.typeText("Work")
        app.button(nil, title: "Save").click()

        // The new folder is selected in the sidebar, and it starts empty.
        app.waitFor(AX.Mac.sidebarFolder(0))
        app.waitFor(AX.Library.noResults)
        app.assertCount(0, of: AX.Library.card)

        app.element(AX.Mac.sidebarAll).click()
        app.contextMenu(on: app.waitFor(AX.Library.card(1)), choose: ["Move to folder", "Work"])

        app.element(AX.Mac.sidebarFolder(0)).click()
        app.assertCount(1, of: AX.Library.card)
        app.element(AX.Mac.sidebarAll).click()
        app.assertCount(3, of: AX.Library.card)
    }

    /// "Continue in background" folds the processing panel into the progress pill: on the Mac the transcript is the
    /// detail column itself, so there is nothing to go back from.
    @MainActor func testContinueInBackgroundCollapsesTheProcessingPanel() {
        let app = UITestApp.launch(seed: "processingHeld", script: "holdAtSeparating", route: "transcript:latest")
        app.waitFor(AX.Transcript.screen, timeout: 20)
        app.waitFor(AX.Processing.continueInBackground).click()
        app.waitForGone(AX.Processing.panel)
        app.waitFor(AX.Processing.collapsedPill)
        app.waitFor(AX.Transcript.screen)
    }
}
