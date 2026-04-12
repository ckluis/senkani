import Foundation
import Testing
@testable import Indexer

// MARK: - Test Helpers

/// Thread-safe event collector for async FileWatcher tests.
final class EventCollector: @unchecked Sendable {
    private var events: [[String]] = []
    private let lock = NSLock()

    func append(_ batch: [String]) {
        lock.lock()
        events.append(batch)
        lock.unlock()
    }

    var allPaths: [String] {
        lock.lock()
        defer { lock.unlock() }
        return events.flatMap { $0 }
    }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return events.count
    }
}

/// Create a unique temp directory for a test. Caller is responsible for cleanup.
private func makeTempDir() -> String {
    let path = NSTemporaryDirectory() + "senkani-filewatcher-test-\(UUID().uuidString)"
    try! FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    return path
}

/// Wait up to `timeout` seconds for a condition to become true.
private func waitFor(timeout: TimeInterval = 1.0, condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        Thread.sleep(forTimeInterval: 0.05)
    }
    return condition()
}

// MARK: - Basic Operation

@Suite("FileWatcher — Basic Operation")
struct FileWatcherBasicTests {

    @Test("Starts and stops cleanly")
    func startsAndStopsCleanly() {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let watcher = FileWatcher(projectRoot: dir) { _ in }
        watcher.start()
        #expect(watcher.isRunning)
        watcher.stop()
        #expect(!watcher.isRunning)
        // Double stop is safe
        watcher.stop()
    }

    @Test("Fires handler on file create")
    func firesOnCreate() {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let collector = EventCollector()
        let watcher = FileWatcher(projectRoot: dir, debounceInterval: 0.05) { paths in
            collector.append(paths)
        }
        watcher.start()
        defer { watcher.stop() }

        // Small delay for FSEvents to register
        Thread.sleep(forTimeInterval: 0.1)

        let filePath = dir + "/new.swift"
        FileManager.default.createFile(atPath: filePath, contents: Data("func hi() {}\n".utf8))

        let fired = waitFor(timeout: 2.0) { !collector.allPaths.isEmpty }
        #expect(fired)
        #expect(collector.allPaths.contains { $0.hasSuffix("new.swift") })
    }

    @Test("Fires handler on file modify")
    func firesOnModify() {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let filePath = dir + "/test.swift"
        FileManager.default.createFile(atPath: filePath, contents: Data("let x = 1\n".utf8))

        let collector = EventCollector()
        let watcher = FileWatcher(projectRoot: dir, debounceInterval: 0.05) { paths in
            collector.append(paths)
        }
        watcher.start()
        defer { watcher.stop() }

        Thread.sleep(forTimeInterval: 0.1)

        try! "let x = 2\n".write(toFile: filePath, atomically: true, encoding: .utf8)

        let fired = waitFor(timeout: 2.0) { !collector.allPaths.isEmpty }
        #expect(fired)
        #expect(collector.allPaths.contains { $0.hasSuffix("test.swift") })
    }

    @Test("Fires handler on file delete")
    func firesOnDelete() {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let filePath = dir + "/test.swift"
        FileManager.default.createFile(atPath: filePath, contents: Data("let x = 1\n".utf8))

        let collector = EventCollector()
        let watcher = FileWatcher(projectRoot: dir, debounceInterval: 0.05) { paths in
            collector.append(paths)
        }
        watcher.start()
        defer { watcher.stop() }

        Thread.sleep(forTimeInterval: 0.1)

        try! FileManager.default.removeItem(atPath: filePath)

        let fired = waitFor(timeout: 2.0) { !collector.allPaths.isEmpty }
        #expect(fired)
        #expect(collector.allPaths.contains { $0.hasSuffix("test.swift") })
    }
}

// MARK: - Filtering

@Suite("FileWatcher — Filtering")
struct FileWatcherFilteringTests {

    @Test("Ignores non-source files")
    func ignoresNonSource() {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let collector = EventCollector()
        let watcher = FileWatcher(projectRoot: dir, debounceInterval: 0.05) { paths in
            collector.append(paths)
        }
        watcher.start()
        defer { watcher.stop() }

        Thread.sleep(forTimeInterval: 0.1)

        // Create non-source files
        FileManager.default.createFile(atPath: dir + "/README.md", contents: Data("# Hello\n".utf8))
        FileManager.default.createFile(atPath: dir + "/data.json", contents: Data("{}\n".utf8))
        FileManager.default.createFile(atPath: dir + "/image.png", contents: Data([0x89, 0x50, 0x4E, 0x47]))

        // Wait and verify no events fired
        Thread.sleep(forTimeInterval: 0.5)
        #expect(collector.callCount == 0)
    }

    @Test("Ignores files in skip directories")
    func ignoresSkipDirs() {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }

        // Create skip directories
        try! FileManager.default.createDirectory(atPath: dir + "/.git", withIntermediateDirectories: true)
        try! FileManager.default.createDirectory(atPath: dir + "/node_modules", withIntermediateDirectories: true)

        let collector = EventCollector()
        let watcher = FileWatcher(projectRoot: dir, debounceInterval: 0.05) { paths in
            collector.append(paths)
        }
        watcher.start()
        defer { watcher.stop() }

        Thread.sleep(forTimeInterval: 0.1)

        FileManager.default.createFile(atPath: dir + "/.git/test.swift", contents: Data("x".utf8))
        FileManager.default.createFile(atPath: dir + "/node_modules/test.swift", contents: Data("x".utf8))

        Thread.sleep(forTimeInterval: 0.5)
        #expect(collector.callCount == 0)
    }

    @Test("Tracks source files at top level")
    func tracksSourceFiles() {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let collector = EventCollector()
        let watcher = FileWatcher(projectRoot: dir, debounceInterval: 0.05) { paths in
            collector.append(paths)
        }
        watcher.start()
        defer { watcher.stop() }

        Thread.sleep(forTimeInterval: 0.1)

        FileManager.default.createFile(atPath: dir + "/app.swift", contents: Data("import Foundation\n".utf8))
        FileManager.default.createFile(atPath: dir + "/utils.py", contents: Data("import os\n".utf8))
        FileManager.default.createFile(atPath: dir + "/main.go", contents: Data("package main\n".utf8))

        let fired = waitFor(timeout: 2.0) { collector.allPaths.count >= 3 }
        #expect(fired)
        let all = collector.allPaths
        #expect(all.contains { $0.hasSuffix("app.swift") })
        #expect(all.contains { $0.hasSuffix("utils.py") })
        #expect(all.contains { $0.hasSuffix("main.go") })
    }
}

// MARK: - Debouncing

@Suite("FileWatcher — Debouncing")
struct FileWatcherDebouncingTests {

    @Test("Debounces rapid changes into one batch")
    func debouncesRapidChanges() {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let filePath = dir + "/test.swift"
        FileManager.default.createFile(atPath: filePath, contents: Data("let x = 0\n".utf8))

        let collector = EventCollector()
        let watcher = FileWatcher(projectRoot: dir, debounceInterval: 0.150) { paths in
            collector.append(paths)
        }
        watcher.start()
        defer { watcher.stop() }

        Thread.sleep(forTimeInterval: 0.1)

        // Rapid writes
        for i in 1...10 {
            try! "let x = \(i)\n".write(toFile: filePath, atomically: true, encoding: .utf8)
        }

        // Wait for debounce to fire
        let fired = waitFor(timeout: 2.0) { collector.callCount >= 1 }
        #expect(fired)

        // All rapid writes should collapse — the handler should have been called
        // a small number of times (ideally once, but timing may cause 2)
        #expect(collector.callCount <= 3)
        #expect(collector.allPaths.contains { $0.hasSuffix("test.swift") })
    }

    @Test("Resets debounce on new changes")
    func resetsDebounceOnNewChanges() {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let fileA = dir + "/a.swift"
        let fileB = dir + "/b.swift"
        FileManager.default.createFile(atPath: fileA, contents: Data("let a = 1\n".utf8))
        FileManager.default.createFile(atPath: fileB, contents: Data("let b = 1\n".utf8))

        let collector = EventCollector()
        let watcher = FileWatcher(projectRoot: dir, debounceInterval: 0.150) { paths in
            collector.append(paths)
        }
        watcher.start()
        defer { watcher.stop() }

        Thread.sleep(forTimeInterval: 0.1)

        // Modify a.swift, wait less than debounce
        try! "let a = 2\n".write(toFile: fileA, atomically: true, encoding: .utf8)
        Thread.sleep(forTimeInterval: 0.05)

        // Modify b.swift, wait less than debounce
        try! "let b = 2\n".write(toFile: fileB, atomically: true, encoding: .utf8)
        Thread.sleep(forTimeInterval: 0.05)

        // Modify a.swift again
        try! "let a = 3\n".write(toFile: fileA, atomically: true, encoding: .utf8)

        // Wait for debounce to fire
        let fired = waitFor(timeout: 2.0) {
            let all = collector.allPaths
            return all.contains { $0.hasSuffix("a.swift") } && all.contains { $0.hasSuffix("b.swift") }
        }
        #expect(fired)

        // Both files should appear in the collected events
        let all = collector.allPaths
        #expect(all.contains { $0.hasSuffix("a.swift") })
        #expect(all.contains { $0.hasSuffix("b.swift") })
    }
}
