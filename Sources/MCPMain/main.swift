import Foundation
import MCPServer

// senkani-mcp argv modes:
//
//   senkani-mcp           → run the MCP server (default; what Claude Code spawns)
//   senkani-mcp eval      → run `senkani ml-eval` orchestration once and exit
//   senkani-mcp prose     → read stdin-JSON, compile prose→cron via MLX,
//                           write stdout-JSON, exit 0/1 (one-shot IPC for
//                           the CLI's `--prose` subprocess delegation —
//                           see Sources/CLI/SubprocessMLXProseCadenceCompiler.swift)
//
// The CLI shells out to `senkani-mcp` for any work that pulls in MLX
// (VLMModelFactory etc.) so the everyday `senkani` binary stays lean —
// `eval` (since v0.2.0) and now `prose` (U.8b follow-up,
// `phase-u8b-mlx-prose-subprocess-delegation-2026-05-28`).

let argv = CommandLine.arguments
let mode = argv.count > 1 ? argv[1] : "server"

switch mode {
case "server":
    try await MCPServerRunner.run()

case "eval":
    _ = try await MLTierEvalOrchestrator.run()

case "prose":
    await ProseSubprocessHandler.run()

default:
    FileHandle.standardError.write(Data(
        "senkani-mcp: unknown mode '\(mode)'. Valid: server (default), eval, prose\n".utf8
    ))
    exit(2)
}
