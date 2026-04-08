import Foundation
import Core

/// Watches Claude Code's session JSONL files for exact token usage.
/// Parses assistant messages with usage.input_tokens / output_tokens.
/// Writes to token_events DB table — MetricsRefresher picks it up on its next poll.
///
/// Source: ~/.claude/projects/<encoded-cwd>/*.jsonl
class ClaudeSessionWatcher {
    private let projectRoot: String
    private let paneId: UUID
    private var source: DispatchSourceFileSystemObject?
    private var fileHandle: FileHandle?
    private var lastReadOffset: UInt64 = 0
    private var watchedFile: String?
    private var retryTimer: Timer?

    /// Compute the Claude Code session directory for a project path.
    /// Claude encodes paths by replacing / with -, keeping the leading dash.
    /// /Users/clank/Desktop/projects/senkani → -Users-clank-Desktop-projects-senkani
    static func claudeProjectDir(for projectRoot: String) -> String {
        let encoded = projectRoot.replacingOccurrences(of: "/", with: "-")
        return NSHomeDirectory() + "/.claude/projects/" + encoded
    }

    init(projectRoot: String, paneId: UUID) {
        // Normalize for consistent DB storage
        self.projectRoot = URL(fileURLWithPath: projectRoot).standardized.path
        self.paneId = paneId
    }

    func start() {
        let dir = Self.claudeProjectDir(for: projectRoot)
        print("🔵 [CLAUDE-WATCHER] Encoded dir: \(dir)")
        print("🔵 [CLAUDE-WATCHER] Dir exists: \(FileManager.default.fileExists(atPath: dir))")

        // Try immediately, then retry every 5 seconds until a session file appears.
        // Claude Code creates its session file when the first conversation starts,
        // which may be after the watcher is initialized.
        if let sessionFile = findLatestSession(in: dir) {
            startWatching(file: sessionFile)
        } else {
            print("🔵 [CLAUDE-WATCHER] No session yet in \(dir), will retry every 5s...")
            retryTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] timer in
                guard let self else { timer.invalidate(); return }
                let dir = Self.claudeProjectDir(for: self.projectRoot)
                if let sessionFile = self.findLatestSession(in: dir) {
                    print("🔵 [CLAUDE-WATCHER] Found session: \(sessionFile)")
                    timer.invalidate()
                    self.retryTimer = nil
                    self.startWatching(file: sessionFile)
                } else {
                    print("🔵 [CLAUDE-WATCHER] No session yet in \(dir), retrying...")
                }
            }
        }
    }

    private func startWatching(file sessionFile: String) {
        print("🔵 [CLAUDE-WATCHER] Watching: \(sessionFile)")
        watchedFile = sessionFile

        guard let fh = FileHandle(forReadingAtPath: sessionFile) else {
            print("🔵 [CLAUDE-WATCHER] Cannot open: \(sessionFile)")
            return
        }
        fh.seekToEndOfFile()
        lastReadOffset = fh.offsetInFile
        fileHandle = fh

        let fd = open(sessionFile, O_RDONLY)
        guard fd >= 0 else { return }

        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend],
            queue: .global(qos: .utility)
        )

        src.setEventHandler { [weak self] in
            self?.readNewMessages()
        }

        src.setCancelHandler { close(fd) }
        src.resume()
        source = src
    }

    private func readNewMessages() {
        guard let fh = fileHandle else { return }

        fh.seek(toFileOffset: lastReadOffset)
        let newData = fh.readDataToEndOfFile()
        let newOffset = fh.offsetInFile
        guard newOffset > lastReadOffset, !newData.isEmpty,
              let text = String(data: newData, encoding: .utf8) else { return }
        lastReadOffset = newOffset

        let lines = text.components(separatedBy: "\n").filter { !$0.isEmpty }

        for line in lines {
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }

            // Only process assistant messages with usage data
            guard json["type"] as? String == "assistant",
                  let message = json["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any] else { continue }

            let inputTokens = usage["input_tokens"] as? Int ?? 0
            let outputTokens = usage["output_tokens"] as? Int ?? 0
            let cacheRead = usage["cache_read_input_tokens"] as? Int ?? 0
            let model = message["model"] as? String

            print("💾 [CLAUDE-WATCHER] Writing token event: project=\(projectRoot) pane=\(paneId) in=\(inputTokens) out=\(outputTokens) cache=\(cacheRead) model=\(model ?? "?")")

            SessionDatabase.shared.recordTokenEvent(
                sessionId: json["sessionId"] as? String ?? "unknown",
                paneId: paneId.uuidString,
                projectRoot: projectRoot,
                source: "claude_session",
                toolName: nil,
                model: model,
                inputTokens: inputTokens,
                outputTokens: outputTokens,
                savedTokens: 0,
                costCents: Self.estimateCost(input: inputTokens, output: outputTokens, model: model),
                feature: nil,
                command: nil
            )
        }
    }

    private static func estimateCost(input: Int, output: Int, model: String?) -> Int {
        let inputRate: Double
        let outputRate: Double
        switch model {
        case let m where m?.contains("opus") == true:
            inputRate = 15.0; outputRate = 75.0
        case let m where m?.contains("sonnet") == true:
            inputRate = 3.0; outputRate = 15.0
        case let m where m?.contains("haiku") == true:
            inputRate = 0.25; outputRate = 1.25
        default:
            inputRate = 3.0; outputRate = 15.0
        }
        let cents = (Double(input) / 1_000_000.0 * inputRate + Double(output) / 1_000_000.0 * outputRate) * 100.0
        return Int(cents)
    }

    private func findLatestSession(in dir: String) -> String? {
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return nil }
        let jsonlFiles = files.filter { $0.hasSuffix(".jsonl") && !$0.contains("index") }

        return jsonlFiles
            .map { dir + "/" + $0 }
            .sorted { path1, path2 in
                let t1 = (try? FileManager.default.attributesOfItem(atPath: path1)[.modificationDate] as? Date) ?? .distantPast
                let t2 = (try? FileManager.default.attributesOfItem(atPath: path2)[.modificationDate] as? Date) ?? .distantPast
                return t1 > t2
            }
            .first
    }

    func stop() {
        retryTimer?.invalidate()
        retryTimer = nil
        source?.cancel()
        source = nil
        fileHandle?.closeFile()
        fileHandle = nil
    }

    deinit {
        stop()
    }
}
