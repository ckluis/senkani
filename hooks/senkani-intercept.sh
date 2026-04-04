#!/bin/bash
# Senkani PreToolUse hook — routes Read/Bash/Grep through senkani MCP tools.
#
# Respects ALL toggle states:
#   SENKANI_MODE=passthrough       → all interception off (native tools only)
#   SENKANI_INTERCEPT=off          → all interception off
#   SENKANI_INTERCEPT_READ=off     → Read passes through (native Read)
#   SENKANI_INTERCEPT_BASH=off     → Bash passes through (native Bash)
#   SENKANI_INTERCEPT_GREP=off     → Grep passes through (native Grep)
#   SENKANI_MCP_FILTER=off         → filtering disabled (still routes through MCP for cache/secrets)
#   SENKANI_MCP_CACHE=off          → cache disabled (still routes for filtering/secrets)
#
# When ALL MCP features are off, there's no reason to route through MCP.
# The hook passes through to native tools in that case.

# Global kill switches
[ "${SENKANI_MODE:-}" = "passthrough" ] && echo '{}' && exit 0
[ "${SENKANI_INTERCEPT:-on}" = "off" ] && echo '{}' && exit 0

# Check if ANY MCP feature is still on. If all are off, pass through.
_FILTER="${SENKANI_MCP_FILTER:-on}"
_CACHE="${SENKANI_MCP_CACHE:-on}"
_SECRETS="${SENKANI_MCP_SECRETS:-on}"
_INDEX="${SENKANI_MCP_INDEX:-on}"

if [ "$_FILTER" = "off" ] && [ "$_CACHE" = "off" ] && [ "$_SECRETS" = "off" ] && [ "$_INDEX" = "off" ]; then
    # All features off — no point routing through MCP
    echo '{}'
    exit 0
fi

INPUT=$(cat)

TOOL_NAME=$(echo "$INPUT" | /usr/bin/python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print(d.get('tool_name', ''))
except:
    print('')
" 2>/dev/null)

case "$TOOL_NAME" in
    Read)
        [ "${SENKANI_INTERCEPT_READ:-on}" = "off" ] && echo '{}' && exit 0

        # Build a reason that tells the model which features are active
        FEATURES=""
        [ "$_CACHE" = "on" ] && FEATURES="${FEATURES}session caching (re-reads free), "
        [ "$_FILTER" = "on" ] && FEATURES="${FEATURES}compression, "
        [ "$_SECRETS" = "on" ] && FEATURES="${FEATURES}secret detection, "
        FEATURES="${FEATURES%%, }"  # trim trailing comma

        echo "{\"decision\":\"block\",\"reason\":\"Use mcp__senkani__senkani_read instead of Read. Active features: ${FEATURES}. Pass the same file_path as the 'path' argument.\"}"
        ;;

    Bash)
        [ "${SENKANI_INTERCEPT_BASH:-on}" = "off" ] && echo '{}' && exit 0

        COMMAND=$(echo "$INPUT" | /usr/bin/python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print(d.get('tool_input', {}).get('command', ''))
except:
    print('')
" 2>/dev/null)

        # Never intercept commands that modify state
        case "$COMMAND" in
            git\ commit*|git\ push*|git\ add*|git\ checkout*|git\ reset*|git\ stash*|git\ merge*|git\ rebase*) echo '{}'; exit 0 ;;
            rm\ *|mv\ *|cp\ *|mkdir\ *|touch\ *|chmod\ *|chown\ *) echo '{}'; exit 0 ;;
            swift\ build*|swift\ test*|swift\ package*|swift\ run*) echo '{}'; exit 0 ;;
            npm\ run*|npm\ start*|npm\ install*|yarn\ *|bun\ run*|bun\ test*|bun\ install*) echo '{}'; exit 0 ;;
            cargo\ build*|cargo\ test*|cargo\ run*|cargo\ install*) echo '{}'; exit 0 ;;
            go\ build*|go\ test*|go\ run*|go\ install*) echo '{}'; exit 0 ;;
            make\ *|cmake\ *|docker\ *|kubectl\ *) echo '{}'; exit 0 ;;
            pip\ install*|pip3\ install*|brew\ install*|brew\ upgrade*) echo '{}'; exit 0 ;;
            cd\ *|export\ *|source\ *|eval\ *) echo '{}'; exit 0 ;;
            sudo\ *) echo '{}'; exit 0 ;;
            *\>*) echo '{}'; exit 0 ;;  # redirects
            echo\ *\>*|printf\ *\>*|cat\ *\>*) echo '{}'; exit 0 ;;  # writes via redirect
        esac

        # Only redirect if filter is on (the main value for Bash interception)
        [ "$_FILTER" = "off" ] && echo '{}' && exit 0

        ESCAPED=$(echo "$COMMAND" | sed 's/"/\\"/g')
        echo "{\"decision\":\"block\",\"reason\":\"Use mcp__senkani__senkani_exec instead of Bash for this read-only command. It filters output (24 command rules, ANSI stripping, dedup, truncation, secret detection). Pass command: \\\"${ESCAPED}\\\"\"}"
        ;;

    Grep)
        [ "${SENKANI_INTERCEPT_GREP:-on}" = "off" ] && echo '{}' && exit 0
        [ "$_INDEX" = "off" ] && echo '{}' && exit 0  # no point without index

        PATTERN=$(echo "$INPUT" | /usr/bin/python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print(d.get('tool_input', {}).get('pattern', ''))
except:
    print('')
" 2>/dev/null)

        # Only intercept simple symbol-like searches, not regex
        case "$PATTERN" in
            *\\*|*\[*|*\(*|*\|*|*\+*|*\?*|*\^*|*\$*) echo '{}'; exit 0 ;;
        esac

        # Only intercept if it looks like a symbol name (alphanumeric + underscore)
        echo "$PATTERN" | grep -qE '^[a-zA-Z_][a-zA-Z0-9_]*$' || { echo '{}'; exit 0; }

        echo "{\"decision\":\"block\",\"reason\":\"Use mcp__senkani__senkani_search instead of Grep for symbol lookup. Returns compact results (~50 tokens vs ~5000). Pass query: \\\"${PATTERN}\\\". For regex or content search, Grep is fine — set SENKANI_INTERCEPT_GREP=off to stop this redirect.\"}"
        ;;

    *)
        echo '{}'
        ;;
esac
