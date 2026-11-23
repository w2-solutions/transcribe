import XCTest

// Mac-only helpers: keyboard shortcuts, context menus, and buttons and fields whose identifier macOS does not
// always carry into the tree (confirmation dialogs and alert fields).

extension XCUIApplication {
    /// Presses a menu shortcut, such as ⌘N.
    @MainActor func shortcut(_ key: String, _ modifiers: XCUIElement.KeyModifierFlags = .command) {
        typeKey(key, modifierFlags: modifiers)
    }

    /// A button by its identifier, falling back to its title. SwiftUI on macOS does not always pass an identifier
    /// from a button inside a confirmation dialog or an alert to the accessibility tree.
    @MainActor func button(_ id: String?, title: String, timeout: TimeInterval = 5,
                           file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        if let id {
            let byID = element(id)
            if byID.waitForExistence(timeout: 1) { return byID }
        }
        // Inside a window (dialogs and sheets included), never the Touch Bar's copy of the same button.
        let byTitle = windows.buttons.matching(NSPredicate(format: "label == %@ OR title == %@", title, title)).firstMatch
        XCTAssertTrue(byTitle.waitForExistence(timeout: timeout), "No button \(id ?? "") or “\(title)”", file: file, line: line)
        return byTitle
    }

    /// The text field of the frontmost alert or sheet (its identifier, or the first field in a dialog or sheet).
    @MainActor func dialogTextField(_ id: String, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        let byID = element(id)
        if byID.waitForExistence(timeout: 2) { return byID }
        for candidate in [dialogs.textFields.firstMatch, sheets.textFields.firstMatch, alerts.textFields.firstMatch] {
            if candidate.waitForExistence(timeout: 1) { return candidate }
        }
        XCTFail("No text field \(id) in a dialog", file: file, line: line)
        return byID
    }

    /// Right-clicks an element and chooses a context-menu item; a path opens submenus on the way
    /// (["Move to folder", "Work"]).
    @MainActor func contextMenu(on target: XCUIElement, choose path: [String],
                                file: StaticString = #filePath, line: UInt = #line) {
        target.rightClick()
        for (i, title) in path.enumerated() {
            let item = menuItems[title].firstMatch
            XCTAssertTrue(item.waitForExistence(timeout: 5), "No menu item “\(title)”", file: file, line: line)
            if i < path.count - 1 { item.hover() }
            item.click()
        }
    }
}

extension XCUIElement {
    /// Whether this element has keyboard focus (macOS exposes it as the `hasKeyboardFocus` attribute).
    @MainActor var hasKeyboardFocusValue: Bool {
        (value(forKey: "hasKeyboardFocus") as? Bool) ?? false
    }
}
