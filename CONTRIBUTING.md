# Contributing to Senkani

Thanks for your interest. Senkani is a small project — keep PRs small,
keep tests green, and we'll be fine.

## Build

```bash
swift build -c release
```

## Test

Use `tools/test-safe.sh`, not `swift test`:

```bash
./tools/test-safe.sh
```

The default `swift test` runner can hang on some machines due to a Swift
concurrency bug in a few NSLock-wrapped helpers. The wrapper script
sidesteps this until the helpers are migrated. See
[spec/testing.md](spec/testing.md) for background.

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
