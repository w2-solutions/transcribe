import XCTest

/// Screen 1: the Library with the `library` seed (recordings A, B, C; Liam and Karan saved).
final class LibraryFlowTests: FlowTestCase {
    @MainActor func testCardsStatusAndNameLink() {
        let app = UITestApp.launch(seed: "library")
        app.waitFor(AX.Library.screen, timeout: 20)
        app.assertCount(3, of: AX.Library.card)
        // A (newest) was auto-labelled; C (12:48) has an unnamed speaker.
        Wait.label(app.element(AX.Library.cardStatus(0)), equals: "Voices recognised")
        XCTAssertTrue(app.element(AX.Library.cardNameLink(2)).exists, "Card 2 should offer to name its speaker")
        XCTAssertFalse(app.element(AX.Library.cardNameLink(0)).exists)
    }

    @MainActor func testFiltersAndSearch() {
        let app = UITestApp.launch(seed: "library")
        app.waitFor(AX.Library.card(2), timeout: 20)

        app.element(AX.Library.filter("favourites")).press()
        app.assertCount(1, of: AX.Library.card)
        app.element(AX.Library.filter("favourites")).press()            // tapping again clears it
        app.assertCount(3, of: AX.Library.card)

        app.element(AX.Library.filter("unnamed")).press()
        app.assertCount(1, of: AX.Library.card)
        app.element(AX.Library.filter("all")).press()
        app.assertCount(3, of: AX.Library.card)

        app.element(AX.Library.searchButton).press()
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "The search field should appear")
        field.press()
        field.typeText("Morning")
        app.assertCount(1, of: AX.Library.card)
        field.typeText("zzz")
        app.waitFor(AX.Library.noResults)
        app.assertCount(0, of: AX.Library.card)
    }

    @MainActor func testSwipeDeleteWithConfirm() {
        let app = UITestApp.launch(seed: "library")
        let card = app.waitFor(AX.Library.card(1), timeout: 20)
        card.swipeLeft()
        // iOS 27 does not always carry the swipe button's identifier into the tree; fall back to its title.
        let delete = app.element(AX.Library.cardDelete(1))
        let deleteButton = delete.waitForExistence(timeout: 2) ? delete : app.buttons["Delete"].firstMatch
        XCTAssertTrue(deleteButton.waitForExistence(timeout: 5), "Swipe should reveal Delete")
        deleteButton.press()
        app.waitFor(AX.Library.deleteConfirm).press()
        app.assertCount(2, of: AX.Library.card)
    }

    @MainActor func testSwipeFavourite() {
        let app = UITestApp.launch(seed: "library")
        let card = app.waitFor(AX.Library.card(0), timeout: 20)
        card.swipeRight()
        // A short swipe reveals the leading action; a full swipe runs it straight away.
        let favourite = app.element(AX.Library.cardFavourite(0))
        let favouriteButton = favourite.waitForExistence(timeout: 2) ? favourite : app.buttons["Favourite"].firstMatch
        if favouriteButton.waitForExistence(timeout: 2), favouriteButton.isHittable { favouriteButton.press() }
        app.element(AX.Library.filter("favourites")).press()
        app.assertCount(2, of: AX.Library.card)
    }

    @MainActor func testSettingsAndVoicesButtonsNavigate() {
        let app = UITestApp.launch(seed: "library")
        app.waitFor(AX.Library.settingsButton, timeout: 20).press()
        app.waitFor(AX.Settings.screen)
        app.goBack()
        app.waitFor(AX.Library.voicesButton).press()
        app.waitFor(AX.Voices.screen)
        app.goBack()
        app.waitFor(AX.Library.screen)
    }
}
