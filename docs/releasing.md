# Releasing

Maintainer notes. Nothing here is needed to *use* LazyKit.

Releases are tagged on `main`, so a tag always points at a commit that passed CI.
Notable changes are listed in [CHANGELOG.md](../CHANGELOG.md), which the release
script writes for you.

## Cutting a release

`Scripts/release.sh` derives the next version from the conventional commits since
the last tag, writes the changelog entry, commits it as `chore: release X.Y.Z`,
and publishes the tag and the GitHub release:

```bash
Scripts/release.sh --dry-run   # preview the version and the notes
Scripts/release.sh minor       # or auto|patch|major|X.Y.Z
```

Run it from a clean clone of `main`. It also rewrites the version references it
can find in `README.md` — the `from:` pin in the installation snippet, and any
version in backticks — so those stay current without a manual edit. It matches
those literal patterns and nothing else, so **keep every other version mention in
the README generic** (write "any 0.x release", not "any 0.1.x release"), or it
will silently go stale on the next release.

## Releasing from CI

The manual **Release** workflow (Actions ▸ Release ▸ Run workflow) runs the same
script on CI when you would rather not release from a local clone. It runs on
Linux and skips the test gate, since the package imports SwiftUI and cannot build
there; `lint.yml` and `tests.yml` cover the code on every push and pull request.

---

[← Back to the README](../README.md)
