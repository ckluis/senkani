#!/usr/bin/env bash
# measure-slos — capture the four release-commitment numbers from
# spec/slos.md (Phase V.14) and append a JSON row to
# ~/.senkani/slo-history.jsonl.
#
#   cold.start       p95 of `senkani --version` wall-time across N=20 runs
#   idle.memory      RSS of senkani-mcp after a 10 s settle (null if down)
#   install.size     du -sk of .build/release (or override path)
#   classifier.p95   null until U.1 TierScorer lands
#
# The doctor surface (`senkani doctor`) reads this file and renders
# the latest row + a regression check (median-of-5 baseline, ≥10%
# fails).
#
# Usage
#   ./tools/measure-slos.sh                     # measure all four
#   ./tools/measure-slos.sh --print             # print, don't append
#   ./tools/measure-slos.sh --release-dir DIR   # override install-size dir
#   ./tools/measure-slos.sh --history PATH      # override history path
#
# Exits 0 on success. Non-zero only if the binary won't even run.

set -euo pipefail

cd "$(dirname "$0")/.."

PRINT_ONLY=0
RELEASE_DIR=".build/release"
HISTORY_PATH="${HOME}/.senkani/slo-history.jsonl"
COLD_START_RUNS=20

while [ $# -gt 0 ]; do
  case "$1" in
    --print)        PRINT_ONLY=1 ;;
    --release-dir)  RELEASE_DIR="$2"; shift ;;
    --history)      HISTORY_PATH="$2"; shift ;;
    --runs)         COLD_START_RUNS="$2"; shift ;;
    *) echo "unknown flag: $1" >&2; exit 2 ;;
  esac
  shift
done

# --- cold-start: p95 of `senkani --version` -----------------------
SENKANI_BIN="${RELEASE_DIR}/senkani"
COLD_START_P95="null"

if [ -x "${SENKANI_BIN}" ]; then
  # Warm-up: page the binary in so the first measured run isn't a
  # cold-disk outlier. p95 measures CLI startup, not disk seek.
  "${SENKANI_BIN}" --version > /dev/null 2>&1 || true

  TMP_SAMPLES="$(mktemp)"
  trap 'rm -f "${TMP_SAMPLES}"' EXIT

  i=0
  while [ "$i" -lt "${COLD_START_RUNS}" ]; do
    # python3 ships on macOS; gives microsecond wall-time without GNU date.
    python3 -c '
import subprocess, time, sys
t0 = time.perf_counter()
subprocess.run([sys.argv[1], "--version"],
               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
               check=False)
print((time.perf_counter() - t0) * 1000.0)
' "${SENKANI_BIN}" >> "${TMP_SAMPLES}"
    i=$((i + 1))
  done

  COLD_START_P95="$(python3 -c '
import sys
samples = sorted(float(x) for x in open(sys.argv[1]) if x.strip())
if not samples:
    print("null"); sys.exit()
# Linear-interpolation p95 — same recipe as Sources/Core/SLO.swift.
q = 0.95 * (len(samples) - 1)
lo = int(q)
hi = min(lo + 1, len(samples) - 1)
frac = q - lo
print(round(samples[lo] * (1 - frac) + samples[hi] * frac, 1))
' "${TMP_SAMPLES}")"
fi

# --- idle memory: RSS of senkani-mcp after 10 s settle ------------
IDLE_MEMORY_MB="null"
MCP_PID="$(pgrep -x senkani-mcp 2>/dev/null | head -1 || true)"
if [ -n "${MCP_PID}" ]; then
  sleep 10
  RSS_KB="$(ps -o rss= -p "${MCP_PID}" 2>/dev/null | tr -d '[:space:]' || true)"
  if [ -n "${RSS_KB}" ]; then
    IDLE_MEMORY_MB="$(python3 -c "print(round(${RSS_KB} / 1024.0, 1))")"
  fi
fi

# --- install size: du -sk of release dir --------------------------
INSTALL_SIZE_MB="null"
if [ -d "${RELEASE_DIR}" ]; then
  SIZE_KB="$(du -sk "${RELEASE_DIR}" | awk '{print $1}')"
  INSTALL_SIZE_MB="$(python3 -c "print(round(${SIZE_KB} / 1024.0, 1))")"
fi

# --- classifier p95: null pending U.1 -----------------------------
CLASSIFIER_P95_MS="null"

# --- provenance ---------------------------------------------------
GIT_SHA="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
VERSION="$(grep -E 'version\s*=' Package.swift 2>/dev/null | head -1 \
            | sed 's/.*"\(.*\)".*/\1/' || echo unknown)"
if [ -z "${VERSION}" ] || [ "${VERSION}" = "unknown" ]; then
  # Fallback: scrape from CHANGELOG.md "## v0.2.0" style header.
  VERSION="$(grep -m1 -E '^## v' CHANGELOG.md 2>/dev/null \
              | sed 's/^## v\([^ ]*\).*/\1/' || echo unknown)"
fi
TS="$(python3 -c 'import time; print(round(time.time(), 3))')"

ROW="$(python3 -c '
import json, sys
def parse(x):
    return None if x == "null" else float(x)
print(json.dumps({
    "ts": float(sys.argv[1]),
    "git_sha": sys.argv[2],
    "version": sys.argv[3],
    "cold_start_ms_p95": parse(sys.argv[4]),
    "idle_memory_mb": parse(sys.argv[5]),
    "install_size_mb": parse(sys.argv[6]),
    "classifier_p95_ms": parse(sys.argv[7]),
}, sort_keys=True))
' "${TS}" "${GIT_SHA}" "${VERSION}" "${COLD_START_P95}" \
    "${IDLE_MEMORY_MB}" "${INSTALL_SIZE_MB}" "${CLASSIFIER_P95_MS}")"

echo "${ROW}"

if [ "${PRINT_ONLY}" -eq 0 ]; then
  mkdir -p "$(dirname "${HISTORY_PATH}")"
  printf '%s\n' "${ROW}" >> "${HISTORY_PATH}"
fi
