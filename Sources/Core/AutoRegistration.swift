import Foundation

/// Handles first-launch auto-registration of Senkani as an MCP server
/// in ~/.claude/settings.json.
///
/// Does NOT register global hooks. Hooks are activated per-terminal via
/// the SENKANI_INTERCEPT=on environment variable set in PaneContainerView.
///
/// Every method is idempotent -- safe to call on every launch.
public enum AutoRegistration {

    // MARK: - Public API

    /// Register Senkani as an MCP server in ~/.claude/settings.json if not already registered.
    /// Also cleans up hooks from global AND project-level settings (legacy behavior).
    public static func registerIfNeeded() throws {
        let binaryPath = resolveBinaryPath()
        let settingsPath = NSHomeDirectory() + "/.claude/settings.json"

        var config = try readJSONOrEmpty(at: settingsPath)
        var needsWrite = false

        // STEP 1: Remove ALL hooks unconditionally. FIRST. Every launch. No exceptions.
        // Senkani must never pollute the global Claude Code hook chain.
        if config["hooks"] != nil {
            config.removeValue(forKey: "hooks")
            needsWrite = true
            logWarning("Removed hooks from global settings.json")
        }

        // Write immediately if hooks were found — don't risk them surviving a crash
        if needsWrite {
            try writeJSONAtomically(config, to: settingsPath)
            needsWrite = false
        }

        // STEP 2: Clean project-level hooks in ~/.claude/projects/*/settings.json
        cleanAllProjectHooks()

        // Register MCP server entry if needed
        var mcpServers = config["mcpServers"] as? [String: Any] ?? [:]
        let mcpRegistered = (mcpServers["senkani"] as? [String: Any])?["command"] as? String == binaryPath

        if !mcpRegistered {
            backupIfFirstWrite(path: settingsPath)

            mcpServers["senkani"] = [
                "command": binaryPath,
                "args": ["--mcp-server"],
            ] as [String: Any]
            config["mcpServers"] = mcpServers
            needsWrite = true
        }

        // Clean up legacy senkani-daemon entry
        if mcpServers["senkani-daemon"] != nil {
            mcpServers.removeValue(forKey: "senkani-daemon")
            config["mcpServers"] = mcpServers
            needsWrite = true
        }

        if needsWrite {
            try writeJSONAtomically(config, to: settingsPath)
        }
    }

    /// Enumerate all project-level settings and remove hooks from each.
    /// Claude Code reads ~/.claude/projects/<encoded>/settings.json per-project.
    private static func cleanAllProjectHooks() {
        let projectsDir = NSHomeDirectory() + "/.claude/projects"
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: projectsDir) else { return }

        for entry in entries {
            let settingsPath = projectsDir + "/" + entry + "/settings.json"
            guard fm.fileExists(atPath: settingsPath) else { continue }
            guard var config = try? readJSONOrEmpty(at: settingsPath) else { continue }

            if config["hooks"] != nil {
                config.removeValue(forKey: "hooks")
                try? writeJSONAtomically(config, to: settingsPath)
                logWarning("Removed hooks from project settings: \(entry)/settings.json")
            }
        }
    }

    /// Install the PreToolUse hook script to ~/.senkani/hooks/ for use
    /// inside Senkani's embedded terminals.
    ///
    /// This writes the script FILE to disk only. It does NOT register
    /// hooks in ~/.claude/settings.json. Hooks are activated per-terminal
    /// via SENKANI_INTERCEPT=on set in PaneContainerView's environment.
    public static func installHooksIfNeeded() throws {
        let hookDir = NSHomeDirectory() + "/.senkani/hooks"
        let hookPath = hookDir + "/senkani-intercept.sh"
        let fm = FileManager.default

        // Write the hook script (but don't register globally)
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

        // Hook is activated per-terminal via SENKANI_INTERCEPT=on env var,
        // NOT via global settings.json. See PaneContainerView for env setup.
    }

    // MARK: - Private: Binary Resolution

    /// Resolve the path to the Senkani binary.
    /// Prefers Bundle.main.executablePath for .app bundles, falls back to argv[0].
    public static func resolveBinaryPath() -> String {
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

        // Relative path -- resolve against cwd
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
            // SECURITY: Corrupt JSON -- refuse to modify to avoid data loss
            logWarning("\(path) contains invalid JSON -- skipping modification")
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

        // Atomic rename -- original stays intact if we crash between write and rename
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

    /// Date of the embedded hook script -- used to skip overwrite if on-disk is newer.
    /// Update this when the embedded script content changes.
    private static let embeddedHookDate: Date = {
        let formatter = ISO8601DateFormatter()
        return formatter.date(from: "2026-04-05T00:00:00Z") ?? Date.distantPast
    }()

    /// Write the hook script to disk atomically and set executable permissions (0755).
    private static func writeHookScript(to path: String) throws {
        let url = URL(fileURLWithPath: path)
        let dir = url.deletingLastPathComponent()
        let tempURL = dir.appendingPathComponent(".\(url.lastPathComponent).tmp.\(ProcessInfo.processInfo.processIdentifier)")

        // Write to temp file, then rename -- prevents truncated script on crash
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
                return "\(path) contains invalid JSON -- refusing to modify"
            }
        }
    }

    // MARK: - Embedded Hook Script

    // TODO: Phase 5 -- replace python3 JSON parsing with compiled helper
    // The hook uses /usr/bin/python3 for JSON parsing. This is a mutable interpreter
    // in the trust chain -- an attacker who controls python3 could alter hook behavior.
    // For Phase 1 this is accepted; Phase 5 should ship a small compiled JSON parser.

    /// The hook script, embedded as a string so it works in MCP server mode too
    /// (no Bundle resource access needed).
    private static let embeddedHookScript = """
#!/bin/bash
# Senkani PreToolUse hook -- routes Read/Bash/Grep through senkani MCP tools.
#
# Respects ALL toggle states:
#   SENKANI_MODE=passthrough       -> all interception off (native tools only)
#   SENKANI_INTERCEPT=off          -> all interception off
#   SENKANI_INTERCEPT_READ=off     -> Read passes through (native Read)
#   SENKANI_INTERCEPT_BASH=off     -> Bash passes through (native Bash)
#   SENKANI_INTERCEPT_GREP=off     -> Grep passes through (native Grep)
#   SENKANI_MCP_FILTER=off         -> filtering disabled (still routes through MCP for cache/secrets)
#   SENKANI_MCP_CACHE=off          -> cache disabled (still routes for filtering/secrets)
#
# When ALL MCP features are off, there's no reason to route through MCP.
# The hook passes through to native tools in that case.

# Global kill switches
[ "${SENKANI_MODE:-}" = "passthrough" ] && echo '{}' && exit 0

# Activation: env var (fast path) OR .mcp.json with senkani entry (fallback).
# The fallback handles the case where Claude Code doesn't inherit env vars
# from the terminal shell to hook subprocesses.
_INTERCEPT="${SENKANI_INTERCEPT:-off}"
if [ "$_INTERCEPT" != "on" ] && [ -f ".mcp.json" ]; then
    grep -q '"senkani"' ".mcp.json" 2>/dev/null && _INTERCEPT="on"
fi
[ "$_INTERCEPT" != "on" ] && echo '{}' && exit 0

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

        # SECURITY: Use python3 for proper JSON encoding to prevent injection
        # via special characters (backslashes, newlines, control chars) in COMMAND
        REASON=$(echo "$COMMAND" | /usr/bin/python3 -c "
import sys, json
cmd = sys.stdin.read().strip()
reason = 'Use mcp__senkani__senkani_exec instead of Bash for this read-only command. It filters output (24 command rules, ANSI stripping, dedup, truncation, secret detection). Pass command: \\"' + cmd + '\\"'
print(json.dumps({'decision': 'block', 'reason': reason}))
" 2>/dev/null)
        [ -z "$REASON" ] && echo '{}' && exit 0
        echo "$REASON"
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

        echo "{\\"decision\\":\\"block\\",\\"reason\\":\\"Use mcp__senkani__senkani_search instead of Grep for symbol lookup. Returns compact results (~50 tokens vs ~5000). Pass query: \\\\\\"${PATTERN}\\\\\\". For regex or content search, Grep is fine -- set SENKANI_INTERCEPT_GREP=off to stop this redirect.\\"}"
        ;;

    *)
        echo '{}'
        ;;
esac
"""
}
