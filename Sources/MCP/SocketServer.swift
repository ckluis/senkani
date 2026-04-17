import Foundation
import MCP
import Core

#if canImport(Darwin)
import Darwin.POSIX
#endif

/// Unix domain socket MCP server.
/// Listens on ~/.senkani/mcp.sock, accepts multiple connections, each getting
/// its own MCP Server + SocketTransport backed by the shared MCPSession.
public final class SocketServerManager: @unchecked Sendable {
    public static let shared = SocketServerManager()

    private let socketPath: String
    private let hookSocketPath: String
    private let paneSocketPath: String
    private var listenFD: Int32 = -1
    private var hookListenFD: Int32 = -1
    private var paneListenFD: Int32 = -1
    private var running = false
    private let queue = DispatchQueue(label: "com.senkani.socket-server", qos: .utility)
    private let hookQueue = DispatchQueue(label: "com.senkani.hook-server", qos: .userInteractive)
    private let paneQueue = DispatchQueue(label: "com.senkani.pane-server", qos: .userInitiated)
    private var acceptSource: DispatchSourceRead?
    private var hookAcceptSource: DispatchSourceRead?
    private var paneAcceptSource: DispatchSourceRead?
    private var activeTasks: [Task<Void, Never>] = []
    private let lock = NSLock()

    /// Hook event handler. Set this before calling start().
    /// Called on hookQueue for each incoming hook event.
    /// Returns the JSON response bytes to send back to the hook binary.
    public var hookHandler: ((_ eventJSON: Data) -> Data)?

    /// Pane command handler. Set this before calling start().
    /// Called on paneQueue for each incoming pane IPC command.
    /// Returns the JSON response bytes to send back to the MCP tool.
    public var paneHandler: ((_ commandJSON: Data) -> Data)?

    private init() {
        let senkaniDir = NSHomeDirectory() + "/.senkani"
        self.socketPath = senkaniDir + "/mcp.sock"
        self.hookSocketPath = senkaniDir + "/hook.sock"
        self.paneSocketPath = senkaniDir + "/pane.sock"
    }

    /// P2-12: cached auth token for this server's lifetime, non-nil when
    /// `SENKANI_SOCKET_AUTH=on`. Rotated on every `start()`.
    private var authToken: String?

    /// Start listening for MCP connections and hook events.
    public func start() {
        lock.lock()
        guard !running else { lock.unlock(); return }
        running = true
        lock.unlock()

        // P2-12: generate socket auth token if enabled. On failure, log and
        // proceed with auth disabled — better than failing to start entirely.
        if SocketAuthToken.isEnabled {
            do {
                let token = try SocketAuthToken.generate()
                lock.lock()
                authToken = token
                lock.unlock()
                Logger.log("socket.auth.enabled", fields: ["outcome": .string("ready")])
            } catch {
                Logger.log("socket.auth.failed", fields: [
                    "error": .string("\(error)"),
                    "outcome": .string("auth_disabled")
                ])
            }
        }

        queue.async { [self] in
            do {
                try startListening()
            } catch {
                FileHandle.standardError.write(
                    Data("[senkani] Socket server failed to start: \(error)\n".utf8))
                lock.lock()
                running = false
                lock.unlock()
            }
        }

        // Start hook listener on separate queue (lightweight, short-lived connections)
        hookQueue.async { [self] in
            do {
                try startHookListening()
            } catch {
                FileHandle.standardError.write(
                    Data("[senkani] Hook socket server failed to start: \(error)\n".utf8))
            }
        }

        // Start pane listener on separate queue (pane control IPC)
        paneQueue.async { [self] in
            do {
                try startPaneListening()
            } catch {
                FileHandle.standardError.write(
                    Data("[senkani] Pane socket server failed to start: \(error)\n".utf8))
            }
        }
    }

    /// Stop accepting new connections and close both listeners.
    public func stop() {
        lock.lock()
        guard running else { lock.unlock(); return }
        running = false
        // P2-12: clear token on clean shutdown so next start rotates a fresh
        // secret. No-op if auth wasn't enabled.
        if authToken != nil {
            SocketAuthToken.clear()
            authToken = nil
        }

        acceptSource?.cancel()
        acceptSource = nil
        hookAcceptSource?.cancel()
        hookAcceptSource = nil
        paneAcceptSource?.cancel()
        paneAcceptSource = nil

        if listenFD >= 0 {
            Darwin.close(listenFD)
            listenFD = -1
        }
        if hookListenFD >= 0 {
            Darwin.close(hookListenFD)
            hookListenFD = -1
        }
        if paneListenFD >= 0 {
            Darwin.close(paneListenFD)
            paneListenFD = -1
        }

        // Clean up socket files
        unlink(socketPath)
        unlink(hookSocketPath)
        unlink(paneSocketPath)

        // Cancel all active connection tasks
        let tasks = activeTasks
        activeTasks.removeAll()
        lock.unlock()

        for task in tasks {
            task.cancel()
        }
    }

    public var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    // MARK: - Private

    private func startListening() throws {
        let dir = (socketPath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        // Remove stale socket file
        unlink(socketPath)

        // Create socket
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw SocketError.createFailed(errno)
        }

        // Bind
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketPath.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            Darwin.close(fd)
            throw SocketError.pathTooLong
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { sunPath in
            pathBytes.withUnsafeBufferPointer { buf in
                let dest = UnsafeMutableRawPointer(sunPath)
                    .assumingMemoryBound(to: CChar.self)
                buf.baseAddress!.withMemoryRebound(to: CChar.self, capacity: buf.count) { src in
                    dest.update(from: src, count: buf.count)
                }
            }
        }

        let bindResult = withUnsafePointer(to: &addr) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                bind(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            Darwin.close(fd)
            throw SocketError.bindFailed(errno)
        }

        // Set permissions so only the user can connect
        chmod(socketPath, 0o600)

        // Listen
        guard Darwin.listen(fd, 5) == 0 else {
            Darwin.close(fd)
            throw SocketError.listenFailed(errno)
        }

        listenFD = fd

        // Use GCD to accept connections
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            self?.acceptConnection()
        }
        source.setCancelHandler { [weak self] in
            guard let self else { return }
            if self.listenFD >= 0 {
                Darwin.close(self.listenFD)
                self.listenFD = -1
            }
        }
        acceptSource = source
        source.resume()

        FileHandle.standardError.write(
            Data("[senkani] Socket server listening on \(socketPath)\n".utf8))
    }

    private func acceptConnection() {
        var clientAddr = sockaddr_un()
        var addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)

        let clientFD = withUnsafeMutablePointer(to: &clientAddr) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.accept(listenFD, sockaddrPtr, &addrLen)
            }
        }

        guard clientFD >= 0 else { return }

        lock.lock()
        // Sweep completed tasks
        activeTasks.removeAll { $0.isCancelled }

        // Enforce connection limit
        if activeTasks.count >= Self.maxConnections {
            lock.unlock()
            Darwin.close(clientFD)
            FileHandle.standardError.write(
                Data("[senkani] Connection limit reached (\(Self.maxConnections)), rejecting fd=\(clientFD)\n".utf8))
            return
        }
        lock.unlock()

        FileHandle.standardError.write(
            Data("[senkani] Socket client connected (fd=\(clientFD))\n".utf8))

        let task = Task {
            await handleConnection(fd: clientFD)
        }

        lock.lock()
        activeTasks.append(task)
        lock.unlock()
    }

    /// Maximum concurrent MCP connections. Rejects beyond this limit.
    private static let maxConnections = 20

    /// P2-12 + F1 fix (Schneier re-audit 2026-04-16): read the handshake
    /// frame on a freshly-accepted fd and validate, with a bounded wait.
    /// Returns true iff auth is disabled OR the handshake matches the active
    /// token within the timeout. The bounded wait is the defense against a
    /// same-UID DoS where a connected-but-silent attacker would otherwise
    /// hold a task slot indefinitely.
    private func validateHandshakeIfRequired(fd: Int32) -> Bool {
        lock.lock()
        let expected = authToken
        lock.unlock()
        guard let expected else { return true } // auth disabled → passthrough
        return SocketAuthToken.readAndValidate(fd: fd, expectedToken: expected)
    }

    private func handleConnection(fd: Int32) async {
        // P2-12: handshake gate before we wire up the MCP server.
        guard validateHandshakeIfRequired(fd: fd) else {
            Logger.log("socket.handshake.rejected", fields: [
                "socket": .string("mcp"),
                "outcome": .string("closed")
            ])
            SessionDatabase.shared.recordEvent(type: "security.socket.handshake.rejected")
            Darwin.close(fd)
            return
        }

        // Each connection uses the shared session (shared cache, index, etc.)
        let session = MCPSession.shared

        let baseInstructions = """
            Senkani is a token compression layer. Use senkani_read instead of reading files directly \
            for automatic compression and caching. senkani_read returns a compact outline by default — \
            pass full: true only when you need the complete file content. Use senkani_search and \
            senkani_fetch for token-efficient code navigation. Use senkani_exec for filtered command \
            execution. Call senkani_session with action 'stats' to see savings.
            """

        // P1-7: bounded instructions payload across the socket path too.
        let instructions = session.instructionsPayload(base: baseInstructions)

        let server = Server(
            name: "senkani",
            version: VersionTool.serverVersion,
            instructions: instructions,
            capabilities: .init(tools: .init(listChanged: false))
        )

        await ToolRouter.register(on: server, session: session)

        let transport = SocketTransport(fd: fd)
        do {
            try await server.start(transport: transport)

            // Non-blocking connection monitoring via GCD.
            // Uses DispatchSource instead of blocking poll() to avoid starving
            // Swift's cooperative thread pool.
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                var resumed = false
                let resumeOnce = {
                    guard !resumed else { return }
                    resumed = true
                    cont.resume()
                }

                let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: self.queue)
                src.setEventHandler {
                    // Non-blocking check: is the connection dead?
                    var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                    let r = poll(&pfd, 1, 0) // instant, non-blocking
                    if r < 0 || pfd.revents & Int16(POLLHUP | POLLERR | POLLNVAL) != 0 {
                        src.cancel()
                    }
                }
                src.setCancelHandler { resumeOnce() }
                src.resume()
            }
        } catch {
            if !Task.isCancelled {
                FileHandle.standardError.write(
                    Data("[senkani] Socket connection error: \(error)\n".utf8))
            }
        }

        // Ensure transport is disconnected
        await transport.disconnect()

        FileHandle.standardError.write(
            Data("[senkani] Socket client disconnected (fd=\(fd))\n".utf8))
    }

    // MARK: - Hook Listener

    /// Start a lightweight socket listener for hook events.
    /// Hook connections are short-lived: one request → one response → close.
    /// Uses length-prefixed binary protocol (4-byte big-endian length + JSON payload).
    private func startHookListening() throws {
        let dir = (hookSocketPath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        // Remove stale socket file
        unlink(hookSocketPath)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw SocketError.createFailed(errno)
        }

        // Bind
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = hookSocketPath.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            Darwin.close(fd)
            throw SocketError.pathTooLong
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { sunPath in
            pathBytes.withUnsafeBufferPointer { buf in
                let dest = UnsafeMutableRawPointer(sunPath).assumingMemoryBound(to: CChar.self)
                buf.baseAddress!.withMemoryRebound(to: CChar.self, capacity: buf.count) { src in
                    dest.update(from: src, count: buf.count)
                }
            }
        }

        let bindResult = withUnsafePointer(to: &addr) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                bind(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            Darwin.close(fd)
            throw SocketError.bindFailed(errno)
        }

        chmod(hookSocketPath, 0o600)

        guard Darwin.listen(fd, 16) == 0 else {
            Darwin.close(fd)
            throw SocketError.listenFailed(errno)
        }

        hookListenFD = fd

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: hookQueue)
        source.setEventHandler { [weak self] in
            self?.acceptHookConnection()
        }
        source.setCancelHandler { [weak self] in
            guard let self else { return }
            if self.hookListenFD >= 0 {
                Darwin.close(self.hookListenFD)
                self.hookListenFD = -1
            }
        }
        hookAcceptSource = source
        source.resume()

        FileHandle.standardError.write(
            Data("[senkani] Hook socket server listening on \(hookSocketPath)\n".utf8))
    }

    private func acceptHookConnection() {
        var clientAddr = sockaddr_un()
        var addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)

        let clientFD = withUnsafeMutablePointer(to: &clientAddr) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.accept(hookListenFD, sockaddrPtr, &addrLen)
            }
        }
        guard clientFD >= 0 else { return }

        // Handle on hookQueue — fast, synchronous, no async overhead
        hookQueue.async { [self] in
            defer { Darwin.close(clientFD) }

            // P2-12: handshake gate before normal frame read.
            guard self.validateHandshakeIfRequired(fd: clientFD) else {
                Logger.log("socket.handshake.rejected", fields: [
                    "socket": .string("hook"),
                    "outcome": .string("closed")
                ])
                SessionDatabase.shared.recordEvent(type: "security.socket.handshake.rejected")
                return
            }

            // Read 4-byte length prefix
            var lengthBytes = [UInt8](repeating: 0, count: 4)
            let readLen = Darwin.read(clientFD, &lengthBytes, 4)
            guard readLen == 4 else { return }

            let payloadLength = Int(UInt32(bigEndian: Data(lengthBytes).withUnsafeBytes { $0.load(as: UInt32.self) }))
            guard payloadLength > 0, payloadLength < 65536 else { return }

            // Read payload
            var payload = Data(count: payloadLength)
            var totalRead = 0
            while totalRead < payloadLength {
                let n = payload.withUnsafeMutableBytes { buf in
                    Darwin.read(clientFD, buf.baseAddress! + totalRead, payloadLength - totalRead)
                }
                if n <= 0 { break }
                totalRead += n
            }
            guard totalRead == payloadLength else { return }

            let eventData = payload

            // Call handler
            let response: Data
            if let handler = self.hookHandler {
                response = handler(eventData)
            } else {
                response = Data("{}".utf8)
            }

            // Send response: 4-byte length prefix + JSON
            var respLength = UInt32(response.count).bigEndian
            let respLengthData = Data(bytes: &respLength, count: 4)
            _ = respLengthData.withUnsafeBytes { Darwin.write(clientFD, $0.baseAddress!, 4) }
            _ = response.withUnsafeBytes { Darwin.write(clientFD, $0.baseAddress!, response.count) }
        }
    }

    // MARK: - Pane Listener (socket-based IPC for pane control)

    /// Start listening for pane control commands on pane.sock.
    /// Same length-prefixed protocol as hook.sock, separate queue.
    private func startPaneListening() throws {
        let dir = (paneSocketPath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        unlink(paneSocketPath)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError.createFailed(errno) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = paneSocketPath.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            Darwin.close(fd)
            throw SocketError.pathTooLong
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { sunPath in
            pathBytes.withUnsafeBufferPointer { buf in
                let dest = UnsafeMutableRawPointer(sunPath).assumingMemoryBound(to: CChar.self)
                buf.baseAddress!.withMemoryRebound(to: CChar.self, capacity: buf.count) { src in
                    dest.update(from: src, count: buf.count)
                }
            }
        }

        let bindResult = withUnsafePointer(to: &addr) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                bind(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            Darwin.close(fd)
            throw SocketError.bindFailed(errno)
        }

        chmod(paneSocketPath, 0o600)

        guard Darwin.listen(fd, 8) == 0 else {
            Darwin.close(fd)
            throw SocketError.listenFailed(errno)
        }

        paneListenFD = fd

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: paneQueue)
        source.setEventHandler { [weak self] in self?.acceptPaneConnection() }
        source.setCancelHandler { [weak self] in
            guard let self else { return }
            if self.paneListenFD >= 0 {
                Darwin.close(self.paneListenFD)
                self.paneListenFD = -1
            }
        }
        paneAcceptSource = source
        source.resume()

        FileHandle.standardError.write(
            Data("[senkani] Pane socket server listening on \(paneSocketPath)\n".utf8))
    }

    private func acceptPaneConnection() {
        var clientAddr = sockaddr_un()
        var addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)

        let clientFD = withUnsafeMutablePointer(to: &clientAddr) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.accept(paneListenFD, sockaddrPtr, &addrLen)
            }
        }
        guard clientFD >= 0 else { return }

        paneQueue.async { [self] in
            defer { Darwin.close(clientFD) }

            // P2-12: handshake gate before normal frame read.
            guard self.validateHandshakeIfRequired(fd: clientFD) else {
                Logger.log("socket.handshake.rejected", fields: [
                    "socket": .string("pane"),
                    "outcome": .string("closed")
                ])
                SessionDatabase.shared.recordEvent(type: "security.socket.handshake.rejected")
                return
            }

            // Read 4-byte length prefix
            var lengthBytes = [UInt8](repeating: 0, count: 4)
            let readLen = Darwin.read(clientFD, &lengthBytes, 4)
            guard readLen == 4 else { return }

            let payloadLength = Int(UInt32(bigEndian: Data(lengthBytes).withUnsafeBytes { $0.load(as: UInt32.self) }))
            guard payloadLength > 0, payloadLength < 65536 else { return }

            // Read payload
            var payload = Data(count: payloadLength)
            var totalRead = 0
            while totalRead < payloadLength {
                let n = payload.withUnsafeMutableBytes { buf in
                    Darwin.read(clientFD, buf.baseAddress! + totalRead, payloadLength - totalRead)
                }
                if n <= 0 { break }
                totalRead += n
            }
            guard totalRead == payloadLength else { return }

            // Call handler
            let response: Data
            if let handler = self.paneHandler {
                response = handler(payload)
            } else {
                response = Data("{\"id\":\"unknown\",\"success\":false,\"error\":\"No pane handler registered\"}".utf8)
            }

            // Send response: 4-byte length prefix + JSON
            var respLength = UInt32(response.count).bigEndian
            let respLengthData = Data(bytes: &respLength, count: 4)
            _ = respLengthData.withUnsafeBytes { Darwin.write(clientFD, $0.baseAddress!, 4) }
            _ = response.withUnsafeBytes { Darwin.write(clientFD, $0.baseAddress!, response.count) }
        }
    }

    enum SocketError: Error, LocalizedError {
        case createFailed(Int32)
        case bindFailed(Int32)
        case listenFailed(Int32)
        case pathTooLong

        var errorDescription: String? {
            switch self {
            case .createFailed(let e): return "socket() failed: \(String(cString: strerror(e)))"
            case .bindFailed(let e): return "bind() failed: \(String(cString: strerror(e)))"
            case .listenFailed(let e): return "listen() failed: \(String(cString: strerror(e)))"
            case .pathTooLong: return "Socket path exceeds sockaddr_un limit"
            }
        }
    }
}
