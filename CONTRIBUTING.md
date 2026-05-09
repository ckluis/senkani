# Contributing to Senkani

Thanks for your interest. Senkani is a small project — keep PRs small,
keep tests green, and we'll be fine.

## Build

```bash
swift build -c release
```

`swift build -c release` runs as a CI gate on every PR (see
`.github/workflows/release-build-smoke.yml`) — replicate locally
before pushing so dependency-pin / package-graph regressions don't
make it to review.

## Test

Use `tools/test-safe.sh`, not `swift test`:

```bash
./tools/test-safe.sh
```

The default `swift test` runner can hang on some machines due to a Swift
concurrency bug in a few NSLock-wrapped helpers. The wrapper script
sidesteps this until the helpers are migrated. See
[spec/testing.md](spec/testing.md) for background.

## macOS / iCloud Drive

**Do not place senkani's working tree under iCloud-Drive-managed
paths.** The defaults that bite: `~/Desktop/`, `~/Documents/`, and
anything under `~/Library/Mobile Documents/` while iCloud Drive's
"Desktop & Documents Sync" is enabled.

iCloud's FileProvider evicts file content under storage pressure
or sync churn (the metadata stays on disk, the bytes vanish behind
the `SF_DATALESS` APFS flag). When SwiftPM hits an evicted
`Package.swift`, the build collapses with errors like:

```
error: 'swift-sdk': the package manifest at
'.build/checkouts/swift-sdk/Package.swift' cannot be accessed
```

A second symptom of the same family: macOS resolves sync conflicts
by creating `* 2` Finder-shadow siblings (`mlx-swift-lm` ↔
`mlx-swift-lm 2`) which can poison `.build/checkouts/` and even
slip into `Sources/`, `Tests/`, and `docs/`.

### Diagnose

`senkani doctor` includes a FileProvider eviction check (added in
v0.3.0). It walks the project root, `.build/checkouts/`, and the
operator-tracked source tree (`Sources/`, `Tests/`, `docs/`)
flagging:

- The project root sitting under a FileProvider-managed path.
- Files carrying the `SF_DATALESS` `st_flag`.
- `* 2` Finder-shadow siblings.

Manual checks if you don't have a working senkani build yet:

```sh
xattr -l ~/Desktop/projects/senkani/         # com.apple.metadata:com_apple_clouddocs sentinel
ls -lO@ .build/checkouts/swift-sdk/          # look for `dataless` flag in the flag column
find Sources Tests docs -name '* 2*'         # Finder-shadow sweep
```

### Remediate (recommended)

The clean fix is to disable iCloud Desktop & Documents sync at the
user level (it covers every project under `~/Desktop/` and
`~/Documents/`, not just senkani):

1. **System Settings → Apple ID → iCloud → Drive.** Toggle "Sync
   this Mac" or, more narrowly, the "Apps syncing to iCloud Drive"
   sub-pane's Desktop & Documents toggle to OFF.
2. macOS prompts to keep local copies of synced files. Choose
   **"Keep a Copy."** Tracked files stay; iCloud-only files are
   restored under `~/Library/Mobile Documents/com~apple~CloudDocs/`.
3. Verify: `git status` from the project root shows the same
   tracked/untracked set as before. No tracked file content is
   lost.
4. Recover the build tree:
   ```sh
   rm -rf .build      # the dataless-flag deletion stall clears
                      # once FileProvider stops re-evicting
   swift package resolve
   swift build -c release
   ```
5. Optional: re-run `senkani doctor` — the FileProvider check
   should report green.

### If you must keep iCloud Drive enabled

You can move just the project off the synced path (e.g.,
`~/dev/senkani/` instead of `~/Desktop/projects/senkani/`).
Per-folder iCloud exclusion via `brctl` exists but is fragile
across macOS versions and not recommended for SwiftPM trees.

## Pull requests

- One topic per PR. Big PRs are hard to review.
- Run `./tools/test-safe.sh` before pushing.
- Match the existing commit message style — look at recent
  `git log --oneline` for examples (e.g. `category: subject`).
- If your change touches a documented area
  (README, CHANGELOG, `spec/*.md`), update those files in the same PR.
  See `spec/autonomous-manifest.yaml` for the doc-sync map.

## Filing an issue

GitHub Issues is fine for bugs, feature requests, and questions.
For security issues, see [SECURITY.md](SECURITY.md) — please don't
file them as public issues.

## Backlog

Senkani uses an autonomous development loop driven by
`spec/autonomous-backlog.yaml`. If you have an idea for a larger
piece of work, open an issue first — we may be able to file it
into the backlog and ship it through the loop.

## Code of conduct

By participating you agree to follow the
[Code of Conduct](CODE_OF_CONDUCT.md).
