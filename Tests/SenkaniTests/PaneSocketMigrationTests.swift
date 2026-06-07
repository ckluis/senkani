import Testing
import Foundation
@testable import Core

#if canImport(Darwin)
import Darwin.POSIX
#endif

/// Tests for the JSONL → Unix socket migration on the pane IPC path.
/// Exercises `PaneIPC.sendFireAndForget` against a real bound UDS listener
/// in a temp directory — no libc mocking, no SocketServerManager dependency.
// The multi-KB `largeFrameRoundTrip` round-trip is freed of full-suite
// cooperative-pool starvation on BOTH sides:
//   - PRODUCTION send (commit 88140b5, RETAINED): `PaneIPC.sendFireAndForget`
//     writes the frame through a partial-write loop (PaneIPC `writeAll`)
//     instead of a single-shot `write(2)`, so a slow-but-DRAINING reader
//     still receives the full frame rather than a truncated one.
//   - TEST reader (this round): the accept-and-drain side runs on a
//     DEDICATED OS `Thread`, NOT a `Task.detached` / cooperative-pool
//     task. The cooperative-pool reader was the residual flake — under
//     ~3691-test parallel load the reader Task got descheduled mid-drain,
//     the kernel send buffer stayed full past the 200 ms `SO_SNDTIMEO`
//     beyond `writeAll`'s zero-progress budget, and even the production
//     loop timed out → `.writeFailed`. A dedicated `Thread` is off both
//     the cooperative pool and the GCD worker pool, so it drains the
//     socket continuously regardless of starvation — DETERMINISTIC, the
//     same idiom R4 used in `MITMPipeBidirectionalDenyTests`. A readiness
//     barrier still ensures the reader is polling before the send.
// `.serialized` is retained as defence-in-depth against intra-suite
// fd/temp-path contention; it is NOT load-bearing for the large-frame
// race (which `.serialized` alone could not close, since other parallel
// suites still starve the pool — that is why this flake recurred AFTER
// the suite was serialized, and again AFTER 88140b5's two lucky greens).
@Suite("PaneIPC — socket migration (fire-and-forget)", .serialized)
struct PaneSocketMigrationTests {

    // MARK: - Helpers

    /// Create a temp-directory UDS path. Short enough to fit sockaddr_un.
    private static func tempSocketPath() -> String {
        let name = "senkani-pane-test-\(UUID().uuidString.prefix(8)).sock"
        return NSTemporaryDirectory() + name
    }

    /// Bind + listen on `path`. Returns the listening fd. Caller closes
    /// the fd and unlinks the path in teardown.
    private static func bindListener(at path: String, backlog: Int32 = 4) throws -> Int32 {
        unlink(path)  // idempotent

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw SocketTestError.createFailed(errno)
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = path.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            Darwin.close(fd)
            throw SocketTestError.pathTooLong
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { rawBuf in
            pathBytes.withUnsafeBufferPointer { srcBuf in
                let count = min(srcBuf.count, rawBuf.count)
                rawBuf.baseAddress!.copyMemory(from: srcBuf.baseAddress!, byteCount: count)
            }
        }

        let bindResult = withUnsafePointer(to: &addr) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.bind(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            Darwin.close(fd)
            throw SocketTestError.bindFailed(errno)
        }

        guard Darwin.listen(fd, backlog) == 0 else {
            Darwin.close(fd)
            throw SocketTestError.listenFailed(errno)
        }
        return fd
    }

    /// Accept one connection on `listenFD` with a bounded wait, read one
    /// length-prefixed frame, return the decoded payload bytes.
    ///
    /// `ready`, when supplied, is invoked immediately before the blocking
    /// `poll()` — a readiness barrier letting a concurrent sender wait
    /// until the reader is armed (used by `largeFrameRoundTrip` to remove
    /// the accept-vs-send start-order race under full-suite load).
    private static func acceptAndReadOneFrame(
        on listenFD: Int32,
        timeoutMs: Int32 = 1000,
        ready: (() -> Void)? = nil
    ) throws -> Data {
        var pfd = pollfd(fd: listenFD, events: Int16(POLLIN), revents: 0)
        ready?()
        let p = poll(&pfd, 1, timeoutMs)
        guard p > 0 else { throw SocketTestError.acceptTimeout }

        var clientAddr = sockaddr_un()
        var addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        let clientFD = withUnsafeMutablePointer(to: &clientAddr) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.accept(listenFD, sockaddrPtr, &addrLen)
            }
        }
        guard clientFD >= 0 else { throw SocketTestError.acceptFailed(errno) }
        defer { Darwin.close(clientFD) }

        // Read 4-byte length prefix
        var lenBytes = [UInt8](repeating: 0, count: 4)
        let r = Darwin.read(clientFD, &lenBytes, 4)
        guard r == 4 else { throw SocketTestError.shortRead }

        let length = Int(UInt32(bigEndian: Data(lenBytes).withUnsafeBytes { $0.load(as: UInt32.self) }))
        guard length > 0, length < 1 << 20 else { throw SocketTestError.invalidLength }

        var buf = Data(count: length)
        var total = 0
        while total < length {
            let n = buf.withUnsafeMutableBytes { raw in
                Darwin.read(clientFD, raw.baseAddress! + total, length - total)
            }
            if n <= 0 { break }
            total += n
        }
        guard total == length else { throw SocketTestError.shortRead }
        return buf
    }

    private enum SocketTestError: Error {
        case createFailed(Int32)
        case bindFailed(Int32)
        case listenFailed(Int32)
        case pathTooLong
        case acceptTimeout
        case acceptFailed(Int32)
        case shortRead
        case invalidLength
    }

    /// A thread-safe, one-shot async signal: `fulfill()` may be called
    /// from any thread (including the detached accept task's pool
    /// thread); `value` suspends until the first `fulfill()`. Idempotent —
    /// extra `fulfill()` calls are ignored. Used as a readiness barrier so
    /// a sender can wait until a concurrent reader is armed.
    private final class OneShotSignal: @unchecked Sendable {
        private let lock = NSLock()
        private var fulfilled = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func fulfill() {
            lock.lock()
            if fulfilled {
                lock.unlock()
                return
            }
            fulfilled = true
            let toResume = waiters
            waiters.removeAll()
            lock.unlock()
            for c in toResume { c.resume() }
        }

        var value: Void {
            get async {
                await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                    lock.lock()
                    if fulfilled {
                        lock.unlock()
                        cont.resume()
                    } else {
                        waiters.append(cont)
                        lock.unlock()
                    }
                }
            }
        }
    }

    // MARK: - Tests

    @Test("write: single fire-and-forget command framed + delivered")
    func singleFrameRoundTrip() throws {
        let path = Self.tempSocketPath()
        let listenFD = try Self.bindListener(at: path)
        defer {
            Darwin.close(listenFD)
            unlink(path)
        }

        let cmd = PaneIPCCommand(action: .setBudgetStatus, params: [
            "pane_id": "pane-A",
            "status": "warning",
            "spent_cents": "80",
            "limit_cents": "100",
        ])

        let outcome = PaneIPC.sendFireAndForget(cmd, socketPath: path)
        #expect(outcome == .written)

        let frame = try Self.acceptAndReadOneFrame(on: listenFD)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(PaneIPCCommand.self, from: frame)
        #expect(decoded.action == .setBudgetStatus)
        #expect(decoded.params["pane_id"] == "pane-A")
        #expect(decoded.params["status"] == "warning")
        #expect(decoded.params["spent_cents"] == "80")
        #expect(decoded.params["limit_cents"] == "100")
    }

    @Test("unreachable: absent socket path no-ops with .socketUnreachable")
    func unreachableNoOps() {
        let path = NSTemporaryDirectory() + "senkani-pane-absent-\(UUID().uuidString.prefix(8)).sock"
        // No bind — path points nowhere

        let cmd = PaneIPCCommand(action: .setBudgetStatus, params: ["pane_id": "x"])
        let start = Date()
        let outcome = PaneIPC.sendFireAndForget(cmd, socketPath: path)
        let elapsed = Date().timeIntervalSince(start)

        #expect(outcome == .socketUnreachable)
        // Must return promptly — fire-and-forget semantics.
        #expect(elapsed < 0.5)
    }

    @Test("unreachable: oversize path is rejected without connecting")
    func oversizePathRejected() {
        // sockaddr_un.sun_path is 104 bytes on Darwin. Make sure we exceed it.
        let long = String(repeating: "a", count: 110)
        let path = "/tmp/" + long + ".sock"

        let cmd = PaneIPCCommand(action: .list)
        let outcome = PaneIPC.sendFireAndForget(cmd, socketPath: path)
        #expect(outcome == .socketUnreachable)
    }

    @Test("all actions round-trip through the socket path")
    func allActionsRoundTripSocket() throws {
        let actions: [PaneIPCAction] = [.list, .add, .remove, .setActive, .setBudgetStatus]
        for action in actions {
            let path = Self.tempSocketPath()
            let listenFD = try Self.bindListener(at: path)
            defer {
                Darwin.close(listenFD)
                unlink(path)
            }

            let cmd = PaneIPCCommand(action: action, params: ["k": "v"])
            #expect(PaneIPC.sendFireAndForget(cmd, socketPath: path) == .written)

            let frame = try Self.acceptAndReadOneFrame(on: listenFD)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let decoded = try decoder.decode(PaneIPCCommand.self, from: frame)
            #expect(decoded.action == action)
            #expect(decoded.params["k"] == "v")
        }
    }

    @Test("concurrent: 4 fire-and-forget writes from distinct queues all land")
    func concurrentWritesAllDelivered() async throws {
        let path = Self.tempSocketPath()
        let listenFD = try Self.bindListener(at: path, backlog: 8)
        defer {
            Darwin.close(listenFD)
            unlink(path)
        }

        // TaskGroup, not DispatchGroup: `group.wait()` on the cooperative
        // pool thread starves swift-testing's scheduler (spec/testing.md
        // "Full-suite hang"). Using `await group.next()` keeps it yielding.
        let successes = await withTaskGroup(of: Bool.self) { group in
            for i in 0..<4 {
                group.addTask {
                    let cmd = PaneIPCCommand(action: .setBudgetStatus, params: [
                        "pane_id": "pane-\(i)"
                    ])
                    return PaneIPC.sendFireAndForget(cmd, socketPath: path) == .written
                }
            }
            var ok = 0
            while let written = await group.next() {
                if written { ok += 1 }
            }
            return ok
        }
        #expect(successes == 4)

        // Drain all 4 frames; each arrives on its own accepted connection.
        var seenPaneIDs = Set<String>()
        for _ in 0..<4 {
            let frame = try Self.acceptAndReadOneFrame(on: listenFD)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let cmd = try decoder.decode(PaneIPCCommand.self, from: frame)
            if let pid = cmd.params["pane_id"] { seenPaneIDs.insert(pid) }
        }
        #expect(seenPaneIDs == Set((0..<4).map { "pane-\($0)" }))
    }

    @Test("large frame: multi-KB payload writes and reads back cleanly")
    func largeFrameRoundTrip() async throws {
        let path = Self.tempSocketPath()
        let listenFD = try Self.bindListener(at: path)
        defer {
            Darwin.close(listenFD)
            unlink(path)
        }

        // Pack a moderately large params dict — exceeds the single-chunk
        // kernel buffer size so the write must drain through. Production
        // drains continuously via SocketServerManager.acceptPaneConnection;
        // this test mirrors that by accepting + reading WHILE the sender
        // writes. The integrity contract — every one of the 200 keys
        // round-trips byte-for-byte — is the load-bearing assertion below;
        // nothing here weakens it.
        var params: [String: String] = [:]
        for i in 0..<200 {
            params["k\(i)"] = String(repeating: "x", count: 40)
        }
        let cmd = PaneIPCCommand(action: .list, params: params)

        // CONCURRENCY NOTE (mirrors the R4 dedicated-thread fix in
        // MITMPipeBidirectionalDenyTests.runPipe): the reader runs on a
        // DEDICATED OS `Thread`, NOT a `Task.detached` / cooperative-pool
        // task. The earlier cooperative-pool reader was the residual flake:
        // under full-suite (~3691-test) parallel load swift-testing
        // saturates the cooperative pool, the reader Task gets descheduled
        // mid-drain, and the kernel UDS send buffer stays FULL past the
        // 200 ms SO_SNDTIMEO for longer than PaneIPC.writeAll's
        // zero-progress budget — so even the production partial-write loop
        // (commit 88140b5, RETAINED) times out and reports .writeFailed. A
        // dedicated `Thread` is off BOTH the cooperative pool and the GCD
        // worker pool, so it `accept()`s and drains the socket continuously
        // regardless of cooperative-pool starvation. This removes the
        // starvation dependence DETERMINISTICALLY, not probabilistically.
        // The `armed` readiness barrier still ensures the reader is polling
        // before the send (no start-order race); `frameBox` + the `done`
        // one-shot ship the read result back to this `async` body. We use
        // `OneShotSignal` (an `await`-able continuation), NOT
        // `DispatchSemaphore.wait`, to join: blocking-wait is unavailable
        // from an async context (it would park a cooperative thread), so
        // the reader thread `fulfill()`s `done` when it exits and the test
        // body `await`s it — joining without blocking the pool.
        let armed = OneShotSignal()
        let done = OneShotSignal()
        let frameBox = FrameBox()

        Thread.detachNewThread {
            let data = try? Self.acceptAndReadOneFrame(
                on: listenFD,
                timeoutMs: 5000,
                ready: { armed.fulfill() }
            )
            frameBox.set(data)
            done.fulfill()
        }

        // Block until the dedicated reader thread has armed its
        // `poll()`/`accept()` loop, so the write below races a reader that
        // is already waiting and draining.
        await armed.value

        #expect(PaneIPC.sendFireAndForget(cmd, socketPath: path) == .written)

        // Join the dedicated reader thread (bounded by the reader's own 5 s
        // accept budget). No thread leak: `detachNewThread`'s thread exits
        // when the closure returns, which it always does — `acceptAndRead`
        // returns on a completed read OR throws on its accept/read timeout,
        // and either way `done.fulfill()` runs and the thread terminates.
        await done.value

        let frame = try #require(frameBox.get())
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(PaneIPCCommand.self, from: frame)
        #expect(decoded.params.count == 200)
        #expect(decoded.params["k42"] == String(repeating: "x", count: 40))
    }

    /// Thread-safe one-shot box shipping the dedicated reader thread's
    /// decoded frame back to the `async` test body (mirrors the R4
    /// `OutcomeBox`/`UpstreamReader` idiom). The reader thread `set`s once;
    /// the test body `get`s after joining on the `DispatchSemaphore`.
    private final class FrameBox: @unchecked Sendable {
        private let lock = NSLock()
        private var _data: Data?
        func set(_ d: Data?) { lock.lock(); _data = d; lock.unlock() }
        func get() -> Data? { lock.lock(); defer { lock.unlock() }; return _data }
    }

    @Test("setBudgetStatus: encodes all four params + sends through socket")
    func setBudgetStatusEndToEnd() throws {
        let path = Self.tempSocketPath()
        let listenFD = try Self.bindListener(at: path)
        defer {
            Darwin.close(listenFD)
            unlink(path)
        }

        let cmd = PaneIPCCommand(action: .setBudgetStatus, params: [
            "pane_id": "550E8400-E29B-41D4-A716-446655440000",
            "status": "blocked",
            "spent_cents": "105",
            "limit_cents": "100",
        ])
        #expect(PaneIPC.sendFireAndForget(cmd, socketPath: path) == .written)

        let frame = try Self.acceptAndReadOneFrame(on: listenFD)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(PaneIPCCommand.self, from: frame)

        #expect(decoded.action == .setBudgetStatus)
        // All four budget-status params preserved intact — the GUI's
        // dispatcher in ContentView.handlePaneCommand reads them by these
        // exact names, so the contract is load-bearing.
        #expect(decoded.params["pane_id"] == "550E8400-E29B-41D4-A716-446655440000")
        #expect(decoded.params["status"] == "blocked")
        #expect(decoded.params["spent_cents"] == "105")
        #expect(decoded.params["limit_cents"] == "100")
    }

    @Test("length prefix: big-endian UInt32 matches payload length")
    func lengthPrefixWireFormat() throws {
        let path = Self.tempSocketPath()
        let listenFD = try Self.bindListener(at: path)
        defer {
            Darwin.close(listenFD)
            unlink(path)
        }

        let cmd = PaneIPCCommand(action: .list)
        #expect(PaneIPC.sendFireAndForget(cmd, socketPath: path) == .written)

        // Accept + peek the first 4 bytes directly, independent of the
        // helper that already decodes the length.
        var pfd = pollfd(fd: listenFD, events: Int16(POLLIN), revents: 0)
        _ = poll(&pfd, 1, 1000)
        var clientAddr = sockaddr_un()
        var addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        let clientFD = withUnsafeMutablePointer(to: &clientAddr) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.accept(listenFD, sockaddrPtr, &addrLen)
            }
        }
        #expect(clientFD >= 0)
        defer { Darwin.close(clientFD) }

        var lenBytes = [UInt8](repeating: 0, count: 4)
        #expect(Darwin.read(clientFD, &lenBytes, 4) == 4)

        let encodedLength = UInt32(bigEndian: Data(lenBytes).withUnsafeBytes { $0.load(as: UInt32.self) })

        // Drain the payload to get the actual byte count.
        var payloadBuf = Data(count: Int(encodedLength))
        var total = 0
        while total < Int(encodedLength) {
            let n = payloadBuf.withUnsafeMutableBytes { raw in
                Darwin.read(clientFD, raw.baseAddress! + total, Int(encodedLength) - total)
            }
            if n <= 0 { break }
            total += n
        }
        #expect(total == Int(encodedLength))

        // Re-encode the same command, length must match (ignoring the
        // timestamp inside — JSON is deterministic enough for byte
        // count, not byte identity; we assert the length matches the
        // stream's length header, which is the contract under test).
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let reencoded = try encoder.encode(cmd)
        #expect(UInt32(reencoded.count) == encodedLength)
    }

    @Test("no directory creation: socket write does not touch pane-commands.jsonl")
    func doesNotCreateLegacyJSONLFile() throws {
        // Regression guard: the old path created `~/.senkani/pane-commands.jsonl`
        // on every fire. The migrated path must not touch that file even
        // when the socket is unreachable.
        let legacyPath = NSHomeDirectory() + "/.senkani/pane-commands.jsonl"
        let preExisted = FileManager.default.fileExists(atPath: legacyPath)
        let preSize: Int
        if preExisted {
            let attrs = try? FileManager.default.attributesOfItem(atPath: legacyPath)
            preSize = (attrs?[.size] as? Int) ?? 0
        } else {
            preSize = 0
        }

        // Socket definitely absent — use a path nothing is bound to.
        let absent = NSTemporaryDirectory() + "senkani-pane-nope-\(UUID().uuidString.prefix(8)).sock"
        let cmd = PaneIPCCommand(action: .setBudgetStatus, params: ["pane_id": "x"])
        _ = PaneIPC.sendFireAndForget(cmd, socketPath: absent)

        // Legacy file either still doesn't exist, or if it did pre-exist
        // (from a prior binary version on disk), its size hasn't changed.
        let nowExists = FileManager.default.fileExists(atPath: legacyPath)
        #expect(nowExists == preExisted)
        if nowExists {
            let attrs = try? FileManager.default.attributesOfItem(atPath: legacyPath)
            let nowSize = (attrs?[.size] as? Int) ?? 0
            #expect(nowSize == preSize)
        }
    }
}
