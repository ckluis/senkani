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
///
/// Burst-rotation contract: the file `setEventHandler` closure captures the
/// intended path as a LOCAL, and the `stateQueue.async` body guards on
/// `self.watchedFile == capturedPath` before reading. Without this guard,
/// pending events from a stale `fileSource` (cancelled but not yet
/// drained) re-run after a fresh `startWatchingFile` has already
/// reassigned `watchedFile`, causing the leftover events to read the NEW
/// active file from offset 0 — the 95% double-emit observed in the 200×10
/// burst harness (`claude-session-watcher-stress-harness-burst-rotation-
/// double-emit-and-partial-drop-2026-05-15`). The guard short-circuits
/// stale callbacks without losing data: the rotation path drains the prior
/// file via `ClaudeSessionWatcherPlan` before the watch flips. Combined
/// with the planner's intermediate-file drain (silent-drop fix), a burst
/// of 200 sessions × 10 events ingests exactly 2000 rows.
///
/// Restart contract: per-file read progress lives in
/// `claude_session_cursors` (keyed by absolute path). On every batch the
/// watcher delegates to `ClaudeSessionTail.tail`, which reads from the
/// persisted offset and writes the post-read offset back. Restarts pick
/// up exactly where the prior process stopped — historical lines are not
/// re-emitted (`claude-session-watcher-restart-double-count-2026-05-14`).
final class ClaudeSessionWatcher: @unchecked Sendable {
    private let projectRoot: String
    private let paneId: UUID
    private let database: SessionDatabase
    private let claudeProjectDirOverride: String?

    // Serial queue owns ALL mutable state below.
    private let stateQueue = DispatchQueue(label: "dev.senkani.claude-session-watcher")

    // Directory watching — detects new conversation files
    private var dirSource: DispatchSourceFileSystemObject?
    private var dirFD: Int32 = -1

    // Current file tailing — reads new JSONL lines
    private var fileSource: DispatchSourceFileSystemObject?
    private var fileFD: Int32 = -1
    private var watchedFile: String?

    // Files we've called `ClaudeSessionTail.tail` on at least once during
    // this process's lifetime. Used by `ClaudeSessionWatcherPlan` to skip
    // repeated drain attempts under burst (cursor table is the source of
    // truth on restart, so this in-memory set is safe to drop).
    private var drainedFiles: Set<String> = []

    /// Compute the Claude Code session directory for a project path.
    /// Claude encodes paths by replacing / with -, keeping the leading dash.
    /// /Users/clank/Desktop/projects/senkani → -Users-clank-Desktop-projects-senkani
    static func claudeProjectDir(for projectRoot: String) -> String {
        let encoded = projectRoot.replacingOccurrences(of: "/", with: "-")
        return NSHomeDirectory() + "/.claude/projects/" + encoded
    }

    init(projectRoot: String,
         paneId: UUID,
         database: SessionDatabase = .shared,
         claudeProjectDirOverride: String? = nil) {
        // Normalize for consistent DB storage
        self.projectRoot = URL(fileURLWithPath: projectRoot).standardized.path
        self.paneId = paneId
        self.database = database
        self.claudeProjectDirOverride = claudeProjectDirOverride
    }

    func start() {
        stateQueue.async { [weak self] in
            guard let self else { return }
            let dir = self.resolvedClaudeDir()
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            self.startDirectoryWatcher(dir: dir)
            self.checkForNewSession()
        }
    }

    private func resolvedClaudeDir() -> String {
        claudeProjectDirOverride ?? Self.claudeProjectDir(for: projectRoot)
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
        let dir = resolvedClaudeDir()
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return }

        let plan = ClaudeSessionWatcherPlan.plan(
            directoryFiles: entries,
            dirPath: dir,
            currentWatched: watchedFile,
            drainedFiles: drainedFiles,
            mtime: { path in
                (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? .distantPast
            }
        )

        // Drain every intermediate file the planner identified. Cursor-
        // idempotent so re-tailing a fully-read file is cheap. The
        // `drainedFiles` set prevents O(N²) re-iteration under burst.
        for path in plan.toDrain {
            _ = ClaudeSessionTail.tail(
                path: path,
                projectRoot: projectRoot,
                paneId: paneId.uuidString,
                db: database
            )
            drainedFiles.insert(path)
        }

        if let next = plan.newWatched {
            startWatchingFile(next)
        }
    }

    // MARK: - File Tailing
    // Caller MUST be on stateQueue.

    private func startWatchingFile(_ path: String) {
        let prior = watchedFile

        // Tear down the old file watcher. Source-cancellation is async; the
        // cancel handler closes the OLD fd via its locally-captured `fd`,
        // so we do NOT call close(fileFD) here — that would double-close
        // once the cancel handler runs.
        fileSource?.cancel()
        fileSource = nil
        fileFD = -1

        watchedFile = path

        let fd = open(path, O_RDONLY | O_EVTONLY)
        guard fd >= 0 else {
            Logger.log("claude_session_watcher.open_failed", fields: ["path": .path(path)])
            return
        }

        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend],
            queue: .global(qos: .utility)
        )
        // Capture the intended path locally. The stateQueue body guards on
        // `self.watchedFile == capturedPath` so leftover events from a
        // cancelled source can't read the post-rotation file from offset 0.
        // See class-level "Burst-rotation contract".
        let capturedPath = path
        src.setEventHandler { [weak self] in
            self?.stateQueue.async { [weak self] in
                guard let self, self.watchedFile == capturedPath else { return }
                self.readNewMessages()
            }
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

        // Initial drain — cursor decides whether this is suffix-only or first read.
        readNewMessages()
    }

    private func readNewMessages() {
        guard let path = watchedFile else { return }
        _ = ClaudeSessionTail.tail(
            path: path,
            projectRoot: projectRoot,
            paneId: paneId.uuidString,
            db: database
        )
    }

    func stop() {
        stateQueue.async { [weak self] in
            guard let self else { return }
            self.dirSource?.cancel()
            self.dirSource = nil
            self.fileSource?.cancel()
            self.fileSource = nil
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
    }
}
