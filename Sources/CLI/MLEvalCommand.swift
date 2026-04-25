import ArgumentParser
import Foundation

/// `senkani ml-eval` — drives the per-tier Gemma 4 quality eval.
///
/// The actual orchestration (model load, inference, report write) lives in
/// `MCPServer.MLTierEvalOrchestrator` because it requires MLX. This CLI
/// command is a thin shim that locates `senkani-mcp` and runs it in
/// `eval` mode, so the everyday `senkani` binary doesn't pull MLX into
/// its dependency surface.
///
/// Output: streams orchestrator progress through to the user. On success
/// `~/.senkani/ml-tier-eval.json` is updated and `senkani doctor` will
/// surface per-tier ratings on its next run.
struct MLEval: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ml-eval",
        abstract: "Evaluate per-RAM-tier Gemma 4 output quality and write the report.",
        discussion: """
            Loads each Gemma 4 tier this machine can host (RAM-permitting and
            installed), runs the 20-task harness from Bench.MLTierEvalTasks,
            and writes ~/.senkani/ml-tier-eval.json. Tiers above this
            machine's RAM, or not yet installed, are recorded as
            `notEvaluated` so `senkani doctor` still surfaces them.

            Requires senkani-mcp to be discoverable next to this binary,
            in .build/{release,debug}/, or on PATH.
            """
    )

    @Option(name: .long, help: "Path to senkani-mcp (default: auto-discover).")
    var mcpBinary: String?

    func run() throws {
        let binary: String
        if let override = mcpBinary {
            guard FileManager.default.isExecutableFile(atPath: override) else {
                FileHandle.standardError.write(Data(
                    "ml-eval: --mcp-binary \(override) is not an executable file\n".utf8
                ))
                throw ExitCode.failure
            }
            binary = override
        } else {
            guard let discovered = Self.discoverMCPBinary() else {
                FileHandle.standardError.write(Data("""
                    ml-eval: could not locate senkani-mcp.
                    Tried: same dir as senkani, .build/release/, .build/debug/, $PATH.
                    Build it with: swift build -c release
                    Or pass --mcp-binary <path>.

                    """.utf8))
                throw ExitCode.failure
            }
            binary = discovered
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["eval"]
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError
        do {
            try process.run()
        } catch {
            FileHandle.standardError.write(Data(
                "ml-eval: failed to spawn \(binary): \(error.localizedDescription)\n".utf8
            ))
            throw ExitCode.failure
        }
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            throw ExitCode(process.terminationStatus)
        }
    }

    // MARK: - Binary discovery

    /// Find a `senkani-mcp` executable. Checks, in order:
    /// 1. Same directory as `argv[0]` (release install).
    /// 2. `.build/release/senkani-mcp` under cwd (dev workflow).
    /// 3. `.build/debug/senkani-mcp` under cwd (test workflow).
    /// 4. `which senkani-mcp` (system PATH).
    static func discoverMCPBinary(
        argv0: String = ProcessInfo.processInfo.arguments.first ?? "",
        cwd: String = FileManager.default.currentDirectoryPath,
        fileManager: FileManager = .default
    ) -> String? {
        let selfDir = (argv0 as NSString).deletingLastPathComponent
        let candidates = [
            (selfDir as NSString).appendingPathComponent("senkani-mcp"),
            (cwd as NSString).appendingPathComponent(".build/release/senkani-mcp"),
            (cwd as NSString).appendingPathComponent(".build/debug/senkani-mcp"),
        ]
        for c in candidates where fileManager.isExecutableFile(atPath: c) {
            return c
        }
        // Fall back to PATH lookup via /usr/bin/which.
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = ["senkani-mcp"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let raw = String(
            data: pipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        )?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let path = raw, !path.isEmpty,
              fileManager.isExecutableFile(atPath: path) else { return nil }
        return path
    }
}
