import Foundation
import MCP
import Core

/// P1-5: `senkani_version` tool — version negotiation surface for MCP clients.
///
/// Returns:
/// - `server_version`: the MCP server string (matches `Server(name:, version:)`).
/// - `tool_schemas_version`: increments on ANY breaking change to a tool's input schema
///   or output contract. Clients can cache schemas keyed on this number.
/// - `schema_db_version`: the current `PRAGMA user_version` from the session DB.
///   Diagnostic signal for migration troubleshooting.
/// - `tools`: names of every tool exposed by this server (discovery helper).
///
/// Stability policy: this tool itself is stable. Clients that depend on version
/// negotiation can call it without worrying about its schema changing.
public enum VersionTool {

    /// Incremented on any breaking change to a tool's schema (args, return shape, or
    /// semantic contract). Document the change in CHANGELOG when bumping this.
    public static let toolSchemasVersion = 1

    /// Bumped alongside any user-visible behavior change. Kept in sync with
    /// `Server(name:, version:)` in MCPMain + SocketServer.
    public static let serverVersion = "0.2.0"

    static func handle(arguments _: [String: Value]?, session _: MCPSession) -> CallTool.Result {
        let dbVersion = SessionDatabase.shared.currentSchemaVersion()
        let toolNames = ToolRouter.allTools().map { $0.name }.sorted()

        // Hand-roll JSON so we keep this dependency-light and avoid Value/AnyCodable.
        var parts: [String] = []
        parts.append("\"server_version\": \"\(serverVersion)\"")
        parts.append("\"tool_schemas_version\": \(toolSchemasVersion)")
        parts.append("\"schema_db_version\": \(dbVersion)")
        let toolList = toolNames.map { "\"\($0)\"" }.joined(separator: ", ")
        parts.append("\"tools\": [\(toolList)]")
        let body = "{ " + parts.joined(separator: ", ") + " }"

        return .init(content: [.text(text: body, annotations: nil, _meta: nil)])
    }
}
