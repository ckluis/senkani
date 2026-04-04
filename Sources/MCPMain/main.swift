import MCPServer

@main
struct SenkaniMCPEntry {
    static func main() async throws {
        try await MCPServerRunner.run()
    }
}
