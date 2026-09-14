---
name: lazykit-api
description: LazyButton and LazyTextField API contracts and invariants. Load when the diff touches component sources, Configuration structs, defaults, timings, accessibility identifiers, or the public component API.
---

# LazyKit API contracts

## LazyButton (`Sources/LazyKit/Components/LazyButton/`)

- Defaults: `showLoaderAfter = .milliseconds(150)`,
  `minimumLoaderDuration = .milliseconds(500)`, `loaderColor = .white`,
  `accessibilityIdentifier = "lazy_button"`,
  `loaderAccessibilityIdentifier = "lazy_button_loader"`,
  `loaderAnimation = .smooth(duration: 0.2)`.
- Loader appears ONLY if the action is still running after `showLoaderAfter`;
  fast actions never flash a loader. A visible loader holds
  `minimumLoaderDuration` after return. Cancellation can end the hold early.
- Taps ignored while busy (`guard !model.isBusy`, `.disabled(model.isBusy)`).
- `handleTap` only bumps `runID`; `.task(id: runID)` + `claimCurrentRun()`
  guarantees a reappearing view never re-runs without a new tap, and a
  superseded run never mutates current state (`launchedRunID` checks).
- The action handles its own errors (`try? await` at call site); the button
  never shows error UI.
- Custom loader is a `@ViewBuilder`; default loader is a `ProgressView`
  tinted with `configuration.loaderColor`.

Flag: loader shown unconditionally, error UI added to the button, tap
re-entrancy, bypassing `claimCurrentRun`, or changing default timings/ids
without updating tests + README + demo.

## LazyTextField (`Sources/LazyKit/Components/LazyTextField/`)

- Defaults: `minimumNumberOfLines = 1`, `maximumNumberOfLines = nil`,
  `characterLimit = nil`, `accessibilityIdentifier = "lazy_text_field"`,
  `placeholderAccessibilityIdentifier = "lazy_text_field_placeholder"`.
- Parent binding is the source of truth. Clamp via `limitedText(_:characterLimit:)`
  (`String(value.prefix(limit))`, grapheme-cluster safe); `nil`/non-positive
  means no limit. No second text buffer, correction applied in
  `.task(id: text)` after the binding update.
- String placeholder uses native `TextField(prompt:)`; custom placeholder is
  an overlay shown only `if text.isEmpty` with `.allowsHitTesting(false)`.
- Growth: `lineLimit = max(1, min)...max(min, max ?? .max)` on a
  vertical-axis `TextField`; past maximum it scrolls internally.
- No validation UI in the component — counters/messages live in the consumer
  (see `CharacterLimitFooter` in demo).

Flag: second `@State` text buffer, `onChange` feedback loops, splitting
grapheme clusters (use `prefix`, not UTF-16 indexing), clamping that breaks
parent-driven updates, or validation UI added to the package.
