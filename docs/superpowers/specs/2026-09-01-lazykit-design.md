# LazyKit Design Specification

## Goal

Create a self-contained Swift Package Manager library named `LazyKit` that provides a customizable, expanding SwiftUI text input (`LazyTextField`) with a UIKit-style placeholder, plus a runnable iOS SwiftUI demo app that consumes the package locally.

## Scope

The package is based on the supplied `TextEditorView.swift` behavior. The control remains multi-line and grows with its content. Its placeholder is visible while the bound text is empty and disappears when the user enters text. The animated border and package-owned toast are removed.

Character limiting remains supported as an optional behavior. When a user enters more than the configured limit, the binding is synchronously clamped to the first `characterLimit` characters. The library does not display a toast or other package-owned error UI.

## Architecture

The repository contains one Swift package and one separate Xcode demo project:

```text
LazyKit/
├── Package.swift
├── Sources/LazyKit/
├── Tests/LazyKitTests/
├── Demo/LazyKitDemo.xcodeproj/
├── Demo/LazyKitDemo/
└── README.md
```

The package exposes one library product, `LazyKit`, with no external dependencies. The demo app references the repository root as a relative local package dependency and imports the library product, proving the package integration path used during development.

The package supports iOS 16 and later and macOS 13 and later. The demo is an iOS SwiftUI application with previews for the empty, populated, customized, and character-limited states.

## Public API

The primary view is:

```swift
public struct LazyTextField: View {
    public init(
        placeholder: String? = nil,
        text: Binding<String>,
        configuration: Configuration = .default,
        characterLimit: Int? = nil
    )
}
```

`LazyTextField.Configuration` is public, mutable, and self-contained:

```swift
public struct Configuration {
    public var font: Font
    public var textColor: Color
    public var placeholderColor: Color
    public var backgroundColor: Color
    public var borderColor: Color
    public var borderWidth: CGFloat
    public var cornerRadius: CGFloat
    public var padding: EdgeInsets
    public var minimumNumberOfLines: Int

    public static let `default`: Configuration
}
```

The default configuration uses system SwiftUI values (`.body`, `.primary`, `.secondary`, `.clear`, and a secondary-color border with reduced opacity`) and conservative layout values. Consumers can copy and modify it:

```swift
var configuration = LazyTextField.Configuration.default
configuration.placeholderColor = .orange
configuration.minimumNumberOfLines = 3

LazyTextField(
    placeholder: "Write a note…",
    text: $text,
    configuration: configuration
)
```

The legacy `isAnimating`, `characterLimitExceededMessage`, `AnimatedBorderView`, theme types, typography types, layout types, toast types, and `TextEditorView` name are intentionally not part of the new public API.

## View behavior

`LazyTextField` renders a vertical-axis SwiftUI `TextField` in a top-leading `ZStack`. A non-interactive placeholder `Text` is overlaid when `text.isEmpty`. The control applies the configured font, colors, padding, minimum height, rounded clipping, background, and static border. The border is never animated.

The binding passed to the internal `TextField` setter writes values directly when no limit is configured. With a positive limit, it writes the full value when it fits and writes `String(newValue.prefix(limit))` otherwise. A non-positive limit is treated as no limit so configuration cannot make text unusable accidentally.

## Demo requirements

The demo app contains:

- A basic empty field demonstrating the placeholder.
- A populated field demonstrating multi-line content and growth.
- A customized field demonstrating configuration overrides.
- A character-limited field with a visible counter implemented by the demo app, not by the package.
- SwiftUI previews covering those states.

## Testing and verification

The package test target uses Swift Testing (`import Testing`, `@Test`, and `#expect`) and covers:

- Text remains unchanged when no character limit is configured.
- Text remains unchanged when it is within the configured limit.
- Text is clamped when it exceeds the configured limit.
- Non-positive limits do not truncate text.
- The default configuration exposes the documented baseline values.

The package is verified with `swift test`. The demo project is verified with an iOS simulator build and UI tests that launch the app, locate the text field by accessibility identifier, verify the placeholder is present initially, type text, verify the placeholder disappears, and verify the character-limited demo does not exceed its limit.

## Documentation and licensing

`README.md` documents installation by local package and Git URL, the basic initializer, configuration customization, and the behavior of the character limit. The supplied copyright header is retained in source files. No software license is invented by this change; a license should be selected before publishing the repository publicly.
