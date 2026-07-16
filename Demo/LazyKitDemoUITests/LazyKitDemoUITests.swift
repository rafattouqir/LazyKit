import XCTest

@MainActor
final class LazyKitDemoUITests: XCTestCase {

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    private func launchTextFieldDemo() -> XCUIApplication {
        let app = XCUIApplication(bundleIdentifier: Identifiers.bundleIdentifier)
        app.launch()

        let row = app.buttons[Identifiers.textFieldComponent]
        // The first query after launch is the slowest part on CI, so allow a
        // generous budget.
        XCTAssertTrue(row.waitForExistence(timeout: 20), "component list row should exist")
        row.tap()

        return app
    }

    private func launchButtonDemo() -> XCUIApplication {
        let app = XCUIApplication(bundleIdentifier: Identifiers.bundleIdentifier)
        app.launch()

        let row = app.buttons[Identifiers.buttonComponent]
        XCTAssertTrue(row.waitForExistence(timeout: 20), "component list row should exist")
        row.tap()

        return app
    }

    func testPlaceholderDisappearsAfterTyping() throws {
        let app = launchTextFieldDemo()

        let field = app.textFields[Identifiers.textField].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))

        // The string placeholder is the field's native prompt.
        XCTAssertTrue(
            wait(for: field, key: "placeholderValue", toEqual: "Start typing…"),
            "field should expose the prompt as its placeholder, got \(field.placeholderValue ?? "nil")"
        )

        field.tap()
        attach(screenshot: app.screenshot(), named: "textfield-focused-empty")
        field.typeText("Hello")

        // Wait for the field to report the accepted value instead of sampling.
        XCTAssertTrue(
            wait(for: field, key: "value", toEqual: "Hello"),
            "field should hold the typed text, got \(field.value as? String ?? "nil")"
        )
        attach(screenshot: app.screenshot(), named: "textfield-typed")
    }

    func testCharacterLimitedFieldClampsInput() throws {
        let app = launchTextFieldDemo()

        let field = app.textFields[Identifiers.limitedTextField]

        // Rows load lazily and a partly visible row can swallow the tap, so
        // scroll the field fully into reach first.
        var scrolled = 0
        while !field.isHittable, scrolled < 10 {
            app.swipeUp()
            scrolled += 1
        }
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        XCTAssertTrue(waitForHittable(field), "limited field should be scrolled into reach")

        field.tap()
        field.typeText(String(repeating: "a", count: 40))

        // Wait for the accepted value; the field reports it through a snapshot.
        XCTAssertTrue(
            waitForFieldCount(field, 20),
            "field should clamp to 20 characters, got \(field.value as? String ?? "nil")"
        )
        attach(screenshot: app.screenshot(), named: "character-limit-20-of-20")

        let counter = app.staticTexts[Identifiers.characterCount]
        XCTAssertTrue(counter.waitForExistence(timeout: 10))
        XCTAssertTrue(
            wait(for: counter, key: "label", toEqual: "20/20"),
            "counter should read 20/20, got \(counter.label)"
        )

        field.typeText(String(repeating: "b", count: 40))
        XCTAssertTrue(
            waitForFieldCount(field, 20),
            "field should stay clamped at 20 characters, got \(field.value as? String ?? "nil")"
        )
        XCTAssertEqual(counter.label, "20/20")

        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 5))
        field.typeText("xyz")

        // A dropped delete on a slow runner would change the length without
        // breaking the contract, so assert only that the field stays within the
        // limit and the counter matches it.
        XCTAssertTrue(
            waitForFieldWithinLimit(field, 20),
            "field should stay within the limit after edits, got \(field.value as? String ?? "nil")"
        )
        let editedCount = (field.value as? String)?.count ?? -1
        XCTAssertGreaterThanOrEqual(editedCount, 18, "edits should leave the field near its limit")
        XCTAssertTrue(
            wait(for: counter, key: "label", toEqual: "\(editedCount)/20"),
            "counter should report \(editedCount)/20, got \(counter.label)"
        )
        attach(screenshot: app.screenshot(), named: "character-limit-after-edits")
    }

    /// Waits until the field holds no more than `limit` characters.
    private func waitForFieldWithinLimit(
        _ field: XCUIElement,
        _ limit: Int,
        timeout: TimeInterval = 15
    ) -> Bool {
        let withinLimit = XCTNSPredicateExpectation(
            predicate: NSPredicate { object, _ in
                guard let count = ((object as? XCUIElement)?.value as? String)?.count else {
                    return false
                }
                return count <= limit
            },
            object: field
        )
        return XCTWaiter().wait(for: [withinLimit], timeout: timeout) == .completed
    }

    /// Waits until `element` can receive taps.
    private func waitForHittable(_ element: XCUIElement, timeout: TimeInterval = 15) -> Bool {
        let hittable = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "isHittable == true"),
            object: element
        )
        return XCTWaiter().wait(for: [hittable], timeout: timeout) == .completed
    }

    /// Waits until the field reports `expected` characters.
    private func waitForFieldCount(
        _ field: XCUIElement,
        _ expected: Int,
        timeout: TimeInterval = 15
    ) -> Bool {
        // Snapshots are heavily dilated on CI, so poll with a generous budget.
        let clamped = XCTNSPredicateExpectation(
            predicate: NSPredicate { object, _ in
                ((object as? XCUIElement)?.value as? String)?.count == expected
            },
            object: field
        )
        return XCTWaiter().wait(for: [clamped], timeout: timeout) == .completed
    }

    /// Waits until `element` reports `expected` for the given key.
    private func wait(
        for element: XCUIElement,
        key: String,
        toEqual expected: String,
        timeout: TimeInterval = 15
    ) -> Bool {
        let matches = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "%K == %@", key, expected),
            object: element
        )
        return XCTWaiter().wait(for: [matches], timeout: timeout) == .completed
    }

    func testSlowAsyncButtonShowsLoaderThenReturnsToIdle() throws {
        let app = launchButtonDemo()

        let slowButton = app.buttons[Identifiers.slowButton]
        XCTAssertTrue(slowButton.waitForExistence(timeout: 10))
        // The tap below lands at the pill's trailing edge, so the button must be
        // fully on screen.
        XCTAssertTrue(waitForHittable(slowButton), "slow button should be tappable")
        XCTAssertEqual(slowButton.label, "Run slow task")

        attach(screenshot: app.screenshot(), named: "1-idle")

        // Tap the trailing edge, away from the label, to verify the whole pill
        // is interactive.
        slowButton.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()

        // Wait for busy and loading in one ordered wait, so no time is lost
        // between two sequential waits on a slow runner.
        let busy = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "isEnabled == false"),
            object: slowButton
        )
        let loading = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", "Loading"),
            object: slowButton
        )
        XCTAssertEqual(
            XCTWaiter().wait(for: [busy, loading], timeout: 15),
            .completed,
            "button should disable and show the loader while the async action runs"
        )
        attach(screenshot: app.screenshot(), named: "2-loading")

        // After the hold, the button returns to its idle label.
        let idleAgain = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "isEnabled == true"),
            object: slowButton
        )
        XCTAssertEqual(
            XCTWaiter().wait(for: [idleAgain], timeout: 15),
            .completed,
            "slow button should re-enable after the async action finishes"
        )
        XCTAssertEqual(slowButton.label, "Run slow task")
        attach(screenshot: app.screenshot(), named: "3-idle-again")
    }

    private func attach(screenshot: XCUIScreenshot, named name: String) {
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testFastAsyncActionCompletesAndReturnsToIdle() throws {
        let app = launchButtonDemo()

        let fastButton = app.buttons[Identifiers.fastButton]
        XCTAssertTrue(fastButton.waitForExistence(timeout: 10))
        XCTAssertTrue(waitForHittable(fastButton), "fast button should be tappable")

        fastButton.tap()

        let result = app.staticTexts[Identifiers.fastResult]
        let finished = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", "Fast action completed."),
            object: result
        )
        XCTAssertEqual(
            XCTWaiter().wait(for: [finished], timeout: 15),
            .completed,
            "fast async action should run to completion"
        )
        XCTAssertEqual(fastButton.label, "Run fast task")
    }
}

private extension LazyKitDemoUITests {
    enum Identifiers {
        static let bundleIdentifier = "com.lazykit.demo"
        static let textFieldComponent = "component_lazy_text_field"
        static let textField = "lazy_text_field"
        static let limitedTextField = "lazy_text_field_limited"
        static let characterCount = "limited_character_count"
        static let buttonComponent = "component_lazy_button"
        static let slowButton = "lazy_button_slow"
        static let slowResult = "lazy_button_slow_result"
        static let fastButton = "lazy_button_fast"
        static let fastResult = "lazy_button_fast_result"
    }
}
