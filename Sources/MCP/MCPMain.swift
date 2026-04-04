import Foundation
import MCP
import MLXLMCommon
import MLXVLM
import MLXEmbedders
import Core

public struct MCPServerRunner {
    public static func run() async throws {
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

        let transport = StdioTransport()
        try await server.start(transport: transport)

        // Keep running until the transport closes (10 year sleep, effectively forever)
        try await Task.sleep(for: .seconds(315_360_000))
    }
}
