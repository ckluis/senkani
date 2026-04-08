import SwiftUI
import Core

struct SenkaniGUI: App {
    @State private var menuBarManager = MenuBarManager()

    init() {
        do {
            try AutoRegistration.registerIfNeeded()
        } catch {
            // Non-fatal -- log and continue. The app works without auto-registration.
            FileHandle.standardError.write(Data("[senkani] Auto-registration failed: \(error.localizedDescription)\n".utf8))
        }
        Self.cleanupStaleMCPProcesses()
    }

    /// Kill stale MCP server processes left over from previous sessions.
    /// Claude Code spawns MCP servers that should exit when stdin closes,
    /// but old versions (before the stdin EOF fix) may linger indefinitely.
    private static func cleanupStaleMCPProcesses() {
        let pipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-f", "mcp-server"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return // pgrep not available or failed — skip cleanup
        }

        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let myPID = ProcessInfo.processInfo.processIdentifier
        let pids = output.split(separator: "\n")
            .compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
            .filter { $0 != myPID }

        if pids.count > 5 {
            print("🧹 [CLEANUP] Found \(pids.count) stale MCP server processes — sending SIGTERM")
            for pid in pids {
                kill(pid, SIGTERM)
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1100, height: 700)

        MenuBarExtra("Senkani", systemImage: "bolt.circle") {
            MenuBarContentView(manager: menuBarManager)
        }
    }
}
