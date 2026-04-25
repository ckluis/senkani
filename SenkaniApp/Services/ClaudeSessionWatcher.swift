import Foundation
import Core

/// Watches Claude Code's session JSONL files for exact token usage.
/// Parses assistant messages with usage.input_tokens / output_tokens.
/// Writes to token_events DB table — MetricsRefresher picks it up on its next poll.
///
/// Watches the DIRECTORY for new .jsonl files (one per conversation) and tails
/// the active file for new lines. Handles conversation rotation automatically.
///
/// Source: ~/.claude/projects/<encoded-cwd>/*.jsonl
class ClaudeSessionWatcher {
    private let projectRoot: String
    private let paneId: UUID

    // Directory watching — detects new conversation files
    private var dirSource: DispatchSourceFileSystemObject?
    private var dirFD: Int32 = -1

    // Current file tailing — reads new JSONL lines
    private var fileSource: DispatchSourceFileSystemObject?
    private var fileFD: Int32 = -1
    private var fileHandle: FileHandle?
    private var lastReadOffset: UInt64 = 0
    private var watchedFile: String?

    // Track files we've already started reading to avoid double-counting
    private var processedFiles: Set<String> = []

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

        // Ensure the directory exists (Claude Code may not have created it yet)
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        // Start directory watcher — fires when new .jsonl files appear
        startDirectoryWatcher(dir: dir)

        // Check for existing session files immediately
        checkForNewSession()
    }

    // MARK: - Directory Watching

    private func startDirectoryWatcher(dir: String) {
        dirFD = open(dir, O_RDONLY | O_EVTONLY)
        guard dirFD >= 0 else {
            Logger.log("claude_session_watcher.dir_open_failed", fields: ["dir": .path(dir)])
            return
        }

        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: dirFD,
            eventMask: [.write],
            queue: .global(qos: .utility)
        )
        src.setEventHandler { [weak self] in
            self?.checkForNewSession()
        }
        src.setCancelHandler { [weak self] in
            guard let self, self.dirFD >= 0 else { return }
            close(self.dirFD)
            self.dirFD = -1
        }
        src.resume()
        dirSource = src
    }

    private func checkForNewSession() {
        let dir = Self.claudeProjectDir(for: projectRoot)
        guard let latest = findLatestSession(in: dir) else { return }

        // Same file we're already watching — no switch needed
        if latest == watchedFile { return }

        // Finish reading remaining lines from old file before switching
        if watchedFile != nil {
            readNewMessages()
        }

        // If we've seen this file before, seek to end to avoid double-counting.
        // If it's brand new, read from the beginning — every line is unprocessed.
        let seekToEnd = processedFiles.contains(latest)
        startWatchingFile(latest, seekToEnd: seekToEnd)
        processedFiles.insert(latest)
    }

    // MARK: - File Tailing

    private func startWatchingFile(_ path: String, seekToEnd: Bool) {
        // Clean up old file watcher
        fileSource?.cancel()
        fileSource = nil
        fileHandle?.closeFile()
        fileHandle = nil
        if fileFD >= 0 { close(fileFD); fileFD = -1 }

        watchedFile = path

        guard let fh = FileHandle(forReadingAtPath: path) else {
            Logger.log("claude_session_watcher.open_failed", fields: ["path": .path(path)])
            return
        }
        if seekToEnd {
            fh.seekToEndOfFile()
        }
        lastReadOffset = fh.offsetInFile
        fileHandle = fh

        fileFD = open(path, O_RDONLY | O_EVTONLY)
        guard fileFD >= 0 else { return }

        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileFD,
            eventMask: [.write, .extend],
            queue: .global(qos: .utility)
        )
        src.setEventHandler { [weak self] in
            self?.readNewMessages()
        }
        src.setCancelHandler { [weak self] in
            guard let self, self.fileFD >= 0 else { return }
            close(self.fileFD)
            self.fileFD = -1
        }
        src.resume()
        fileSource = src

        // Read any existing content (for new files, this reads from the beginning)
        readNewMessages()
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
            let model = message["model"] as? String

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
        let pricing = ModelPricing.find(model ?? "sonnet")
        let dollars = Double(input) / 1_000_000.0 * pricing.inputPerMillion
                    + Double(output) / 1_000_000.0 * pricing.outputPerMillion
        return Int(dollars * 100.0)
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
        dirSource?.cancel()
        dirSource = nil
        fileSource?.cancel()
        fileSource = nil
        fileHandle?.closeFile()
        fileHandle = nil
    }

    deinit {
        stop()
    }
}
