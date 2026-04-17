import Testing
import Foundation
import MCP
@testable import MCPServer
@testable import Core

/// P1-5: senkani_version tool. Exercises both the static constants and
/// the live handler so a schema/shape regression is caught by the test
/// suite instead of the next client update.
@Suite("VersionTool")
struct VersionToolTests {

    // MARK: - Constants

    @Test func serverVersionMatchesExpectedBump() {
        // If you intentionally bump the server version, update this constant.
        #expect(VersionTool.serverVersion == "0.2.0")
    }

    @Test func toolSchemasVersionIsAtLeastOne() {
        #expect(VersionTool.toolSchemasVersion >= 1)
    }

    @Test func serverVersionFollowsSemverShape() {
        // Guards against accidentally writing "v0.2.0" or "0.2" — clients
        // cache by exact string match, so the shape has to stay MAJOR.MINOR.PATCH.
        let parts = VersionTool.serverVersion.split(separator: ".")
        #expect(parts.count == 3, "server version must be MAJOR.MINOR.PATCH")
        for part in parts {
            #expect(Int(part) != nil, "version component '\(part)' must be a non-negative integer")
        }
    }

    // MARK: - Routing

    @Test func routerRegistersVersionTool() {
        let names = ToolRouter.allTools().map { $0.name }
        #expect(names.contains("version"), "version tool must be in allTools()")
    }

    // MARK: - Handler output shape (the client contract)

    /// Helper — call handle() with an ad-hoc session and parse its JSON.
    private func decodePayload() throws -> [String: Any] {
        let root = NSTemporaryDirectory() + "senkani-version-test-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }

        let session = MCPSession(
            projectRoot: root,
            filterEnabled: false,
            secretsEnabled: false,
            indexerEnabled: false,
            cacheEnabled: false
        )
        let result = VersionTool.handle(arguments: nil, session: session)

        guard case .text(let body, _, _) = result.content.first else {
            Issue.record("handle() must return a text content block")
            return [:]
        }
        let data = Data(body.utf8)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            Issue.record("handle() must return valid JSON; got: \(body)")
            return [:]
        }
        return obj
    }

    @Test func handlerReturnsAllRequiredKeys() throws {
        let payload = try decodePayload()
        #expect(payload["server_version"] as? String == VersionTool.serverVersion)
        #expect(payload["tool_schemas_version"] as? Int == VersionTool.toolSchemasVersion)
        #expect(payload["schema_db_version"] is Int, "schema_db_version must be numeric")
        #expect(payload["tools"] is [Any], "tools must be a JSON array")
    }

    @Test func handlerToolsArrayMatchesRouter() throws {
        let payload = try decodePayload()
        guard let tools = payload["tools"] as? [String] else {
            Issue.record("tools array must be [String]")
            return
        }
        let expected = ToolRouter.allTools().map { $0.name }.sorted()
        #expect(tools == expected, "handler's tools list must match ToolRouter.allTools() exactly (sorted)")
    }

    @Test func handlerToolsArrayIsSorted() throws {
        let payload = try decodePayload()
        guard let tools = payload["tools"] as? [String] else {
            Issue.record("tools array must be [String]")
            return
        }
        #expect(tools == tools.sorted(), "tools must be returned sorted for client cache stability")
    }

    @Test func handlerOutputIsNotMarkedAsError() throws {
        let root = NSTemporaryDirectory() + "senkani-version-test-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }

        let session = MCPSession(
            projectRoot: root,
            filterEnabled: false,
            secretsEnabled: false,
            indexerEnabled: false,
            cacheEnabled: false
        )
        let result = VersionTool.handle(arguments: nil, session: session)
        #expect(result.isError != true, "version tool must never return isError=true")
    }
}
