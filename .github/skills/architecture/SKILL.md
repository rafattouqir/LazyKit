---
name: architecture
description: LazyKit repository architecture rules for peer review.
---

# Architecture

One SwiftPM library, zero dependencies, plus a separate demo app.

## Layout

```text
Package.swift              # single library product LazyKit, Swift 6.0, iOS 17+, macOS 14+
Sources/LazyKit/Components/<Component>/<Component>.swift
Sources/LazyKit/Components/<Component>/<Component>+Configuration.swift
Tests/LazyKitTests/<Component>Tests.swift
Demo/LazyKitDemo.xcodeproj   # references repo root as local package
Demo/LazyKitDemo/            # SwiftUI demo screens + previews
docs/                        # design specs and plans (not shipped)
```

## Rules

1. `Sources/LazyKit` must stay dependency-free (`import SwiftUI` only).
   Flag any new `import` of a third-party package or `Package.swift` dependency.
2. One public view per component directory, paired with exactly one
   `<Name>+Configuration.swift` value type.
3. Public API surface stays minimal: generic `View` structs + plain
   `Configuration` structs with a `static var default`. No theme types,
   no toast types, no package-owned error UI (see design spec).
4. Configuration pattern is copy-and-mutate:
   `var c = LazyButtonConfiguration.default; c.showLoaderAfter = ...`.
   Flag mutable singletons, global state, or environment-injected config.
5. Demo is the integration proof, never the source of truth. Business logic
   in `Demo/` that belongs in `Sources/` is a finding.
6. New files must follow the existing component path. A new top-level
   `Sources/` directory or a Demo-to-Sources import inversion is a finding.

## Review checklist

- Does the diff add a dependency or widen the public API beyond view + config?
- Does Demo duplicate logic instead of consuming the package?
- Are file locations consistent with the layout above?
