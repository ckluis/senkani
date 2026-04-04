import ArgumentParser
import Foundation

struct Init: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Install or uninstall the Claude Code hook."
    )

    @Flag(name: .long, help: "Install hook globally (~/.claude/hooks/).")
    var global = false

    @Flag(name: .long, help: "Remove the hook.")
    var uninstall = false

    func run() throws {
        let hookDir: String
        if global {
            hookDir = NSHomeDirectory() + "/.claude/hooks"
        } else {
            hookDir = ".claude/hooks"
        }

        let hookPath = hookDir + "/senkani-hook.sh"
        let settingsPath: String
        if global {
            settingsPath = NSHomeDirectory() + "/.claude/settings.json"
        } else {
            settingsPath = ".claude/settings.json"
        }

        if uninstall {
            try? FileManager.default.removeItem(atPath: hookPath)
            print("Removed hook at \(hookPath)")
            print("Note: You may need to manually remove the hook entry from \(settingsPath)")
            return
        }

        // Create hooks directory
        try FileManager.default.createDirectory(atPath: hookDir, withIntermediateDirectories: true)

        // Find senkani binary path
        let senkaniPath = ProcessInfo.processInfo.arguments.first ?? "/usr/local/bin/senkani"
        let resolvedPath: String
        if senkaniPath.hasPrefix("/") {
            resolvedPath = senkaniPath
        } else {
            // Try to find in PATH
            let which = Process()
            let pipe = Pipe()
            which.executableURL = URL(fileURLWithPath: "/usr/bin/which")
            which.arguments = ["senkani"]
            which.standardOutput = pipe
            try? which.run()
            which.waitUntilExit()
            let pathData = pipe.fileHandleForReading.readDataToEndOfFile()
            resolvedPath = String(data: pathData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? senkaniPath
        }

        let hookScript = generateHookScript(senkaniPath: resolvedPath)
        try hookScript.write(toFile: hookPath, atomically: true, encoding: .utf8)

        // Make executable
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hookPath)

        print("Hook installed at \(hookPath)")
        print("")
        print("To activate, add this to \(settingsPath):")
        print("""
        {
          "hooks": {
            "PreToolUse": [
              {
                "matcher": "Bash",
                "hooks": ["\(hookPath)"]
              }
            ]
          }
        }
        """)
        print("")
        print("Toggle modes:")
        print("  export SENKANI_MODE=filter      # default, filter output")
        print("  export SENKANI_MODE=passthrough  # no filtering (control)")
        print("  export SENKANI_MODE=stats        # measure without filtering")
    }

    private func generateHookScript(senkaniPath: String) -> String {
        return """
        #!/bin/bash
        # Senkani PreToolUse:Bash hook
        # Rewrites shell commands to run through senkani's filter pipeline.
        # Toggle: export SENKANI_MODE=filter|passthrough|stats

        INPUT=$(cat)
        COMMAND=$(echo "$INPUT" | /usr/bin/python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('tool_input',{}).get('command',''))" 2>/dev/null)

        if [ -z "$COMMAND" ]; then
          echo '{}'
          exit 0
        fi

        MODE="${SENKANI_MODE:-filter}"

        if [ "$MODE" = "passthrough" ]; then
          echo '{}'
          exit 0
        fi

        SENKANI_BIN="\(senkaniPath)"

        if [ ! -x "$SENKANI_BIN" ]; then
          echo '{}'
          exit 0
        fi

        STATS_FLAG=""
        [ "$MODE" = "stats" ] && STATS_FLAG="--stats-only"

        # Set up metrics file for this session
        SENKANI_METRICS_FILE="${SENKANI_METRICS_FILE:-/tmp/senkani-session-$PPID.jsonl}"
        export SENKANI_METRICS_FILE

        # Rewrite the command
        NEW_COMMAND="SENKANI_MODE=$MODE SENKANI_METRICS_FILE=$SENKANI_METRICS_FILE $SENKANI_BIN exec $STATS_FLAG -- $COMMAND"

        /usr/bin/python3 -c "
        import json, sys
        print(json.dumps({'decision': 'modify', 'updatedInput': {'command': sys.argv[1]}}))
        " "$NEW_COMMAND"
        """
    }
}
