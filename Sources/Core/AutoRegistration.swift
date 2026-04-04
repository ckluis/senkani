import Foundation

/// Handles first-launch auto-registration of Senkani as an MCP server
/// and installation of PreToolUse hooks for Claude Code.
///
/// Every method is idempotent — safe to call on every launch.
public enum AutoRegistration {

    // MARK: - Public API

    /// Register Senkani as an MCP server in ~/.claude/settings.json if not already registered.
    public static func registerIfNeeded() throws {
        let binaryPath = resolveBinaryPath()
        let settingsPath = NSHomeDirectory() + "/.claude/settings.json"

        var config = try readJSONOrEmpty(at: settingsPath)

        var mcpServers = config["mcpServers"] as? [String: Any] ?? [:]

        // Already registered with correct path — nothing to do
        if let existing = mcpServers["senkani"] as? [String: Any],
           let existingCommand = existing["command"] as? String,
           existingCommand == binaryPath {
            return
        }

        // SECURITY: Back up before first modification
        backupIfFirstWrite(path: settingsPath)

        mcpServers["senkani"] = [
            "command": binaryPath,
            "args": ["--mcp-server"],
        ] as [String: Any]
        config["mcpServers"] = mcpServers

        try writeJSONAtomically(config, to: settingsPath)
    }

    /// Install the PreToolUse hook script and register it in Claude Code settings.
    public static func installHooksIfNeeded() throws {
        let hookDir = NSHomeDirectory() + "/.senkani/hooks"
        let hookPath = hookDir + "/senkani-intercept.sh"
        let settingsPath = NSHomeDirectory() + "/.claude/settings.json"
        let fm = FileManager.default

        // --- Step 1: Write the hook script ---

        if !fm.fileExists(atPath: hookDir) {
            try fm.createDirectory(atPath: hookDir, withIntermediateDirectories: true)
        }

        // Don't overwrite if existing hook is newer (user may have customized it)
        var shouldWriteHook = true
        if fm.fileExists(atPath: hookPath) {
            let attrs = try? fm.attributesOfItem(atPath: hookPath)
            if let mtime = attrs?[.modificationDate] as? Date,
               mtime > embeddedHookDate {
                shouldWriteHook = false
            }
        }

        if shouldWriteHook {
            try writeHookScript(to: hookPath)
        }

        // --- Step 2: Register in Claude Code settings ---

        var config = try readJSONOrEmpty(at: settingsPath)

        var hooks = config["hooks"] as? [String: Any] ?? [:]
        var preToolUse = hooks["PreToolUse"] as? [[String: Any]] ?? []

        // Check if senkani hook is already registered
        let alreadyRegistered = preToolUse.contains { entry in
            guard let cmd = entry["command"] as? String else { return false }
            return cmd.contains("senkani-intercept")
        }

        if alreadyRegistered { return }

        // SECURITY: Back up before first modification
        backupIfFirstWrite(path: settingsPath)

        // The hook script handles tool routing internally (Read/Bash/Grep),
        // so we register a single entry.
        // TODO: Phase 5 — replace python3 JSON parsing in hook with compiled helper.
        // The hook uses /usr/bin/python3, a mutable interpreter in the trust chain.
        preToolUse.append([
            "type": "command",
            "command": hookPath,
        ] as [String: Any])
        hooks["PreToolUse"] = preToolUse
        config["hooks"] = hooks

        try writeJSONAtomically(config, to: settingsPath)
    }

    // MARK: - Private: Binary Resolution

    /// Resolve the path to the Senkani binary.
    /// Prefers Bundle.main.executablePath for .app bundles, falls back to argv[0].
    private static func resolveBinaryPath() -> String {
        // In a .app bundle, Bundle.main.executablePath points inside Contents/MacOS/
        if let bundlePath = Bundle.main.executablePath,
           bundlePath.contains(".app/") {
            return bundlePath
        }

        // CLI / direct invocation
        let argv0 = ProcessInfo.processInfo.arguments[0]
        if argv0.hasPrefix("/") {
            return argv0
        }

        // Relative path — resolve against cwd
        return FileManager.default.currentDirectoryPath + "/" + argv0
    }

    // MARK: - Private: JSON I/O

    /// Read a JSON file as a dictionary, or return empty dict if file doesn't exist.
    /// Throws (returns early) if file exists but contains corrupt JSON.
    private static func readJSONOrEmpty(at path: String) throws -> [String: Any] {
        guard let data = FileManager.default.contents(atPath: path) else {
            return [:]
        }
        guard let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            // SECURITY: Corrupt JSON — refuse to modify to avoid data loss
            logWarning("\(path) contains invalid JSON — skipping modification")
            throw AutoRegistrationError.corruptJSON(path)
        }
        return parsed
    }

    /// Write a JSON dictionary to a file atomically (write to temp file, then rename).
    /// Prevents corruption if the process crashes mid-write.
    private static func writeJSONAtomically(_ dict: [String: Any], to path: String) throws {
        let data = try JSONSerialization.data(
            withJSONObject: dict,
            options: [.prettyPrinted, .sortedKeys]
        )

        let url = URL(fileURLWithPath: path)
        let dir = url.deletingLastPathComponent()
        let tempURL = dir.appendingPathComponent(".\(url.lastPathComponent).tmp.\(ProcessInfo.processInfo.processIdentifier)")

        // Write to temp file first
        try data.write(to: tempURL)

        // Atomic rename — original stays intact if we crash between write and rename
        if FileManager.default.fileExists(atPath: path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tempURL)
        } else {
            try FileManager.default.moveItem(at: tempURL, to: url)
        }
    }

    /// Create a .bak backup only if one doesn't already exist.
    private static func backupIfFirstWrite(path: String) {
        let backupPath = path + ".bak"
        let fm = FileManager.default
        if fm.fileExists(atPath: path) && !fm.fileExists(atPath: backupPath) {
            try? fm.copyItem(atPath: path, toPath: backupPath)
        }
    }

    // MARK: - Private: Hook Script

    /// Date of the embedded hook script — used to skip overwrite if on-disk is newer.
    /// Update this when the embedded script content changes.
    private static let embeddedHookDate: Date = {
        let formatter = ISO8601DateFormatter()
        return formatter.date(from: "2026-04-03T00:00:00Z") ?? Date.distantPast
    }()

    /// Write the hook script to disk atomically and set executable permissions (0755).
    private static func writeHookScript(to path: String) throws {
        let url = URL(fileURLWithPath: path)
        let dir = url.deletingLastPathComponent()
        let tempURL = dir.appendingPathComponent(".\(url.lastPathComponent).tmp.\(ProcessInfo.processInfo.processIdentifier)")

        // Write to temp file, then rename — prevents truncated script on crash
        try Data(embeddedHookScript.utf8).write(to: tempURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: tempURL.path
        )
        if FileManager.default.fileExists(atPath: path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tempURL)
        } else {
            try FileManager.default.moveItem(at: tempURL, to: url)
        }
    }

    private static func logWarning(_ message: String) {
        FileHandle.standardError.write(Data("[senkani] \(message)\n".utf8))
    }

    // MARK: - Errors

    enum AutoRegistrationError: Error, LocalizedError {
        case corruptJSON(String)

        var errorDescription: String? {
            switch self {
            case .corruptJSON(let path):
                return "\(path) contains invalid JSON — refusing to modify"
            }
        }
    }

    // MARK: - Embedded Hook Script

    // TODO: Phase 5 — replace python3 JSON parsing with compiled helper
    // The hook uses /usr/bin/python3 for JSON parsing. This is a mutable interpreter
    // in the trust chain — an attacker who controls python3 could alter hook behavior.
    // For Phase 1 this is accepted; Phase 5 should ship a small compiled JSON parser.

    /// The hook script, embedded as a string so it works in MCP server mode too
    /// (no Bundle resource access needed).
    private static let embeddedHookScript = """
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

        FEATURES=""
        [ "$_CACHE" = "on" ] && FEATURES="${FEATURES}session caching (re-reads free), "
        [ "$_FILTER" = "on" ] && FEATURES="${FEATURES}compression, "
        [ "$_SECRETS" = "on" ] && FEATURES="${FEATURES}secret detection, "
        FEATURES="${FEATURES%%, }"

        echo "{\\"decision\\":\\"block\\",\\"reason\\":\\"Use mcp__senkani__senkani_read instead of Read. Active features: ${FEATURES}. Pass the same file_path as the 'path' argument.\\"}"
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

        case "$COMMAND" in
            git\\ commit*|git\\ push*|git\\ add*|git\\ checkout*|git\\ reset*|git\\ stash*|git\\ merge*|git\\ rebase*) echo '{}'; exit 0 ;;
            rm\\ *|mv\\ *|cp\\ *|mkdir\\ *|touch\\ *|chmod\\ *|chown\\ *) echo '{}'; exit 0 ;;
            swift\\ build*|swift\\ test*|swift\\ package*|swift\\ run*) echo '{}'; exit 0 ;;
            npm\\ run*|npm\\ start*|npm\\ install*|yarn\\ *|bun\\ run*|bun\\ test*|bun\\ install*) echo '{}'; exit 0 ;;
            cargo\\ build*|cargo\\ test*|cargo\\ run*|cargo\\ install*) echo '{}'; exit 0 ;;
            go\\ build*|go\\ test*|go\\ run*|go\\ install*) echo '{}'; exit 0 ;;
            make\\ *|cmake\\ *|docker\\ *|kubectl\\ *) echo '{}'; exit 0 ;;
            pip\\ install*|pip3\\ install*|brew\\ install*|brew\\ upgrade*) echo '{}'; exit 0 ;;
            cd\\ *|export\\ *|source\\ *|eval\\ *) echo '{}'; exit 0 ;;
            sudo\\ *) echo '{}'; exit 0 ;;
            *\\>*) echo '{}'; exit 0 ;;
            echo\\ *\\>*|printf\\ *\\>*|cat\\ *\\>*) echo '{}'; exit 0 ;;
        esac

        [ "$_FILTER" = "off" ] && echo '{}' && exit 0

        ESCAPED=$(echo "$COMMAND" | sed 's/"/\\\\"/g')
        echo "{\\"decision\\":\\"block\\",\\"reason\\":\\"Use mcp__senkani__senkani_exec instead of Bash for this read-only command. It filters output (24 command rules, ANSI stripping, dedup, truncation, secret detection). Pass command: \\\\\\"${ESCAPED}\\\\\\"\\"}";
        ;;

    Grep)
        [ "${SENKANI_INTERCEPT_GREP:-on}" = "off" ] && echo '{}' && exit 0
        [ "$_INDEX" = "off" ] && echo '{}' && exit 0

        PATTERN=$(echo "$INPUT" | /usr/bin/python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print(d.get('tool_input', {}).get('pattern', ''))
except:
    print('')
" 2>/dev/null)

        case "$PATTERN" in
            *\\\\*|*\\[*|*\\(*|*\\|*|*\\+*|*\\?*|*\\^*|*\\$*) echo '{}'; exit 0 ;;
        esac

        echo "$PATTERN" | grep -qE '^[a-zA-Z_][a-zA-Z0-9_]*$' || { echo '{}'; exit 0; }

        echo "{\\"decision\\":\\"block\\",\\"reason\\":\\"Use mcp__senkani__senkani_search instead of Grep for symbol lookup. Returns compact results (~50 tokens vs ~5000). Pass query: \\\\\\"${PATTERN}\\\\\\". For regex or content search, Grep is fine — set SENKANI_INTERCEPT_GREP=off to stop this redirect.\\"}"
        ;;

    *)
        echo '{}'
        ;;
esac
"""
}
