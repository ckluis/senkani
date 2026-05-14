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
///
/// Concurrency contract: all mutable state below is owned by `stateQueue`
/// (a private serial dispatch queue). Reads and writes — including from
/// dispatch-source event and cancel handlers — must run on
/// `stateQueue.async`. Dispatch sources still publish events on
/// `.global(qos: .utility)` (no back-pressure on filesystem events), but
/// their handlers hop to `stateQueue` before touching state. Each source's
/// cancel handler captures its file descriptor as a LOCAL — never reads
/// `self.fileFD` / `self.dirFD` — so cancelling a stale source closes the
/// correct fd even if `startWatchingFile` has already reassigned the
/// property to a newer fd. Rationale: the original design read
/// `self.fileFD` inside the cancel handler closure, which crashed the app
/// (`EXC_BREAKPOINT` at `makeFileSystemObjectSource`) when a stale cancel
/// handler raced with a fresh `open()`+`makeFileSystemObjectSource()` and
/// closed the just-opened fd before the source could bind to it.
final class ClaudeSessionWatcher: @unchecked Sendable {
    private let projectRoot: String
    private let paneId: UUID

    // Serial queue owns ALL mutable state below.
    private let stateQueue = DispatchQueue(label: "dev.senkani.claude-session-watcher")

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
    // within a single process lifetime. Note: this set is in-memory only,
    // so app restart re-emits historical lines — tracked separately as
    // `claude-session-watcher-restart-double-count-2026-05-14`.
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
        stateQueue.async { [weak self] in
            guard let self else { return }
            let dir = Self.claudeProjectDir(for: self.projectRoot)
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            self.startDirectoryWatcher(dir: dir)
            self.checkForNewSession()
        }
    }

    // MARK: - Directory Watching
    // Caller MUST be on stateQueue.

    private func startDirectoryWatcher(dir: String) {
        let fd = open(dir, O_RDONLY | O_EVTONLY)
        guard fd >= 0 else {
            Logger.log("claude_session_watcher.dir_open_failed", fields: ["dir": .path(dir)])
            return
        }

        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write],
            queue: .global(qos: .utility)
        )
        src.setEventHandler { [weak self] in
            self?.stateQueue.async { [weak self] in self?.checkForNewSession() }
        }
        // Cancel handler captures `fd` LOCALLY — does not read self.dirFD.
        // This is the load-bearing detail; see class-level contract.
        src.setCancelHandler { close(fd) }
        src.resume()

        dirFD = fd
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
    // Caller MUST be on stateQueue.

    private func startWatchingFile(_ path: String, seekToEnd: Bool) {
        let prior = watchedFile

        // Tear down the old file watcher. Source-cancellation is async; the
        // cancel handler closes the OLD fd via its locally-captured `fd`,
        // so we do NOT call close(fileFD) here — that would double-close
        // once the cancel handler runs.
        fileSource?.cancel()
        fileSource = nil
        fileHandle?.closeFile()
        fileHandle = nil
        fileFD = -1

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

        let fd = open(path, O_RDONLY | O_EVTONLY)
        guard fd >= 0 else { return }

        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend],
            queue: .global(qos: .utility)
        )
        src.setEventHandler { [weak self] in
            self?.stateQueue.async { [weak self] in self?.readNewMessages() }
        }
        // Captures `fd` locally — see class-level contract.
        src.setCancelHandler { close(fd) }
        src.resume()

        fileFD = fd
        fileSource = src

        if let prior {
            Logger.log("claude_session_watcher.rotated",
                       fields: ["from": .path(prior), "to": .path(path)])
        } else {
            Logger.log("claude_session_watcher.attached",
                       fields: ["path": .path(path)])
        }

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

        for line in text.components(separatedBy: "\n") {
            // Delegate JSONL parsing to the canonical helper in Core so the
            // realtime tail path and the cursor-driven `readNew` path can't
            // drift in how they extract `cache_read_input_tokens` (the bug
            // surfaced 2026-05-12: this watcher previously had its own
            // copy of the parser and hardcoded `savedTokens: 0`, suppressing
            // the `firstNonzeroSavings` onboarding milestone).
            guard let parsed = ClaudeSessionReader.parseAssistantUsageLine(line) else { continue }

            SessionDatabase.shared.recordTokenEvent(
                sessionId: parsed.sessionId ?? "unknown",
                paneId: paneId.uuidString,
                projectRoot: projectRoot,
                source: "claude_session",
                toolName: nil,
                model: parsed.model,
                inputTokens: parsed.inputTokens,
                outputTokens: parsed.outputTokens,
                savedTokens: parsed.cacheReadTokens,
                costCents: Self.estimateCost(input: parsed.inputTokens, output: parsed.outputTokens, model: parsed.model),
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
        stateQueue.async { [weak self] in
            guard let self else { return }
            self.dirSource?.cancel()
            self.dirSource = nil
            self.fileSource?.cancel()
            self.fileSource = nil
            self.fileHandle?.closeFile()
            self.fileHandle = nil
            self.fileFD = -1
            self.dirFD = -1
        }
    }

    deinit {
        // `stop()` is async and may not run before deallocation, so cancel
        // sources directly here. Each source's cancel handler captures its
        // fd as a local, so the fds close correctly without needing `self`
        // to still exist.
        dirSource?.cancel()
        fileSource?.cancel()
        fileHandle?.closeFile()
    }
}
