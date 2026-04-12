// senkani-hook — compiled Claude Code hook binary
// Zero dependencies beyond Foundation. Reads hook event from stdin,
// relays to the Senkani daemon via Unix socket, writes response to stdout.
// On ANY failure: exits 0 with empty JSON (passthrough — never block the agent).

import Foundation
#if canImport(Darwin)
import Darwin.POSIX
#endif

// MARK: - Configuration

let socketPath = NSHomeDirectory() + "/.senkani/hook.sock"
let timeoutMs: UInt32 = 5 // 5ms — hooks must be imperceptible

// MARK: - Entry Point

func hookMain() -> Int32 {
    // Check activation env vars
    let intercept = ProcessInfo.processInfo.environment["SENKANI_INTERCEPT"] ?? "off"
    let hookEnabled = ProcessInfo.processInfo.environment["SENKANI_HOOK"] ?? "off"
    guard intercept == "on" || hookEnabled == "on" else {
        passthrough()
        return 0
    }

    // Read hook event JSON from stdin
    let inputData = FileHandle.standardInput.readDataToEndOfFile()
    guard !inputData.isEmpty else {
        passthrough()
        return 0
    }

    // Connect to daemon socket
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else {
        passthrough()
        return 0
    }
    defer { Darwin.close(fd) }

    // Set non-blocking for timeout control
    let flags = fcntl(fd, F_GETFL)
    _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

    // Build sockaddr_un
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = socketPath.utf8CString
    guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
        passthrough()
        return 0
    }
    withUnsafeMutablePointer(to: &addr.sun_path) { sunPath in
        pathBytes.withUnsafeBufferPointer { buf in
            let dest = UnsafeMutableRawPointer(sunPath).assumingMemoryBound(to: CChar.self)
            buf.baseAddress!.withMemoryRebound(to: CChar.self, capacity: buf.count) { src in
                dest.update(from: src, count: buf.count)
            }
        }
    }

    // Connect
    let connectResult = withUnsafePointer(to: &addr) { addrPtr in
        addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
            Darwin.connect(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }

    if connectResult != 0 && errno != EINPROGRESS {
        passthrough()
        return 0
    }

    // Wait for connect with poll (5ms timeout)
    var pollFD = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
    let pollResult = poll(&pollFD, 1, Int32(timeoutMs))
    guard pollResult > 0 else {
        passthrough()
        return 0
    }

    // Switch back to blocking for write/read
    _ = fcntl(fd, F_SETFL, flags)

    // Send: 4-byte length prefix + JSON payload
    var length = UInt32(inputData.count).bigEndian
    let lengthData = Data(bytes: &length, count: 4)
    let sent1 = lengthData.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!, 4) }
    guard sent1 == 4 else { passthrough(); return 0 }

    let sent2 = inputData.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!, inputData.count) }
    guard sent2 == inputData.count else { passthrough(); return 0 }

    // Read response: 4-byte length prefix + JSON
    // Use poll for read timeout
    pollFD = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
    let readPoll = poll(&pollFD, 1, Int32(timeoutMs))
    guard readPoll > 0 else {
        passthrough()
        return 0
    }

    var respLengthBytes = [UInt8](repeating: 0, count: 4)
    let readLen = Darwin.read(fd, &respLengthBytes, 4)
    guard readLen == 4 else { passthrough(); return 0 }

    let respLength = Int(UInt32(bigEndian: Data(respLengthBytes).withUnsafeBytes { $0.load(as: UInt32.self) }))
    guard respLength > 0, respLength < 65536 else { passthrough(); return 0 }

    var respBuffer = Data(count: respLength)
    var totalRead = 0
    while totalRead < respLength {
        let n = respBuffer.withUnsafeMutableBytes { buf in
            Darwin.read(fd, buf.baseAddress! + totalRead, respLength - totalRead)
        }
        if n <= 0 { break }
        totalRead += n
    }
    guard totalRead == respLength else { passthrough(); return 0 }

    // Write response to stdout
    FileHandle.standardOutput.write(respBuffer)
    return 0
}

func passthrough() {
    // Empty JSON object = "no opinion, let the tool proceed"
    FileHandle.standardOutput.write(Data("{}".utf8))
}

exit(hookMain())
