# LazyKit

LazyKit is a small collection of SwiftUI components:

- `LazyTextField` is a multi-line input that reserves one line by default,
  grows with its content, and keeps a placeholder visible while empty.
- `LazyButton` runs an asynchronous action with a lifecycle-aware loading
  state.

## Requirements

- iOS 17+
- macOS 14+
- Swift 6+

## Installation

In Xcode, choose **File > Add Package Dependencies…** and add:

```text
https://github.com/rafattouqir/LazyKit.git
```

Then import the package product:

```swift
import LazyKit
```

For local development, add the repository directory as a local package
dependency.

## `LazyTextField`

The string convenience form uses SwiftUI's native text-field prompt:

```swift
struct NotesView: View {
    @State private var note = ""

    var body: some View {
        LazyTextField(
            text: $note,
            placeholder: "Write a note…"
        )
    }
}
```

For a custom placeholder, pass a view builder. It is drawn as an overlay, so
its font and insets may need to be matched to the field's styling on the
target platform.

```swift
var configuration = LazyTextFieldConfiguration.default
configuration.minimumNumberOfLines = 3
configuration.maximumNumberOfLines = 6

LazyTextField(configuration: configuration, text: $note) {
    Text("Write a note…")
        .foregroundStyle(.blue)
}
```

Style the field with ordinary SwiftUI modifiers. `minimumNumberOfLines` sets the
minimum number of lines reserved by the field and defaults to one. Set
`maximumNumberOfLines` to cap growth; once the limit is reached, the field
scrolls internally. A `nil` maximum leaves growth uncapped, and values below the
minimum are treated as the minimum.

```swift
LazyTextField(
    configuration: configuration,
    text: $note
)
.font(.body)
.foregroundStyle(.primary)
.padding(EdgeInsets(top: 10, leading: 14, bottom: 10, trailing: 14))
.background(Color.blue.opacity(0.08))
.clipShape(RoundedRectangle(cornerRadius: 12))
```

Set `characterLimit` to clamp input. A `nil` or non-positive value disables the
limit. The component does not render validation UI, so consumers can provide
their own counter or message.

```swift
configuration.characterLimit = 200

LazyTextField(
    configuration: configuration,
    text: $note
)
```

Typing, pasting, and parent-driven updates are clamped through the field's
binding. The parent binding remains the source of truth, and the character
limit applies without introducing a second text buffer.

## `LazyButton`

`LazyButton` accepts an asynchronous action and runs it in a task tied to the
view's lifecycle. It ignores taps while the action or loader hold is active.
If the view disappears, cancellation is cooperative: cancellation-aware work
can stop at a suspension point, and the button resets after the action returns.
Reappearing does not re-run the last tap.

```swift
LazyButton("Save") {
    try? await api.save()
}
```

The loader appears only when the action is still running after
`showLoaderAfter` (150ms by default). If it is visible when the action returns,
it stays visible for `minimumLoaderDuration` after that return (500ms by
default) before the button becomes idle. Cancellation can end this hold early.
The action handles its own errors.

```swift
var buttonConfiguration = LazyButtonConfiguration.default
buttonConfiguration.showLoaderAfter = .milliseconds(150)
buttonConfiguration.minimumLoaderDuration = .milliseconds(800)

LazyButton("Publish", configuration: buttonConfiguration) {
    try? await publisher.publish()
}
```

The label is rendered as supplied and can be styled with ordinary SwiftUI
modifiers. `loaderAnimation` controls the loader's appearance animation.

```swift
LazyButton("Publish", configuration: buttonConfiguration) {
    try? await publisher.publish()
}
.font(.body.weight(.semibold))
.foregroundStyle(.white)
.frame(maxWidth: .infinity)
.padding()
.background(.indigo)
.clipShape(RoundedRectangle(cornerRadius: 12))
```

Pass a custom loader when the built-in spinner is not enough:

```swift
LazyButton(
    "Publish",
    configuration: buttonConfiguration,
    loader: {
        Image(systemName: "circle.dotted")
            .foregroundStyle(.white)
    }
) {
    try? await publisher.publish()
}
```

## Configuration names

Use `LazyTextFieldConfiguration` and `LazyButtonConfiguration` for standalone
values, annotations, and tests. The generic views also expose
`LazyTextField.Configuration` and `LazyButton.Configuration` as shorthand when
the view's generic types are already known.

## Development

The package source and unit tests live under `Sources/` and `Tests/`. The demo
app in `Demo/LazyKitDemo.xcodeproj` uses the package as a local dependency.
CI runs the strict formatter lint command; the demo target's lint build phase
reports formatter issues as Xcode warnings.

```bash
swift format lint --strict --parallel --recursive Sources Tests Demo
swift test

xcodebuild -project Demo/LazyKitDemo.xcodeproj \
  -scheme LazyKitDemo \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  build

xcodebuild -project Demo/LazyKitDemo.xcodeproj \
  -scheme LazyKitDemo \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  test
```

To run the demo in Xcode, open `Demo/LazyKitDemo.xcodeproj`, select the
`LazyKitDemo` scheme, and choose an iOS Simulator destination.
