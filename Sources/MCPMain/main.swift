import Foundation
import MCPServer

// senkani-mcp argv modes:
//
//   senkani-mcp           → run the MCP server (default; what Claude Code spawns)
//   senkani-mcp eval      → run `senkani ml-eval` orchestration once and exit
//
// The CLI's `senkani ml-eval` subcommand shells out to `senkani-mcp eval`
// because the eval pulls in MLX (VLMModelFactory etc.) and we don't want
// the everyday senkani CLI binary to grow that dependency surface.

let argv = CommandLine.arguments
let mode = argv.count > 1 ? argv[1] : "server"

switch mode {
case "server":
    try await MCPServerRunner.run()

case "eval":
    _ = try await MLTierEvalOrchestrator.run()

default:
    FileHandle.standardError.write(Data(
        "senkani-mcp: unknown mode '\(mode)'. Valid: server (default), eval\n".utf8
    ))
    exit(2)
}
