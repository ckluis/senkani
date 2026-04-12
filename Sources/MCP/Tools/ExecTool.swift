import Foundation
import MCP
import Core
import Filter

enum ExecTool {

    // MARK: - Helpers

    /// Read up to `limit` bytes from a file handle. Returns the data and whether it was truncated.
    private static func readCapped(from handle: FileHandle, limit: Int) -> (Data, Bool) {
        var result = Data()
        while result.count < limit {
            let chunk = handle.availableData
            if chunk.isEmpty { break } // EOF
            result.append(chunk)
        }
        let truncated = result.count > limit
        if truncated { result = result.prefix(limit) }
        // Drain remaining data to avoid broken pipe
        if truncated {
            while true {
                let discard = handle.availableData
                if discard.isEmpty { break }
            }
        }
        return (result, truncated)
    }

    // MARK: - Handler

    static func handle(arguments: [String: Value]?, session: MCPSession) -> CallTool.Result {
        guard let command = arguments?["command"]?.stringValue else {
            return .init(content: [.text(text: "Error: 'command' is required", annotations: nil, _meta: nil)], isError: true)
        }

        let sandboxMode: Core.SandboxMode = {
            guard let raw = arguments?["sandbox"]?.stringValue else { return .auto }
            return Core.SandboxMode(rawValue: raw) ?? .auto
        }()

        // Run the command
        let process = Process()
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.environment = ProcessInfo.processInfo.environment
        process.currentDirectoryURL = URL(fileURLWithPath: session.projectRoot)

        do {
            try process.run()
        } catch {
            return .init(content: [.text(text: "Error: failed to execute command: \(error)", annotations: nil, _meta: nil)], isError: true)
        }

        // Timeout: kill the process after 30 seconds to prevent MCP server stalls
        let timeoutWork = DispatchWorkItem {
            if process.isRunning {
                print("[EXEC] Command timeout after 30s, sending SIGTERM: \(command)")
                process.terminate() // SIGTERM
                // If still running after 5 more seconds, SIGKILL
                DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
                    if process.isRunning {
                        print("[EXEC] SIGKILL: \(command)")
                        kill(process.processIdentifier, SIGKILL)
                    }
                }
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 30, execute: timeoutWork)

        // Read BEFORE waitUntilExit to avoid pipe buffer deadlock on large output.
        // Cap at 1MB to prevent OOM on commands that produce massive output.
        let maxBytes = 1_048_576 // 1MB
        let (outData, outTruncated) = Self.readCapped(from: outPipe.fileHandleForReading, limit: maxBytes)
        let (errData, errTruncated) = Self.readCapped(from: errPipe.fileHandleForReading, limit: maxBytes)
        process.waitUntilExit()
        timeoutWork.cancel() // Cancel timeout if process finished naturally
        var rawOutput = String(data: outData, encoding: .utf8) ?? ""
        var rawStderr = String(data: errData, encoding: .utf8) ?? ""
        if outTruncated { rawOutput += "\n// [senkani: output truncated at 1MB — full output was larger]" }
        if errTruncated { rawStderr += "\n// [senkani: stderr truncated at 1MB — full output was larger]" }

        let rawBytes = rawOutput.utf8.count
        var output: String

        if session.filterEnabled || session.secretsEnabled || session.terseEnabled {
            let config = FeatureConfig(filter: session.filterEnabled, secrets: session.secretsEnabled, indexer: false, terse: session.terseEnabled)
            let pipeline = FilterPipeline(config: config)
            let result = pipeline.process(command: command, output: rawOutput)
            output = result.output
        } else {
            output = rawOutput
        }

        let compressedBytes = output.utf8.count
        session.recordMetrics(rawBytes: rawBytes, compressedBytes: compressedBytes, feature: "exec",
                              command: command, outputPreview: String(output.prefix(200)))

        let exitCode = process.terminationStatus
        let savedPct = rawBytes > 0 ? Int(Double(rawBytes - compressedBytes) / Double(rawBytes) * 100) : 0

        // Sandbox decision
        let lineCount = output.components(separatedBy: "\n").count
        let shouldSandbox: Bool = {
            switch sandboxMode {
            case .always: return true
            case .never: return false
            case .auto: return lineCount > sandboxLineThreshold
            }
        }()

        var text = "// senkani exec: \(rawBytes) → \(compressedBytes) bytes (\(savedPct)% saved), exit \(exitCode)\n"

        if shouldSandbox, let sid = session.sessionId {
            let resultId = SessionDatabase.shared.storeSandboxedResult(
                sessionId: sid,
                command: command,
                output: output
            )
            text += Core.buildSandboxSummary(
                output: output,
                lineCount: lineCount,
                byteCount: compressedBytes,
                resultId: resultId
            )
        } else {
            text += output
        }

        if !rawStderr.isEmpty {
            text += "\n--- stderr ---\n" + rawStderr
        }

        return .init(content: [.text(text: text, annotations: nil, _meta: nil)], isError: exitCode != 0)
    }
}
