#!/usr/bin/env bash
# perf-gate — run the SLO perf gate test in isolation.
#
# This is a thin convenience wrapper. The CI gate is the
# `SLOPerfGateTests` suite inside `swift test`. `tools/test-safe.sh`
# runs the whole suite (including this gate); `tools/perf-gate.sh`
# runs ONLY the SLO gate, for fast local iteration when you're
# tuning a hot path and want sub-second feedback on whether you've
# regressed an SLO.
#
# Background
#   See `spec/slos.md` for the three published SLOs and the
#   error-budget model. The gate synthesises a representative
#   workload for each SLO, measures latency for each call, then
#   asserts p99 falls under threshold. A regression that pushes
#   p99 across the ceiling fails the build.
#
# Usage
#   ./tools/perf-gate.sh           # run the SLO gate
#
# Exits with the exit code of `swift test`.

set -euo pipefail

cd "$(dirname "$0")/.."

# Skip the multiplier-claim pre-flight that test-safe.sh runs — we
# want the perf gate alone, not the whole repo's docs lint.
export SKIP_MULTIPLIER_CHECK=1
export SWT_NO_PARALLEL=1

exec swift test --no-parallel \
    --filter "SLOPerfGate"
