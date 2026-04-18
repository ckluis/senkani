# Bach test-strategy audit — 2026-04-16

Adversarial read of the 953-test suite. Bach's lens: tests exist to
give signal about risk, not to produce a green count. A 953-number
is impressive; the question is what it PROVES.

## Inventory

- **91 test files**, **18,428 lines**, **953 passing**.
- **Types:** ~91 example-based unit, ~5 integration (WebFetch file://,
  migration fixtures, socketpair in SocketAuth), 0 property-based,
  0 fuzz, ~5 perf (timing bounds on normalize / secret-scan / 1 MB
  input), **0 chaos**.
- **Strongest coverage:** 20 tree-sitter language backends (~350 LOC
  each), KnowledgeStore/FileLayer/Tool (≥300 each), CompoundLearning,
  AgentTracking, AutoValidate (≥350 each). Recent hardening (Wave
  1/2/3) has dedicated test files for every P0/P1 shipping item.
- **Notable thin files:** VersionToolTests (24 LOC, 3 tests),
  FeatureConfigTests (33 LOC), WikiLinkCompletionTests (34 LOC).

## What the 953 tests *don't* prove

Bach rule: absence of a test is evidence of absence of signal.

| # | Gap | Severity | Signal per hour |
|---|-----|----------|-----------------|
| G1 | `ProjectSecurity` has ZERO tests | **P1** | High — trust boundary |
| G2 | Migration runner concurrency test was planned but never shipped | **P1** | ✅ 2026-04-17 — `MigrationMultiProcTests` spawns two `senkani-mig-helper` processes via `Foundation.Process`, releases a shared barrier, and asserts exactly-once semantics (union of applied versions = full registry, exactly one applies + one no-ops, kill-switch lockfile not produced). Found and fixed a real flock race in `MigrationRunner.run` — `FileManager.createFile` was pre-racing `open(O_RDWR\|O_CREAT)` on the same sidecar because `createFile`'s atomic write unlinks + renames, so concurrent processes flocked different inodes. 3 new tests. |
| G3 | No property-based / fuzz tests anywhere in 91 files | **P2** | High — SSRF parser has 25 cases but zero fuzzing |
| G4 | WebFetch redirect `decidePolicyFor` logic only tested via its inner helpers | **P2** | High — the actual policy fn is untested as a unit |
| G5 | HookRouter (507 LOC, Layer-3 interception) has 9 tests — thin | P2 | Medium — happy-path heavy |
| G6 | CLI commands have no direct test coverage | P2 | ✅ 2026-04-17 — `CLISmokeTests` iterates every subcommand in `Senkani.configuration.subcommands`: non-empty commandName + abstract, renders helpMessage(), round-trips `--help` through parseAsRoot, rejects bogus subcommand names. Also caught 9 commands relying on ArgumentParser's default name derivation (now explicit). 7 new tests (1086 total). |
| G7 | HookRelay inline handshake (zero-dep) has no tests | P3 | ✅ 2026-04-17 — `HookRelayHandshakeTests` locks the inline frame format to `SocketAuthToken.handshakeFrame` byte-for-byte over socketpair, covers the 0600 permission guard, whitespace trim, no-op path, and server-side round-trip via `SocketAuthToken.readAndValidate`. Made `loadAuthToken` / `sendHandshake` internal with injectable `path` / `tokenPath` params (zero-dep contract preserved). 10 new tests. |
| G8 | PaneControlTool client-side handshake send not tested | P3 | ✅ 2026-04-17 — `PaneControlHandshakeTests` extracts the inline handshake into `writeHandshakeFrame(fd:tokenPath:)` and covers: no-token no-op, 0644 rejection (must not leak an insecure token onto the wire), byte-identical canonical frame, good/bad server validation, EPIPE short-write returns false. 6 new tests. |
| G9 | `MCPSession.instructionsPayload` end-to-end not tested (only `truncate`) | P3 | ✅ 2026-04-17 — `InstructionsPayloadIntegrationTests` adds 5 end-to-end tests: budget ceiling holds across base + repoMap + brief + skills for tight (256B) and default (2048B) budgets, base always prefix, monotone in budget, empty project returns base-only. Real `MCPSession` with temp project root. |
| G10 | Thin test files: VersionTool, FeatureConfig, WikiLinkCompletion | P3 | ✅ 2026-04-17 — fleshed out: VersionToolTests 3→9 (semver shape, JSON parse, tools list matches+sorted, non-error), FeatureConfigTests 4→11 (default policy, CaseIterable, arithmetic, raw-value contract, config file precedence, flag-beats-file, malformed JSON fallback), WikiLinkCompletionTests 5→14 (closed-then-open, single-bracket rejection, spaces in partial/candidate, round-trip, prefix preservation). 22 new tests. |

## G1 — ProjectSecurity is untested (P1)

`Sources/Core/ProjectSecurity.swift`, 220 LOC. Contract:
- `validateProjectPath(_:)` rejects null bytes, `..` components,
  non-existent paths, non-directories, unreadable paths, symlinks
  that escape allowed roots. Used at workspace-open time to validate
  user-supplied project paths.
- `redactPath(_:)` replaces home dir with `~` and `/Users/<user>`
  with `/Users/***` in log output.

**Risk if untested:**
- Symlink-escape regression silently grants access to /etc, /Library,
  /var/…
- redactPath leaking username into logs (privacy).
- Null-byte truncation attack on C-string APIs.

**Fix shipped this commit:** `ProjectSecurityTests.swift` with 12
cases covering every branch.

## G2 — Migration concurrency test (closed 2026-04-17)

The P1-4 plan called for:
> "concurrency test: spawn two DatabaseQueues against the same file,
> race them, assert only one migration transaction wins."

**Intra-process limitation.** macOS `flock(2)` is a **per-process**
advisory lock. Two `Task.detached` handles inside the same test
process hold the *same* process-level flock and both proceed
concurrently. The second runner's `CREATE TABLE` fails with "table
already exists" — the intra-process race exposes the test's own
limitation, not a bug in `MigrationRunner`. This is why the original
follow-up required a subprocess harness.

**What shipped (prior commit).** `sequentialRunnersAreIdempotent` —
a deterministic test that proves the single-process idempotency
contract: two sequential runs on the same DB, second is a no-op,
sidecar flock file is created. Plus a documented comment explaining
the intra-process flock limitation.

**What shipped 2026-04-17 (this audit trail entry).** Bach G2 is
fully closed by `MigrationMultiProcTests`, which spawns two real
processes (`senkani-mig-helper`, a 60 LOC executable under
`tools/migration-runner/`) via `Foundation.Process`. A shared
barrier file releases both helpers at approximately the same
instant; assertions check the union of applied versions equals the
full registry, exactly one helper applies while the other no-ops,
schema_migrations is fully populated, and no kill-switch lockfile
is written. Additional tests cover (a) two helpers against an
already-migrated DB both no-op and (b) a planted kill-switch
lockfile blocks both concurrent launches.

**Production defect found and fixed.** The multi-process test
failed on first run with `UNIQUE constraint failed:
schema_migrations.version` — the cross-process flock was NOT
serializing the two processes. Root cause: `MigrationRunner.run`
called `FileManager.default.createFile(atPath: dbPath +
".migrating", contents: nil)` immediately before
`open(O_RDWR|O_CREAT)`. `FileManager.createFile` performs an
atomic write (write to temp, rename to target), which unlinks the
existing sidecar and installs a new inode at the same path. A
concurrent process holding flock on the old inode does not
conflict with another process flocking the new inode — both
proceed into the critical section and race on `schema_migrations`.
The fix was a one-line deletion: `open(O_RDWR|O_CREAT)` on its own
creates the file if absent and opens the existing inode if
present, never unlinking. The fix shipped with the test in the
same commit.

## G3 — No property-based or fuzz tests in 91 files (P2)

Every one of the 953 tests is example-based with hand-picked inputs.
For a parser like `isPrivateHost` (which dispatches on dotted-
decimal / IPv6 literal / bracket notation / IPv4-mapped / IPv4-
compat), hand-picked cases cover known bypasses but not edge cases
the author didn't think of.

Swift Testing's `@Test(arguments:)` gives us parameterized testing
without adding a SwiftCheck / Hypothesis dependency. True randomized
fuzz is still a follow-up.

**Fix shipped this commit:** `SSRFTableTests.swift` — 50+ parametric
cases for `isPrivateHost`: every RFC 1918 boundary, CGNAT edges,
IPv6 ULA/link-local/multicast boundaries, IPv4-mapped IPv6 with
private / public / loopback payloads, IPv4-compat IPv6 deprecated
forms. Also table-driven cases for `inet_pton` rejection paths.

## G4 — Redirect policy is not unit-tested (P2)

`NavigationHandler.webView(_:decidePolicyFor:)` enforces the SSRF
defense-in-depth for redirects. Its inner helpers (`isPrivateHost`,
`hostResolvesToPrivate`) are well-tested. The POLICY itself —
first-nav-allowed / redirect-strict-scheme / redirect-host-check /
depth-cap — is only verified through unit tests of the helpers.

**Fix shipped this commit:** extract pure `RedirectPolicy.decide(
url:navigationIndex:allowPrivate:)` from `NavigationHandler`. Tests
call the pure function directly — no WKWebView / no WKNavigationAction
mocking needed. 10 new cases cover:
- initial nav allowed (any scheme)
- redirect to `file://` rejected
- redirect to `data:` rejected
- redirect to `javascript:` rejected
- redirect to public http allowed
- redirect to `10.0.0.1` rejected (privateAddressBlocked)
- redirect to `169.254.169.254` rejected (cloud metadata)
- redirect to `10.0.0.1` allowed when `allowPrivate=true`
- 6th navigation rejected (tooManyRedirects)
- redirect to public https allowed after N<5 redirects

## What we did NOT ship this round (tracked)

G5–G10 stay in the debt list. Priorities for next round: G5 hook
router coverage expansion (Layer-3 interception pathways that affect
every Claude Code interaction).

**Follow-up 2026-04-17.** G5 closed earlier (HookRouter coverage
expansion). G6, G9, G10 closed 2026-04-17. G7, G8 closed 2026-04-17 —
the inline HookRelay handshake and the PaneControlTool client-side
handshake are now covered end-to-end against `SocketAuthToken`'s
canonical format via socketpair round-trips. Bach's entire G1–G10
debt ledger is now GREEN.

## Summary

| Gap | Shipped this commit | Tests added |
|-----|---------------------|-------------|
| G1 ProjectSecurity | ✅ | ~12 |
| G2 Migration concurrency (intra-process) | ✅ | 1 |
| G2 Migration concurrency (multi-process) | ✅ 2026-04-17 | 3 |
| G3 SSRF table expansion | ✅ | ~50 parametric |
| G4 RedirectPolicy extraction | ✅ | 10 |
| G5–G10 | ✅ 2026-04-17 | see G6–G10 rows above |

Expected post-commit test count: 953 + ~73 = ~1026.

## Exit

Bach audit GREEN for the items this round addresses. Two P1 gaps
closed. Test suite now covers the trust boundaries at
`ProjectSecurity` and the previously-theoretical migration
concurrency contract.
