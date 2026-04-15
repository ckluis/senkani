import Foundation

/// Runs validator subprocesses for auto-validate.
/// Reuses the Process+Pipe+timeout pattern from ExecTool.
/// Niced to avoid starving user processes.
public enum AutoValidateWorker {

    /// Result of a single validator run.
    public struct ValidationResult: Sendable {
        public let path: String
        public let validatorName: String
        public let category: String
        public let exitCode: Int32
        public let rawOutput: String
        public let advisory: String
        public let durationMs: Int
    }

    /// Run validators for a file path. Returns results for each validator that produced output.
    /// Only runs validators matching the file extension AND the specified categories.
    public static func validate(
        path: String,
        projectRoot: String,
        categories: [String],
        timeoutMs: Int,
        registry: ValidatorRegistry
    ) -> [ValidationResult] {
        let ext = (path as NSString).pathExtension
        guard !ext.isEmpty else { return [] }

        let allValidators = registry.validatorsFor(extension: ext)
        let filtered = allValidators.filter { categories.contains($0.category) }
        guard !filtered.isEmpty else { return [] }

        var results: [ValidationResult] = []

        for v in filtered {
            let start = Date()
            let (output, code) = runValidator(v, filePath: path, projectRoot: projectRoot, timeoutMs: timeoutMs)
            let elapsed = Int(Date().timeIntervalSince(start) * 1000)

            // Skip successful runs with no output (nothing to report)
            if code == 0 && output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                continue
            }

            let advisory = DiagnosticRewriter.rewrite(
                rawOutput: output,
                validatorName: v.name,
                filePath: path
            )

            // Skip if rewriter produced nothing useful
            guard !advisory.isEmpty else { continue }

            results.append(ValidationResult(
                path: path,
                validatorName: v.name,
                category: v.category,
                exitCode: code,
                rawOutput: String(output.prefix(65536)),  // cap at 64KB
                advisory: advisory,
                durationMs: elapsed
            ))
        }

        return results
    }

    // MARK: - Subprocess Execution

    /// Run a single validator subprocess with timeout and nice.
    /// Returns (stdout+stderr, exitCode). Never throws — errors return exitCode -1.
    private static func runValidator(
        _ validator: ValidatorDef,
        filePath: String,
        projectRoot: String,
        timeoutMs: Int
    ) -> (String, Int32) {
        let process = Process()
        let outPipe = Pipe()
        let errPipe = Pipe()

        // Nice the process to avoid starving user work
        process.executableURL = URL(fileURLWithPath: "/usr/bin/nice")
        process.arguments = ["-n", "10", validator.command] + validator.args + [filePath]
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.currentDirectoryURL = URL(fileURLWithPath: projectRoot)
        process.qualityOfService = .utility

        // Timeout mechanism: SIGTERM → 2s → SIGKILL
        let timeoutWork = DispatchWorkItem { [weak process] in
            guard let p = process, p.isRunning else { return }
            p.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [weak process] in
                guard let p = process, p.isRunning else { return }
                kill(p.processIdentifier, SIGKILL)
            }
        }

        do {
            try process.run()
        } catch {
            timeoutWork.cancel()
            return ("Failed to run \(validator.command): \(error.localizedDescription)", -1)
        }

        let timeoutSec = Double(timeoutMs) / 1000.0
        DispatchQueue.global().asyncAfter(deadline: .now() + timeoutSec, execute: timeoutWork)

        // Read output BEFORE waitUntilExit to avoid pipe deadlock
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timeoutWork.cancel()

        let stdout = String(data: outData, encoding: .utf8) ?? ""
        let stderr = String(data: errData, encoding: .utf8) ?? ""
        let combined = (stdout + "\n" + stderr).trimmingCharacters(in: .whitespacesAndNewlines)

        return (combined, process.terminationStatus)
    }
}
