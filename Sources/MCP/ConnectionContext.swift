import Foundation

/// Per-connection routing + identity context threaded through `ToolRouter`.
///
/// One value lives for the lifetime of a single MCP connection (or, for the
/// stdio server, the lifetime of the process). It carries:
/// - `connectionId` — UUID minted on socket accept; tags metrics so per-
///   connection vs aggregate views can both be recovered.
/// - `projectRoot` — the project this connection serves; the registry key.
///
/// Phase B-ii will extend this with `toggleOverrides:` for per-connection
/// feature-toggle overrides without mutating the shared session's defaults.
public struct ConnectionContext: Sendable {
    public let connectionId: String
    public let projectRoot: String

    public init(connectionId: String, projectRoot: String) {
        self.connectionId = connectionId
        self.projectRoot = projectRoot
    }

    /// Synthesize a stdio-mode context from a session's project root. Used
    /// by `MCPMain` (single-connection stdio path) and existing tests that
    /// don't yet pass a context explicitly.
    static func stdio(session: MCPSession) -> ConnectionContext {
        ConnectionContext(connectionId: "stdio", projectRoot: session.projectRoot)
    }
}
