import Foundation
import CoreServices

/// V.3c — Pure-Core FSEvents watch on a pane's `<workingDirectory>/.git`
/// directory that fires a change handler when the branch-defining files
/// (`HEAD` and anything under `refs/heads/`) change. This is the branch-refresh
/// driver for `PaneMetadataRefreshCoordinator`.
///
/// ## Why not reuse `Indexer.FileWatcher`?
/// `Indexer.FileWatcher` is the proven headless FSEvents pattern in-repo, but
/// it filters events to language SOURCE files and hard-REJECTS anything under a
/// skip directory — and `.git` is a skip directory (`FileWalker.skipDirs`). So
/// it would never fire on `.git/HEAD`. This watcher REUSES FileWatcher's
/// lifetime-safe FSEvents lifecycle (the `passRetained` context + paired
/// release callback + `queue.sync` drain on stop, the fix for
/// `filewatcher-fsevents-flake-under-parallel-runner-2026-05-04`) but swaps the
/// source-file filter for a git-ref filter. It also keeps Core dependency-free:
/// Core cannot depend on the `Indexer` target, and FSEvents is a system
/// framework (`Core.KnowledgeFileLayer` already watches via FSEvents), so no
/// new package edge is introduced.
///
/// Silent by design: no logging above `info` — a metadata chip is best-effort,
/// so a watcher that fails to start just means "no live branch refresh for this
/// pane," never a crash or a noisy log (mirrors `PaneMetadataProbes`).
public final class GitHeadWatcher: @unchecked Sendable {
    /// Fired (on the watcher's serial queue) when `HEAD` or a `refs/heads/*`
    /// entry under the watched `.git` directory changes. Debounced.
    public typealias ChangeHandler = @Sendable () -> Void

    private let gitDir: String
    private let handler: ChangeHandler
    private let queue: DispatchQueue
    private var stream: FSEventStreamRef?
    private var debounceWorkItem: DispatchWorkItem?
    private var pending = false
    private let lock = NSLock()

    /// Coalesce the burst git writes on a checkout (HEAD, then possibly
    /// packed-refs / ORIG_HEAD) into one handler call. 120ms is imperceptible
    /// for a branch-chip refresh and collapses the burst.
    private let debounceInterval: TimeInterval

    /// - Parameters:
    ///   - gitDir: absolute path to the pane's `.git` directory. The watcher
    ///     resolves symlinks (macOS `/var`→`/private/var`) so FSEvents-reported
    ///     paths match the prefix check.
    ///   - debounceInterval: coalescing window (default 120ms).
    ///   - handler: fired on a debounced batch of relevant ref changes.
    public init(gitDir: String, debounceInterval: TimeInterval = 0.120, handler: @escaping ChangeHandler) {
        if let resolved = realpath(gitDir, nil) {
            self.gitDir = String(cString: resolved)
            free(resolved)
        } else {
            self.gitDir = gitDir
        }
        self.debounceInterval = debounceInterval
        self.handler = handler
        self.queue = DispatchQueue(label: "com.senkani.githeadwatcher", qos: .utility)
    }

    deinit {
        // Defensive: if the owner forgot stop(), invalidate the stream from
        // deinit. stop() is idempotent and handles the nil / already-stopped
        // cases — same contract as Indexer.FileWatcher.
        stop()
    }

    /// Start watching. Idempotent — starting an already-running watcher is a no-op.
    public func start() {
        lock.lock()
        defer { lock.unlock() }
        guard stream == nil else { return }

        // Hand FSEvents a strong +1 on self via passRetained + a paired release
        // callback, so a callback already in flight on `queue` can never see a
        // deallocated `self` during a concurrent deinit. The +1 is dropped only
        // after FSEventStreamInvalidate drains queued callbacks. (This is the
        // exact lifetime fix Indexer.FileWatcher carries.)
        let retainedSelf = Unmanaged.passRetained(self).toOpaque()
        var context = FSEventStreamContext(
            version: 0,
            info: retainedSelf,
            retain: nil,
            release: { ptr in
                guard let ptr else { return }
                Unmanaged<GitHeadWatcher>.fromOpaque(ptr).release()
            },
            copyDescription: nil
        )

        let paths = [gitDir] as CFArray
        let flags = UInt32(
            kFSEventStreamCreateFlagFileEvents |
            kFSEventStreamCreateFlagUseCFTypes |
            kFSEventStreamCreateFlagNoDefer
        )

        guard let newStream = FSEventStreamCreate(
            kCFAllocatorDefault,
            { (_, info, numEvents, eventPaths, _, _) in
                guard let info else { return }
                let watcher = Unmanaged<GitHeadWatcher>.fromOpaque(info).takeUnretainedValue()
                let paths = unsafeBitCast(eventPaths, to: NSArray.self) as! [String]
                _ = numEvents
                watcher.handleEvents(paths: paths)
            },
            &context,
            paths,
            UInt64(kFSEventStreamEventIdSinceNow),
            0.05,
            flags
        ) else {
            Unmanaged<GitHeadWatcher>.fromOpaque(retainedSelf).release()
            fputs("[senkani] GitHeadWatcher: FSEventStreamCreate failed for \(Self.redactPath(gitDir))\n", stderr)
            return
        }

        FSEventStreamSetDispatchQueue(newStream, queue)
        guard FSEventStreamStart(newStream) else {
            FSEventStreamInvalidate(newStream)
            FSEventStreamRelease(newStream)
            fputs("[senkani] GitHeadWatcher: FSEventStreamStart failed for \(Self.redactPath(gitDir))\n", stderr)
            return
        }
        stream = newStream
    }

    /// Stop watching. Idempotent. After this returns, no further callbacks will
    /// fire and any callback in flight at call time has completed.
    public func stop() {
        lock.lock()
        guard let activeStream = stream else {
            lock.unlock()
            return
        }
        FSEventStreamStop(activeStream)
        FSEventStreamInvalidate(activeStream)
        FSEventStreamRelease(activeStream)
        stream = nil

        debounceWorkItem?.cancel()
        debounceWorkItem = nil
        pending = false
        // Release the lock BEFORE draining: an in-flight handleEvents on the
        // queue acquires the same lock, so holding it across the drain would
        // deadlock.
        lock.unlock()

        // Synchronously drain the serial queue so any already-submitted
        // callback runs to completion before stop() returns — closes the
        // use-after-free window during fast teardown.
        queue.sync { /* drain */ }
    }

    /// Whether the watcher is currently running.
    public var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stream != nil
    }

    // MARK: - Event handling

    private func handleEvents(paths: [String]) {
        lock.lock()
        defer { lock.unlock() }

        var sawRelevant = false
        for path in paths where isBranchDefining(path) {
            sawRelevant = true
            break
        }
        guard sawRelevant else { return }

        pending = true
        scheduleDebouncedFlush()
    }

    /// Schedule a debounced flush. Caller must hold the lock.
    private func scheduleDebouncedFlush() {
        debounceWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.flushPending()
        }
        debounceWorkItem = workItem
        queue.asyncAfter(deadline: .now() + debounceInterval, execute: workItem)
    }

    private func flushPending() {
        lock.lock()
        let fire = pending
        pending = false
        debounceWorkItem = nil
        lock.unlock()

        guard fire else { return }
        handler()
    }

    // MARK: - Filtering

    /// A path is branch-defining when it is `<gitDir>/HEAD` or lives under
    /// `<gitDir>/refs/heads/`. This matches exactly what a branch switch or a
    /// local-branch create/delete touches — and ignores the high-churn `index`,
    /// object writes, and lock files that would otherwise re-probe git on every
    /// `git add`.
    private func isBranchDefining(_ path: String) -> Bool {
        guard path.hasPrefix(gitDir) else { return false }
        let rel = String(path.dropFirst(gitDir.count).drop(while: { $0 == "/" }))
        if rel == "HEAD" { return true }
        if rel.hasPrefix("refs/heads/") { return true }
        return false
    }

    /// Redact `/Users/<name>` → `/Users/***` for log output. Minimal inline
    /// mirror of `ProjectSecurity.redactPath` to keep this file self-contained.
    static func redactPath(_ p: String) -> String {
        let comps = p.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard comps.count >= 2, comps[0] == "Users" else { return p }
        var redacted = comps
        redacted[1] = "***"
        return "/" + redacted.joined(separator: "/")
    }
}
