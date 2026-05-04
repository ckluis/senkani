# tools/soak/runner — uninstall-walk runner artifacts

Scripts and bundle artifacts used by `senkani uninstall` real-install
test walks (per-item plans live under `spec/autonomous/`). This
directory is the on-disk surface that v1 and v2 of the
`release-v0-3-0-uninstall-pass*` plans consumed; v3+ plans should
read the **canonical launcher** section below before adding any new
runner-bundle dependency.

## Status

- v1 — closed (`spec/autonomous/completed/2026/2026-04-26-luminary-2026-04-24-15-uninstall-ci-…`).
- v2 — closed (`spec/autonomous/completed/2026/2026-05-03-release-v0-3-0-uninstall-pass-v2-plan-amendments-fix-three-defects-from-2026-05-02-walk.md`).
  v2-walk scripts: `tools/soak/v2-walk/phase-{1,2,3,3a-checks,6-checks}.sh`.
- v3+ — no plan groomed yet. When authoring, copy the **smoke-launch**
  and **derived-data-fresh** probes below into `## Pre-conditions`.

## Canonical launcher (v3+)

`tools/soak/runner/SenkaniApp.app` is **deprecated**: on the
2026-05-03 v2 walk it crashed instantly on `open -a` despite passing
the v2 `runner-app-fresh` mtime probe (Finding #1, archived in the v2
closure record above). Mtime-freshness checks freshness, not
correctness — a bundle can be fresh and broken.

The bundle is left in place for audit-trail reasons (do not delete);
do not launch it. The canonical launcher path is:

1. Open the project in Xcode (`Senkani.xcworkspace` or
   `Package.swift`).
2. Click **Play** (or `Product → Build` then `Product → Run`).
3. Xcode builds the app under
   `~/Library/Developer/Xcode/DerivedData/senkani-*/Build/Products/Debug/SenkaniApp.app`
   and launches the binary at
   `~/Library/Developer/Xcode/DerivedData/senkani-*/Build/Products/Debug/SenkaniApp`.
4. The Xcode-launched bundle is the **DerivedData binary**. The
   operator's `~/.claude/settings.json` `mcpServers.senkani.command`
   path captures the resolved DerivedData path on a registered
   install (e.g.
   `~/Library/Developer/Xcode/DerivedData/senkani-aythacdltelkegejecsazpxwajad/Build/Products/Debug/SenkaniApp`
   on the operator's 2026-05-03 walk machine).
5. The DerivedData hash (`-aythacdltelkegejecsazpxwajad` etc.) varies
   per machine. Probes below glob `senkani-*` and resolve to the
   newest match.

A future build-system fix MAY restore `tools/soak/runner/SenkaniApp.app`
as a launchable bundle. That work is out of scope for path (b) and
filed as path (a) on `runner-bundle-smoke-launch-precondition`.
Until path (a) lands, treat the bundle as a build artifact with
unknown launch state.

## Probes for v3+ pre-conditions

Both probes are read-only (probe.sh-style) and can be pasted into a
test plan's `## Setup` block.

### derived-data-fresh — replaces v2's `runner-app-fresh`

Verifies the Xcode DerivedData binary is at least as recent as the
newest `SenkaniApp/*.swift` source file. Replaces the v2-walk's
`runner-app-fresh` probe (which probed the deprecated bundle).

```sh
# derived-data-fresh — fail the test if Xcode binary is older than source.
DERIVED_BIN=$(ls -1t ~/Library/Developer/Xcode/DerivedData/senkani-*/Build/Products/Debug/SenkaniApp 2>/dev/null | head -1)
if [ -z "$DERIVED_BIN" ]; then
  echo "derived-data-fresh: ERROR (no Xcode DerivedData build of SenkaniApp found — Build the app in Xcode first)"
  exit 1
fi
SRC_NEWEST=$(find "$SENKANI_REPO/SenkaniApp" -type f -name '*.swift' -exec stat -f '%m %N' {} \; 2>/dev/null | sort -nr | head -1 | cut -d' ' -f1)
BIN_MTIME=$(stat -f '%m' "$DERIVED_BIN" 2>/dev/null || echo 0)
if [ -z "$SRC_NEWEST" ]; then
  echo "derived-data-fresh: ERROR (no .swift files under $SENKANI_REPO/SenkaniApp)"
  exit 1
elif [ "$BIN_MTIME" -ge "$SRC_NEWEST" ]; then
  echo "derived-data-fresh: OK (bin=$BIN_MTIME src=$SRC_NEWEST $DERIVED_BIN)"
else
  echo "derived-data-fresh: STALE (bin=$BIN_MTIME src=$SRC_NEWEST) — open Xcode and Build the app"
  exit 1
fi
```

### smoke-launch — necessary companion to derived-data-fresh

Freshness alone does not catch a crashing bundle (Finding #1). The
smoke-launch probe runs the binary, waits 3 seconds, asserts a PID
is alive, then quits. Add this AFTER `derived-data-fresh` and BEFORE
any pre-condition that mutates operator state.

```sh
# smoke-launch — fail the test if SenkaniApp crashes on launch.
# Must run from a clean state (no other SenkaniApp instance running).
if pgrep -f "SenkaniApp" >/dev/null; then
  echo "smoke-launch: SKIPPED (SenkaniApp already running — quit it before re-running this probe)"
else
  open -a "$DERIVED_BIN" >/dev/null 2>&1 &
  sleep 3
  if pgrep -f "SenkaniApp" >/dev/null; then
    echo "smoke-launch: OK"
    osascript -e 'tell application "SenkaniApp" to quit' 2>/dev/null \
      || pkill -x SenkaniApp 2>/dev/null \
      || true
    sleep 1
  else
    echo "smoke-launch: FAIL (DerivedData binary at $DERIVED_BIN crashed within 3s)"
    exit 1
  fi
fi
```

`open -a "$DERIVED_BIN"` works because `$DERIVED_BIN` resolves to a
binary inside a `.app` bundle — `open -a` accepts both the `.app`
path and an executable inside it. If you have a notarized
`/Applications/SenkaniApp.app`, prefer that path —
`open -a /Applications/SenkaniApp.app` skips Gatekeeper.

### prerunning-process — pre-condition (optional, recommended)

Catches a still-running SenkaniApp instance from a prior session
(see Finding #3 in the v2 closure record). Silently re-creating
`workspace.json` between Step 2 and Step 3 contaminated v2 walk
state — the strict-moment post-checks held but the transient
contamination warrants an upfront probe.

```sh
# prerunning-process — fail the test if SenkaniApp is already running.
if pgrep -f "SenkaniApp" >/dev/null; then
  echo "prerunning-process: FAIL (SenkaniApp PIDs: $(pgrep -f SenkaniApp | tr '\n' ' '))"
  echo "  Quit SenkaniApp via the dock or Cmd+Q, then re-run."
  exit 1
else
  echo "prerunning-process: OK (no SenkaniApp instance)"
fi
```

This probe is filed as a separate backlog item
(`uninstall-test-plan-prerunning-process-precondition`) but the
text lives here so the v3 author can paste from one place.

## Inventory

| File | Origin | Status |
| --- | --- | --- |
| `SenkaniApp.app/` | v1 ad-hoc bundle | DEPRECATED — crashes on launch (Finding #1). Do not use. |
| `00-probe-only.command` … `15-finalize-fixed.command` | v1 numbered launchers | Kept for audit; superseded by `tools/soak/v2-walk/phase-{1,2,3,3a-checks,6-checks}.sh`. |
| `_lib.sh`, `phase-a.sh`, `phase-c.sh`, `phase-e.sh`, `probe.sh` | v1 phase scripts | Kept for audit; superseded by v2-walk scripts. |
| `.phase-NN-done`, `.phase-NN-pid` | v1 progress markers | Stale; safe to delete on the operator's next clean-up. |
| `05-status.log`, `06-app.std{out,err}`, `06-launch.log`, `08-bundle.log`, `11-diag.log`, `12-diag.log` | v1 walk logs | Audit-trail; do not delete until v0.3.0 ships clean. |

## Cross-references

- Originating finding:
  `spec/autonomous/completed/2026/2026-05-03-release-v0-3-0-uninstall-pass-v2-plan-amendments-fix-three-defects-from-2026-05-02-walk.md`
  → `### Findings` → entry **1**.
- Backlog item shipping this README:
  `spec/autonomous/completed/2026/<close-date>-runner-bundle-smoke-launch-precondition-…`
  (path resolved at close).
- Bundle ID: `dev.senkani.app`. CFBundleExecutable: `SenkaniApp`.
- v2-walk scripts that reference the deprecated bundle's
  `runner-app-fresh` probe: `tools/soak/v2-walk/phase-1.sh:46-56`.
  Annotated in-place to point future authors here.
