# LazyKit Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a self-contained `LazyKit` Swift package with a configurable expanding placeholder text input (`LazyTextField`), local iOS SwiftUI demo app, Swift Testing coverage, and UI tests.

**Architecture:** The repository root is the Swift package. Its single library target contains the public `LazyTextField` view and nested `Configuration`, while its test target exercises the character-limit helper and configuration defaults. A separate `Demo/LazyKitDemo.xcodeproj` references the package root as a local Swift package dependency and contains the SwiftUI sample app plus an XCUITest target.

**Tech Stack:** Swift 6.3, SwiftUI, Swift Package Manager, Swift Testing, Xcode 26.6, XCTest/XCUITest.

**Spec:** `docs/superpowers/specs/2026-09-01-lazykit-design.md`

## Global Constraints

- Package platforms: iOS 16 and later, macOS 13 and later.
- The control remains multi-line and uses `TextField(axis: .vertical)` with a configurable minimum line count.
- Placeholder is a non-interactive overlay shown only while the bound text is empty.
- Character limiting is optional; positive limits clamp input, while nil and non-positive limits leave input unchanged.
- The package has no external dependencies.
- Tests use Swift Testing for package behavior and XCUITest for demo interaction.
- Preserve the supplied copyright header; do not add an unrequested software license.

---

### Task 1: Create package metadata and failing Swift Testing cases

**Files:**
- Create: `Package.swift`
- Create: `Tests/LazyKitTests/LazyKitTests.swift`

**Interfaces:**
- Produces the package product `LazyTextField`, target `LazyTextField`, and test target `LazyKitTests`.
- Defines the test-facing expected internal helper signature `limitedText(_:characterLimit:) -> String`.

- [x] **Step 1: Create the package manifest**

Create `Package.swift` with Swift tools 6.0, iOS 16/macOS 13 platforms, one library product, one target at `Sources/LazyKit`, and one test target depending on `LazyTextField`.

```swift
// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "LazyKit",
    platforms: [
        .iOS(.v16),
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "LazyKit",
            targets: ["LazyKit"]
        )
    ],
    targets: [
        .target(name: "LazyKit"),
        .testTarget(
            name: "LazyKitTests",
            dependencies: ["LazyKit"]
        )
    ]
)
```

- [x] **Step 2: Write the failing Swift Testing cases before production implementation**

Create `Tests/LazyKitTests/LazyKitTests.swift`:

```swift
import Testing
@testable import LazyKit

struct LazyKitTests {
    @Test("leaves text unchanged when no limit is configured")
    func noCharacterLimitLeavesTextUnchanged() {
        #expect(limitedText("A long note", characterLimit: nil) == "A long note")
    }

    @Test("leaves text unchanged when it fits the limit")
    func textWithinCharacterLimitIsUnchanged() {
        #expect(limitedText("Hello", characterLimit: 5) == "Hello")
    }

    @Test("clamps text that exceeds the limit")
    func textOverCharacterLimitIsClamped() {
        #expect(limitedText("Hello world", characterLimit: 5) == "Hello")
    }

    @Test("treats non-positive limits as unlimited")
    func nonPositiveCharacterLimitDoesNotTruncateText() {
        #expect(limitedText("Hello", characterLimit: 0) == "Hello")
        #expect(limitedText("Hello", characterLimit: -1) == "Hello")
    }

    @Test("default configuration exposes the documented baseline")
    func defaultConfigurationHasExpectedLayoutValues() {
        let configuration = LazyTextField.Configuration.default

        #expect(configuration.minimumNumberOfLines == 4)
        #expect(configuration.borderWidth == 1)
        #expect(configuration.cornerRadius == 8)
        #expect(configuration.padding.top == 8)
        #expect(configuration.padding.leading == 12)
    }

    @Test("configuration values can be customized")
    func configurationCanBeCustomized() {
        var configuration = LazyTextField.Configuration.default
        configuration.minimumNumberOfLines = 2
        configuration.borderWidth = 0

        #expect(configuration.minimumNumberOfLines == 2)
        #expect(configuration.borderWidth == 0)
    }
}
```

- [x] **Step 3: Run the focused test command and verify the expected RED result**

Run:

```bash
swift test --filter LazyKitTests
```

Expected: FAIL because the package target has not yet defined `LazyTextField` or `limitedText`. If SwiftPM reports the target has no source files before compiling tests, add no behavior; proceed to the next task and implement the missing source.

---

### Task 2: Implement the self-contained library and turn the tests green

**Files:**
- Create: `Sources/LazyKit/LazyKit.swift`
- Create: `Sources/LazyKit/LazyKit+Configuration.swift`
- Modify: `Tests/LazyKitTests/LazyKitTests.swift` only if compiler diagnostics require a syntax correction without changing assertions

**Interfaces:**
- Consumes: `Binding<String>`, optional placeholder, optional positive character limit, and `Configuration`.
- Produces: public `LazyTextField`, public `LazyTextField.Configuration`, and internal `limitedText(_:characterLimit:)` used by the view and tests.

- [x] **Step 1: Add the minimal production implementation**

Create `Sources/LazyKit/LazyKit.swift`:

```swift
// Copyright (c) Rafat Touqir

import SwiftUI

internal func limitedText(_ newValue: String, characterLimit: Int?) -> String {
    guard let characterLimit, characterLimit > 0 else {
        return newValue
    }

    return String(newValue.prefix(characterLimit))
}

public struct LazyTextField: View {
    private let placeholder: String?
    @Binding private var text: String
    private let configuration: Configuration
    private let characterLimit: Int?

    public init(
        placeholder: String? = nil,
        text: Binding<String>,
        configuration: Configuration = .default,
        characterLimit: Int? = nil
    ) {
        self.placeholder = placeholder
        self._text = text
        self.configuration = configuration
        self.characterLimit = characterLimit
    }

    public var body: some View {
        ZStack(alignment: .topLeading) {
            TextField(
                "",
                text: Binding(
                    get: { limitedText(text, characterLimit: characterLimit) },
                    set: { text = limitedText($0, characterLimit: characterLimit) }
                ),
                axis: .vertical
            )
            .textFieldStyle(.plain)
            .lineLimit(max(1, configuration.minimumNumberOfLines)...)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .foregroundStyle(configuration.textColor)
            .accessibilityIdentifier("lazy_text_field")

            if let placeholder, text.isEmpty {
                Text(placeholder)
                    .foregroundStyle(configuration.placeholderColor)
                    .allowsHitTesting(false)
                    .accessibilityIdentifier("lazy_text_field_placeholder")
            }
        }
        .font(configuration.font)
        .padding(configuration.padding)
        .background(configuration.backgroundColor)
        .clipShape(RoundedRectangle(cornerRadius: max(0, configuration.cornerRadius)))
        .overlay {
            RoundedRectangle(cornerRadius: max(0, configuration.cornerRadius))
                .stroke(
                    configuration.borderColor,
                    lineWidth: max(0, configuration.borderWidth)
                )
        }
    }
}
```

Create `Sources/LazyKit/LazyKit+Configuration.swift`:

```swift
import SwiftUI

public extension LazyTextField {
    struct Configuration {
        public var font: Font
        public var textColor: Color
        public var placeholderColor: Color
        public var backgroundColor: Color
        public var borderColor: Color
        public var borderWidth: CGFloat
        public var cornerRadius: CGFloat
        public var padding: EdgeInsets
        public var minimumNumberOfLines: Int

        public init(
            font: Font = .body,
            textColor: Color = .primary,
            placeholderColor: Color = .secondary,
            backgroundColor: Color = .clear,
            borderColor: Color = Color.secondary.opacity(0.35),
            borderWidth: CGFloat = 1,
            cornerRadius: CGFloat = 8,
            padding: EdgeInsets = EdgeInsets(
                top: 8,
                leading: 12,
                bottom: 8,
                trailing: 12
            ),
            minimumNumberOfLines: Int = 4
        ) {
            self.font = font
            self.textColor = textColor
            self.placeholderColor = placeholderColor
            self.backgroundColor = backgroundColor
            self.borderColor = borderColor
            self.borderWidth = borderWidth
            self.cornerRadius = cornerRadius
            self.padding = padding
            self.minimumNumberOfLines = minimumNumberOfLines
        }

        public static var `default`: Configuration {
            Configuration()
        }
    }
}
```

- [x] **Step 2: Run the focused tests and verify GREEN**

Run:

```bash
swift test --filter LazyKitTests
```

Expected: PASS for all six Swift Testing cases, with no references to the removed private dependencies.

- [x] **Step 3: Run the complete package test suite**

Run:

```bash
swift test
```

Expected: PASS with the `LazyKitTests` test suite.

---

### Task 3: Add package documentation and consumer usage example

**Files:**
- Create: `README.md`

**Interfaces:**
- Documents the public product name `LazyTextField`, initializer, configuration customization, character-limit semantics, local package usage, and Git URL usage.

- [x] **Step 1: Write the README with the runnable API example**

Create `README.md`:

```markdown
# LazyKit

`LazyTextField` is a SwiftUI multi-line text input with a UIKit-style placeholder. It grows as the user types and keeps its placeholder visible while the text is empty.

## Requirements

- iOS 16+
- macOS 13+
- Swift 6+

## Installation

In Xcode, choose **File > Add Package Dependencies…** and add the repository URL. For local development, add the repository directory as a local package dependency.

The repository URL is `https://github.com/rafattouqir/LazyKit.git`.

Then import the product:

```swift
import LazyKit
```

## Basic usage

```swift
struct NotesView: View {
    @State private var note = ""

    var body: some View {
        LazyTextField(
            placeholder: "Write a note…",
            text: $note
        )
    }
}
```

## Custom appearance

```swift
var configuration = LazyTextField.Configuration.default
configuration.font = .body
configuration.textColor = .primary
configuration.placeholderColor = .secondary
configuration.backgroundColor = Color.blue.opacity(0.08)
configuration.borderColor = .blue
configuration.borderWidth = 1
configuration.cornerRadius = 12
configuration.padding = EdgeInsets(top: 10, leading: 14, bottom: 10, trailing: 14)
configuration.minimumNumberOfLines = 3

LazyTextField(
    placeholder: "Describe the issue…",
    text: $note,
    configuration: configuration
)
```

## Character limit

Pass `characterLimit` to clamp input. The package does not show a toast or error message; consumers can render their own counter or validation UI.

```swift
LazyTextField(
    placeholder: "Short note…",
    text: $note,
    characterLimit: 200
)
```
```

- [x] **Step 2: Check the README example against the package API**

Run:

```bash
swift test
```

Expected: PASS; the documentation-only change must not alter package behavior.

---

### Task 4: Create the local SwiftUI demo project and failing UI test

**Files:**
- Create: `Demo/LazyKitDemo.xcodeproj/project.pbxproj`
- Create: `Demo/LazyKitDemoUITests/LazyKitDemoUITests.swift`

**Interfaces:**
- Produces an iOS app scheme named `LazyKitDemo` and UI test target `LazyKitDemoUITests`.
- The Xcode project references the repository root as a local Swift package and links product `LazyTextField` to the app target.
- The UI test expects text fields with accessibility identifier `lazy_text_field` and placeholder text with identifier `lazy_text_field_placeholder`.

- [x] **Step 1: Create the Xcode project structure and target settings**

Create a minimal Xcode project with these target settings:

```text
App target: LazyKitDemo
  PRODUCT_BUNDLE_IDENTIFIER = com.lazykit.demo
  PRODUCT_NAME = LazyKitDemo
  SWIFT_VERSION = 6.0
  IPHONEOS_DEPLOYMENT_TARGET = 16.0
  TARGETED_DEVICE_FAMILY = 1,2
  GENERATE_INFOPLIST_FILE = YES

UI test target: LazyKitDemoUITests
  PRODUCT_BUNDLE_IDENTIFIER = com.lazykit.demo.uitests
  SWIFT_VERSION = 6.0
  IPHONEOS_DEPLOYMENT_TARGET = 16.0
  TARGETED_DEVICE_FAMILY = 1,2
  TEST_TARGET_NAME = LazyKitDemo
```

Add a package reference whose relative path is `..` (resolved from the `Demo` directory), add product dependency `LazyTextField` to the app target, and create the app/UI-test file references before adding their source implementations.

- [x] **Step 2: Write the failing UI tests before demo implementation**

Create `Demo/LazyKitDemoUITests/LazyKitDemoUITests.swift`:

```swift
import XCTest

@MainActor
final class LazyKitDemoUITests: XCTestCase {
    func testPlaceholderDisappearsAfterTyping() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.lazykit.demo")
        app.launch()

        let placeholder = app.staticTexts["lazy_text_field_placeholder"]
        XCTAssertTrue(placeholder.waitForExistence(timeout: 5))

        let field = app.textFields["lazy_text_field"].firstMatch
        XCTAssertTrue(field.exists)
        field.tap()
        field.typeText("Hello")

        XCTAssertFalse(placeholder.exists)
    }

    func testCharacterLimitedFieldClampsInput() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.lazykit.demo")
        app.launch()

        let field = app.textFields.matching(identifier: "lazy_text_field").element(boundBy: 3)
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText(String(repeating: "a", count: 40))

        let counter = app.staticTexts["limited_character_count"]
        XCTAssertTrue(counter.waitForExistence(timeout: 5))

        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", "20/20"),
            object: counter
        )
        XCTAssertEqual(
            XCTWaiter().wait(for: [expectation], timeout: 5),
            .completed
        )
    }
}
```

- [x] **Step 3: Run the demo UI-test command and verify the expected RED result**

Run against an available iOS simulator:

```bash
xcodebuild -project Demo/LazyKitDemo.xcodeproj \
  -scheme LazyKitDemo \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  test
```

Expected: FAIL because the demo app source files have not yet been added. If the named simulator is unavailable, use the exact name returned by `xcrun simctl list devices available` without changing the test assertions.

---

### Task 5: Implement the demo app and SwiftUI previews

**Files:**
- Create: `Demo/LazyKitDemo/LazyKitDemoApp.swift`
- Create: `Demo/LazyKitDemo/ContentView.swift`
- Modify: `Demo/LazyKitDemo.xcodeproj/project.pbxproj` to include the source files and package product dependency

**Interfaces:**
- Consumes: public `LazyTextField` package product and its `Configuration` API.
- Produces: a runnable iOS SwiftUI demo with one empty placeholder field, one populated multi-line field, one customized field, one 20-character field, and previews.

- [x] **Step 1: Add the app entry point**

Create `Demo/LazyKitDemo/LazyKitDemoApp.swift`:

```swift
import SwiftUI

@main
struct LazyKitDemoApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
```

- [x] **Step 2: Add the demo screen and preview fixtures**

Create `Demo/LazyKitDemo/ContentView.swift`:

```swift
import LazyKit
import SwiftUI

struct ContentView: View {
    @State private var basicText = ""
    @State private var populatedText = "This field starts with multiple lines.\nKeep typing to see it grow."
    @State private var customizedText = "A custom configuration"
    @State private var limitedText = ""

    private var customizedConfiguration: LazyTextField.Configuration {
        var configuration = .default
        configuration.placeholderColor = .orange
        configuration.backgroundColor = Color.orange.opacity(0.08)
        configuration.borderColor = .orange
        configuration.cornerRadius = 14
        configuration.minimumNumberOfLines = 3
        return configuration
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    DemoSection(title: "Basic placeholder") {
                        LazyTextField(
                            placeholder: "Start typing…",
                            text: $basicText
                        )
                    }

                    DemoSection(title: "Multi-line content") {
                        LazyTextField(
                            placeholder: "Add more detail…",
                            text: $populatedText
                        )
                    }

                    DemoSection(title: "Custom configuration") {
                        LazyTextField(
                            placeholder: "Customize the appearance…",
                            text: $customizedText,
                            configuration: customizedConfiguration
                        )
                    }

                    DemoSection(title: "Character limit") {
                        LazyTextField(
                            placeholder: nil,
                            text: $limitedText,
                            characterLimit: 20
                        )

                        HStack {
                            Text("Maximum 20 characters")
                            Spacer()
                            Text("\(limitedText.count)/20")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
                .padding()
            }
            .navigationTitle("LazyKit")
        }
    }
}

private struct DemoSection<Content: View>: View {
    private let title: LocalizedStringKey
    private let content: Content

    init(title: LocalizedStringKey, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            content
        }
    }
}

#Preview("Demo") {
    ContentView()
}

#Preview("Empty") {
    PreviewContainer(text: "")
}

#Preview("Populated") {
    PreviewContainer(text: "A populated preview\nwith multiple lines")
}

private struct PreviewContainer: View {
    @State private var text: String

    init(text: String) {
        _text = State(initialValue: text)
    }

    var body: some View {
        LazyTextField(
            placeholder: "Preview placeholder…",
            text: $text
        )
        .padding()
    }
}
```

- [x] **Step 3: Run Swift package tests and build the demo app**

Run:

```bash
swift test
xcodebuild -project Demo/LazyKitDemo.xcodeproj \
  -scheme LazyKitDemo \
  -destination 'generic/platform=iOS Simulator' \
  build
```

Expected: package tests PASS and the demo app build PASS with the local `LazyTextField` product resolved from `..`.

- [x] **Step 4: Run the UI tests and verify GREEN**

Run:

```bash
xcodebuild -project Demo/LazyKitDemo.xcodeproj \
  -scheme LazyKitDemo \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  test
```

Expected: both UI tests PASS. The placeholder test must observe the placeholder before typing and its disappearance afterward; the character-limit test must observe the demo counter reach `20/20` after oversized input.

---

### Task 6: Add repository hygiene, local remote, and final verification

**Files:**
- Create: `.gitignore`
- Modify: `README.md` only if verification reveals an incorrect command or path
- Modify: Git configuration to add `origin` as `git@github.com:rafattouqir/LazyKit.git`

**Interfaces:**
- Produces a clean repository layout that excludes Xcode/Swift build artifacts and records the supplied GitHub repository as the local origin without pushing.

- [x] **Step 1: Add Swift/Xcode ignore rules**

Create `.gitignore`:

```gitignore
.DS_Store
.build/
DerivedData/
*.xcuserstate
xcuserdata/
```

- [x] **Step 2: Add the supplied GitHub URL as the local origin**

Run:

```bash
git remote add origin git@github.com:rafattouqir/LazyKit.git
```

Expected: `git remote -v` reports the supplied fetch and push URL. Do not push or change repository visibility.

- [x] **Step 3: Run final static and behavioral verification**

Run:

```bash
git diff --check
swift test
xcodebuild -project Demo/LazyKitDemo.xcodeproj \
  -scheme LazyKitDemo \
  -destination 'generic/platform=iOS Simulator' \
  build
git status --short
```

Expected: no whitespace errors, Swift Testing PASS, demo build PASS, and only intended source/documentation/project files reported by Git.

- [x] **Step 4: Commit the implementation**

Run:

```bash
git add .gitignore Package.swift Sources Tests Demo README.md
git commit -m "feat: add open source LazyKit package and demo"
```

Expected: a local commit containing the package, demo app, tests, and documentation. Leave the commit local; do not push to GitHub.
