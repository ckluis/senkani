#!/bin/bash
# t4c-corpus-runner.sh — T.4c adversarial-corpus driver (Phase A, t4c-1).
#
# Spawns `senkani-mcp` over stdio, performs the MCP initialize handshake,
# then fires 20 distinct `tools/call` invocations and captures every
# `tools/call` response (one JSON object per line) to corpus.jsonl.
#
# This is the CI-SHAPE driver: it has NO keychain dependency. The
# operator-gated T.4c walk re-runs this script against a tool whose
# `MCPToolConfig.credentialGateway.enabled=true` references a real
# sentinel key in the live macOS Keychain, then scans corpus.jsonl for
# sentinel leakage (parent walk Step 5). Here in Phase A we prove the
# DRIVER: 20 lines emitted, zero `.error` fields, against the always-
# available `senkani_version` tool — no secret, no keychain.
#
# Fail-CLOSED note: no production catalog tool ships gateway-enabled
# (Torvalds capability invariant), so this CI run exercises the
# transport + 20-call loop, not the injection itself. The injection
# success path is unit-tested (CredentialGatewayTests + the t4c-1
# bridge test); the real-key leak proof stays operator-gated.
#
# Usage:
#   tools/soak/t4c-corpus-runner.sh [OUTDIR] [TOOL_NAME] [N]
#
# Args (all optional):
#   OUTDIR     directory for corpus.jsonl (default: a fresh mktemp dir)
#   TOOL_NAME  the tool to call 20x       (default: senkani_version)
#   N          number of tools/call calls (default: 20)
#
# Exit codes:
#   0  success: N lines captured, zero .error fields
#   1  the senkani-mcp binary was not found / not executable
#   2  fewer than N response lines captured
#   3  at least one response carried an .error field

set -euo pipefail

OUTDIR="${1:-$(mktemp -d "${TMPDIR:-/tmp}/t4c-corpus.XXXXXX")}"
TOOL_NAME="${2:-senkani_version}"
N="${3:-20}"

mkdir -p "${OUTDIR}"
CORPUS="${OUTDIR}/corpus.jsonl"
: > "${CORPUS}"

# Locate the senkani-mcp binary: prefer an explicit env override, then
# the debug build, then the release build.
MCP_BIN="${SENKANI_MCP:-}"
if [ -z "${MCP_BIN}" ]; then
  for cand in \
    "$(pwd)/.build/debug/senkani-mcp" \
    "$(pwd)/.build/release/senkani-mcp"; do
    if [ -x "${cand}" ]; then MCP_BIN="${cand}"; break; fi
  done
fi

if [ -z "${MCP_BIN}" ] || [ ! -x "${MCP_BIN}" ]; then
  echo "FAIL: senkani-mcp binary not found. Build it (swift build) or set SENKANI_MCP=<path>." >&2
  exit 1
fi

# The MCP server's access gate requires SENKANI_PANE_ID (it only
# activates in Senkani-managed panes). Set a synthetic pane id so the
# stdio server boots; a project root keeps the session deterministic.
export SENKANI_PANE_ID="${SENKANI_PANE_ID:-t4c-corpus-runner}"
export SENKANI_PROJECT_ROOT="${SENKANI_PROJECT_ROOT:-$(pwd)}"

# Build the stdio request stream: initialize, initialized notification,
# then N tools/call requests (ids 100..100+N-1). Each request is one
# line of JSON-RPC over stdio (line-delimited).
build_requests() {
  printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"t4c-corpus-runner","version":"1"}}}'
  printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/initialized","params":{}}'
  local i=0
  while [ "${i}" -lt "${N}" ]; do
    local id=$((100 + i))
    printf '{"jsonrpc":"2.0","id":%d,"method":"tools/call","params":{"name":"%s","arguments":{}}}\n' \
      "${id}" "${TOOL_NAME}"
    i=$((i + 1))
  done
}

# Drive the server: pipe the request stream in, capture stdout. The
# server runs until stdin closes (or its parent-exit watchdog fires);
# we cap the wall-clock so a hung boot can't wedge CI.
RAW="${OUTDIR}/raw-stdout.jsonl"
build_requests | (
  # 60s ceiling; macOS ships BSD `timeout` only via coreutils, so fall
  # back to a background-kill if `timeout` is absent.
  if command -v timeout >/dev/null 2>&1; then
    timeout 60 "${MCP_BIN}" server
  else
    "${MCP_BIN}" server &
    pid=$!
    ( sleep 60; kill "${pid}" 2>/dev/null || true ) &
    wait "${pid}" 2>/dev/null || true
  fi
) > "${RAW}" 2>"${OUTDIR}/mcp-stderr.log" || true

# Extract only the tools/call responses (ids >= 100) into corpus.jsonl.
# Use jq when available for robustness; otherwise grep the id range.
if command -v jq >/dev/null 2>&1; then
  jq -c 'select(.id != null and .id >= 100)' "${RAW}" 2>/dev/null > "${CORPUS}" || true
else
  grep -E '"id":(1[0-9][0-9]|[2-9][0-9][0-9]|[1-9][0-9]{3,})' "${RAW}" > "${CORPUS}" || true
fi

LINES=$(wc -l < "${CORPUS}" | tr -d ' ')
echo "corpus: ${CORPUS} (${LINES} lines, tool=${TOOL_NAME}, N=${N})"

if [ "${LINES}" -lt "${N}" ]; then
  echo "FAIL: expected ${N} response lines, captured ${LINES}." >&2
  echo "  raw stdout: ${RAW}" >&2
  echo "  server stderr: ${OUTDIR}/mcp-stderr.log" >&2
  exit 2
fi

# Zero .error fields across the captured responses.
if command -v jq >/dev/null 2>&1; then
  ERR_COUNT=$(jq -r '.error // empty' "${CORPUS}" 2>/dev/null | grep -c . || true)
else
  ERR_COUNT=$(grep -c '"error"' "${CORPUS}" || true)
fi

if [ "${ERR_COUNT}" -ne 0 ]; then
  echo "FAIL: ${ERR_COUNT} response(s) carried an .error field." >&2
  exit 3
fi

echo "OK: ${LINES} corpus lines, zero .error fields."
exit 0
