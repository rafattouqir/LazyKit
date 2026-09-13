---
name: repo-conventions
description: LazyKit repo conventions for copyright, docs, demo, and CI.
---

# Repo conventions

1. Copyright header: every new `Sources/`, `Tests/`, `Demo/` Swift file starts
   with `// Copyright (c) Rafat Touqir` followed by a blank line.
2. Docs: `///` triple-slash on all public declarations touched; keep the
   one-line-summary style used in `LazyButton.swift` / configs. If a default
   value, timing, or identifier changes, `README.md` + demo + tests must change
   in the same PR.
3. Demo conventions: `List` + `Section`, per-variant `*Configuration`
   builders, `DemoCaption`-style result labels with identifiers, `#Preview`
   blocks (`#Preview("...")`, `@Previewable @State` where needed).
   New component states need a preview.
4. Config extension pattern: demo-only presets live as `extension
   <Configuration> { fileprivate static var ... }` inside the demo file
   (see `.maxLinesDemo`), never in `Sources/`.
5. CI: `lint.yml` = `swift format lint --strict ... Sources Tests Demo`;
   `tests.yml` = `swift test` + xcodebuild UI tests. A PR that needs a lint
   exception or a new workflow permission must say why in the PR body.
6. No checked-in noise: `.build/`, `DerivedData`, `*.xcresult`,
   `xcuserdata` (except shared schemes), `.DS_Store` do not belong in diffs.

Flag: missing header, public API without docs, README/demo/test drift,
`Sources/` importing demo code, or generated artifacts in the diff.
