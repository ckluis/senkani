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

        // Start watching for macOS memory-pressure warnings. Registered
        // MLX engines will drop their ModelContainers when a warning fires.
        await MLXInferenceLock.shared.startMemoryMonitor()

        // Register download handler so ModelManager.download(modelId:) works from the UI.
        // This bridges Core (no MLX dependency) to the MCP layer (has MLX).
        ModelManager.shared.registerDownloadHandler { modelId in
            switch modelId {
            case EmbedEngine.modelId:
                _ = try await EmbedTool.engine.ensureModel()
            case let id where ModelManager.visionModelIds.contains(id):
                _ = try await VisionTool.engine.ensureModel()
            default:
                throw NSError(
                    domain: "dev.senkani.MCPServer",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Unknown model ID: \(modelId). Known: \(ModelManager.shared.models.map(\.id))"]
                )
            }
        }

        let baseInstructions = """
            Senkani is a token compression layer. Use senkani_read instead of reading files directly \
            for automatic compression and caching. senkani_read returns a compact outline by default — \
            pass full: true only when you need the complete file content. Use senkani_search and \
            senkani_fetch for token-efficient code navigation. Use senkani_exec for filtered command \
            execution. Call senkani_session with action 'stats' to see savings. \
            Use senkani_session action='pin' to keep a symbol's outline in context across calls.
            """

        // P1-7: bounded instructions payload. instructionsPayload handles repoMap +
        // sessionBrief + skills assembly with a single byte budget (default 2 KB).
        let payload = session.instructionsPayload(base: baseInstructions)
        let instructions: String
        if TerseMode.isEnabled {
            instructions = TerseMode.systemPrompt + "\n\n" + payload
        } else {
            instructions = payload
        }

        let server = Server(
            name: "senkani",
            version: VersionTool.serverVersion,
            instructions: instructions,
            capabilities: .init(tools: .init(listChanged: false))
        )

        await ToolRouter.register(on: server, session: session)

        // P1-6: start hourly retention pruning. Previously the prune functions existed
        // but nothing scheduled them — long-running installs accumulated unbounded rows.
        let retentionConfig = RetentionConfig.load(projectRoot: ProcessInfo.processInfo.environment["SENKANI_PROJECT_ROOT"])
        RetentionScheduler.shared.start(config: retentionConfig)

        // Handle SIGTERM/SIGINT for clean shutdown
        let sigTermSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        sigTermSource.setEventHandler {
            Logger.log("mcp.signal.received", fields: ["signal": .string("SIGTERM"), "outcome": .string("shutdown")])
            RetentionScheduler.shared.stop()
            session.shutdown()
            SessionDatabase.shared.close()
            exit(0)
        }
        sigTermSource.resume()
        signal(SIGTERM, SIG_IGN) // Let DispatchSource handle it

        let sigIntSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        sigIntSource.setEventHandler {
            Logger.log("mcp.signal.received", fields: ["signal": .string("SIGINT"), "outcome": .string("shutdown")])
            RetentionScheduler.shared.stop()
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

        Logger.log("mcp.started", fields: ["parent_pid": .int(Int(parentPID))])

        while true {
            try await Task.sleep(for: .seconds(2))

            // Parent died — Claude Code disconnected
            if getppid() != parentPID {
                Logger.log("mcp.parent.exited", fields: [
                    "was_pid": .int(Int(parentPID)),
                    "now_pid": .int(Int(getppid())),
                    "outcome": .string("shutdown")
                ])
                break
            }

            // Safety timeout — prevent zombie accumulation
            if Date().timeIntervalSince(startTime) > maxLifetime {
                Logger.log("mcp.safety.timeout", fields: [
                    "max_lifetime_seconds": .int(Int(maxLifetime)),
                    "outcome": .string("shutdown")
                ])
                break
            }
        }

        // Clean shutdown
        RetentionScheduler.shared.stop()
        session.shutdown()
        SessionDatabase.shared.close()
        Logger.log("mcp.exited", fields: ["outcome": .string("clean")])

        // Keep signal sources alive until exit
        withExtendedLifetime((sigTermSource, sigIntSource)) {}
        exit(0)
    }
}
