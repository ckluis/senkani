#!/usr/bin/env bash
# test-safe — deterministic full-suite run for senkani.
#
# Background
#   `swift test` hangs indefinitely on some machines during the
#   initial surge of parallel @Test startup. Root cause documented in
#   spec/testing.md ("Full-suite hang — Swift concurrency pool
#   starvation"). Until the NSLock-based test helpers are migrated
#   off cooperative-pool blocking primitives, use this script to run
#   the full suite with Swift Testing's intra-process parallelism
#   disabled. Slower but always terminates.
#
# Two knobs (applied together, because the hang mode can be either):
#   SWT_NO_PARALLEL=1     — disables Swift Testing's own parallelism
#                           (the one causing the hangs named in the
#                           testing.md fingerprint).
#   --no-parallel         — SwiftPM default; explicit here for clarity.
#
# Usage
#   ./tools/test-safe.sh                 # all tests
#   ./tools/test-safe.sh --filter Foo    # passthrough filter
#
# Exits with the exit code of `swift test`.

set -euo pipefail

cd "$(dirname "$0")/.."

export SWT_NO_PARALLEL=1

exec swift test --no-parallel "$@"
