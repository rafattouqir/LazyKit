# LazyButton Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `LazyButton` to the `LazyKit` Swift package: a SwiftUI button wrapper whose action is `async`, with a lifecycle-managed loading state and duration-based loader timing (delay + minimum duration), plus demo, Swift Testing coverage, and UI tests.

**Architecture:** The package target gains `Sources/LazyKit/Components/LazyButton/LazyButton.swift` and `LazyButton+Configuration.swift`. The demo app gains a `Button` row in the component `List`, a new `LazyButtonDemoView`, and manual registration in the Xcode project. Package behavior tests live in `Tests/LazyKitTests`; interaction tests live in `Demo/LazyKitDemoUITests`.

**Tech Stack:** Swift 6.3, SwiftUI, Swift Package Manager, Swift Testing, Xcode 26.6, XCTest/XCUITest.

**Spec:** `docs/superpowers/specs/2026-09-02-lazybutton-design.md`

## Global Constraints

- Package platforms: iOS 16 and later, macOS 13 and later.
- The component is a self-contained view; it is not a `ButtonStyle` / `PrimitiveButtonStyle`.
- The action is `async`, non-throwing, and `@MainActor`-isolated; there is no built-in error UI.
- Loader timing defaults to a delay before the loader appears and a minimum duration once it appears.
- The in-flight task is cancelled when the view disappears (`.task {}`-style lifecycle).
- The package has no external dependencies.
- Package tests use Swift Testing; demo interaction uses XCUITest.
- Preserve the `// Copyright (c) Rafat Touqir` header in new source files; do not add an unrequested license.
- Existing tests keep passing; `swift test` stays green.

---

### Task 1: Write failing Swift Testing cases for the loader-timing rules

**Files:**
- Create: `Tests/LazyKitTests/LazyButtonTimingTests.swift`

**Interfaces:**
- Consumes an internal (testable) helper that decides loader visibility from action-duration and loader-duration inputs.
- Produces failing tests that document the delay + minimum-duration contract.

- [ ] **Step 1: Write the failing tests before production code**

Define an internal pure helper in the library (to be implemented in Task 2), e.g. `LazyButton.loaderVisibility(...)` or a small internal `LazyButton.Timing` type, that takes:
- whether the action has finished,
- how much time has elapsed since the tap,
- `showLoaderAfter`,
- `minimumLoaderDuration`

and returns whether the loader is visible and whether the button is still busy. With small `Duration` values these rules are deterministic and unit-testable.

Test cases to write (all RED until the helper exists):

```swift
import Testing
@testable import LazyKit

struct LazyButtonTimingTests {
    @Test("loader does not appear before the delay elapses")
    // elapsed < showLoaderAfter and action still running -> idle, not busy

    @Test("loader appears once the action outlasts the delay")
    // elapsed >= showLoaderAfter and action still running -> loader visible, busy

    @Test("fast action finishing before the delay shows no loader")
    // action finished before showLoaderAfter -> no loader ever, button idle

    @Test("action finishing during the minimum loader duration keeps the loader visible")
    // action done but elapsed - showLoaderAfter < minimumLoaderDuration -> loader still visible

    @Test("loader hides once the action is done and the minimum duration is met")
    // action done and elapsed - showLoaderAfter >= minimumLoaderDuration -> idle

    @Test("default configuration uses the documented timing baseline")
    // showLoaderAfter == 0.3s, minimumLoaderDuration == 0.5s
}
```

- [ ] **Step 2: Run the focused test command and verify the expected RED result**

```bash
swift test --filter LazyButtonTimingTests
```

Expected: FAIL to compile / fail assertions because the helper does not exist yet. Do not add production code in this task.

---

### Task 2: Implement `LazyButton` and turn the timing tests green

**Files:**
- Create: `Sources/LazyKit/Components/LazyButton/LazyButton.swift`
- Create: `Sources/LazyKit/Components/LazyButton/LazyButton+Configuration.swift`
- Modify: `Tests/LazyKitTests/LazyButtonTimingTests.swift` only if a compiler diagnostic requires a syntax correction without changing assertions

**Interfaces:**
- Produces public `LazyButton`, public `LazyButton.Configuration`, and the internal timing helper the tests consume.

- [ ] **Step 1: Add the internal timing helper and pure rules**

Create the internal helper the Task 1 tests reference. It encodes:

```
loader visible   = actionRunning && elapsed >= showLoaderAfter
still busy/idle  = actionRunning
                || (loader was shown && elapsedSinceLoaderShown < minimumLoaderDuration)
```

- [ ] **Step 2: Implement the public `LazyButton` view**

```swift
// Copyright (c) Rafat Touqir

import SwiftUI

public struct LazyButton<Label: View>: View {
    private let configuration: Configuration
    private let label: Label
    private let action: @MainActor () async -> Void

    public init(
        configuration: Configuration = .default,
        @ViewBuilder label: () -> Label,
        action: @escaping @MainActor () async -> Void
    ) {
        self.configuration = configuration
        self.label = label()
        self.action = action
    }

    public var body: some View {
        // A Button whose action spawns a lifecycle-managed Task; disabled while
        // the task runs; label swaps to / overlays with the loader per Timing.
    }
}
```

Behavior requirements:

- The wrapper renders a tappable button whose label is the provided `Label`.
- Tapping starts the async action on the main actor. Further taps while busy are ignored.
- Loader visibility and busy/idle transitions follow the internal timing helper using `showLoaderAfter` and `minimumLoaderDuration`.
- The in-flight task is tied to the view lifecycle (`.task {}`-style): if the view disappears mid-run, cancel the task and reset state.
- Busy state is observable by consumers (public `isBusy` binding and/or a configuration observation hook) so labels can react ("Saving…").

- [ ] **Step 3: Run the timing tests and verify GREEN**

```bash
swift test --filter LazyButtonTimingTests
```

Expected: PASS for all Task 1 cases.

- [ ] **Step 4: Run the full package suite**

```bash
swift test
```

Expected: PASS — new `LazyButtonTimingTests` plus existing `LazyTextFieldTests`.

---

### Task 3: Add the Button demo row, demo screen, and previews

**Files:**
- Create: `Demo/LazyKitDemo/LazyButtonDemoView.swift`
- Modify: `Demo/LazyKitDemo/ContentView.swift` (add a `Button` row / `NavigationLink`)
- Modify: `Demo/LazyKitDemo.xcodeproj/project.pbxproj` (file ref + build file + group + sources)

**Interfaces:**
- Consumes public `LazyButton` and its `Configuration`.
- Produces a demo screen the component list pushes to, exercising fast action, slow action, custom loader, and busy-state label.

- [ ] **Step 1: Add the demo screen**

Create `Demo/LazyKitDemo/LazyButtonDemoView.swift` mirroring `LazyTextFieldDemoView`'s section-based layout, showing:
- a **fast action** (well under `showLoaderAfter`) that returns to idle with no loader flash,
- a **slow action** (well over `minimumLoaderDuration`) whose loader appears and then clears,
- a **custom loader** demonstrating loader customization,
- a busy-state label swap if the mechanism is public.

- [ ] **Step 2: Add the component row**

Modify `Demo/LazyKitDemo/ContentView.swift` to append a `Button` row with accessibility id `component_lazy_button`, pushing `LazyButtonDemoView`.

- [ ] **Step 3: Register the new file in the Xcode project**

Manually add `LazyButtonDemoView.swift` to `Demo/LazyKitDemo.xcodeproj/project.pbxproj` (file reference, build file, group children, sources phase), the same way `LazyTextFieldDemoView.swift` was registered.

- [ ] **Step 4: Verify the demo builds**

```bash
swift test
xcodebuild -project Demo/LazyKitDemo.xcodeproj \
  -scheme LazyKitDemo \
  -destination 'generic/platform=iOS Simulator' \
  build
```

Expected: package tests PASS and the demo build PASS with the new row and screen.

---

### Task 4: Write and pass UI tests for the async button

**Files:**
- Modify: `Demo/LazyKitDemoUITests/LazyKitDemoUITests.swift`

**Interfaces:**
- Consumes the real user flow: launch app, wait for and tap `component_lazy_button`, then assert behavior on the pushed screen.

- [ ] **Step 1: Write the failing UI tests before final wiring**

Add UI tests that:
- launch the app and navigate to the LazyButton demo,
- tap the slow async button,
- assert the loader appears (via loader accessibility id) and later disappears,
- assert the label returns and the button is hittable again.

- [ ] **Step 2: Run the UI tests and verify GREEN**

```bash
xcodebuild -project Demo/LazyKitDemo.xcodeproj \
  -scheme LazyKitDemo \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  test
```

Expected: all UI tests PASS (existing LazyTextField tests plus the new LazyButton tests). If the named simulator is unavailable, use the exact name returned by `xcrun simctl list devices available` without changing test assertions.

---

### Task 5: Update README documentation

**Files:**
- Modify: `README.md`

**Interfaces:**
- Documents the public `LazyButton` product, the async action, loader-timing defaults, customization, and busy-state observation.

- [ ] **Step 1: Add a LazyButton section**

Add a component-row entry and a usage section covering:
- basic async usage,
- the delay + minimum-duration loader defaults,
- custom loader configuration,
- busy-state observation,
- a note that errors must be handled inside the async action (no package-owned error UI).

- [ ] **Step 2: Verify the documentation-only change does not break the build**

```bash
swift test
```

Expected: PASS; documentation-only change must not alter package behavior.

---

### Task 6: Final verification

- [ ] **Step 1: Static and behavioral verification**

```bash
git diff --check
swift test
xcodebuild -project Demo/LazyKitDemo.xcodeproj \
  -scheme LazyKitDemo \
  -destination 'generic/platform=iOS Simulator' \
  build
```

Expected: no whitespace errors, Swift Testing PASS, demo build PASS.

- [ ] **Step 2: End-to-end launch verification**

Install and launch the demo app on the simulator, confirm the new **Button** row navigates to the LazyButton demo and the demo screen renders with no crash, per the project's end-to-end validation preference.

- [ ] **Step 3: Commit the implementation**

Commit the spec, plan, package source, tests, demo, project wiring, and README with a conventional message such as `feat: add LazyButton async SwiftUI button`. Keep the commit local unless the user asks to push.
