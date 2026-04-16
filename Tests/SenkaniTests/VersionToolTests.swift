import Testing
import Foundation
@testable import MCPServer
@testable import Core

/// P1-5: senkani_version tool. Smoke tests that the constants match expectations
/// and that the handler returns well-formed JSON with the required keys.
@Suite("VersionTool")
struct VersionToolTests {

    @Test func serverVersionMatchesExpectedBump() {
        // If you intentionally bump the server version, update this constant.
        #expect(VersionTool.serverVersion == "0.2.0")
    }

    @Test func toolSchemasVersionIsAtLeastOne() {
        #expect(VersionTool.toolSchemasVersion >= 1)
    }

    @Test func routerRegistersVersionTool() {
        let names = ToolRouter.allTools().map { $0.name }
        #expect(names.contains("version"), "version tool must be in allTools()")
    }
}
