import Foundation

/// Per-connection routing + identity context threaded through `ToolRouter`.
///
/// One value lives for the lifetime of a single MCP connection (or, for the
/// stdio server, the lifetime of the process). It carries:
/// - `connectionId` — UUID minted on socket accept; tags metrics so per-
///   connection vs aggregate views can both be recovered.
/// - `projectRoot` — the project this connection serves; the registry key.
/// - `toggleOverrides` — Phase B-ii per-connection feature-toggle overrides.
///   `nil` (default) preserves the session-wide toggle behaviour.
struct ConnectionContext: Sendable {
    let connectionId: String
    let projectRoot: String
    let toggleOverrides: MCPSession.ToggleOverrides?

    init(
        connectionId: String,
        projectRoot: String,
        toggleOverrides: MCPSession.ToggleOverrides? = nil
    ) {
        self.connectionId = connectionId
        self.projectRoot = projectRoot
        self.toggleOverrides = toggleOverrides
    }

    /// Synthesize a stdio-mode context from a session's project root. Used
    /// by `MCPMain` (single-connection stdio path) and existing tests that
    /// don't yet pass a context explicitly.
    static func stdio(session: MCPSession) -> ConnectionContext {
        ConnectionContext(
            connectionId: "stdio",
            projectRoot: session.projectRoot,
            toggleOverrides: nil
        )
    }
}
