import ArgumentParser
import Core
import Foundation

struct Init: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Register senkani-hook for the current project."
    )

    @Flag(name: .long, help: "Remove the hook registration.")
    var uninstall = false

    @Option(name: .long, help: "Path to the senkani-hook binary (auto-detected if omitted).")
    var hookPath: String?

    func run() throws {
        let projectPath = FileManager.default.currentDirectoryPath

        // Find the hook binary
        let resolvedHookPath: String
        if let explicit = hookPath {
            resolvedHookPath = explicit
        } else if let found = HookRegistration.findHookBinary() {
            resolvedHookPath = found
        } else {
            print("Error: senkani-hook binary not found.")
            print("Build it with: swift build -c release --product senkani-hook")
            print("Or specify the path: senkani init --hook-path /path/to/senkani-hook")
            throw ExitCode.failure
        }

        if uninstall {
            try HookRegistration.unregisterForProject(at: projectPath, hookBinaryPath: resolvedHookPath)
            print("Removed senkani-hook from \(projectPath)/.claude/settings.json")
            return
        }

        // Register hooks for this project
        try HookRegistration.registerForProject(at: projectPath, hookBinaryPath: resolvedHookPath)

        print("senkani-hook registered for project: \(projectPath)")
        print("")
        print("Hook binary: \(resolvedHookPath)")
        print("Settings:    \(projectPath)/.claude/settings.json")
        print("")
        print("Hooks registered for: PreToolUse, PostToolUse")
        print("")
        print("Activation:")
        print("  Hooks fire automatically inside Senkani terminals (SENKANI_INTERCEPT=on)")
        print("  For standalone use: export SENKANI_HOOK=on")
    }
}
