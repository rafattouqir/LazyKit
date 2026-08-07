---
name: swift-lint
description: Swift formatting rules enforced by swift-format in CI. Load when the diff adds or edits Swift code where style matters (imports, spacing, naming, doc-comment style). Low severity only.
---

# Swift lint (swift-format, strict)

CI runs: `swift format lint --strict --parallel --recursive Sources Tests Demo`

## Rules from `.swift-format` (flag violations, do not nitpick anything else)

1. 4 spaces, line length 120, max 1 blank line, no blank-line indent.
2. `OrderedImports: true` with `shouldGroupImports: true` — imports sorted
   (`LazyKit` then `SwiftUI`, etc.) and split into blank-line-separated groups:
   plain `import` first, then declaration-prefixed imports
   (`import func`/`import class`/...), then `@testable import`.
   `includeConditionalImports: false` — imports inside `#if` are not reordered.
3. Triple-slash docs `///`, no block comments (`NoBlockComments: true`).
4. No semicolons, no `return Void`, shorthand types (`AnyObject`, `[T]`,
   `String?`), one variable per line, one case per line.
5. `AlwaysUseLowerCamelCase`, `TypeNamesShouldBeCapitalized`,
   `IdentifiersMustBeASCII`, no leading underscores.
6. `NoParensAroundConditions`, `NoAssignmentInExpressions`,
   `UseExplicitNilCheckInConditions` (write `x == nil`, not `!x` for optionals
   where the rule applies), `OmitExplicitReturns: false` is NOT enforced —
   do not flag explicit `return`.
7. `FileScopedDeclarationPrivacy` with `private` file access level.
8. `NoEmptyTrailingClosureParentheses`, `OnlyOneTrailingClosureArgument`,
   `ReplaceForEachWithForLoop` (prefer `for` over `forEach`).

## What NOT to flag

- Anything already covered by `swift-format` auto-fix (whitespace) as
  🔴 Critical — report as 🟢 Low at most.
- `NeverForceUnwrap: false` / `NeverUseForceTry: false` — force unwrap/try
  are allowed by config; only flag when they guard user input or async
  boundaries where a crash is probable.
- `UseEarlyExits: false` — do not demand guard-early-exit refactors.
