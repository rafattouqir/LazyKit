# LazyButton Design Specification

## Goal

Add a new SwiftUI component, `LazyButton`, to the `LazyKit` package: a button wrapper that supports an **asynchronous action** (which SwiftUI's built-in `Button` does not) with a loading state driven by the duration of that async work. It takes the same visual construction as SwiftUI's `Button` (`action:` plus a `label`), but its action is `async`.

## Background and problem

SwiftUI's `Button` accepts only a synchronous, non-throwing action:

```swift
Button("Save") { save() }           // sync only
Button("Save") { try await save() } // not allowed
```

Developers who need to run async work on tap — network calls, file I/O, animations, `Task.sleep` for UX — have to roll their own `Button` that:

- Spins up a `Task`.
- Disables itself while work runs.
- Shows and hides a loading indicator.
- Handles view disappearance (cancellation) and re-appearance.

`LazyButton` packages that recurring behavior into one component.

## Scope

In scope:

- A public `LazyButton` view with an `async` action and a SwiftUI-style label.
- An automatic loading state: the button disables and shows a loader while the async action runs.
- A `Configuration` for the loader appearance and timing, mirroring the `LazyTextField.Configuration` pattern.
- Default behavior that avoids spinner flicker: the loader is shown only when the action outlasts a configurable delay, and once shown stays for a configurable minimum duration.
- A busy/loading state exposed to consumers (e.g. to change the label or disable an adjacent control) through a `Configuration`-driven or environment-accessible mechanism.
- A demo row in the LazyKitDemo component list, a demo screen, SwiftUI previews, Swift Testing package tests, and XCUITest demo coverage.
- `README.md` documentation for the new component.

Out of scope:

- A replacement for every overload of `Button` (role-based, bordered/prominent styles, custom `ButtonStyle`). `LazyButton` is a self-contained view, not a `PrimitiveButtonStyle` / `ButtonStyle` that would let consumers restyle any existing `Button`.
- Throwable actions. A throwing async action is deliberately *not* in the initial API: the component has no built-in error surface (no toast or alert), so a throwing action would leave errors silently swallowed. Consumers handle errors inside their own action or via a `Result`/callback.
- Package-owned toast or error UI (consistent with `LazyTextField`).
- `ProgressView` styles beyond a thin built-in spinner; consumers who need a custom loader can replace the built-in loader via `Configuration`, without the package owning arbitrary spinner implementations.

## Decisions

### 1. Lifecycle-managed task (recommended choice)

Tapping starts the async work. The button disables and shows its loader until the work finishes. If the view disappears mid-run, the in-flight `Task` is cancelled and the loading state resets — mirroring the cancellation guarantee that SwiftUI's `.task {}` modifier gives. A `.task`-style lifecycle ties the task to the button's presence.

### 2. Delay + minimum duration loader timing

The loader does **not** appear instantly on tap. Instead:

- A short **delay** (`showLoaderAfter`, default `0.3s`) means fast async actions never flash a spinner.
- Once shown, the loader is guaranteed to stay for a **minimum duration** (`minimumLoaderDuration`, default `0.5s`) so a just-finished action does not cause a jarring flicker.

This is the recommended answer to "custom loader based on async duration."

## Architecture

`LazyButton` lives beside `LazyTextField` under the existing package target:

```text
Sources/LazyKit/
├── Components/
│   ├── LazyTextField/
│   │   ├── LazyTextField.swift
│   │   └── LazyTextField+Configuration.swift
│   └── LazyButton/                     # new
│       ├── LazyButton.swift
│       └── LazyButton+Configuration.swift
```

Reuses the established patterns:

- Public view struct + nested public `Configuration`, mutable and self-contained, with a static `.default`.
- Copyright header `// Copyright (c) Rafat Touqir`.
- SwiftUI-only, no external dependencies.
- Demo integration as a new row in `ContentView`'s component `List`, plus a new `LazyButtonDemoView.swift` registered manually in `LazyKitDemo.xcodeproj/project.pbxproj`.

## Public API

```swift
public struct LazyButton<Label: View>: View {
    public init(
        configuration: Configuration = .default,
        @ViewBuilder label: () -> Label,
        action: @escaping @MainActor () async -> Void
    )

    /// Simpler label overload.
    public init(
        _ titleKey: LocalizedStringKey,
        configuration: Configuration = .default,
        action: @escaping @MainActor () async -> Void
    ) where Label == Text
}
```

The action is `async`, runs on the main actor, and the button manages its own task. While the task runs, taps are ignored and the label is replaced (or overlaid) with the loader.

`LazyButton.Configuration`:

```swift
public extension LazyButton {
    struct Configuration {
        /// How long the async work must outlast before the loader appears.
        public var showLoaderAfter: Duration
        /// Once the loader is visible, the minimum time it stays before the
        /// button can return to idle.
        public var minimumLoaderDuration: Duration
        /// Color of the built-in loader spinner.
        public var loaderColor: Color
        /// Optional custom loader view, shown when the button is busy.
        public var customLoader: AnyView?   // or type-erased loader
        /// Optional tint applied to the button's label while busy.
        public var busyLabelColor: Color?
        /// Accessibility identifier shown on the loader.
        public var loaderAccessibilityIdentifier: String
        // ... plus appearance values (font, colors, corner radius, padding)
        // to match LazyTextField.Configuration.
    }
}
```

Consumers who need to react to the busy state (disable an adjacent control, swap the title to "Saving…") observe it through a public `isBusy`-style binding passed to the initializer, or through a configuration-provided observation hook. The precise mechanism is fixed during implementation.

## View behavior

While the async action runs, `LazyButton`:

1. **Ignores further taps** — the running action is not re-entered.
2. **Shows the loader** only after `showLoaderAfter` has elapsed (default `0.3s`). Fast work therefore shows no loader.
3. **Keeps the loader visible** for at least `minimumLoaderDuration` (default `0.5s`) once it has appeared.
4. **Returns to idle** only when the action has finished **and** any minimum loader time has elapsed.
5. On view disappearance, **cancels** the in-flight task (like `.task {}`) and resets state, so a dismissed screen never leaks work or leaves a stale busy state.

These timing rules are the component's core testable behavior and are deterministic enough for Swift Testing with small durations.

## Demo requirements

Add to the LazyKitDemo app a **Button** component row (accessibility id `component_lazy_button`) that pushes a `LazyButtonDemoView` showing:

- A fast async action (completes well under `showLoaderAfter`) that does not flash a loader.
- A slow async action (well over the minimum loader duration) whose loader appears and disappears cleanly.
- A short-delay custom loader demonstrating custom loader color/view.
- A button whose label reacts to the busy state (e.g. "Save…"/"Saving…") if that mechanism is public.
- SwiftUI previews.

## Testing and verification

Package tests use Swift Testing and cover the deterministic timing/state rules. Because the loader logic is private to the view, the package tests will test the **configurable pure rules** (delay / minimum-duration clamping) through small, internal, testable helpers, mirroring how `LazyTextField` keeps its clamp helper internal and unit-tested.

Demo UI tests drive the real user flow per the project convention: launch the app, tap the **Button** component row, then assert the async button behavior — e.g. that a slow button shows its loader while running and returns to its label after finishing.

Verification commands follow `README.md`:

- `swift test` (package unit tests, RED/GREEN per plan)
- `xcodebuild ... build` (demo app)
- `xcodebuild ... test` (UI tests)
- Final end-to-end: install and launch the demo app on the simulator, confirm the new Button row navigates and renders without crash.

## Documentation and licensing

`README.md` documents `LazyButton`, its async action, the loader-timing defaults, customization, and the busy-state observation hook. The existing copyright header is retained in new source files. No new software license is introduced.
