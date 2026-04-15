import Testing
import Foundation
@testable import Core

@Suite("Daemon Health Check")
struct DaemonHealthTests {

    @Test func missingSocketFails() {
        let path = "/tmp/senkani-health-nonexistent-\(UUID().uuidString).sock"
        let result = DaemonHealthCheck.check(socketPath: path, timeoutMs: 100)
        #expect(result == .fail, "Missing socket should return .fail")
    }

    @Test func responsiveSocketPasses() {
        // Create a real listening socket
        let path = "/tmp/senkani-health-test-\(UUID().uuidString).sock"
        defer { unlink(path) }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        defer { Darwin.close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = path.utf8CString
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
        guard bindResult == 0 else { return }
        guard Darwin.listen(fd, 1) == 0 else { return }

        let result = DaemonHealthCheck.check(socketPath: path, timeoutMs: 1000)
        #expect(result == .pass, "Responsive socket should return .pass")
    }

    @Test func regularFileNotSocket() {
        // Create a regular file (not a socket) — connect should fail
        let path = "/tmp/senkani-health-file-\(UUID().uuidString).sock"
        FileManager.default.createFile(atPath: path, contents: Data("not a socket".utf8))
        defer { try? FileManager.default.removeItem(atPath: path) }

        let result = DaemonHealthCheck.check(socketPath: path, timeoutMs: 100)
        #expect(result == .fail, "Regular file should return .fail")
    }
}
