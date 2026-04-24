import Foundation
import CoreServices

/// Watches a project directory for file changes using FSEvents.
/// Debounces rapid changes and calls a handler for each unique changed file.
public final class FileWatcher: @unchecked Sendable {
    /// Handler called for each debounced batch of changed files.
    /// Receives absolute file paths. Called on the watcher's queue.
    public typealias ChangeHandler = ([String]) -> Void

    private let projectRoot: String
    private let handler: ChangeHandler
    private let queue: DispatchQueue
    private var stream: FSEventStreamRef?
    private var pendingChanges: Set<String> = []
    private var debounceWorkItem: DispatchWorkItem?
    private let lock = NSLock()

    /// Debounce interval — coalesce events within this window.
    /// 150ms is imperceptible but collapses most editor-save bursts.
    private let debounceInterval: TimeInterval

    public init(projectRoot: String, debounceInterval: TimeInterval = 0.150, handler: @escaping ChangeHandler) {
        // Resolve symlinks so FSEvents-reported paths match our prefix check.
        // macOS /var → /private/var symlink is a common source of mismatch.
        if let resolved = realpath(projectRoot, nil) {
            self.projectRoot = String(cString: resolved)
            free(resolved)
        } else {
            self.projectRoot = projectRoot
        }
        self.debounceInterval = debounceInterval
        self.handler = handler
        self.queue = DispatchQueue(label: "com.senkani.filewatcher", qos: .utility)
    }

    deinit {
        // Defensive: if the owner forgot to call stop(), at least invalidate
        // the FSEvents stream from deinit. FSEvents holds a +1 retain on self
        // (see start() — passRetained context info), so reaching deinit means
        // either start() was never called, or the +1 was already released by
        // the FSEvents release callback. Either way, the stream pointer here
        // is either nil or stopped-but-not-yet-released, and stop() handles
        // both cases idempotently.
        stop()
    }

    /// Start watching. Idempotent — starting an already-running watcher is a no-op.
    public func start() {
        lock.lock()
        defer { lock.unlock() }
        guard stream == nil else { return }

        // FSEvents holds the `info` pointer for the lifetime of the stream
        // and dispatches callbacks asynchronously on `self.queue`. To prevent
        // a use-after-free between a callback that's already in flight and
        // a concurrent deinit, we hand FSEvents a strong retain on self via
        // `passRetained` and provide a paired release callback. The +1 is
        // dropped only after `FSEventStreamInvalidate` has drained any
        // in-flight callback — so any callback executing on the queue is
        // guaranteed to see a live `self`.
        let retainedSelf = Unmanaged.passRetained(self).toOpaque()
        var context = FSEventStreamContext(
            version: 0,
            info: retainedSelf,
            retain: nil,
            release: { ptr in
                guard let ptr else { return }
                Unmanaged<FileWatcher>.fromOpaque(ptr).release()
            },
            copyDescription: nil
        )

        let paths = [projectRoot] as CFArray
        let flags = UInt32(
            kFSEventStreamCreateFlagFileEvents |
            kFSEventStreamCreateFlagUseCFTypes |
            kFSEventStreamCreateFlagNoDefer
        )

        guard let newStream = FSEventStreamCreate(
            kCFAllocatorDefault,
            { (_, info, numEvents, eventPaths, eventFlags, _) in
                guard let info else { return }
                // `takeUnretainedValue` is safe here: FSEvents' own +1
                // (set via passRetained in the context) keeps `self` alive
                // until the release callback fires — which only happens
                // after FSEventStreamInvalidate has drained queued events.
                let watcher = Unmanaged<FileWatcher>.fromOpaque(info).takeUnretainedValue()
                let paths = unsafeBitCast(eventPaths, to: NSArray.self) as! [String]
                let flagsBuffer = UnsafeBufferPointer(start: eventFlags, count: numEvents)
                watcher.handleEvents(paths: paths, flags: Array(flagsBuffer))
            },
            &context,
            paths,
            UInt64(kFSEventStreamEventIdSinceNow),
            0.05,
            flags
        ) else {
            // FSEventStreamCreate didn't take ownership of our +1 — release it
            // ourselves so we don't leak.
            Unmanaged<FileWatcher>.fromOpaque(retainedSelf).release()
            fputs("[senkani] FileWatcher: FSEventStreamCreate failed for \(Self.redactPath(projectRoot))\n", stderr)
            return
        }

        FSEventStreamSetDispatchQueue(newStream, queue)
        // FSEventStreamStart returns false if the stream could not be scheduled.
        // When that happens, the stream must be invalidated + released here;
        // otherwise FSEvents would hold the +1 on self indefinitely and no
        // callbacks (including the release callback) would ever fire.
        guard FSEventStreamStart(newStream) else {
            FSEventStreamInvalidate(newStream)
            FSEventStreamRelease(newStream)
            // FSEventStreamRelease drops the stream's retain on the `info`
            // pointer — which is the +1 we handed it. No extra release needed.
            fputs("[senkani] FileWatcher: FSEventStreamStart failed for \(Self.redactPath(projectRoot))\n", stderr)
            return
        }
        stream = newStream
    }

    /// Stop watching. Idempotent.
    ///
    /// After this returns, no further callbacks will fire and any callback
    /// that was in flight at call time has completed. Safe to call from
    /// `deinit` because we drop the lock before draining the dispatch queue.
    public func stop() {
        lock.lock()
        guard let activeStream = stream else {
            lock.unlock()
            return
        }
        // Tear down FSEvents first so no new callbacks are scheduled. The
        // release callback installed in start() drops the FSEvents-owned +1
        // on self once invalidation has drained queued callbacks.
        FSEventStreamStop(activeStream)
        FSEventStreamInvalidate(activeStream)
        FSEventStreamRelease(activeStream)
        stream = nil

        debounceWorkItem?.cancel()
        debounceWorkItem = nil
        pendingChanges.removeAll()
        // Release the lock BEFORE draining: an in-flight handleEvents on the
        // queue acquires the same lock, so holding it across the drain would
        // deadlock.
        lock.unlock()

        // Synchronously drain the watcher's serial queue. Any FSEvents
        // callback that was already submitted runs to completion before
        // this returns; new callbacks won't arrive because we invalidated
        // the stream above. This closes the use-after-free window observed
        // as `Object … of class FileWatcher deallocated with non-zero
        // retain count 2` during fast test teardown.
        queue.sync { /* drain */ }
    }

    /// Whether the watcher is currently running.
    public var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stream != nil
    }

    // MARK: - Event Handling

    private func handleEvents(paths: [String], flags: [FSEventStreamEventFlags]) {
        lock.lock()
        defer { lock.unlock() }

        for (i, path) in paths.enumerated() {
            let flag = flags[i]

            // Skip directory events
            if flag & UInt32(kFSEventStreamEventFlagItemIsDir) != 0 {
                continue
            }

            guard shouldTrack(path: path) else { continue }
            pendingChanges.insert(path)
        }

        if !pendingChanges.isEmpty {
            scheduleDebouncedFlush()
        }
    }

    /// Schedule a debounced flush. Caller must hold the lock.
    private func scheduleDebouncedFlush() {
        debounceWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.flushPending()
        }
        debounceWorkItem = workItem
        queue.asyncAfter(deadline: .now() + debounceInterval, execute: workItem)
    }

    /// Flush pending changes to the handler.
    private func flushPending() {
        lock.lock()
        let changes = Array(pendingChanges)
        pendingChanges.removeAll()
        debounceWorkItem = nil
        lock.unlock()

        guard !changes.isEmpty else { return }
        handler(changes)
    }

    // MARK: - Filtering

    /// Redact `/Users/<name>` → `/Users/***` in log output. Indexer can't
    /// depend on Core, so this is a minimal inline mirror of
    /// `ProjectSecurity.redactPath`.
    static func redactPath(_ p: String) -> String {
        let comps = p.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard comps.count >= 2, comps[0] == "Users" else { return p }
        var redacted = comps
        redacted[1] = "***"
        return "/" + redacted.joined(separator: "/")
    }

    /// Determine if a path should trigger re-indexing.
    private func shouldTrack(path: String) -> Bool {
        guard path.hasPrefix(projectRoot) else { return false }

        let relativePath = String(path.dropFirst(projectRoot.count + 1))
        let components = relativePath.split(separator: "/").map(String.init)

        // Reject files inside skip directories
        for component in components.dropLast() {
            if FileWalker.skipDirs.contains(component) {
                return false
            }
        }

        // Must have a supported source file extension
        let ext = (path as NSString).pathExtension.lowercased()
        return FileWalker.languageMap[ext] != nil
    }
}
