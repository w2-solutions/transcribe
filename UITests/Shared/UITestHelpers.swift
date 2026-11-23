import XCTest

// Per-platform helpers shared by every UI test, on the iPhone and the Mac (`#if os(macOS)` branches).
// Created by the skeleton and handed over to WP8. Tests wait only with `waitForExistence` and predicate
// expectations; there is no `sleep` anywhere in the UI tests.

extension XCUIElement {
    /// Tap on iOS, click on macOS.
    @MainActor func press() {
        #if os(macOS)
        click()
        #else
        tap()
        #endif
    }

    /// The visible text of an element: `label` on iOS, `value` on macOS (a button's text stays in `label`).
    @MainActor var textValue: String {
        #if os(macOS)
        if let text = value as? String, !text.isEmpty { return text }
        return label
        #else
        label
        #endif
    }

    /// The on/off state of a switch (SwiftUI `Toggle`): its value is "1" or "0" (a number on macOS).
    @MainActor var isOn: Bool {
        let value = toggleControl.value
        if let number = value as? NSNumber { return number.boolValue }
        return (value as? String) == "1"
    }

    /// The switch itself: this element, or the switch (Mac: a switch or a checkbox) inside it.
    @MainActor var toggleControl: XCUIElement {
        if elementType == .switch || elementType == .checkBox { return self }
        #if os(macOS)
        let inner = switches.firstMatch
        return inner.exists ? inner : checkBoxes.firstMatch
        #else
        return switches.firstMatch
        #endif
    }

    /// Flips a SwiftUI `Toggle`. The identifier can land on the row or on the switch; either way the switch
    /// itself is tapped, because tapping the centre of a full-width row misses the control.
    @MainActor func flipSwitch() {
        let target = toggleControl
        #if os(macOS)
        target.click()
        #else
        // The thumb sits at the trailing edge of the switch element.
        target.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        #endif
    }
}

extension XCUIApplication {
    /// Any element with this accessibility identifier, whatever its type. iOS 27 sometimes exposes the same
    /// identifier twice (a confirmation-dialog button nested in a button), so this takes the first match.
    @MainActor func element(_ id: String) -> XCUIElement {
        descendants(matching: .any).matching(identifier: id).firstMatch
    }

    /// Waits for the element with this identifier; fails the test if it never appears.
    @MainActor @discardableResult
    func waitFor(_ id: String, timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        let e = element(id)
        XCTAssertTrue(e.waitForExistence(timeout: timeout), "Timed out waiting for \(id)", file: file, line: line)
        return e
    }

    /// Waits for the element with this identifier to go away; fails the test if it stays.
    @MainActor func waitForGone(_ id: String, timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line) {
        let e = element(id)
        XCTAssertTrue(e.waitForNonExistence(timeout: timeout), "\(id) is still on screen", file: file, line: line)
    }

    /// Asserts that a numbered list (`id(0)`, `id(1)`, …) shows exactly `count` rows.
    @MainActor func assertCount(_ count: Int, of id: (Int) -> String, timeout: TimeInterval = 10,
                                file: StaticString = #filePath, line: UInt = #line) {
        if count > 0 {
            XCTAssertTrue(element(id(count - 1)).waitForExistence(timeout: timeout),
                          "Expected \(id(count - 1)) to exist", file: file, line: line)
        }
        XCTAssertTrue(element(id(count)).waitForNonExistence(timeout: timeout),
                      "Expected no \(id(count)) (more than \(count) rows)", file: file, line: line)
    }

    /// Scrolls the frontmost scroll view until the element is hittable (or gives up after `maxSwipes`).
    /// On the Mac it scrolls with the wheel over the scroll view that holds the element (or the window).
    @MainActor @discardableResult
    func scrollTo(_ id: String, maxSwipes: Int = 8, up: Bool = true, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        let e = element(id)
        var swipes = 0
        while !(e.exists && e.isHittable) && swipes < maxSwipes {
            #if os(macOS)
            let scrollView = scrollViews.containing(.any, identifier: id).firstMatch
            let target = scrollView.exists ? scrollView : windows.firstMatch
            target.scroll(byDeltaX: 0, deltaY: up ? -300 : 300)
            #else
            if up { swipeUp(velocity: .slow) } else { swipeDown(velocity: .slow) }
            #endif
            swipes += 1
        }
        XCTAssertTrue(e.exists && e.isHittable, "Could not scroll to \(id)", file: file, line: line)
        return e
    }

    /// Opens a Library card by its title area (the centre can land on a speaker chip or the name link).
    @MainActor func openCard(_ i: Int, file: StaticString = #filePath, line: UInt = #line) {
        let card = waitFor(AX.Library.card(i), file: file, line: line)
        #if os(macOS)
        card.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.15)).click()
        #else
        card.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.15)).tap()
        #endif
    }

    /// iPhone: taps the navigation bar's back button. Mac: pops the detail column with ⌘[ when it has pushed a
    /// screen, otherwise clicks the sidebar item that is selected now (back to its list).
    @MainActor func goBack() {
        #if os(macOS)
        let selected = outlines.firstMatch.descendants(matching: .any)
            .matching(NSPredicate(format: "isSelected == true")).firstMatch
        if selected.exists {
            selected.click()
        } else {
            typeKey("[", modifierFlags: .command)
        }
        #else
        navigationBars.buttons.element(boundBy: 0).press()
        #endif
    }
}

/// Predicate waits on element properties (polled by XCTest; no sleeping).
@MainActor enum Wait {
    @discardableResult
    static func until(_ element: XCUIElement, _ format: String, _ args: any CVarArg..., timeout: TimeInterval = 10,
                      _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) -> Bool {
        let predicate = NSPredicate(format: format, argumentArray: args)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        let ok = XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
        let detail = element.exists ? "label “\(element.label)”, value “\(String(describing: element.value))”" : "element missing"
        XCTAssertTrue(ok, "\(message()) — waited for \(format) \(args) on \(element.identifier); \(detail)", file: file, line: line)
        return ok
    }

    // The `label` waits read the visible text: `label` on iOS, `textValue` on macOS (a Mac static text carries
    // its string in `value`; a button keeps it in `label`, which `textValue` falls back to).

    @discardableResult
    static func label(_ element: XCUIElement, contains text: String, timeout: TimeInterval = 10,
                      file: StaticString = #filePath, line: UInt = #line) -> Bool {
        #if os(macOS)
        pollText(element, "contains", text, timeout: timeout, file: file, line: line) { $0.contains(text) }
        #else
        until(element, "exists == true AND label CONTAINS %@", text, timeout: timeout, file: file, line: line)
        #endif
    }

    @discardableResult
    static func label(_ element: XCUIElement, equals text: String, timeout: TimeInterval = 10,
                      file: StaticString = #filePath, line: UInt = #line) -> Bool {
        #if os(macOS)
        pollText(element, "==", text, timeout: timeout, file: file, line: line) { $0 == text }
        #else
        until(element, "exists == true AND label == %@", text, timeout: timeout, file: file, line: line)
        #endif
    }

    @discardableResult
    static func label(_ element: XCUIElement, changesFrom text: String, timeout: TimeInterval = 10,
                      file: StaticString = #filePath, line: UInt = #line) -> Bool {
        #if os(macOS)
        pollText(element, "!=", text, timeout: timeout, file: file, line: line) { $0 != text }
        #else
        until(element, "exists == true AND label != %@", text, timeout: timeout, file: file, line: line)
        #endif
    }

    #if os(macOS)
    private static func pollText(_ element: XCUIElement, _ op: String, _ expected: String, timeout: TimeInterval,
                                 file: StaticString, line: UInt, matches: @escaping (String) -> Bool) -> Bool {
        check(element, "text \(op) “\(expected)”", timeout: timeout, file: file, line: line) { matches($0.textValue) }
    }
    #endif

    /// Polls until `condition` holds for the element (a block predicate, for properties a format string cannot
    /// compare, such as a Mac switch's numeric `value`). Fails the test on timeout.
    @discardableResult
    static func check(_ element: XCUIElement, _ description: String, timeout: TimeInterval = 10,
                      file: StaticString = #filePath, line: UInt = #line,
                      _ condition: @escaping @MainActor (XCUIElement) -> Bool) -> Bool {
        let predicate = NSPredicate { _, _ in
            MainActor.assumeIsolated { element.exists && condition(element) }
        }
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: nil)
        let ok = XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
        let detail = element.exists ? "text “\(element.textValue)”, value “\(String(describing: element.value))”" : "element missing"
        XCTAssertTrue(ok, "Waited for \(description) on \(element.identifier); \(detail)", file: file, line: line)
        return ok
    }

    /// Waits for a switch (SwiftUI `Toggle`) to read on or off, whatever type its value has.
    @discardableResult
    static func switchState(_ element: XCUIElement, on: Bool, timeout: TimeInterval = 10,
                            file: StaticString = #filePath, line: UInt = #line) -> Bool {
        check(element, on ? "switch on" : "switch off", timeout: timeout, file: file, line: line) { $0.isOn == on }
    }

    @discardableResult
    static func value(_ element: XCUIElement, equals text: String, timeout: TimeInterval = 10,
                      file: StaticString = #filePath, line: UInt = #line) -> Bool {
        until(element, "exists == true AND value == %@", text, timeout: timeout, file: file, line: line)
    }

    @discardableResult
    static func enabled(_ element: XCUIElement, _ enabled: Bool, timeout: TimeInterval = 10,
                        file: StaticString = #filePath, line: UInt = #line) -> Bool {
        until(element, "exists == true AND enabled == %@", NSNumber(value: enabled), timeout: timeout, file: file, line: line)
    }
}

/// Every flow test stops at its first failure (XCTest attaches a screenshot of that moment).
class FlowTestCase: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }
}
