#!/bin/bash
# Eval: Measure MCP tool call latency (p50, p95, p99)
set -e
cd "$(dirname "$0")/.."

# Find MCP binary
if [ -x .build/debug/senkani-mcp ]; then
    MCP=.build/debug/senkani-mcp
elif [ -x .build/release/senkani-mcp ]; then
    MCP=.build/release/senkani-mcp
else
    echo "FAIL: no senkani-mcp binary found"; exit 1
fi

echo "==============================================="
echo "  Eval 07: MCP Tool Latency"
echo "==============================================="
echo ""

# We'll measure latency by sending batch requests to the MCP server
# and timing them with Python's high-resolution timer.

INIT='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}'
NOTIF='{"jsonrpc":"2.0","method":"notifications/initialized"}'

# Build a sequence of 20 senkani_read calls on a small file
TIMINGS_FILE=/tmp/senkani-eval-latency-$$.txt
rm -f "$TIMINGS_FILE"

echo "Measuring senkani_read latency (20 calls on Package.swift)..."

for i in $(seq 1 20); do
    CALL='{"jsonrpc":"2.0","id":'$((i + 10))',"method":"tools/call","params":{"name":"senkani_read","arguments":{"path":"Package.swift"}}}'

    START=$(python3 -c "import time; print(time.time())")
    RESP=$(printf "%s\n%s\n%s\n" "$INIT" "$NOTIF" "$CALL" | perl -e "
        use IPC::Open2;
        my \$pid = open2(my \$out, my \$in, '$MCP 2>/dev/null');
        while (my \$line = <STDIN>) { print \$in \$line; \$in->flush(); }
        close(\$in);
        eval {
            local \$SIG{ALRM} = sub { die 'timeout' };
            alarm 8;
            while (my \$line = <\$out>) { print \$line; }
        };
        kill 9, \$pid;
    " 2>/dev/null || true)
    END=$(python3 -c "import time; print(time.time())")

    MS=$(python3 -c "print(f'{($END - $START) * 1000:.1f}')")
    echo "$MS" >> "$TIMINGS_FILE"
    printf "  Call %2d: %sms\n" "$i" "$MS"
done

echo ""
echo "Measuring senkani_session latency (10 calls)..."

SESSION_TIMINGS=/tmp/senkani-eval-latency-session-$$.txt
rm -f "$SESSION_TIMINGS"

for i in $(seq 1 10); do
    CALL='{"jsonrpc":"2.0","id":'$((i + 100))',"method":"tools/call","params":{"name":"senkani_session","arguments":{"action":"stats"}}}'

    START=$(python3 -c "import time; print(time.time())")
    RESP=$(printf "%s\n%s\n%s\n" "$INIT" "$NOTIF" "$CALL" | perl -e "
        use IPC::Open2;
        my \$pid = open2(my \$out, my \$in, '$MCP 2>/dev/null');
        while (my \$line = <STDIN>) { print \$in \$line; \$in->flush(); }
        close(\$in);
        eval {
            local \$SIG{ALRM} = sub { die 'timeout' };
            alarm 5;
            while (my \$line = <\$out>) { print \$line; }
        };
        kill 9, \$pid;
    " 2>/dev/null || true)
    END=$(python3 -c "import time; print(time.time())")

    MS=$(python3 -c "print(f'{($END - $START) * 1000:.1f}')")
    echo "$MS" >> "$SESSION_TIMINGS"
done

# Calculate percentiles
echo ""
echo "-------------------------------------------"

if [ -f "$TIMINGS_FILE" ] && [ -s "$TIMINGS_FILE" ]; then
    python3 -c "
import sys
timings = sorted([float(line.strip()) for line in open('$TIMINGS_FILE') if line.strip()])
n = len(timings)
if n == 0:
    print('  No timing data collected')
    sys.exit()

p50 = timings[int(n * 0.5)]
p95 = timings[int(min(n * 0.95, n - 1))]
p99 = timings[int(min(n * 0.99, n - 1))]
avg = sum(timings) / n

print(f'  senkani_read ({n} calls):')
print(f'    avg:  {avg:.1f}ms')
print(f'    p50:  {p50:.1f}ms')
print(f'    p95:  {p95:.1f}ms')
print(f'    p99:  {p99:.1f}ms')
print()
print(f'EVAL: mcp_read_p50_ms = {p50:.1f} (baseline: <50ms)')
print(f'EVAL: mcp_read_p95_ms = {p95:.1f} (baseline: <200ms)')
print(f'EVAL: mcp_read_p99_ms = {p99:.1f} (baseline: <500ms)')
" 2>/dev/null
fi

if [ -f "$SESSION_TIMINGS" ] && [ -s "$SESSION_TIMINGS" ]; then
    python3 -c "
timings = sorted([float(line.strip()) for line in open('$SESSION_TIMINGS') if line.strip()])
n = len(timings)
if n == 0: exit()

p50 = timings[int(n * 0.5)]
p95 = timings[int(min(n * 0.95, n - 1))]

print()
print(f'  senkani_session ({n} calls):')
print(f'    p50:  {p50:.1f}ms')
print(f'    p95:  {p95:.1f}ms')
print()
print(f'EVAL: mcp_session_p50_ms = {p50:.1f} (baseline: <10ms)')
print(f'EVAL: mcp_session_p95_ms = {p95:.1f} (baseline: <50ms)')
" 2>/dev/null
fi

echo ""

# Cleanup
rm -f "$TIMINGS_FILE" "$SESSION_TIMINGS"

# Pass — latency is informational, not gated
exit 0
