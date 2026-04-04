import Foundation
import MCP
import Logging

#if canImport(System)
import System
#else
@preconcurrency import SystemPackage
#endif

#if canImport(Darwin)
import Darwin.POSIX
#endif

/// MCP Transport that wraps a Unix domain socket file descriptor.
/// Each accepted client connection gets its own SocketTransport instance.
public actor SocketTransport: Transport {
    public nonisolated let logger: Logger

    private let fd: Int32
    private var isConnected = false
    private let messageStream: AsyncThrowingStream<Data, Swift.Error>
    private let messageContinuation: AsyncThrowingStream<Data, Swift.Error>.Continuation

    public init(fd: Int32, logger: Logger? = nil) {
        self.fd = fd
        self.logger = logger ?? Logger(
            label: "mcp.transport.socket",
            factory: { _ in SwiftLogNoOpLogHandler() }
        )

        var continuation: AsyncThrowingStream<Data, Swift.Error>.Continuation!
        self.messageStream = AsyncThrowingStream { continuation = $0 }
        self.messageContinuation = continuation
    }

    public func connect() async throws {
        guard !isConnected else { return }

        // Set non-blocking
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0 else {
            throw MCPError.transportError(Errno(rawValue: CInt(errno)))
        }
        let result = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        guard result >= 0 else {
            throw MCPError.transportError(Errno(rawValue: CInt(errno)))
        }

        isConnected = true
        logger.debug("Socket transport connected (fd=\(fd))")

        Task { await readLoop() }
    }

    private func readLoop() async {
        let bufferSize = 4096
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        var pendingData = Data()

        while isConnected && !Task.isCancelled {
            let bytesRead = buffer.withUnsafeMutableBufferPointer { ptr -> Int in
                let raw = UnsafeMutableRawPointer(ptr.baseAddress!)
                return Darwin.read(fd, raw, bufferSize)
            }

            if bytesRead > 0 {
                pendingData.append(Data(buffer[..<bytesRead]))

                while let newlineIndex = pendingData.firstIndex(of: UInt8(ascii: "\n")) {
                    let messageData = pendingData[..<newlineIndex]
                    pendingData = pendingData[(newlineIndex + 1)...]
                    if !messageData.isEmpty {
                        messageContinuation.yield(Data(messageData))
                    }
                }
            } else if bytesRead == 0 {
                // EOF
                break
            } else {
                let err = errno
                if err == EAGAIN || err == EWOULDBLOCK {
                    try? await Task.sleep(for: .milliseconds(10))
                    continue
                }
                logger.error("Socket read error: \(err)")
                break
            }
        }

        messageContinuation.finish()
    }

    public func disconnect() async {
        guard isConnected else { return }
        isConnected = false
        messageContinuation.finish()
        Darwin.close(fd)
        logger.debug("Socket transport disconnected (fd=\(fd))")
    }

    public func send(_ message: Data) async throws {
        guard isConnected else {
            throw MCPError.transportError(Errno(rawValue: ENOTCONN))
        }

        var messageWithNewline = message
        messageWithNewline.append(UInt8(ascii: "\n"))

        var remaining = messageWithNewline
        while !remaining.isEmpty {
            let written = remaining.withUnsafeBytes { buf -> Int in
                Darwin.write(fd, buf.baseAddress!, buf.count)
            }

            if written > 0 {
                remaining = remaining.dropFirst(written)
            } else {
                let err = errno
                if err == EAGAIN || err == EWOULDBLOCK {
                    try await Task.sleep(for: .milliseconds(10))
                    continue
                }
                throw MCPError.transportError(Errno(rawValue: CInt(err)))
            }
        }
    }

    public func receive() -> AsyncThrowingStream<Data, Swift.Error> {
        messageStream
    }
}
