import Foundation
import Combine
import Core

/// Owns per-tag pull state + the `ollama pull` subprocess(es).
///
/// Round `ollama-model-curation` (umbrella sub-item c). One controller
/// per Ollama pane (mirrors `@StateObject` hookup inside
/// `OllamaLauncherPane`). Concurrent pulls are allowed (ollama tolerates
/// them) but the drawer UI currently exposes one button per row — the
/// common case is one active pull at a time.
///
/// Testability: the Process-spawn path is deliberately NOT unit-tested
/// (would require a real `ollama` binary on the CI runner). The parser
/// + state machine driving this controller IS unit-tested — see
/// `OllamaModelCatalogTests`.
@MainActor
final class OllamaModelDownloadController: ObservableObject {

    @Published private var states: [String: OllamaPullState] = [:]
    private var activePulls: [String: Process] = [:]
    private var parsers: [String: OllamaPullOutputParser] = [:]

    /// Absolute path to the `ollama` binary, resolved on first use.
    /// Nil means ollama isn't on PATH — all pulls will short-circuit
    /// to `.failed("ollama binary not found")`.
    private var resolvedBinaryPath: String?

    init() {}

    // MARK: - Reads

    func state(for tag: String) -> OllamaPullState {
        states[tag] ?? .notPulled
    }

    // MARK: - Installed refresh

    /// Run `ollama list`, parse output, and seed installed state for any
    /// curated tag that shows up. Non-curated tags are ignored (FUTURE:
    /// custom-tag surface).
    func refreshInstalled() async {
        guard let binary = await resolveBinary() else { return }
        let output = await Self.runToCompletion(binary: binary,
                                                arguments: OllamaPullCommand.arguments())
        guard let stdout = output.stdout else { return }
        let entries = OllamaInstalledListParser.parse(stdout)
        let byTag = Dictionary(uniqueKeysWithValues: entries.map { ($0.tag, $0.digest) })
        for model in OllamaModelCatalog.curated {
            if let digest = byTag[model.tag] {
                if case .pulling = states[model.tag] { continue }
                states[model.tag] = .pulled(digest: digest)
            }
        }
    }

    // MARK: - Pull / cancel

    func startPull(tag: String) async {
        guard OllamaLauncherSupport.isValidModelTag(tag) else {
            states[tag] = .failed("Invalid model tag")
            return
        }
        if case .pulling = states[tag] { return }
        guard let binary = await resolveBinary() else {
            states[tag] = .failed("ollama binary not found on PATH")
            return
        }
        guard let args = OllamaPullCommand.arguments(forPullingTag: tag) else {
            states[tag] = .failed("Invalid model tag")
            return
        }

        states[tag] = .pulling(progress: 0)
        parsers[tag] = OllamaPullOutputParser()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = args
        // Ensure ollama sees HOME for cache resolution.
        process.environment = ProcessInfo.processInfo.environment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        activePulls[tag] = process

        let lineChannel = LineBuffer()

        let handler: @Sendable (FileHandle) -> Void = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let chunk = String(data: data, encoding: .utf8) ?? ""
            let lines = lineChannel.append(chunk)
            guard !lines.isEmpty else { return }
            Task { @MainActor [weak self] in
                self?.ingestLines(tag: tag, lines: lines)
            }
        }

        stdoutPipe.fileHandleForReading.readabilityHandler = handler
        stderrPipe.fileHandleForReading.readabilityHandler = handler

        do {
            try process.run()
        } catch {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            activePulls[tag] = nil
            states[tag] = .failed("Failed to start: \(error.localizedDescription)")
            return
        }

        // Wait off-main for exit, then reconcile state on main.
        Task.detached { [weak self] in
            process.waitUntilExit()
            // Flush any trailing bytes the readability handler missed.
            let trailingStdout = try? stdoutPipe.fileHandleForReading.readToEnd()
            let trailingStderr = try? stderrPipe.fileHandleForReading.readToEnd()
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            let stderrText = trailingStderr.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let stdoutText = trailingStdout.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let exitCode = process.terminationStatus
            await self?.finalizePull(tag: tag,
                                     exitCode: exitCode,
                                     trailingStdout: stdoutText,
                                     trailingStderr: stderrText)
        }
    }

    /// Called by the readability handler's @MainActor hop. Feeds lines
    /// into the per-tag parser and republishes the aggregated state.
    private func ingestLines(tag: String, lines: [String]) {
        guard activePulls[tag] != nil else { return }
        var parser = parsers[tag] ?? OllamaPullOutputParser()
        for line in lines {
            _ = parser.feed(line)
        }
        parsers[tag] = parser
        states[tag] = parser.state
    }

    private func finalizePull(tag: String,
                              exitCode: Int32,
                              trailingStdout: String,
                              trailingStderr: String) async {
        // If the cancel path already cleared the record, respect that.
        guard activePulls.removeValue(forKey: tag) != nil else { return }

        // Drain trailing bytes into the same parser so a late "success"
        // frame or error line surfaces in the final state.
        var parser = parsers.removeValue(forKey: tag) ?? OllamaPullOutputParser()
        for line in (trailingStdout + trailingStderr)
            .split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            _ = parser.feed(String(line))
        }

        if exitCode == 0 {
            // Success. If the parser picked up a digest, keep it; else
            // fall back to a targeted `ollama list` parse for this tag.
            var digest = parser.layerDigest
            if digest == nil, let binary = await resolveBinary() {
                let listOut = await Self.runToCompletion(
                    binary: binary,
                    arguments: OllamaPullCommand.arguments())
                if let stdout = listOut.stdout {
                    digest = OllamaInstalledListParser.parse(stdout)
                        .first { $0.tag == tag }?
                        .digest
                }
            }
            states[tag] = .pulled(digest: digest)
        } else {
            // Truncate long error lines for the UI.
            let message = parser.errorMessage
                ?? trailingStderr
                    .split(whereSeparator: { $0 == "\n" || $0 == "\r" })
                    .last
                    .map { String($0).trimmingCharacters(in: .whitespaces) }
                ?? "ollama pull exited \(exitCode)"
            states[tag] = .failed(message.isEmpty
                                  ? "ollama pull exited \(exitCode)"
                                  : String(message.prefix(120)))
        }
    }

    func cancelPull(tag: String) {
        guard let process = activePulls.removeValue(forKey: tag) else { return }
        parsers.removeValue(forKey: tag)
        if process.isRunning {
            process.terminate()
        }
        states[tag] = .notPulled
    }

    // MARK: - Binary resolution

    private func resolveBinary() async -> String? {
        if let resolvedBinaryPath { return resolvedBinaryPath }
        let candidate = await Self.resolveOllamaBinary()
        resolvedBinaryPath = candidate
        return candidate
    }

    private static func resolveOllamaBinary() async -> String? {
        let env = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let searchDirs = env.split(separator: ":").map(String.init) + [
            "/usr/local/bin",
            "/opt/homebrew/bin",
            "/Applications/Ollama.app/Contents/Resources",
        ]
        let fm = FileManager.default
        for dir in searchDirs {
            let candidate = (dir as NSString)
                .appendingPathComponent(OllamaPullCommand.binaryName)
            if fm.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    private struct ProcessOutput {
        let stdout: String?
        let exitCode: Int32
    }

    private static func runToCompletion(binary: String,
                                        arguments: [String]) async -> ProcessOutput {
        await Task.detached {
            let process = Process()
            let stdoutPipe = Pipe()
            process.executableURL = URL(fileURLWithPath: binary)
            process.arguments = arguments
            process.standardOutput = stdoutPipe
            process.standardError = Pipe()
            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                return ProcessOutput(stdout: nil, exitCode: -1)
            }
            let data = (try? stdoutPipe.fileHandleForReading.readToEnd()) ?? Data()
            let text = String(data: data, encoding: .utf8)
            return ProcessOutput(stdout: text, exitCode: process.terminationStatus)
        }.value
    }
}

/// Thread-safe line buffer — ollama emits progress via \r which needs
/// line-splitting at both \n AND \r so the parser sees complete frames.
private final class LineBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var residual: String = ""

    func append(_ chunk: String) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        residual += chunk
        var lines: [String] = []
        while let idx = residual.firstIndex(where: { $0 == "\n" || $0 == "\r" }) {
            let line = String(residual[..<idx])
            if !line.isEmpty {
                lines.append(line)
            }
            residual.removeSubrange(residual.startIndex...idx)
        }
        return lines
    }
}
