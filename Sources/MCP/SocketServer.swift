import Foundation
import MCP

#if canImport(Darwin)
import Darwin.POSIX
#endif

/// Unix domain socket MCP server.
/// Listens on ~/.senkani/mcp.sock, accepts multiple connections, each getting
/// its own MCP Server + SocketTransport backed by the shared MCPSession.
public final class SocketServerManager: @unchecked Sendable {
    public static let shared = SocketServerManager()

    private let socketPath: String
    private var listenFD: Int32 = -1
    private var running = false
    private let queue = DispatchQueue(label: "com.senkani.socket-server", qos: .utility)
    private var acceptSource: DispatchSourceRead?
    private var activeTasks: [Task<Void, Never>] = []
    private let lock = NSLock()

    private init() {
        let senkaniDir = NSHomeDirectory() + "/.senkani"
        self.socketPath = senkaniDir + "/mcp.sock"
    }

    /// Start listening for connections.
    public func start() {
        lock.lock()
        guard !running else { lock.unlock(); return }
        running = true
        lock.unlock()

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
    }

    /// Stop accepting new connections and close the listener.
    public func stop() {
        lock.lock()
        guard running else { lock.unlock(); return }
        running = false

        acceptSource?.cancel()
        acceptSource = nil

        if listenFD >= 0 {
            Darwin.close(listenFD)
            listenFD = -1
        }

        // Clean up socket file
        unlink(socketPath)

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

        FileHandle.standardError.write(
            Data("[senkani] Socket client connected (fd=\(clientFD))\n".utf8))

        let task = Task {
            await handleConnection(fd: clientFD)
        }

        lock.lock()
        activeTasks.append(task)
        lock.unlock()
    }

    private func handleConnection(fd: Int32) async {
        // Each connection uses the shared session (shared cache, index, etc.)
        let session = MCPSession.shared

        let server = Server(
            name: "senkani",
            version: "0.1.0",
            instructions: """
            Senkani is a token compression layer. Use senkani_read instead of reading files directly \
            for automatic compression and caching. Use senkani_search and senkani_fetch for \
            token-efficient code navigation. Use senkani_exec for filtered command execution. \
            Call senkani_session with action 'stats' to see savings.
            """,
            capabilities: .init(tools: .init(listChanged: false))
        )

        await ToolRouter.register(on: server, session: session)

        let transport = SocketTransport(fd: fd)
        do {
            try await server.start(transport: transport)
            // Keep alive until transport closes
            try await Task.sleep(for: .seconds(315_360_000))
        } catch {
            if !Task.isCancelled {
                FileHandle.standardError.write(
                    Data("[senkani] Socket connection error: \(error)\n".utf8))
            }
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
