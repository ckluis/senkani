import Foundation
import MCP
import Core
import Filter

enum ExecTool {
    static func handle(arguments: [String: Value]?, session: MCPSession) -> CallTool.Result {
        guard let command = arguments?["command"]?.stringValue else {
            return .init(content: [.text(text: "Error: 'command' is required", annotations: nil, _meta: nil)], isError: true)
        }

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
                print("⚠️ [EXEC] Command timeout after 30s, sending SIGTERM: \(command)")
                process.terminate() // SIGTERM
                // If still running after 5 more seconds, SIGKILL
                DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
                    if process.isRunning {
                        print("💀 [EXEC] SIGKILL: \(command)")
                        kill(process.processIdentifier, SIGKILL)
                    }
                }
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 30, execute: timeoutWork)

        // Read BEFORE waitUntilExit to avoid pipe buffer deadlock on large output
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timeoutWork.cancel() // Cancel timeout if process finished naturally
        let rawOutput = String(data: outData, encoding: .utf8) ?? ""
        let rawStderr = String(data: errData, encoding: .utf8) ?? ""

        let rawBytes = rawOutput.utf8.count
        var output: String

        if session.filterEnabled || session.secretsEnabled {
            let config = FeatureConfig(filter: session.filterEnabled, secrets: session.secretsEnabled, indexer: false)
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

        var text = "// senkani exec: \(rawBytes) → \(compressedBytes) bytes (\(savedPct)% saved), exit \(exitCode)\n"
        text += output
        if !rawStderr.isEmpty {
            text += "\n--- stderr ---\n" + rawStderr
        }

        return .init(content: [.text(text: text, annotations: nil, _meta: nil)], isError: exitCode != 0)
    }
}
