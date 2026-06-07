#!/usr/bin/env bash
# measure-install-size — print the honest install.size SLO figure (MB).
#
# install.size (spec/slos.md, Phase V.14) is the on-disk footprint of
# the SHIPPED artifact, not the build tree. A SwiftPM release build
# leaves `.build/release` as a SYMLINK to `.build/<triple>/release`,
# and that directory holds ~1.8 GB of build intermediates (`*.build`,
# object files, ModuleCache) alongside the handful of product binaries
# that actually ship. Two failure modes follow:
#
#   du -sk .build/release       -> ~0 KB  (du does not follow a symlink
#                                           given as its argument)
#   du -sk -L .build/release    -> ~1.8 GB (the whole intermediate tree)
#
# Neither is the install size. This helper resolves the release dir
# through any symlink, then sums the sizes of the SHIPPED executable
# products — the `.executable` products declared in Package.swift.
# Build intermediates and the SenkaniApp GUI bundle (a separate DMG
# distribution, not a CLI product) are excluded.
#
# Usage:  measure-install-size.sh <release-dir>
# Prints: size in MB rounded to 1 decimal, or `null` when the dir is
#         missing or contains none of the shipped products.
# Exits:  0 always — a measurement miss is `null`, not an error, so the
#         caller (measure-slos.sh) never aborts a run on it; 2 on a
#         usage error.

set -euo pipefail

if [ $# -ne 1 ]; then
  echo "usage: measure-install-size.sh <release-dir>" >&2
  exit 2
fi

RELEASE_DIR="$1"

# Shipped executable products — keep in sync with the `.executable`
# product list in Package.swift. SenkaniApp is intentionally absent: it
# is an executableTarget built into a `.app` bundle (separate DMG
# distribution), not a CLI product an operator gets via `brew install`.
PRODUCTS="senkani senkani-mcp senkani-hook senkani-mig-helper"

# Resolve through symlinks so `du` measures real files. `cd … && pwd -P`
# canonicalizes without GNU `readlink -f` (absent on stock macOS).
RESOLVED_DIR="$(cd "${RELEASE_DIR}" 2>/dev/null && pwd -P || true)"

if [ -z "${RESOLVED_DIR}" ] || [ ! -d "${RESOLVED_DIR}" ]; then
  echo "null"
  exit 0
fi

TOTAL_KB=0
FOUND=0
for prod in ${PRODUCTS}; do
  bin="${RESOLVED_DIR}/${prod}"
  if [ -f "${bin}" ]; then
    # -L follows the (unlikely) case where a product is itself a
    # symlink, so we measure the binary, not a ~0 KB link.
    kb="$(du -sk -L "${bin}" | awk '{print $1}')"
    TOTAL_KB=$((TOTAL_KB + kb))
    FOUND=$((FOUND + 1))
  fi
done

if [ "${FOUND}" -eq 0 ]; then
  echo "null"
  exit 0
fi

python3 -c "print(round(${TOTAL_KB} / 1024.0, 1))"
