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
        stop()
    }

    /// Start watching. Idempotent — starting an already-running watcher is a no-op.
    public func start() {
        lock.lock()
        defer { lock.unlock() }
        guard stream == nil else { return }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
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
                guard let info = info else { return }
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
            fputs("[senkani] FileWatcher: FSEventStreamCreate failed\n", stderr)
            return
        }

        FSEventStreamSetDispatchQueue(newStream, queue)
        FSEventStreamStart(newStream)
        stream = newStream

        fputs("[senkani] FileWatcher started for \(projectRoot)\n", stderr)
    }

    /// Stop watching. Idempotent.
    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        guard let activeStream = stream else { return }
        FSEventStreamStop(activeStream)
        FSEventStreamInvalidate(activeStream)
        FSEventStreamRelease(activeStream)
        stream = nil

        debounceWorkItem?.cancel()
        debounceWorkItem = nil
        pendingChanges.removeAll()
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
