#!/usr/bin/env bash
# test-safe — chunked deterministic full-suite run for senkani.
#
# Background
#   `swift test` (and the prior all-in-one wrapper of this script) runs
#   the entire ~1600-test suite in a single `swiftpm-testing-helper`
#   process. A `signal code 5` (SIGTRAP) inside that process — see
#   `spec/testing.md` "Full-suite hang" — kills the whole run and
#   leaves us blind to every test that would have run after the crash
#   point. CI run 25213437924 hit this on all three retries.
#
#   This script splits the suite into named CHUNKS, each run as its
#   own `swift test --no-parallel --filter <regex>` invocation. A
#   crash in one chunk fails only that chunk; the rest still run to
#   completion and contribute their pass/fail signal. Per-chunk
#   retry-on-flake is preserved for the SIGTRAP-prone chunks.
#
#   The script's overall exit is the OR of all chunk exits — any
#   genuine red still red-lines the harness.
#
# Usage
#   ./tools/test-safe.sh                # run every chunk
#   ./tools/test-safe.sh --filter Foo   # passthrough single filter
#                                       # (skips chunking; matches
#                                       #  the legacy single-process
#                                       #  workflow for ad-hoc runs)
#   ./tools/test-safe.sh --chunk NAME   # run a single named chunk
#                                       # (useful for CI matrix +
#                                       #  bisect)
#   ./tools/test-safe.sh --list-chunks  # print chunk regex table
#
# Knobs
#   SWT_NO_PARALLEL=1       Disables Swift Testing's intra-process
#                           parallelism. Set automatically by every
#                           chunk run; stays off for passthrough too.
#   TEST_SAFE_RETRIES=N     Per-chunk retry count on SIGTRAP / non-
#                           zero exit. Default 3.
#   SKIP_MULTIPLIER_CHECK,
#   SKIP_GRAMMAR_HASH_CHECK Skip the two pre-flight guard scripts
#                           (set when re-running after a known-good
#                           pre-flight or when bisecting older
#                           commits without those guards).
#   SKIP_MIG_HELPER_CHECK   Skip the stale-`senkani-mig-helper`-process
#                           pre-flight guard. Off by default — a fresh
#                           `swift test` cannot start while leftover
#                           helpers from a previous run are still alive
#                           (they will contend for the same flock /tmp
#                           sidecars and have historically deadlocked
#                           fresh runs). See
#                           spec/autonomous/backlog/swift-test-suite-hang-mig-helper-zombies-2026-05-14.md.
#   FORCE_REAP_MIG_HELPERS  When the guard finds stale helpers, send
#                           SIGKILL and continue. Default behavior is to
#                           print PIDs + cputime + tmp-dir paths and
#                           refuse to start the run.
#
# Adding a new suite to the harness
#   New tests fall into the catch-all `other` chunk by default.
#   If a suite is heavy or shares the SIGTRAP-prone area
#   (file watcher / SQLite migration / per-test-temp-DB churn), add
#   its prefix to the matching chunk regex below — chunks are
#   grouped by topical proximity, not file count.

set -uo pipefail
cd "$(dirname "$0")/.."

# ---------------------------------------------------------------------
# Chunk table — (name, filter-regex). Order is the run order.
#
# Catch-all "other" chunk is constructed at run-time from the union
# of every other chunk's regex (skip-inverted). New chunks added
# above "other" automatically narrow it.
# ---------------------------------------------------------------------
CHUNKS=(
  "parsers:TreeSitter|GrammarManifest|GrammarStaleness"
  "learning:Compound|ContextPlan|Combinator|InstructionSignal|AnnotationSignal|ContextSignal|EnrichmentValidator|EnrichmentWorkflow|MultiplierClaim|ReflectiveLearningRun|PromptArtifactRegression"
  "kb:Knowledge|KB[A-Z]|PinnedContext|EntityTracker"
  "pane:Pane[A-Z]|PaneRefresh|PaneSocket|PaneFont|PaneGallery|PaneDiary|Browser|Workspace|Workstream|Schedule|Watch|RelationsGraph"
  "hook:Hook|ConfirmationGate|AutoValidate|InjectionGuard|SecretDetector|EntropyDetector|HookRelayHandshake"
  "session:Migration|SessionDatabase|TokenEventStore|Chain[A-Z]|Agent[A-Z]|ClaudeSession|ValidationStore|Sandbox|Authorship|Daemon|RetentionScheduler|Logger|Persistence|StoreExec"
  "onboarding:Onboarding|Welcome|FCSIT|FirstValue|TaskStarter|LaunchCoordinator|ActivationStatus|EmptyState|DocsTruth|DocsShape|CommandPalette"
)

# ---------------------------------------------------------------------
# Args / mode resolution
# ---------------------------------------------------------------------
MODE="all"                  # all | filter | chunk | list
PASSTHROUGH_FILTER=""
SELECTED_CHUNK=""
RETRIES="${TEST_SAFE_RETRIES:-3}"

while [ $# -gt 0 ]; do
  case "$1" in
    --filter)
      MODE="filter"
      PASSTHROUGH_FILTER="$2"
      shift 2
      ;;
    --chunk)
      MODE="chunk"
      SELECTED_CHUNK="$2"
      shift 2
      ;;
    --list-chunks)
      MODE="list"
      shift
      ;;
    *)
      # Unknown args — pass through to swift test (legacy contract).
      MODE="filter"
      PASSTHROUGH_FILTER="$*"
      break
      ;;
  esac
done

# ---------------------------------------------------------------------
# Pre-flight guards (Luminary P0 round 2026-04-24-0 + P2 2026-04-24-13)
# ---------------------------------------------------------------------
preflight() {
  if [ -z "${SKIP_MULTIPLIER_CHECK:-}" ] && [ -x ./tools/check-multiplier-claims.sh ]; then
    ./tools/check-multiplier-claims.sh
  fi
  if [ -z "${SKIP_GRAMMAR_HASH_CHECK:-}" ] && [ -x ./tools/verify-grammar-hashes.sh ]; then
    ./tools/verify-grammar-hashes.sh
  fi
  # Stale-helper guard. Refuses to start a new test run while any
  # senkani-mig-helper process from a previous (likely-deadlocked) run
  # is still alive — fresh test spawns would compete with them for
  # /tmp sidecars and have historically deadlocked the whole suite.
  # Operator can override with FORCE_REAP_MIG_HELPERS=1 to send SIGKILL
  # and continue, or SKIP_MIG_HELPER_CHECK=1 to bypass the check entirely.
  if ! mig_helper_zombie_guard; then
    exit 2
  fi
  # /tmp staleness alarm — a future test that creates `SessionDatabase(path:)`
  # without the canonical sidecar cleanup (see
  # Tests/SenkaniTests/Helpers/TempSessionDatabase.swift) leaks `.migrating`
  # and `.schema.lock` flock sidecars to /tmp every run. This warns when
  # accumulation crosses a stale-state threshold so the regression
  # surfaces during local dev rather than after months of buildup.
  if [ -z "${SKIP_TMP_STALENESS_CHECK:-}" ]; then
    local stale
    stale="$(/bin/ls -1 /tmp 2>/dev/null | grep -c '^senkani-' || true)"
    if [ "${stale:-0}" -gt 50 ]; then
      echo "::warning::/tmp has ${stale} leftover senkani-* files —" \
           "likely a test creating SessionDatabase(path:) without calling" \
           "TempSessionDatabase.cleanup(path:) at teardown." \
           "Clear with: rm /tmp/senkani-*"
    fi
  fi
}

# Stale-helper guard. Detects leftover `senkani-mig-helper` processes
# from a previous (likely-deadlocked) test run and either reaps them
# (FORCE_REAP_MIG_HELPERS=1) or prints them and exits non-zero. Background:
# pre-2026-05-15 each MigrationMultiProcTests test inlined an unbounded
# busy-poll on a parent-supplied `go` file; if the parent test crashed
# before writing `go`, the helper spun forever. Across Apr/May 2026 this
# leaked ~18 zombies that accumulated ~90 min of CPU each. The helper-side
# timeout (commit 2026-05-15) keeps new tests from leaking, but any
# residual zombies from before the fix can still deadlock a fresh suite.
# This guard catches them.
mig_helper_zombie_guard() {
  if [ -n "${SKIP_MIG_HELPER_CHECK:-}" ]; then
    return 0
  fi
  local pids
  pids="$(pgrep -f senkani-mig-helper 2>/dev/null || true)"
  if [ -z "$pids" ]; then
    return 0
  fi
  local n
  n="$(echo "$pids" | wc -l | tr -d ' ')"
  echo "::error::found ${n} stale senkani-mig-helper process(es) — running new tests will compete with them and may deadlock the suite:"
  # `ps` accepts a space-separated PID list via -p.
  # shellcheck disable=SC2086
  ps -o pid,etime,cputime,command -p $pids 2>/dev/null | head -50 || true
  if [ -n "${FORCE_REAP_MIG_HELPERS:-}" ]; then
    echo "FORCE_REAP_MIG_HELPERS=1 — sending SIGKILL to ${n} process(es)"
    # shellcheck disable=SC2086
    kill -9 $pids 2>/dev/null || true
    # Give the kernel up to 2 s to reap; in practice this is sub-second.
    local waited=0
    while [ "$waited" -lt 20 ]; do
      sleep 0.1
      waited=$(( waited + 1 ))
      if [ -z "$(pgrep -f senkani-mig-helper 2>/dev/null || true)" ]; then
        echo "reaped ${n} stale helper(s); continuing"
        return 0
      fi
    done
    local remaining
    remaining="$(pgrep -f senkani-mig-helper 2>/dev/null || true)"
    echo "::error::reap failed — ${remaining} still alive"
    return 1
  fi
  echo
  echo "to reap and continue: FORCE_REAP_MIG_HELPERS=1 $0 $*"
  echo "to bypass guard:      SKIP_MIG_HELPER_CHECK=1 $0 $*"
  echo "to reap manually:     pkill -9 -f senkani-mig-helper"
  return 1
}

# /tmp staleness post-flight (runs in the all-mode tail). Same idea as the
# pre-flight but compares pre vs post: if the suite leaves the floor
# materially dirtier than it found it, name it. Soft warning only — the
# pre-flight already absolves stale state at startup.
tmp_staleness_postcheck() {
  if [ -z "${SKIP_TMP_STALENESS_CHECK:-}" ] && [ -n "${TEST_SAFE_TMP_BASELINE:-}" ]; then
    local now
    now="$(/bin/ls -1 /tmp 2>/dev/null | grep -c '^senkani-' || true)"
    local delta=$(( now - TEST_SAFE_TMP_BASELINE ))
    if [ "$delta" -gt 50 ]; then
      echo "::warning::test run leaked ${delta} new senkani-* files to /tmp" \
           "(baseline ${TEST_SAFE_TMP_BASELINE}, now ${now})." \
           "Likely a test missing TempSessionDatabase.cleanup(path:)."
    fi
  fi
}

# ---------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------
chunk_regex() {
  # echo the regex for a named chunk, or build the "other" catch-all
  # from the inverse of every other chunk's regex.
  local name="$1"
  if [ "$name" = "other" ]; then
    # Caller uses --skip on each non-other regex; we don't return a
    # filter regex for "other".
    echo ""
    return 0
  fi
  for entry in "${CHUNKS[@]}"; do
    local n="${entry%%:*}"
    local r="${entry#*:}"
    if [ "$n" = "$name" ]; then
      echo "$r"
      return 0
    fi
  done
  return 1
}

list_chunks() {
  printf '%-14s  %s\n' "CHUNK" "FILTER REGEX"
  for entry in "${CHUNKS[@]}"; do
    local n="${entry%%:*}"
    local r="${entry#*:}"
    printf '%-14s  %s\n' "$n" "$r"
  done
  printf '%-14s  %s\n' "other" "(everything not matched by the above)"
}

# Run swift test for one chunk. Retries on non-zero exit (covers the
# SIGTRAP flake until `bisect-sigtrap-source` lands a real fix).
run_chunk() {
  local name="$1"
  local args=()
  if [ "$name" = "other" ]; then
    # Catch-all: skip every other chunk's regex.
    for entry in "${CHUNKS[@]}"; do
      local r="${entry#*:}"
      args+=(--skip "$r")
    done
  else
    local regex
    regex="$(chunk_regex "$name")" || {
      echo "::error::unknown chunk '$name'"
      return 2
    }
    args+=(--filter "$regex")
  fi

  export SWT_NO_PARALLEL=1
  local attempt=1
  local start_ts
  start_ts="$(date +%s)"
  while [ "$attempt" -le "$RETRIES" ]; do
    echo "::group::chunk[$name] attempt $attempt of $RETRIES"
    if swift test --no-parallel "${args[@]}"; then
      echo "::endgroup::"
      local elapsed=$(( $(date +%s) - start_ts ))
      echo "✓ chunk[$name] passed (attempt $attempt, ${elapsed}s)"
      return 0
    fi
    local rc=$?
    echo "::endgroup::"
    if [ "$attempt" -lt "$RETRIES" ]; then
      echo "::warning::chunk[$name] attempt $attempt failed (exit $rc) — retrying"
    fi
    attempt=$(( attempt + 1 ))
  done
  local elapsed=$(( $(date +%s) - start_ts ))
  # Surface as a CI annotation so the PR UI links straight to the
  # offending chunk instead of forcing a log dive.
  echo "::error title=chunk[$name] failed::after $RETRIES attempts (${elapsed}s) — likely swiftpm-testing-helper SIGTRAP, see spec/testing.md"
  echo "✘ chunk[$name] failed after $RETRIES attempts (${elapsed}s)"
  return 1
}

# ---------------------------------------------------------------------
# Mode dispatch
# ---------------------------------------------------------------------
case "$MODE" in
  list)
    list_chunks
    exit 0
    ;;
  filter)
    preflight
    export SWT_NO_PARALLEL=1
    # Legacy passthrough — single process, no retries. Backwards-
    # compat with `tools/test-safe.sh --filter Foo` usage.
    # shellcheck disable=SC2086
    exec swift test --no-parallel --filter $PASSTHROUGH_FILTER
    ;;
  chunk)
    preflight
    run_chunk "$SELECTED_CHUNK"
    exit $?
    ;;
  all)
    preflight
    # Capture /tmp baseline so the post-flight can name a leak delta.
    TEST_SAFE_TMP_BASELINE="$(/bin/ls -1 /tmp 2>/dev/null | grep -c '^senkani-' || true)"
    export TEST_SAFE_TMP_BASELINE
    overall=0
    declare -a SUMMARY=()
    # Run each named chunk, then the catch-all.
    for entry in "${CHUNKS[@]}"; do
      name="${entry%%:*}"
      if run_chunk "$name"; then
        SUMMARY+=("✓ $name")
      else
        SUMMARY+=("✘ $name")
        overall=1
      fi
    done
    if run_chunk "other"; then
      SUMMARY+=("✓ other")
    else
      SUMMARY+=("✘ other")
      overall=1
    fi

    echo
    echo "test-safe chunk summary:"
    for line in "${SUMMARY[@]}"; do
      echo "  $line"
    done
    tmp_staleness_postcheck
    if [ "$overall" -eq 0 ]; then
      echo "test-safe: all chunks green"
    else
      echo "test-safe: at least one chunk failed (see summary above)"
    fi
    exit $overall
    ;;
esac
