import Testing
import Foundation
@testable import Core

// MARK: - Pane IPC Protocol Tests

@Suite("senkani_pane — IPC Protocol")
struct PaneSocketTests {

    @Test func commandEncodesCorrectly() throws {
        let command = PaneIPCCommand(action: .list)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(command)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        #expect(json["action"] as? String == "list")
        #expect(json["id"] as? String != nil)
    }

    @Test func responseDecodesCorrectly() throws {
        let json = """
        {"id":"test-id","success":true,"result":"3 panes"}
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(PaneIPCResponse.self, from: json)
        #expect(response.success == true)
        #expect(response.result == "3 panes")
        #expect(response.id == "test-id")
    }

    @Test func errorResponseDecodesCorrectly() throws {
        let json = """
        {"id":"test-id","success":false,"error":"pane not found"}
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(PaneIPCResponse.self, from: json)
        #expect(response.success == false)
        #expect(response.error == "pane not found")
    }

    @Test func allActionsRoundTrip() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        for action in [PaneIPCAction.list, .add, .remove, .setActive] {
            let cmd = PaneIPCCommand(action: action, params: ["type": "terminal"])
            let data = try encoder.encode(cmd)
            let decoded = try decoder.decode(PaneIPCCommand.self, from: data)
            #expect(decoded.action == action)
            #expect(decoded.params["type"] == "terminal")
        }
    }

    @Test func commandParamsPreserved() throws {
        let cmd = PaneIPCCommand(action: .add, params: [
            "type": "browser",
            "title": "Test",
            "url": "http://localhost:3000",
        ])

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(cmd)
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let decoded = try dec.decode(PaneIPCCommand.self, from: data)

        #expect(decoded.params["type"] == "browser")
        #expect(decoded.params["title"] == "Test")
        #expect(decoded.params["url"] == "http://localhost:3000")
    }

    @Test func connectionRefusedProducesError() {
        // Try connecting to a non-existent socket path
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        defer { Darwin.close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let fakePath = "/tmp/senkani-nonexistent-\(UUID().uuidString).sock"
        withUnsafeMutableBytes(of: &addr.sun_path) { rawBuf in
            fakePath.withCString { cstr in
                let count = min(strlen(cstr) + 1, rawBuf.count)
                rawBuf.baseAddress!.copyMemory(from: cstr, byteCount: count)
            }
        }

        let result = withUnsafePointer(to: &addr) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.connect(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }

        #expect(result != 0, "Connection to nonexistent socket should fail")
    }
}
