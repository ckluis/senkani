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

    private static func generateJobId() -> String {
        "j_" + UUID().uuidString.prefix(8).lowercased()
    }

    static func handle(arguments: [String: Value]?, session: MCPSession) -> CallTool.Result {
        // --- Poll or kill an existing background job ---
        if let jobId = arguments?["job_id"]?.stringValue {
            guard let job = session.backgroundJob(id: jobId) else {
                return .init(content: [.text(text: "Error: unknown job_id '\(jobId)'", annotations: nil, _meta: nil)], isError: true)
            }
            if arguments?["kill"]?.boolValue == true {
                if job.isRunning {
                    job.process.terminate()
                    DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
                        if job.isRunning { kill(job.pid, SIGKILL) }
                    }
                    job.markKilled()
                }
                return .init(content: [.text(text: "{\"killed\": true, \"job_id\": \"\(jobId)\"}", annotations: nil, _meta: nil)])
            }
            // Status poll
            var output = job.output
            if session.filterEnabled || session.secretsEnabled {
                let config = FeatureConfig(filter: session.filterEnabled, secrets: session.secretsEnabled, indexer: false, terse: false)
                let pipeline = FilterPipeline(config: config)
                output = pipeline.process(command: job.command, output: output).output
            }
            let elapsed = Int(Date().timeIntervalSince(job.startTime))
            let exitStr = job.exitCode.map { String($0) } ?? "null"
            let status = "{\"job_id\": \"\(jobId)\", \"running\": \(job.isRunning), \"pid\": \(job.pid), \"exit_code\": \(exitStr), \"elapsed_seconds\": \(elapsed), \"killed\": \(job.killed)}"
            let text = status + "\n---\n" + output
            return .init(content: [.text(text: text, annotations: nil, _meta: nil)], isError: !job.isRunning && (job.exitCode ?? 0) != 0)
        }

        guard let command = arguments?["command"]?.stringValue else {
            return .init(content: [.text(text: "Error: 'command' is required", annotations: nil, _meta: nil)], isError: true)
        }

        let isBackground = arguments?["background"]?.boolValue == true

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
        // Sanitize inherited env: strip TOKEN/SECRET/API_KEY/cloud creds before
        // handing them to an arbitrary shell command. A hostile postinstall
        // script or prompt-injected command would otherwise read the parent
        // shell's secrets verbatim. See Core.SensitiveEnvironmentPolicy.
        process.environment = SensitiveEnvironmentPolicy.sanitize(ProcessInfo.processInfo.environment)
        process.currentDirectoryURL = URL(fileURLWithPath: session.projectRoot)

        do {
            try process.run()
        } catch {
            return .init(content: [.text(text: "Error: failed to execute command: \(error)", annotations: nil, _meta: nil)], isError: true)
        }

        // --- Background mode: return job_id immediately ---
        if isBackground {
            let jobId = generateJobId()
            let job = MCPSession.BackgroundJob(id: jobId, process: process, command: command)

            // Spawn output reader on background queue (blocking availableData, no busy-wait)
            DispatchQueue.global(qos: .utility).async {
                while true {
                    let chunk = outPipe.fileHandleForReading.availableData
                    if chunk.isEmpty { break }  // EOF
                    job.appendOutput(chunk)
                }
            }

            process.terminationHandler = { proc in
                job.setExitCode(proc.terminationStatus)
            }

            session.registerBackgroundJob(job)

            let result = "{\"job_id\": \"\(jobId)\", \"pid\": \(process.processIdentifier), \"command\": \"\(command)\"}"
            return .init(content: [.text(text: result, annotations: nil, _meta: nil)])
        }

        // Timeout: kill the process after 30 seconds to prevent MCP server stalls
        let timeoutWork = DispatchWorkItem {
            if process.isRunning {
                Logger.log("exec.timeout", fields: [
                    "signal": .string("SIGTERM"),
                    "outcome": .string("terminating"),
                ])
                process.terminate() // SIGTERM
                // If still running after 5 more seconds, SIGKILL
                DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
                    if process.isRunning {
                        Logger.log("exec.timeout", fields: [
                            "signal": .string("SIGKILL"),
                            "outcome": .string("killed"),
                        ])
                        kill(process.processIdentifier, SIGKILL)
                    }
                }
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 30, execute: timeoutWork)

        // Read BEFORE waitUntilExit to avoid pipe buffer deadlock on large output.
        // Adaptive truncation: cap scales with budget remaining.
        let budgetRemaining = session.budgetRemainingPercent()
        let maxBytes = AdaptiveTruncation.maxBytes(forBudgetRemaining: budgetRemaining)
        let (outData, outTruncated) = Self.readCapped(from: outPipe.fileHandleForReading, limit: maxBytes)
        let (errData, errTruncated) = Self.readCapped(from: errPipe.fileHandleForReading, limit: maxBytes)
        process.waitUntilExit()
        timeoutWork.cancel() // Cancel timeout if process finished naturally
        var rawOutput = String(data: outData, encoding: .utf8) ?? ""
        var rawStderr = String(data: errData, encoding: .utf8) ?? ""
        if outTruncated { rawOutput += "\n// [senkani: output truncated at \(maxBytes / 1024)KB]" }
        if errTruncated { rawStderr += "\n// [senkani: stderr truncated at \(maxBytes / 1024)KB]" }

        let rawBytes = rawOutput.utf8.count
        var output: String

        if session.filterEnabled || session.secretsEnabled || session.terseEnabled {
            let config = FeatureConfig(filter: session.filterEnabled, secrets: session.secretsEnabled, indexer: false, terse: session.terseEnabled, injectionGuard: session.injectionGuardEnabled)
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
            case .auto: return lineCount > AdaptiveTruncation.sandboxThreshold(forBudgetRemaining: budgetRemaining)
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
