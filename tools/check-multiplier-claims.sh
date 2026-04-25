#!/usr/bin/env bash
# check-multiplier-claims — gate external-facing multiplier copy.
#
# Background
#   spec/testing.md ("Live Session Caveat") declares a hard rule:
#   do NOT use "80x" / "80.37" / "5-10x" in any public-facing material
#   without a paired live-session number (or a "pending" placeholder
#   while Phase G capture is in flight). This script enforces that
#   rule against the surfaces users actually see.
#
#   Background — Luminary P0 round 2026-04-24-0.
#
# Scope
#   Surfaces scanned:
#     README.md
#     index.html
#     docs/**/*.html
#     spec/spec.md           (product-level principle text)
#     spec/roadmap.md
#     spec/testing.md
#
# Rule
#   A line that matches one of the BARE-CLAIM patterns must ALSO be
#   paired — either on the same line, or within PAIR_WINDOW lines
#   above/below — with one of the PAIR patterns:
#     fixture | Fixture
#     live    | Live
#     synthetic | Synthetic
#     ceiling
#     benchmark
#     pending
#     replay
#     caveat
#
# Exit codes
#   0 — all claims paired (or absent)
#   1 — one or more unpaired claims
#   2 — bad invocation / missing input
#
# Usage
#   ./tools/check-multiplier-claims.sh              # scan default surfaces
#   ./tools/check-multiplier-claims.sh <path>...    # scan specific files
#   MULTIPLIER_CHECK_DEBUG=1 ./tools/check-multiplier-claims.sh

set -euo pipefail

PAIR_WINDOW="${MULTIPLIER_PAIR_WINDOW:-4}"
DEBUG="${MULTIPLIER_CHECK_DEBUG:-0}"

# Canonical repo root = parent of this script's dir.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# BSD awk has no \b — use POSIX character-class guards on both sides.
# Claim patterns: 80x, 80.37, 5-10x, 5 to 10x, 5x-10x (case-sensitive
# on the number tokens since "80X" isn't a live risk in our copy).
BARE_CLAIM_RE='(^|[^[:alnum:]])(80x|80\.37|5-10x|5 to 10x|5x-10x)([^[:alnum:]]|$)'
PAIR_RE='([Ff]ixture|[Ll]ive|[Ss]ynthetic|ceiling|benchmark|pending|replay|caveat)'

debug() {
  [ "$DEBUG" = "1" ] && printf '[debug] %s\n' "$*" >&2 || true
}

# Default scan set if no args.
if [ "$#" -eq 0 ]; then
  set -- \
    "$ROOT/README.md" \
    "$ROOT/index.html" \
    "$ROOT/spec/spec.md" \
    "$ROOT/spec/roadmap.md" \
    "$ROOT/spec/testing.md"
  # Expand docs/**/*.html (may be empty on some forks — tolerate).
  while IFS= read -r -d '' f; do
    set -- "$@" "$f"
  done < <(find "$ROOT/docs" -type f -name '*.html' -print0 2>/dev/null || true)
fi

violations=0
scanned=0

for file in "$@"; do
  if [ ! -f "$file" ]; then
    debug "skip (not a file): $file"
    continue
  fi
  scanned=$((scanned + 1))
  debug "scan: $file"

  # Walk the file line by line. For each bare-claim hit, check the
  # line itself and the +/- PAIR_WINDOW neighborhood for a PAIR token.
  # awk is the right tool here (no jq/python dep).
  awk -v file="$file" -v bare="$BARE_CLAIM_RE" -v pair="$PAIR_RE" \
      -v window="$PAIR_WINDOW" '
  {
    lines[NR] = $0
  }
  END {
    total = NR
    miss = 0
    for (i = 1; i <= total; i++) {
      if (match(lines[i], bare) == 0) continue
      # Check the line itself + the window above/below.
      paired = 0
      lo = i - window; if (lo < 1) lo = 1
      hi = i + window; if (hi > total) hi = total
      for (j = lo; j <= hi; j++) {
        if (match(lines[j], pair)) { paired = 1; break }
      }
      if (!paired) {
        printf("%s:%d: UNPAIRED multiplier claim: %s\n", file, i, lines[i]) > "/dev/stderr"
        miss++
      }
    }
    exit miss == 0 ? 0 : 1
  }
  ' "$file" || violations=$((violations + 1))
done

if [ "$violations" -gt 0 ]; then
  printf '\n' >&2
  printf 'check-multiplier-claims: %d file(s) with unpaired multiplier claims.\n' "$violations" >&2
  printf 'Scanned %d file(s). Pair window = %d lines.\n' "$scanned" "$PAIR_WINDOW" >&2
  printf 'Fix: add a fixture/live/pending qualifier within %d lines, or drop the number.\n' "$PAIR_WINDOW" >&2
  exit 1
fi

debug "ok: $scanned file(s) scanned, all multiplier claims paired"
exit 0
