#!/usr/bin/env bash
# measure-install-size — print the honest install.size SLO figures (MB).
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
# through any symlink, then measures the SHIPPED executable products —
# the `.executable` products declared in Package.swift. Build
# intermediates and the SenkaniApp GUI bundle (a separate DMG
# distribution, not a CLI product) are excluded.
#
# STRIP-BEFORE-MEASURE (D5, slo-install-size-...-2026-05-27).
# A SwiftPM release binary keeps its DWARF debug symbols inline, so the
# on-disk file is ~2x the size a notarized/Homebrew distribution would
# ship. The honest install figure is the STRIPPED artifact. Every
# product has a matching `.dSYM` in the release dir, so stripping is
# LOSSLESS — symbolication still works from the dSYM. This helper
# copies each product into a temp dir and runs the canonical recipe:
#
#   strip -rSTx <copy>
#       -r  save dynamically-referenced symbols (don't break dyld)
#       -S  remove debug symbol-table entries (these live in the .dSYM)
#       -T  remove Swift symbols (_$S / _$s)
#       -x  remove all local symbols (keep only globals)
#
# The recipe is SIZE-deterministic (44 / 67 / 1 / 5 MB at v0.4.0,
# reproducible run-to-run). It never mutates the file on disk — only the
# temp copy is stripped, so a `--strip`'d release dir and an un-stripped
# one measure identically.
#
# PER-BINARY BUDGETS (D5). One summed 50 MB gate is wrong: the
# senkani-mcp daemon links MLX/MLXVLM/Metal and is IRREDUCIBLY ~67 MB
# stripped — no honest gate puts the whole product family under 50 MB.
# Each shipped binary gets its own falsifiable budget instead:
#
#   senkani            < 50 MB   (CLI; 44 MB stripped)
#   senkani-mcp        < 70 MB   (MLX/Metal daemon; 67 MB stripped)
#   senkani-hook       <  5 MB   (zero-dep hook; 1 MB stripped)
#   senkani-mig-helper < 15 MB   (migration helper; 5 MB stripped)
#
# These mirror `ReleaseSLOInstallBudget` in Sources/Core/ReleaseSLO.swift
# — keep the two in sync.
#
# Usage
#   measure-install-size.sh <release-dir>            # total stripped MB (back-compat)
#   measure-install-size.sh --per-binary <dir>       # one `name<TAB>MB` line per product
#   measure-install-size.sh --check <dir>            # per-binary budget gate; exit 1 on breach
#   measure-install-size.sh --no-strip <dir>         # measure on-disk (un-stripped) instead
#
# Prints (default): summed stripped size in MB to 1 decimal, or `null`
#   when the dir is missing or holds none of the shipped products.
# Exits:  0 on success / measurement-miss (`null` is not an error, so
#   measure-slos.sh never aborts a run on it); 1 only in --check mode
#   when a binary exceeds its budget; 2 on a usage error.

set -euo pipefail

# --- per-binary budgets (MB) — keep in sync with ReleaseSLO.swift ---
# Mirrored as a name/budget pair list (stock-bash 3.2 has no assoc arrays).
PRODUCTS="senkani senkani-mcp senkani-hook senkani-mig-helper"
budget_for() {
  case "$1" in
    senkani)            echo 50 ;;
    senkani-mcp)        echo 70 ;;
    senkani-hook)       echo 5 ;;
    senkani-mig-helper) echo 15 ;;
    *)                  echo 0 ;;
  esac
}

MODE="total"   # total | per-binary | check
STRIP=1
RELEASE_DIR=""

while [ $# -gt 0 ]; do
  case "$1" in
    --per-binary) MODE="per-binary" ;;
    --check)      MODE="check" ;;
    --no-strip)   STRIP=0 ;;
    -*)           echo "unknown flag: $1" >&2; exit 2 ;;
    *)            RELEASE_DIR="$1" ;;
  esac
  shift
done

if [ -z "${RELEASE_DIR}" ]; then
  echo "usage: measure-install-size.sh [--per-binary|--check] [--no-strip] <release-dir>" >&2
  exit 2
fi

# Resolve through symlinks so we measure real files. `cd … && pwd -P`
# canonicalizes without GNU `readlink -f` (absent on stock macOS).
RESOLVED_DIR="$(cd "${RELEASE_DIR}" 2>/dev/null && pwd -P || true)"

if [ -z "${RESOLVED_DIR}" ] || [ ! -d "${RESOLVED_DIR}" ]; then
  echo "null"
  exit 0
fi

# Temp dir for stripped copies; always cleaned up.
TMP_STRIP="$(mktemp -d "${TMPDIR:-/tmp}/senkani-strip.XXXXXX")"
trap 'rm -rf "${TMP_STRIP}"' EXIT

# Echo the measured size (KB) of one product, or empty if absent.
# When STRIP=1, copies the product to a temp file and runs the canonical
# lossless recipe before measuring — never touches the on-disk binary.
measure_kb() {
  local prod="$1"
  local bin="${RESOLVED_DIR}/${prod}"
  [ -f "${bin}" ] || return 0
  if [ "${STRIP}" -eq 1 ]; then
    local copy="${TMP_STRIP}/${prod}"
    cp "${bin}" "${copy}"
    # Lossless because every product has a sibling .dSYM in the release
    # dir. `|| true` so a strip refusal (e.g. a re-stripped copy) is not
    # fatal — we then measure the (already-thin) copy as-is.
    strip -rSTx "${copy}" 2>/dev/null || true
    du -sk -L "${copy}" | awk '{print $1}'
  else
    # -L follows the (unlikely) case where a product is itself a symlink.
    du -sk -L "${bin}" | awk '{print $1}'
  fi
}

case "${MODE}" in
  total)
    TOTAL_KB=0
    FOUND=0
    for prod in ${PRODUCTS}; do
      kb="$(measure_kb "${prod}")"
      if [ -n "${kb}" ]; then
        TOTAL_KB=$((TOTAL_KB + kb))
        FOUND=$((FOUND + 1))
      fi
    done
    if [ "${FOUND}" -eq 0 ]; then
      echo "null"; exit 0
    fi
    python3 -c "print(round(${TOTAL_KB} / 1024.0, 1))"
    ;;

  per-binary)
    FOUND=0
    for prod in ${PRODUCTS}; do
      kb="$(measure_kb "${prod}")"
      if [ -n "${kb}" ]; then
        mb="$(python3 -c "print(round(${kb} / 1024.0, 1))")"
        printf '%s\t%s\n' "${prod}" "${mb}"
        FOUND=$((FOUND + 1))
      fi
    done
    if [ "${FOUND}" -eq 0 ]; then echo "null"; fi
    exit 0
    ;;

  check)
    BREACH=0
    FOUND=0
    for prod in ${PRODUCTS}; do
      kb="$(measure_kb "${prod}")"
      [ -z "${kb}" ] && continue
      FOUND=$((FOUND + 1))
      mb="$(python3 -c "print(round(${kb} / 1024.0, 1))")"
      budget="$(budget_for "${prod}")"
      over="$(python3 -c "print(1 if ${mb} > ${budget} else 0)")"
      if [ "${over}" -eq 1 ]; then
        printf '✘ %s: %s MB > %s MB budget — OVER BUDGET\n' "${prod}" "${mb}" "${budget}"
        BREACH=1
      else
        printf '✓ %s: %s MB (< %s MB budget)\n' "${prod}" "${mb}" "${budget}"
      fi
    done
    if [ "${FOUND}" -eq 0 ]; then
      echo "null — no shipped products found in ${RELEASE_DIR}"
      exit 0
    fi
    exit "${BREACH}"
    ;;
esac
