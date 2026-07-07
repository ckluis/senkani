import Testing
import Foundation
import Dispatch
@testable import CLI

/// Regression pin for
/// `egress-start-dispatchmain-non-main-thread-crash-2026-07-05`.
///
/// `senkani egress start` used to park the foreground daemon with
/// `dispatchMain()`. But `Egress.Start.run()` executes on a
/// Swift-concurrency cooperative-pool thread (the parent `Senkani` is an
/// `AsyncParsableCommand`, so its async `main()` drains on the real main
/// thread and the sync subcommand `run()` lands off-main). `dispatch_main()`
/// asserts it is called on the main thread and traps
/// (`brk 1` → EXC_BREAKPOINT/SIGTRAP, exit 133) off-main, so the daemon
/// crashed on every invocation — after binding the listener and writing the
/// pid/port files, but before servicing a single connection.
///
/// The fix replaced `dispatchMain()` with `blockForegroundDaemon(until:)`,
/// a `DispatchSemaphore` park that is thread-agnostic and returns when
/// signalled. Two layers pin the invariant:
///
///   1. `parkReturnsWhenSignalled` — a fast unit check that the park
///      primitive UNWINDS when signalled (`dispatchMain()` never returns,
///      so the SIGTERM handler could never unwind the daemon cleanly).
///   2. `startStaysUpThenStopsCleanly` — the revert-catcher. Spawns the
///      real `senkani egress start` binary and asserts it stays up (no
///      SIGTRAP) then stops cleanly on SIGTERM. A revert to `dispatchMain()`
///      anywhere on `run()`'s park path re-introduces the off-main trap and
///      this test fails: the process dies with signal 5 within
///      milliseconds instead of parking.
@Suite("egress start — foreground daemon park (no dispatchMain off-main)")
struct EgressStartForegroundBlockTests {

    // MARK: - Layer 1: seam unit check (always runs)

    @Test func parkReturnsWhenSignalled() {
        let gate = DispatchSemaphore(value: 0)
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(20)) {
            gate.signal()
        }
        // A revert to dispatchMain() would never return → this hangs and the
        // coarse suite timeout trips. The semaphore park unwinds promptly
        // once signalled.
        blockForegroundDaemon(until: gate)
        #expect(Bool(true), "blockForegroundDaemon returned after signal")
    }

    // MARK: - Layer 2: real-binary integration (the revert-catcher)

    /// Spawn `senkani egress start --port 0` and prove the foreground daemon
    /// (a) stays up past the park point without trapping, and (b) shuts down
    /// cleanly on SIGTERM (handler unlinks both pid + port files).
    ///
    /// Isolation: the CLI writes `~/.senkani/egress.{pid,port}` against the
    /// REAL home (`NSHomeDirectory()` ignores `$HOME` on macOS), so the test
    /// refuses to run if a pid file already exists — never touch a daemon a
    /// human may have started — and removes any files it created on exit.
    @Test func startStaysUpThenStopsCleanly() throws {
        guard let binary = Self.senkaniBinaryURL() else {
            // No built `senkani` product next to the test bundle — skip
            // gracefully (matches BrowserPaneExerciserTests' convention).
            return
        }
        let pidFile = NSHomeDirectory() + "/.senkani/egress.pid"
        let portFile = NSHomeDirectory() + "/.senkani/egress.port"
        let fm = FileManager.default
        // Refuse to stomp a live daemon's state.
        guard !fm.fileExists(atPath: pidFile) else { return }

        let proc = Process()
        proc.executableURL = binary
        proc.arguments = ["egress", "start", "--port", "0"]
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        try proc.run()

        // Ensure we never leak the child, whatever the assertions do.
        defer {
            if proc.isRunning {
                kill(proc.processIdentifier, SIGKILL)
            }
            try? fm.removeItem(atPath: pidFile)
            try? fm.removeItem(atPath: portFile)
        }

        // Poll for the port file: the daemon binds, writes the port, THEN
        // parks. A revert SIGTRAPs at the park, so `proc.isRunning` flips to
        // false well before this budget elapses.
        var boundAndParked = false
        for _ in 0..<40 {
            if !proc.isRunning { break }              // crashed (SIGTRAP) → stop early
            if fm.fileExists(atPath: portFile) {
                // Give the park a beat to execute after the port write.
                Thread.sleep(forTimeInterval: 0.2)
                boundAndParked = proc.isRunning
                break
            }
            Thread.sleep(forTimeInterval: 0.05)
        }

        #expect(boundAndParked,
                "egress start must bind + park in the foreground WITHOUT trapping (a revert to dispatchMain() off-main SIGTRAPs here). isRunning=\(proc.isRunning) status=\(proc.isRunning ? -1 : proc.terminationStatus)")

        guard boundAndParked else { return }

        // SIGTERM → the handler stops the listener, unlinks pid, signals the
        // gate; run() unwinds and the process exits 0.
        kill(proc.processIdentifier, SIGTERM)
        // Bounded wait for clean exit.
        for _ in 0..<40 where proc.isRunning { Thread.sleep(forTimeInterval: 0.05) }

        #expect(!proc.isRunning, "SIGTERM must unwind the park and exit the daemon (it hung)")
        if !proc.isRunning {
            #expect(proc.terminationStatus == 0,
                    "clean SIGTERM shutdown must exit 0; got status \(proc.terminationStatus) reason \(proc.terminationReason.rawValue)")
        }
        #expect(!fm.fileExists(atPath: pidFile), "SIGTERM handler must unlink the pid file")
        #expect(!fm.fileExists(atPath: portFile), "SIGTERM handler must unlink the port file")
    }

    // MARK: - Helpers

    /// Resolve the built `senkani` binary. Under `swift test` neither
    /// `Bundle.main` nor `argv[0]` point at the SwiftPM build dir (they
    /// resolve into the Xcode toolchain's testing helper), so anchor on the
    /// test's own source path (`#filePath`), walk up to the package root, and
    /// take `.build/debug/senkani` (SwiftPM maintains that symlink to the
    /// active `<triple>/debug`). `swift test` builds the `senkani` product
    /// because the `CLI` target is a test dependency, so this normally
    /// resolves; returns nil (graceful skip) only if the binary is absent.
    private static func senkaniBinaryURL() -> URL? {
        let fm = FileManager.default
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<10 {
            if fm.fileExists(atPath: dir.appendingPathComponent("Package.swift").path) {
                let candidate = dir
                    .appendingPathComponent(".build/debug/senkani")
                if fm.isExecutableFile(atPath: candidate.path) {
                    return candidate.resolvingSymlinksInPath()
                }
                return nil
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        return nil
    }
}
