import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Live TCP listener for the EgressProxy daemon (Phase T.1a.2).
///
/// Binds to `127.0.0.1:<port>` (port 0 = random), accepts each
/// connection on a dispatch queue, and hands the fd to an
/// `EgressConnectionHandler`. The handler reads the first request
/// line, evaluates it through `EgressRuleEngine`, and either pipes
/// to the upstream host or replies with `403 Forbidden`.
///
/// Lifecycle:
///   - `start()` binds, optionally writes the port file, and begins
///     accepting. Idempotent — calling twice is a no-op.
///   - `stop()` cancels the accept source, closes listening fd, and
///     unlinks the port file. Idempotent.
///
/// Concurrency: every public mutation funnels through `lock`; the
/// dispatch source runs on `queue`. Each accepted connection gets
/// its own short-lived task that either completes (response sent +
/// closed) or runs the bidirectional pipe to EOF on either side.
///
/// fd ownership contract: the accept-source's cancel handler captures
/// the bound listening `fd` as a LOCAL — never reads `self.listenFD`
/// — so a stale cancel handler closes the correct fd even if `start()`
/// has already reassigned `self.listenFD` to a newer fd. The `= -1`
/// nil-out of `self.listenFD` happens in `stop()` under the lock.
/// Rationale: the original design read `self.listenFD` inside the
/// cancel handler closure; a stop()-then-start() sequence (config
/// reload, port collision recovery, test teardown + re-init) could
/// queue an old cancel handler that fired after the new listener had
/// bound, silently closing the new healthy listening socket. Same
/// race-class as `ClaudeSessionWatcher`'s 2026-05-14 EXC_BREAKPOINT
/// fix — listener variant is silent-failure rather than crash, since
/// `accept(-1, …)` returns EBADF and the listener appears stopped.
public final class EgressListener: @unchecked Sendable {

    public struct Config: Sendable {
        /// Port to bind. 0 means kernel-assigned (read back via getsockname).
        public var port: Int
        /// Persist the bound port to `~/.senkani/egress.port` after bind.
        public var writePortFile: Bool
        /// Path of the port file. Override for tests.
        public var portFilePath: String

        public init(
            port: Int = 0,
            writePortFile: Bool = true,
            portFilePath: String = NSHomeDirectory() + "/.senkani/egress.port"
        ) {
            self.port = port
            self.writePortFile = writePortFile
            self.portFilePath = portFilePath
        }
    }

    /// Reasons a connection was closed by the proxy. Surfaced via
    /// the decision row's `rule_id` for the operator's audit log.
    public enum CloseReason: String, Sendable {
        case allowed
        case deniedByRule          = "rule-match"
        case parseFailure          = "parse-failure"
        case sniMismatch           = "sni_mismatch"
        case sniUnparseable        = "sni_unparseable"
        case upstreamFailure       = "upstream_unreachable"
    }

    private let policy: EgressPolicy
    private let judge: JudgeAdapter?
    private let database: SessionDatabase
    private let config: Config
    /// Upstream-connect seam (V.13b-4d-ii). Defaults to the production
    /// `DefaultEgressUpstreamConnector` adopter. Tests inject a
    /// `LoopbackStubConnector` to redirect ALLOW-arm CONNECTs at a
    /// fixture loopback port without dialing the real upstream.
    private let upstreamConnector: EgressUpstreamConnecting
    private let queue = DispatchQueue(label: "com.senkani.egress-listener", qos: .userInitiated)
    private let connectionQueue = DispatchQueue(label: "com.senkani.egress-conn", qos: .userInitiated, attributes: .concurrent)
    private let lock = NSLock()
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var boundPort: Int = 0
    private var running = false

    /// T.1b primary init — takes a per-pane policy and an optional
    /// judge adapter. Production wires both; tests can pass `judge: nil`
    /// to assert static-only behavior.
    public init(
        policy: EgressPolicy,
        judge: JudgeAdapter? = nil,
        database: SessionDatabase = .shared,
        config: Config = Config(),
        upstreamConnector: EgressUpstreamConnecting = DefaultEgressUpstreamConnector()
    ) {
        self.policy = policy
        self.judge = judge
        self.database = database
        self.config = config
        self.upstreamConnector = upstreamConnector
    }

    /// Back-compat init for T.1a callers. Wraps the flat rule engine in
    /// an `EgressPolicy` covering every `PaneMode`. No judge adapter
    /// (static-only behavior — matches T.1a semantics exactly).
    public convenience init(
        rules: EgressRuleEngine,
        database: SessionDatabase = .shared,
        config: Config = Config(),
        upstreamConnector: EgressUpstreamConnecting = DefaultEgressUpstreamConnector()
    ) {
        var engines: [PaneMode: EgressRuleEngine] = [:]
        for mode in PaneMode.allCases { engines[mode] = rules }
        let policy = EgressPolicy(engines: engines)
        self.init(
            policy: policy,
            judge: nil,
            database: database,
            config: config,
            upstreamConnector: upstreamConnector
        )
    }

    /// Bound port after `start()` succeeds. Zero before start / after stop.
    public var port: Int {
        lock.lock(); defer { lock.unlock() }
        return boundPort
    }

    public var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return running
    }

    public enum ListenError: Error, Equatable {
        case createFailed(Int32)
        case bindFailed(Int32)
        case listenFailed(Int32)
        case getsocknameFailed(Int32)
    }

    /// Bind, listen, install the accept source, and (optionally) write
    /// the port file. Throws on any POSIX failure during setup.
    public func start() throws {
        lock.lock()
        if running { lock.unlock(); return }
        lock.unlock()

        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ListenError.createFailed(errno) }

        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(config.port).bigEndian
        // 127.0.0.1 in network byte order — bind(2) only accepts loopback.
        addr.sin_addr.s_addr = UInt32(0x7F00_0001).bigEndian
        #if canImport(Darwin)
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif

        let bindResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            let e = errno
            close(fd)
            throw ListenError.bindFailed(e)
        }

        guard listen(fd, 32) == 0 else {
            let e = errno
            close(fd)
            throw ListenError.listenFailed(e)
        }

        // Read back the kernel-assigned port (if config.port == 0).
        var bound = sockaddr_in()
        var boundLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &bound) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                getsockname(fd, sa, &boundLen)
            }
        }
        guard nameResult == 0 else {
            let e = errno
            close(fd)
            throw ListenError.getsocknameFailed(e)
        }
        let port = Int(UInt16(bigEndian: bound.sin_port))

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            self?.acceptOne()
        }
        // Capture fd locally — see class doc `fd ownership contract`.
        source.setCancelHandler { close(fd) }

        lock.lock()
        listenFD = fd
        acceptSource = source
        boundPort = port
        running = true
        lock.unlock()

        if config.writePortFile {
            writePortFile(port: port)
        }

        source.resume()
    }

    public func stop() {
        lock.lock()
        guard running else { lock.unlock(); return }
        running = false
        let source = acceptSource
        acceptSource = nil
        let path = config.portFilePath
        let writePort = config.writePortFile
        boundPort = 0
        // Nil out under the lock; the actual close(fd) happens
        // asynchronously in the dispatch source's cancel handler,
        // which captured the fd locally.
        listenFD = -1
        lock.unlock()

        source?.cancel()
        if writePort {
            unlink(path)
        }
    }

    // MARK: - Private

    private func acceptOne() {
        var clientAddr = sockaddr_in()
        var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        let clientFD = withUnsafeMutablePointer(to: &clientAddr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                accept(listenFD, sa, &addrLen)
            }
        }
        guard clientFD >= 0 else { return }

        // Reject any non-loopback peer. The bind is already loopback-only,
        // so this is belt-and-braces — defends against a kernel bug or a
        // misconfigured proxy chain.
        let peerIP = UInt32(bigEndian: clientAddr.sin_addr.s_addr)
        guard peerIP == 0x7F00_0001 else {
            close(clientFD)
            return
        }

        let handler = EgressConnectionHandler(
            policy: policy,
            judge: judge,
            database: database,
            clientFD: clientFD,
            upstreamConnector: upstreamConnector
        )
        connectionQueue.async {
            handler.run()
        }
    }

    private func writePortFile(port: Int) {
        let path = config.portFilePath
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let bytes = "\(port)\n".data(using: .utf8) ?? Data()
        let tmp = path + ".tmp"
        do {
            try bytes.write(to: URL(fileURLWithPath: tmp), options: [.atomic])
            // Atomic rename so a concurrent reader either sees the old file
            // or the new one — never a half-written file.
            rename(tmp, path)
        } catch {
            // Best-effort: if we can't write the port file, the listener
            // still functions; doctor will report "down" until corrected.
        }
    }
}
