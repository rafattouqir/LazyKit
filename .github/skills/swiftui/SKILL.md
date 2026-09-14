---
name: swiftui
description: SwiftUI idioms used across LazyKit views. Load when the diff touches views, @State/@Binding, .task or concurrency, animations, placeholders/loaders, or accessibility.
---

# SwiftUI

## Approved patterns (from `Sources/` and `Demo/`)

- Value-type views (`struct ... : View`), `@Binding` source of truth owned by
  the parent, `@State` only for view-local UI (see `DemoSection.text`).
- `@ViewBuilder` label/placeholder/loader slots; render the label untouched so
  callers style with ordinary modifiers.
- Overlays for non-interactive adornment with `.allowsHitTesting(false)`
  (placeholder) and `.accessibilityHidden(...)` while loading.
- Lifecycle work via `.task(id:)` + cooperative cancellation
  (`try? await Task.sleep`, `Task.isCancelled` checks). Never fire-and-forget
  `Task {}` from `body` without tying it to the view lifetime.
- State models as `@MainActor final class ... : ObservableObject` owned by
  `@StateObject`; mutations from the running task must remain visible to
  SwiftUI (see `LazyButton.Model`).
- Animations explicit and small (`.easeOut(duration: 0.15)`,
  `.smooth(duration: 0.2)`); loader animation comes from configuration.
- Accessibility identifiers on every interactive element
  (`lazy_button`, `lazy_text_field`, `*_loader`, `*_placeholder`).

## Findings to raise

1. `@State` duplicating a `@Binding` (second text buffer / feedback loop).
2. Un-cancelled `Task`, `Timer`, or `sleep` that outlives the view; missing
   `Task.isCancelled` guard after an `await`.
3. Main-actor isolation dropped on UI-mutating async code
   (`action: @escaping @MainActor () async -> Void` is the baseline).
4. Placeholder/loader intercepting touches or missing accessibility label/id.
5. New public `@Published` state that bypasses the run-ownership guards
   (`claimCurrentRun`, `launchedRunID` checks in `LazyButton.Model`).
6. Hard-coded fonts/colors inside `Sources/` views — styling belongs to the
   caller via modifiers; only the demo defines `PillButtonStyle`-like styles.
