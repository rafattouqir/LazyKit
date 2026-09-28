# LazyKit

![Tests](https://github.com/rafattouqir/LazyKit/actions/workflows/tests.yml/badge.svg)
![Lint](https://github.com/rafattouqir/LazyKit/actions/workflows/lint.yml/badge.svg)

Two small SwiftUI components that take care of the state you would otherwise
rebuild in every screen: a text field that grows with its content, and a button
whose loading state follows the work it starts.

![LazyTextField growing as it is typed into](docs/assets/lazy-text-field.gif) ![LazyButton showing a loader while its action runs](docs/assets/lazy-button.gif)

- [`LazyTextField`](#lazytextfield) reserves one line by default, grows as you
  type, and keeps its placeholder visible while empty.
- [`LazyButton`](#lazybutton) runs an async action with a loader that shows
  only when the work outlasts a threshold.

## Quick start

```swift
import LazyKit
import SwiftUI

struct NoteView: View {
    @State private var note = ""

    var body: some View {
        VStack(spacing: 16) {
            LazyTextField(text: $note, placeholder: "Write a note…")

            LazyButton("Save") {
                try? await api.save(note)
            }
        }
        .padding()
    }
}
```

## Requirements

- iOS 17+ or macOS 14+
- Swift 6 toolchain (the package uses `swift-tools-version: 6.0`)

## Installation

LazyKit follows [semantic versioning](https://semver.org), so pin a release in
`Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/rafattouqir/LazyKit.git", from: "0.1.0")
]
```

In Xcode, choose **File ▸ Add Package Dependencies…**, enter the repository
URL, and pick the version you want:

```text
https://github.com/rafattouqir/LazyKit.git
```

`from:` accepts any 0.1.x release. Use `.exact("0.1.0")` to pin the tag, or
`.branch("main")` to track unreleased changes.

Then import the product:

```swift
import LazyKit
```

To work on the package itself, add this repository as a local package
dependency, or open `Demo/LazyKitDemo.xcodeproj` and run the demo app.

## LazyTextField

A multi-line input that starts at a single line, grows with its content, and
keeps a placeholder visible while the bound text is empty.

### Basic usage

```swift
@State private var note = ""

LazyTextField(text: $note, placeholder: "Write a note…")
```

A string placeholder becomes the text field's native prompt, so the system
keeps its usual placeholder styling on every platform.

### Growth and line limits

```swift
var configuration = LazyTextFieldConfiguration.default
configuration.minimumNumberOfLines = 3
configuration.maximumNumberOfLines = 6

LazyTextField(configuration: configuration, text: $note)
```

`minimumNumberOfLines` is how many lines the field always reserves, and
defaults to `1`. `maximumNumberOfLines` caps growth: past the limit the field
stops growing and scrolls internally instead. A `nil` maximum leaves growth
uncapped, and a maximum below the minimum is treated as the minimum.

### Character limit

```swift
configuration.characterLimit = 200
```

The limit clamps typing, pasting, and parent-driven updates through the
binding, so the parent binding stays the single source of truth. The field
renders no counter or error message of its own — draw your own when you need
one.

### Styling

Appearance comes from ordinary SwiftUI modifiers:

```swift
LazyTextField(configuration: configuration, text: $note)
    .font(.body)
    .padding(EdgeInsets(top: 10, leading: 14, bottom: 10, trailing: 14))
    .background(Color.blue.opacity(0.08))
    .clipShape(RoundedRectangle(cornerRadius: 12))
```

### Custom placeholder

Pass a view builder to replace the native prompt:

```swift
LazyTextField(configuration: configuration, text: $note) {
    Text("Write a note…")
        .foregroundStyle(.blue)
}
```

The custom placeholder is drawn as an overlay on top of the field, so match
its font and insets to the field's styling on the platform you target.

## LazyButton

A button whose action is asynchronous, and whose loading state follows that
work.

### Basic usage

```swift
LazyButton("Save") {
    try? await api.save()
}
```

The action runs in a task tied to the view's lifecycle:

- Taps are ignored while the action, or the loader it raised, is still active.
- If the view disappears, cancellation is cooperative: cancellation-aware work
  stops at a suspension point, and the button resets once the action returns.
- Reappearing does not re-run the last tap.

The action handles its own errors; the button has no error UI.

### Loader timing

```swift
var configuration = LazyButtonConfiguration.default
configuration.showLoaderAfter = .milliseconds(150)
configuration.minimumLoaderDuration = .milliseconds(800)

LazyButton("Publish", configuration: configuration) {
    try? await publisher.publish()
}
```

The loader appears only if the action is still running after
`showLoaderAfter`, so quick work never flashes a spinner. If the loader is
visible when the action returns, it stays for `minimumLoaderDuration` before
the button becomes idle again. Cancellation ends that hold early.

### Custom loaders and colors

```swift
LazyButton(
    "Publish",
    configuration: configuration,
    loader: {
        Image(systemName: "circle.dotted")
            .foregroundStyle(.white)
    }
) {
    try? await publisher.publish()
}
```

Without a custom loader, the built-in spinner is tinted with
`configuration.loaderColor` (white by default), and
`configuration.loaderAnimation` controls how it appears.

### Styling

The label is rendered as supplied, so the button imposes no style of its own:

```swift
LazyButton("Publish", configuration: configuration) {
    try? await publisher.publish()
}
.font(.body.weight(.semibold))
.foregroundStyle(.white)
.frame(maxWidth: .infinity)
.padding()
.background(.indigo)
.clipShape(RoundedRectangle(cornerRadius: 12))
```

## Demo app

`Demo/LazyKitDemo.xcodeproj` builds a small app that exercises both
components — every configuration shown above lives in `Demo/LazyKitDemo/`.
Open the project, pick the `LazyKitDemo` scheme, and run it on any iOS
Simulator.

## Development

```bash
# Formatting (also enforced in CI)
swift format lint --strict --parallel --recursive Sources Tests Demo

# Unit tests
swift test

# Demo app and UI tests
xcodebuild -project Demo/LazyKitDemo.xcodeproj \
  -scheme LazyKitDemo \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  build

xcodebuild -project Demo/LazyKitDemo.xcodeproj \
  -scheme LazyKitDemo \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  test
```

CI runs the formatter lint and the test suites on every push and pull request;
the demo target's lint build phase reports formatter issues as Xcode warnings.

## Releases

Releases are tagged on `main`, so a tag like
[`0.1.0`](https://github.com/rafattouqir/LazyKit/releases/tag/0.1.0) always
points at a commit that passed CI. Notable changes are listed in
[CHANGELOG.md](CHANGELOG.md).

## License

LazyKit is available under the MIT license. See [LICENSE](LICENSE) for details.
