#!/usr/bin/env bash
# Start / stop a local static HTTP server against the repo root for
# the site-audit harnesses (`a11y-check.sh`, `perf-check.sh`). Pages
# resolve from `index.html` + `docs/**/*.html` + `assets/`.
#
# Usage:
#   ./scripts/site-serve.sh start [port]   # default port 8765
#   ./scripts/site-serve.sh stop  [port]
#   ./scripts/site-serve.sh status [port]
set -euo pipefail

cmd="${1:-status}"
port="${2:-8765}"
pidfile="/tmp/senkani-site-serve-${port}.pid"
logfile="/tmp/senkani-site-serve-${port}.log"
root="$(cd "$(dirname "$0")/.." && pwd)"

case "$cmd" in
  start)
    if [[ -f "$pidfile" ]] && kill -0 "$(cat "$pidfile")" 2>/dev/null; then
      echo "already running (pid $(cat "$pidfile")) on port $port"
      exit 0
    fi
    cd "$root"
    nohup python3 -m http.server "$port" --bind 127.0.0.1 > "$logfile" 2>&1 &
    echo $! > "$pidfile"
    sleep 0.5
    if curl -sf -o /dev/null "http://127.0.0.1:$port/index.html"; then
      echo "started: http://127.0.0.1:$port/  (pid $(cat "$pidfile"))"
    else
      echo "start failed — see $logfile" >&2
      exit 1
    fi
    ;;
  stop)
    if [[ -f "$pidfile" ]]; then
      kill "$(cat "$pidfile")" 2>/dev/null || true
      rm -f "$pidfile"
      echo "stopped"
    else
      echo "not running"
    fi
    ;;
  status)
    if [[ -f "$pidfile" ]] && kill -0 "$(cat "$pidfile")" 2>/dev/null; then
      echo "running (pid $(cat "$pidfile")) on port $port"
    else
      echo "not running"
      exit 1
    fi
    ;;
  *)
    echo "usage: $0 {start|stop|status} [port]" >&2
    exit 2
    ;;
esac
