#!/usr/bin/env bash
#
# check-push-gap.sh — warn when local `main` has drifted too far ahead of
# `origin/main` (unpushed). Run at session start.
#
# Surfaced by the 2026-06-08 luminary groom (decision D3, panel
# Majors/Allspaw/Bach/Carmack): origin/main silently fell 358 commits / a
# month behind local `main`, so CI was effectively dark and the loop shipped
# CI-red code undetected. This is the cheap, buildable half of the D3
# mechanism — the observable push-gap signal. (The loop-side close-gate /
# hard-block-next-round-on-CI-red is the SKILL.md-edit remainder, NOT here.)
#
# Usage:
#   tools/check-push-gap.sh [threshold]   # default threshold: 3
#   tools/check-push-gap.sh --self-test   # exercise the verdict logic, no git
#
# Exit codes:
#   0  gap within threshold, OR no origin/main ref to compare against
#   3  gap exceeds threshold (fail-CLOSED WARN — push or open a PR)
#   2  usage error
#
set -euo pipefail

# Pure verdict function: (count, threshold) -> prints a line, returns 0 or 3.
# No git, no I/O beyond echo — this is what --self-test pins.
evaluate_gap() {
  local count="$1" threshold="$2"
  if [ "$count" -gt "$threshold" ]; then
    echo "WARN: ${count} unpushed commit(s) on main (> ${threshold}) — push or open a PR before the gap grows (luminary D3 fail-CLOSED ceiling)."
    return 3
  fi
  echo "OK: ${count} unpushed commit(s) on main (<= ${threshold})."
  return 0
}

self_test() {
  local fails=0 rc out
  # over threshold -> rc 3
  out="$(evaluate_gap 5 3)" && rc=0 || rc=$?
  { [ "$rc" -eq 3 ] && [[ "$out" == WARN:* ]]; } || { echo "self-test FAIL: 5>3 expected rc3/WARN, got rc${rc}: ${out}"; fails=1; }
  # at threshold -> rc 0
  out="$(evaluate_gap 3 3)" && rc=0 || rc=$?
  { [ "$rc" -eq 0 ] && [[ "$out" == OK:* ]]; } || { echo "self-test FAIL: 3==3 expected rc0/OK, got rc${rc}: ${out}"; fails=1; }
  # under threshold -> rc 0
  out="$(evaluate_gap 0 3)" && rc=0 || rc=$?
  { [ "$rc" -eq 0 ] && [[ "$out" == OK:* ]]; } || { echo "self-test FAIL: 0<3 expected rc0/OK, got rc${rc}: ${out}"; fails=1; }
  if [ "$fails" -eq 0 ]; then echo "check-push-gap self-test: PASS"; return 0; fi
  return 1
}

main() {
  if [ "${1:-}" = "--self-test" ]; then
    self_test
    exit $?
  fi
  local threshold="${1:-${PUSH_GAP_THRESHOLD:-3}}"
  case "$threshold" in
    ''|*[!0-9]*) echo "usage: $0 [threshold-nonneg-int] | --self-test" >&2; exit 2 ;;
  esac

  if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "note: not inside a git work tree; skipping push-gap check."; exit 0
  fi
  if ! git rev-parse --verify --quiet origin/main >/dev/null 2>&1; then
    echo "note: no origin/main ref (fetch first?); cannot measure push gap — skipping."; exit 0
  fi
  local count
  count="$(git rev-list --count origin/main..main 2>/dev/null || echo 0)"

  set +e
  evaluate_gap "$count" "$threshold"
  local rc=$?
  set -e
  exit "$rc"
}

main "$@"
