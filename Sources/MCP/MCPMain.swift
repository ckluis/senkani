import MCP

public struct MCPServerRunner {
    public static func run() async throws {
        let session = MCPSession.resolve()

        let server = Server(
            name: "senkani",
            version: "0.1.0",
            instructions: """
            Senkani is a token compression layer. Use senkani_read instead of reading files directly \
            for automatic compression and caching. Use senkani_search and senkani_fetch for \
            token-efficient code navigation. Use senkani_exec for filtered command execution. \
            Call senkani_session with action 'stats' to see savings.
            """,
            capabilities: .init(tools: .init(listChanged: false))
        )

        await ToolRouter.register(on: server, session: session)

        let transport = StdioTransport()
        try await server.start(transport: transport)

        // Keep running until the transport closes (10 year sleep, effectively forever)
        try await Task.sleep(for: .seconds(315_360_000))
    }
}
