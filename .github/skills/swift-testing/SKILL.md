---
name: swift-testing
description: Swift Testing and UI test conventions. Load when the diff adds or changes Tests/, test coverage, Demo UI identifiers consumed by UI tests, or timing-sensitive async tests.
---

# Testing

## Unit tests (`Tests/LazyKitTests/`, Swift Testing)

- `import Testing`, `@testable import LazyKit`, `struct <Name>Tests`
  (not `XCTestCase`), `@Test("...") func ...`, `#expect(...)`.
- Always cover: default config baseline values AND customized values
  (see `LazyButtonTests`, `LazyTextFieldTests`).
- Pure helpers tested directly: `limitedText` clamping, repeated overflow,
  Unicode grapheme clusters (`"A👩‍🚀B"` prefix 2 == `"A👩‍🚀"`), nil/zero/negative
  limits leave values unchanged, in-limit values unchanged.
- Concurrency tests use `@MainActor`, drive `Model` directly
  (`claimCurrentRun`, `run(id:...)`, `execute(...)` with small
  `Duration`s), and assert `isBusy`/`loaderVisible` reset on cancel and on
  superseded runs.
- No `XCTAssert*`, no `expectation`/`waitForExpectations`; new tests must
  follow the `#expect` style.

Flag: XCTest imports in new tests, missing baseline/customization coverage
for a new config value, timing-flaky sleeps (>1s) where a direct model call
would do, or tests that sleep without asserting loader/busy transitions.

## UI tests (`Demo/LazyKitDemoUITests/`)

- Locate via accessibility identifiers (`lazy_button_fast`,
  `lazy_text_field`, `lazy_text_field_placeholder`, `limited_character_count`),
  never by hard-coded label text that localizes.
- Placeholder contract: present while empty, gone after typing; limited demo
  never exceeds its limit.

Flag: new interactive UI without an identifier, or identifiers changed
without updating tests + demo + skill docs.
