import Foundation

/// Runs validator subprocesses for auto-validate.
/// Reuses the Process+Pipe+timeout pattern from ExecTool.
/// Runs at utility QoS to avoid starving user processes.
public enum AutoValidateWorker {
    public enum Outcome: String, Sendable {
        case advisory
        case clean
        case dropped
    }

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

    /// Full attempt record, including clean and infrastructure outcomes that
    /// do not produce an advisory but still matter for observability.
    public struct ValidationAttempt: Sendable {
        public let path: String
        public let validatorName: String
        public let category: String
        public let exitCode: Int32
        public let rawOutput: String
        public let advisory: String
        public let durationMs: Int
        public let outcome: Outcome
        public let reason: String?
    }

    private final class TimeoutFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false

        func set() {
            lock.lock()
            value = true
            lock.unlock()
        }

        func get() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    private struct ProcessResult {
        let output: String
        let code: Int32
        let timedOut: Bool
        let spawnFailed: Bool
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
        validateAttempts(
            path: path,
            projectRoot: projectRoot,
            categories: categories,
            timeoutMs: timeoutMs,
            registry: registry
        )
        .filter { $0.outcome == .advisory }
        .map {
            ValidationResult(
                path: $0.path,
                validatorName: $0.validatorName,
                category: $0.category,
                exitCode: $0.exitCode,
                rawOutput: $0.rawOutput,
                advisory: $0.advisory,
                durationMs: $0.durationMs
            )
        }
    }

    /// Run validators and return one attempt per selected validator, including
    /// clean and dropped outcomes. This is the observability path used by the
    /// auto-validation queue.
    public static func validateAttempts(
        path: String,
        projectRoot: String,
        categories: [String],
        timeoutMs: Int,
        registry: ValidatorRegistry
    ) -> [ValidationAttempt] {
        let ext = (path as NSString).pathExtension
        guard !ext.isEmpty else { return [] }

        let allValidators = registry.validatorsFor(extension: ext)
        let filtered = allValidators.filter { categories.contains($0.category) }
        guard !filtered.isEmpty else { return [] }

        var attempts: [ValidationAttempt] = []

        for v in filtered {
            let start = Date()
            let processResult = runValidator(v, filePath: path, projectRoot: projectRoot, timeoutMs: timeoutMs)
            let elapsed = Int(Date().timeIntervalSince(start) * 1000)
            let output = processResult.output
            let code = processResult.code

            let cappedOutput = String(output.prefix(65536))
            if processResult.spawnFailed {
                attempts.append(ValidationAttempt(
                    path: path,
                    validatorName: v.name,
                    category: v.category,
                    exitCode: code,
                    rawOutput: cappedOutput,
                    advisory: output,
                    durationMs: elapsed,
                    outcome: .dropped,
                    reason: "spawn_failed"
                ))
                continue
            }

            if processResult.timedOut {
                attempts.append(ValidationAttempt(
                    path: path,
                    validatorName: v.name,
                    category: v.category,
                    exitCode: code,
                    rawOutput: cappedOutput,
                    advisory: output,
                    durationMs: elapsed,
                    outcome: .dropped,
                    reason: "timeout"
                ))
                continue
            }

            if code == 0 && output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                attempts.append(ValidationAttempt(
                    path: path,
                    validatorName: v.name,
                    category: v.category,
                    exitCode: code,
                    rawOutput: "",
                    advisory: "",
                    durationMs: elapsed,
                    outcome: .clean,
                    reason: nil
                ))
                continue
            }

            let advisory = DiagnosticRewriter.rewrite(
                rawOutput: output,
                validatorName: v.name,
                filePath: path
            )

            if advisory.isEmpty {
                attempts.append(ValidationAttempt(
                    path: path,
                    validatorName: v.name,
                    category: v.category,
                    exitCode: code,
                    rawOutput: cappedOutput,
                    advisory: "",
                    durationMs: elapsed,
                    outcome: .dropped,
                    reason: "empty_rewrite"
                ))
                continue
            }

            attempts.append(ValidationAttempt(
                path: path,
                validatorName: v.name,
                category: v.category,
                exitCode: code,
                rawOutput: cappedOutput,
                advisory: advisory,
                durationMs: elapsed,
                outcome: .advisory,
                reason: nil
            ))
        }

        return attempts
    }

    // MARK: - Subprocess Execution

    /// Run a single validator subprocess with timeout.
    /// Returns (stdout+stderr, exitCode). Never throws — errors return exitCode -1.
    private static func runValidator(
        _ validator: ValidatorDef,
        filePath: String,
        projectRoot: String,
        timeoutMs: Int
    ) -> ProcessResult {
        guard let executable = resolveExecutable(validator.command, projectRoot: projectRoot) else {
            return ProcessResult(
                output: "Failed to run \(validator.command): executable not found",
                code: -1,
                timedOut: false,
                spawnFailed: true
            )
        }

        let process = Process()
        let outPipe = Pipe()
        let errPipe = Pipe()
        let timedOut = TimeoutFlag()

        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = validator.args + [filePath]
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.currentDirectoryURL = URL(fileURLWithPath: projectRoot)
        process.qualityOfService = .utility

        // Timeout mechanism: SIGTERM → 2s → SIGKILL
        let timeoutWork = DispatchWorkItem { [weak process] in
            guard let p = process, p.isRunning else { return }
            timedOut.set()
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
            return ProcessResult(
                output: "Failed to run \(validator.command): \(error.localizedDescription)",
                code: -1,
                timedOut: false,
                spawnFailed: true
            )
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

        return ProcessResult(
            output: combined,
            code: process.terminationStatus,
            timedOut: timedOut.get(),
            spawnFailed: false
        )
    }

    private static func resolveExecutable(_ command: String, projectRoot: String) -> String? {
        let fm = FileManager.default

        if command.hasPrefix("/") {
            return fm.isExecutableFile(atPath: command) ? command : nil
        }

        if command.contains("/") {
            let candidate = projectRoot + "/" + command
            if fm.isExecutableFile(atPath: candidate) { return candidate }
            return fm.isExecutableFile(atPath: command) ? command : nil
        }

        let path = ProcessInfo.processInfo.environment["PATH"]
            ?? "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        for dir in path.split(separator: ":").map(String.init) {
            let candidate = dir + "/" + command
            if fm.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }
}
