# LazyButton

A button whose action is asynchronous, and whose loading state follows that
work.

```swift
import LazyKit

LazyButton("Save") {
    try? await api.save()
}
```

## The gap it closes

SwiftUI's `Button` takes a synchronous, non-throwing action, so
`Button("Save") { try await save() }` does not compile. An async button means
hand-rolling a `Task`, a busy flag, a spinner, and the timing rules that keep
the spinner from flickering. `LazyButton` is that, once.

## Usage

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

## Loader timing

```swift
var configuration = LazyButtonConfiguration.default
configuration.showLoaderAfter = .milliseconds(150)
configuration.minimumLoaderDuration = .milliseconds(800)

LazyButton("Publish", configuration: configuration) {
    try? await publisher.publish()
}
```

The loader appears only if the action is still running after `showLoaderAfter`,
so quick work never flashes a spinner. If the loader is visible when the action
returns, it stays for `minimumLoaderDuration` before the button becomes idle
again. Cancellation ends that hold early.

## Custom loaders and colors

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

## Styling

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

While the loader is visible the label fades out rather than being removed, so
the button keeps its size and nothing around it reflows. The button itself
dims to 60% opacity while busy.

## Configuration

`LazyButtonConfiguration` is a mutable value type. Start from `.default` and
change only the values you need.

| Property | Type | Default | Notes |
| --- | --- | --- | --- |
| `showLoaderAfter` | `Duration` | `.milliseconds(150)` | How long the action must still run before the loader appears. Actions that finish sooner never show one. |
| `minimumLoaderDuration` | `Duration` | `.milliseconds(500)` | How long a visible loader stays up after the action returns. Cancellation ends the hold early. |
| `loaderColor` | `Color` | `.white` | Tint of the built-in spinner. Ignored when a custom loader is passed. |
| `loaderAnimation` | `Animation` | `.smooth(duration: 0.2)` | Animation used when the loader appears. |
| `accessibilityIdentifier` | `String` | `"lazy_button"` | Applied to the button. |
| `loaderAccessibilityIdentifier` | `String` | `"lazy_button_loader"` | Applied to the loader while it is visible. |

## Initializers

Every initializer takes the action as an `@escaping @MainActor () async -> Void`.

| Label | Loader | Signature |
| --- | --- | --- |
| any `View` | any `View` | `LazyButton(configuration:label:loader:action:)` |
| any `View` | built-in spinner | `LazyButton(configuration:label:action:)` |
| `Text` | built-in spinner | `LazyButton(_ titleKey:configuration:action:)` |
| `Text` | any `View` | `LazyButton(_ titleKey:configuration:loader:action:)` |

---

[← Back to the README](../../README.md)
