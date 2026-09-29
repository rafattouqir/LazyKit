# Changelog

All notable changes to LazyKit are documented in this file. The project follows
[semantic versioning](https://semver.org).

## 0.1.0 — 2026-09-28

Initial release.

### Added

- `LazyButton`: a button that runs an async action, with a loader that appears
  only after a configurable delay and stays up for a minimum duration. Supports
  custom loader views, a spinner tint, and accessibility identifiers.
- `LazyTextField`: a multi-line input that grows with its content and keeps a
  placeholder visible while empty, with line limits, a character limit, string
  or custom placeholders, and accessibility identifiers.
- `LazyButtonConfiguration` and `LazyTextFieldConfiguration` for per-instance
  behavior, plus a demo app and UI tests under `Demo/`.
