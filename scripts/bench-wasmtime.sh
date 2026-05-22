#!/usr/bin/env bash
# bench-wasmtime.sh — measure per-invocation subprocess overhead of `wasmtime`.
#
# Drives the senkani T.3a conditional-gate decision (subprocess-vs-embedded
# wasm runtime). Runs N=100 subprocess invocations of a minimal empty-`_start`
# wasm module, captures wall-clock timing per invocation, and writes a markdown
# table to stdout with cold-start / warm-median / p95 / capture-method.
#
# Gates (carried verbatim from the T.3a parent acceptance):
#   cold-start    ≤ 50 ms
#   warm-median   ≤  5 ms
#
# If both gates met → recorded as `subprocess (final)` in spec/architecture.md.
# If either missed → conditional follow-up `phase-t3-embedded-runtime-revisit`
# is filed with the miss-margin, and `subprocess (provisional)` is recorded.
#
# Usage:
#   ./scripts/bench-wasmtime.sh             # build .wasm via wasm-tools, run N=100
#   ./scripts/bench-wasmtime.sh --module=/path/to/prebuilt.wasm   # skip build
#   ./scripts/bench-wasmtime.sh -n 200      # override iteration count
#   ./scripts/bench-wasmtime.sh --help
#
# Prereqs:
#   - wasmtime (brew install wasmtime)
#   - one of: wasm-tools (brew install wasm-tools), OR a prebuilt .wasm via --module=

set -euo pipefail

N=100
MODULE=""
SHOW_HELP=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    -n) N="$2"; shift 2 ;;
    --module=*) MODULE="${1#--module=}"; shift ;;
    --module) MODULE="$2"; shift 2 ;;
    -h|--help) SHOW_HELP=1; shift ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

if [[ "$SHOW_HELP" == "1" ]]; then
  sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'
  exit 0
fi

if ! command -v wasmtime >/dev/null 2>&1; then
  echo "error: wasmtime not on PATH. Install via: brew install wasmtime" >&2
  exit 1
fi

# Resolve the wasm module: prefer --module=, else assemble from inline .wat.
if [[ -z "$MODULE" ]]; then
  if ! command -v wasm-tools >/dev/null 2>&1; then
    echo "error: wasm-tools not on PATH and no --module= given." >&2
    echo "hint: brew install wasm-tools  OR  pass --module=/path/to/prebuilt.wasm" >&2
    exit 1
  fi
  TMPDIR_BENCH="$(mktemp -d)"
  trap 'rm -rf "$TMPDIR_BENCH"' EXIT
  WAT="$TMPDIR_BENCH/empty.wat"
  MODULE="$TMPDIR_BENCH/empty.wasm"
  cat >"$WAT" <<'WAT_EOF'
(module
  (func (export "_start"))
)
WAT_EOF
  wasm-tools parse "$WAT" -o "$MODULE"
fi

if [[ ! -r "$MODULE" ]]; then
  echo "error: module not readable: $MODULE" >&2
  exit 1
fi

# Pick a millisecond-precision timer. macOS `date +%s%N` is BSD and does NOT
# support nanoseconds; prefer GNU `gdate` (brew install coreutils) if present,
# else fall back to `python3` which is shipped on every recent macOS.
CAPTURE_METHOD=""
time_ms() {
  if [[ -n "${USE_GDATE:-}" ]]; then
    gdate +%s%3N
  elif [[ -n "${USE_PYTHON:-}" ]]; then
    python3 -c 'import time; print(int(time.monotonic()*1000))'
  fi
}

if command -v gdate >/dev/null 2>&1 && [[ "$(gdate +%N)" != "N" ]]; then
  USE_GDATE=1
  CAPTURE_METHOD="gdate +%s%3N (GNU coreutils, ms precision)"
elif command -v python3 >/dev/null 2>&1; then
  USE_PYTHON=1
  CAPTURE_METHOD="python3 time.monotonic() (ms precision)"
else
  echo "error: no ms-precision clock available (need gdate or python3)" >&2
  exit 1
fi

# Run the bench. First invocation is cold (binary not paged in, .wasm cache cold).
# Subsequent invocations are warm.
SAMPLES=()
for ((i=0; i<N; i++)); do
  T0="$(time_ms)"
  wasmtime run --invoke _start "$MODULE" >/dev/null 2>&1 || {
    echo "error: wasmtime invocation $i failed" >&2
    exit 1
  }
  T1="$(time_ms)"
  SAMPLES+=("$((T1 - T0))")
done

# Compute cold (sample 0), warm-median (samples 1..N-1), p95 (samples 1..N-1).
COLD="${SAMPLES[0]}"
WARM_SAMPLES=("${SAMPLES[@]:1}")

# Sort warm samples ascending. bash has no sort-builtin; pipe through sort -n.
SORTED_WARM=()
while IFS= read -r line; do SORTED_WARM+=("$line"); done < <(printf '%s\n' "${WARM_SAMPLES[@]}" | sort -n)
WARM_COUNT="${#SORTED_WARM[@]}"
MED_IDX=$(( WARM_COUNT / 2 ))
P95_IDX=$(( (WARM_COUNT * 95 + 99) / 100 - 1 ))
[[ "$P95_IDX" -lt 0 ]] && P95_IDX=0
WARM_MEDIAN="${SORTED_WARM[$MED_IDX]}"
WARM_P95="${SORTED_WARM[$P95_IDX]}"

WASMTIME_VERSION="$(wasmtime --version 2>/dev/null | head -1)"

cat <<EOF
| cold (ms) | warm-median (ms) | p95 (ms) | capture method |
|-----------|------------------|----------|----------------|
| $COLD | $WARM_MEDIAN | $WARM_P95 | $CAPTURE_METHOD |

Bench config: N=$N invocations (1 cold + $WARM_COUNT warm), module=$(basename "$MODULE"), runtime=$WASMTIME_VERSION
EOF
