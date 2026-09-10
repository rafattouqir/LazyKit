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
        XCTAssertTrue(row.waitForExistence(timeout: 5), "component list row should exist")
        row.tap()

        return app
    }

    private func launchButtonDemo() -> XCUIApplication {
        let app = XCUIApplication(bundleIdentifier: Identifiers.bundleIdentifier)
        app.launch()

        let row = app.buttons[Identifiers.buttonComponent]
        XCTAssertTrue(row.waitForExistence(timeout: 5), "component list row should exist")
        row.tap()

        return app
    }

    func testPlaceholderDisappearsAfterTyping() throws {
        let app = launchTextFieldDemo()

        let field = app.textFields[Identifiers.textField].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))

        // The built-in string placeholder is the field's native prompt.
        XCTAssertEqual(field.placeholderValue, "Start typing…")

        field.tap()
        Thread.sleep(forTimeInterval: 1.0)
        attach(screenshot: app.screenshot(), named: "textfield-focused-empty")
        field.typeText("Hello")
        Thread.sleep(forTimeInterval: 1.0)
        attach(screenshot: app.screenshot(), named: "textfield-typed")

        XCTAssertEqual(field.value as? String, "Hello")
    }

    func testCharacterLimitedFieldClampsInput() throws {
        let app = launchTextFieldDemo()

        let field = app.textFields[Identifiers.limitedTextField]

        // The limit section starts offscreen in the List, whose rows load
        // lazily, so scroll until the field exists before tapping it.
        var scrolled = 0
        while !field.exists, scrolled < 10 {
            app.swipeUp()
            scrolled += 1
        }
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText(String(repeating: "a", count: 40))

        // The clamp is live: while the field is still focused (keyboard up),
        // the value must already be capped at 20 characters.
        XCTAssertEqual((field.value as? String)?.count, 20)
        attach(screenshot: app.screenshot(), named: "character-limit-20-of-20")

        let counter = app.staticTexts[Identifiers.characterCount]
        XCTAssertTrue(counter.waitForExistence(timeout: 5))

        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", "20/20"),
            object: counter
        )
        XCTAssertEqual(
            XCTWaiter().wait(for: [expectation], timeout: 5),
            .completed
        )

        field.typeText(String(repeating: "b", count: 40))
        XCTAssertEqual((field.value as? String)?.count, 20)
        XCTAssertEqual(counter.label, "20/20")

        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 5))
        field.typeText("xyz")
        XCTAssertEqual((field.value as? String)?.count, 18)
        XCTAssertEqual(counter.label, "18/20")
        attach(screenshot: app.screenshot(), named: "character-limit-18-of-20")
    }

    func testSlowAsyncButtonShowsLoaderThenReturnsToIdle() throws {
        let app = launchButtonDemo()

        let slowButton = app.buttons[Identifiers.slowButton]
        XCTAssertTrue(slowButton.waitForExistence(timeout: 5))
        XCTAssertEqual(slowButton.label, "Run slow task")

        attach(screenshot: app.screenshot(), named: "1-idle")

        // Tap the colored background near the trailing edge, away from the
        // label, to verify the whole pill is interactive.
        slowButton.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()

        // The button immediately becomes busy and stays disabled until the
        // async action finishes and the minimum loader hold elapses.
        let busy = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "isEnabled == false"),
            object: slowButton
        )
        let busyResult = XCTWaiter().wait(for: [busy], timeout: 2)
        XCTAssertEqual(busyResult, .completed, "button should disable while the async action runs")

        // The loader overlays the hidden label, so the button exposes the
        // loader's "Loading" label while busy.
        let loading = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", "Loading"),
            object: slowButton
        )
        XCTAssertEqual(
            XCTWaiter().wait(for: [loading], timeout: 3),
            .completed,
            "loader should appear for a slow async action"
        )
        attach(screenshot: app.screenshot(), named: "2-loading")

        // Once the action finishes and the minimum loader duration elapses,
        // the button returns to its idle label and accepts taps again.
        let idleAgain = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "isEnabled == true"),
            object: slowButton
        )
        XCTAssertEqual(
            XCTWaiter().wait(for: [idleAgain], timeout: 6),
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
        XCTAssertTrue(fastButton.waitForExistence(timeout: 5))

        fastButton.tap()

        let result = app.staticTexts[Identifiers.fastResult]
        let finished = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", "Fast action completed."),
            object: result
        )
        XCTAssertEqual(
            XCTWaiter().wait(for: [finished], timeout: 5),
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
