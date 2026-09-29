# LazyTextField

A multi-line input that starts at a single line, grows with its content, and
keeps a placeholder visible while the bound text is empty.

```swift
import LazyKit

@State private var note = ""

LazyTextField(text: $note, placeholder: "Write a note…")
```

## The gap it closes

`TextEditor` has no placeholder and no intrinsic height — it fills whatever
space you hand it. `TextField(axis: .vertical)` grows with its content, but the
placeholder, the line range, and a character cap that also survives a paste are
still yours to write.

`LazyTextField` is built on `TextField(axis: .vertical)` and adds those, so the
growth and the native placeholder styling come from the system rather than from
a reimplementation.

## Usage

```swift
@State private var note = ""

LazyTextField(text: $note, placeholder: "Write a note…")
```

A string placeholder becomes the text field's native prompt, so the system
keeps its usual placeholder styling on every platform.

## Growth and line limits

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

## Character limit

```swift
configuration.characterLimit = 200
```

The limit clamps typing, pasting, and parent-driven updates through the
binding, so the parent binding stays the single source of truth. The field
renders no counter or error message of its own — draw your own when you need
one.

The clamp is applied in the same update that carries the edit, not deferred.
Deferring it lets the native editor stack further keystrokes onto the clamped
value, and nothing removes them again.

## Styling

Appearance comes from ordinary SwiftUI modifiers:

```swift
LazyTextField(configuration: configuration, text: $note)
    .font(.body)
    .padding(EdgeInsets(top: 10, leading: 14, bottom: 10, trailing: 14))
    .background(Color.blue.opacity(0.08))
    .clipShape(RoundedRectangle(cornerRadius: 12))
```

## Custom placeholder

Pass a view builder to replace the native prompt:

```swift
LazyTextField(configuration: configuration, text: $note) {
    Text("Write a note…")
        .foregroundStyle(.blue)
}
```

The custom placeholder is drawn as an overlay on top of the field and does not
take hits, so taps still reach the field. Match its font and insets to the
field's own styling on the platform you target — the overlay is not inset for
you.

## Configuration

`LazyTextFieldConfiguration` is a mutable value type. Start from `.default` and
change only the values you need.

| Property | Type | Default | Notes |
| --- | --- | --- | --- |
| `minimumNumberOfLines` | `Int` | `1` | Lines the field always reserves. Values below `1` are treated as `1`. |
| `maximumNumberOfLines` | `Int?` | `nil` | Cap on growth; past it the field scrolls internally. `nil` leaves growth uncapped. Values below the minimum are treated as the minimum. |
| `characterLimit` | `Int?` | `nil` | Maximum characters accepted. `nil` or non-positive means no limit. Input beyond the limit is clamped; the field renders no counter or error UI of its own. |
| `accessibilityIdentifier` | `String` | `"lazy_text_field"` | Applied to the text field. |
| `placeholderAccessibilityIdentifier` | `String` | `"lazy_text_field_placeholder"` | Applied to a custom placeholder while it is visible. A string placeholder renders as the field's native prompt instead, so UI tests observe it through the field's placeholder value. |

## Initializers

| Placeholder | Signature |
| --- | --- |
| `String?` | `LazyTextField(configuration:text:placeholder:)` |
| any `View` | `LazyTextField(configuration:text:placeholder:)` with a `@ViewBuilder` closure |

Both take `text` as a `Binding<String>`, which stays the source of truth.

---

[← Back to the README](../../README.md)
