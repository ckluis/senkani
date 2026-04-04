import ArgumentParser
import Foundation

struct MCPInstall: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mcp-install",
        abstract: "Register the senkani MCP server with Claude Code."
    )

    @Flag(name: .long, help: "Install for all projects (writes to ~/.claude.json).")
    var global = false

    @Flag(name: .long, help: "Remove the MCP server registration.")
    var uninstall = false

    func run() throws {
        let mcpBinary = findMCPBinary()

        if uninstall {
            if global {
                try removeFromClaudeJson()
            } else {
                try removeFromMcpJson()
            }
            return
        }

        guard let binary = mcpBinary else {
            print("Error: senkani-mcp binary not found.")
            print("Build it first: swift build -c release")
            throw ExitCode.failure
        }

        if global {
            try installGlobal(binaryPath: binary)
        } else {
            try installProject(binaryPath: binary)
        }

        print("")
        print("  Restart Claude Code to activate. You'll see these tools:")
        print("    senkani_read      compressed file reads with caching")
        print("    senkani_exec      filtered command execution")
        print("    senkani_search    symbol search")
        print("    senkani_fetch     symbol source fetch")
        print("    senkani_explore   project structure")
        print("    senkani_session   stats, toggle features, reset")
        print("    senkani_validate  local compiler/linter validation")
        print("    senkani_parse     structured output extraction")
        print("    senkani_embed     semantic code search (local ML)")
        print("    senkani_vision    image analysis (local ML)")
        print("")
        print("  Toggle features:")
        print("    export SENKANI_MCP_FILTER=off    # disable filtering")
        print("    export SENKANI_MCP_CACHE=off     # disable read cache")
        print("    export SENKANI_MODE=passthrough   # disable everything")
        print("")
    }

    // MARK: - Project-level install (.mcp.json)

    /// Write to .mcp.json in the current directory (project root).
    /// This is how Claude Code discovers project-level MCP servers.
    private func installProject(binaryPath: String) throws {
        let mcpJsonPath = FileManager.default.currentDirectoryPath + "/.mcp.json"

        var config: [String: Any] = [:]
        if let data = FileManager.default.contents(atPath: mcpJsonPath),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            config = existing
        }

        var mcpServers = config["mcpServers"] as? [String: Any] ?? [:]
        mcpServers["senkani"] = [
            "command": binaryPath,
            "args": [String](),
        ] as [String: Any]
        config["mcpServers"] = mcpServers

        let data = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: mcpJsonPath))

        print("Senkani MCP server registered in \(mcpJsonPath)")
        print("  Binary: \(binaryPath)")
    }

    // MARK: - Global install (~/.claude.json)

    /// Write to ~/.claude.json under the current project path.
    /// Claude Code reads per-project MCP servers from projects.{path}.mcpServers.
    private func installGlobal(binaryPath: String) throws {
        let claudeJsonPath = NSHomeDirectory() + "/.claude.json"
        let projectRoot = FileManager.default.currentDirectoryPath

        guard let data = FileManager.default.contents(atPath: claudeJsonPath),
              var config = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            print("Error: ~/.claude.json not found. Run Claude Code at least once first.")
            throw ExitCode.failure
        }

        var projects = config["projects"] as? [String: Any] ?? [:]
        var projectConfig = projects[projectRoot] as? [String: Any] ?? [:]
        var mcpServers = projectConfig["mcpServers"] as? [String: Any] ?? [:]

        mcpServers["senkani"] = [
            "command": binaryPath,
            "args": [String](),
        ] as [String: Any]

        projectConfig["mcpServers"] = mcpServers
        projects[projectRoot] = projectConfig
        config["projects"] = projects

        let newData = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys])
        try newData.write(to: URL(fileURLWithPath: claudeJsonPath))

        print("Senkani MCP server registered globally for \(projectRoot)")
        print("  Binary: \(binaryPath)")
        print("  Config: \(claudeJsonPath)")
    }

    // MARK: - Uninstall

    private func removeFromMcpJson() throws {
        let mcpJsonPath = FileManager.default.currentDirectoryPath + "/.mcp.json"
        guard let data = FileManager.default.contents(atPath: mcpJsonPath),
              var config = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            print("No .mcp.json found.")
            return
        }

        if var mcpServers = config["mcpServers"] as? [String: Any] {
            mcpServers.removeValue(forKey: "senkani")
            config["mcpServers"] = mcpServers
        }

        let newData = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys])
        try newData.write(to: URL(fileURLWithPath: mcpJsonPath))
        print("Removed senkani from .mcp.json")
    }

    private func removeFromClaudeJson() throws {
        let claudeJsonPath = NSHomeDirectory() + "/.claude.json"
        let projectRoot = FileManager.default.currentDirectoryPath

        guard let data = FileManager.default.contents(atPath: claudeJsonPath),
              var config = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            print("No ~/.claude.json found.")
            return
        }

        if var projects = config["projects"] as? [String: Any],
           var projectConfig = projects[projectRoot] as? [String: Any],
           var mcpServers = projectConfig["mcpServers"] as? [String: Any] {
            mcpServers.removeValue(forKey: "senkani")
            projectConfig["mcpServers"] = mcpServers
            projects[projectRoot] = projectConfig
            config["projects"] = projects
        }

        let newData = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys])
        try newData.write(to: URL(fileURLWithPath: claudeJsonPath))
        print("Removed senkani from ~/.claude.json for \(projectRoot)")
    }

    // MARK: - Binary detection

    private func findMCPBinary() -> String? {
        let selfPath = ProcessInfo.processInfo.arguments.first ?? ""
        let selfDir = (selfPath as NSString).deletingLastPathComponent

        let sameDir = selfDir + "/senkani-mcp"
        if FileManager.default.isExecutableFile(atPath: sameDir) { return sameDir }

        let buildDir = FileManager.default.currentDirectoryPath + "/.build/release/senkani-mcp"
        if FileManager.default.isExecutableFile(atPath: buildDir) { return buildDir }

        let debugDir = FileManager.default.currentDirectoryPath + "/.build/debug/senkani-mcp"
        if FileManager.default.isExecutableFile(atPath: debugDir) { return debugDir }

        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = ["senkani-mcp"]
        process.standardOutput = pipe
        try? process.run()
        process.waitUntilExit()
        if process.terminationStatus == 0 {
            let path = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let p = path, !p.isEmpty { return p }
        }

        return nil
    }
}
