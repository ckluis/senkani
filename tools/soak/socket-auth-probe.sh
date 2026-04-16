#!/bin/bash
# S6 — socket-auth handshake probe.
# Precondition: SenkaniApp was launched with SENKANI_SOCKET_AUTH=on.
set -e

TOKEN="$HOME/.senkani/.token"

echo "== Token file =="
if [ ! -f "$TOKEN" ]; then
  echo "FAIL: no token file at $TOKEN. Did you launch with SENKANI_SOCKET_AUTH=on?"
  exit 1
fi
perms=$(stat -f "%Sp %OLp" "$TOKEN")
echo "$perms $TOKEN"
mode=$(stat -f "%OLp" "$TOKEN")
if [ "$mode" = "600" ]; then
  echo "PASS: mode is 600"
else
  echo "FAIL: expected 600, got $mode"
fi

echo ""
echo "== Unauthenticated connect on pane.sock =="
# Send a malformed minimum frame; server should reject without handshake.
printf '\x00\x00\x00\x02{}' | nc -U "$HOME/.senkani/pane.sock" >/dev/null 2>&1 || true
echo "Done. Check app stderr for: socket.handshake.rejected"
echo ""
echo "Grep (adjust path to match how you capture app stderr):"
echo "  grep socket.handshake.rejected /tmp/senkani.stderr"
