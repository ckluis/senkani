import Foundation
import MCP
import MLXLMCommon
import MLXVLM
import MLXEmbedders
import Core

public struct MCPServerRunner {
    public static func run() async throws {
        FileHandle.standardError.write(Data("🔴 [MCP-SERVER] Senkani MCP server STARTED at \(Date())\n".utf8))
        FileHandle.standardError.write(Data("🔴 [MCP-SERVER] PID=\(ProcessInfo.processInfo.processIdentifier) binary=\(ProcessInfo.processInfo.arguments.first ?? "?")\n".utf8))
        FileHandle.standardError.write(Data("🔴 [MCP-SERVER] SENKANI_METRICS_FILE = \(ProcessInfo.processInfo.environment["SENKANI_METRICS_FILE"] ?? "NOT SET")\n".utf8))
        FileHandle.standardError.write(Data("🔴 [MCP-SERVER] SENKANI_PROJECT_ROOT = \(ProcessInfo.processInfo.environment["SENKANI_PROJECT_ROOT"] ?? "NOT SET")\n".utf8))
        FileHandle.standardError.write(Data("🔴 [MCP-SERVER] SENKANI_PANE_ID = \(ProcessInfo.processInfo.environment["SENKANI_PANE_ID"] ?? "NOT SET")\n".utf8))
        // Access gate: only activate in Senkani-managed panes.
        // SENKANI_PANE_ID is injected by PaneContainerView into Senkani-spawned shells
        // via execve() and inherited by claude → MCP server. It is never present in
        // a shell opened outside the Senkani app.
        guard ProcessInfo.processInfo.environment["SENKANI_PANE_ID"] != nil else {
            FileHandle.standardError.write(
                Data("[MCP] SENKANI_PANE_ID absent — not a Senkani pane, exiting\n".utf8))
            exit(0)
        }

        let session = MCPSession.resolve()

        // Register download handler so ModelManager.download(modelId:) works from the UI.
        // This bridges Core (no MLX dependency) to the MCP layer (has MLX).
        ModelManager.shared.registerDownloadHandler { modelId in
            switch modelId {
            case "minilm-l6":
                _ = try await EmbedTool.engine.ensureModel()
            case "qwen2-vl-2b", "gemma3-4b":
                _ = try await VisionTool.engine.ensureModel()
            default:
                throw NSError(
                    domain: "dev.senkani.MCPServer",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Unknown model ID: \(modelId)"]
                )
            }
        }

        let baseInstructions = """
            Senkani is a token compression layer. Use senkani_read instead of reading files directly \
            for automatic compression and caching. Use senkani_search and senkani_fetch for \
            token-efficient code navigation. Use senkani_exec for filtered command execution. \
            Call senkani_session with action 'stats' to see savings.
            """

        let instructions: String
        if TerseMode.isEnabled {
            instructions = TerseMode.systemPrompt + "\n\n" + baseInstructions
        } else {
            instructions = baseInstructions
        }

        let server = Server(
            name: "senkani",
            version: "0.1.0",
            instructions: instructions,
            capabilities: .init(tools: .init(listChanged: false))
        )

        await ToolRouter.register(on: server, session: session)

        // Handle SIGTERM/SIGINT for clean shutdown
        let sigTermSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        sigTermSource.setEventHandler {
            FileHandle.standardError.write(Data("🔴 [MCP] Received SIGTERM — shutting down\n".utf8))
            session.shutdown()
            SessionDatabase.shared.close()
            exit(0)
        }
        sigTermSource.resume()
        signal(SIGTERM, SIG_IGN) // Let DispatchSource handle it

        let sigIntSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        sigIntSource.setEventHandler {
            FileHandle.standardError.write(Data("🔴 [MCP] Received SIGINT — shutting down\n".utf8))
            session.shutdown()
            SessionDatabase.shared.close()
            exit(0)
        }
        sigIntSource.resume()
        signal(SIGINT, SIG_IGN)

        let transport = StdioTransport()
        try await server.start(transport: transport)

        // Detect when Claude Code disconnects by monitoring the parent process.
        // When the parent exits, macOS reparents us to launchd (PID 1).
        // Also enforce a 2-hour max lifetime as a safety net.
        let parentPID = getppid()
        let startTime = Date()
        let maxLifetime: TimeInterval = 7200 // 2 hours

        FileHandle.standardError.write(Data("🔴 [MCP] Parent PID=\(parentPID). Monitoring for disconnect...\n".utf8))

        while true {
            try await Task.sleep(for: .seconds(2))

            // Parent died — Claude Code disconnected
            if getppid() != parentPID {
                FileHandle.standardError.write(Data("🔴 [MCP] Parent process exited (was PID \(parentPID), now \(getppid())). Shutting down.\n".utf8))
                break
            }

            // Safety timeout — prevent zombie accumulation
            if Date().timeIntervalSince(startTime) > maxLifetime {
                FileHandle.standardError.write(Data("🔴 [MCP] Safety timeout — 2 hour max session reached. Shutting down.\n".utf8))
                break
            }
        }

        // Clean shutdown
        session.shutdown()
        SessionDatabase.shared.close()
        FileHandle.standardError.write(Data("🔴 [MCP] Process exiting cleanly.\n".utf8))

        // Keep signal sources alive until exit
        withExtendedLifetime((sigTermSource, sigIntSource)) {}
        exit(0)
    }
}
