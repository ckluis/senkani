import Foundation
import Core

/// Process-global registry of MCPSession actors keyed by project root.
///
/// Replaces the legacy `MCPSession.shared` singleton. The daemon (socket
/// server) and stdio MCP server both acquire their session here. Sessions
/// are created lazily via `bootstrap()` when first needed, then reused for
/// every subsequent acquisition of the same project root.
///
/// Thread safety: `MCPSessionRegistry` is `Sendable` via an internal NSLock-
/// guarded dictionary. The lock guards a small dictionary of references; the
/// `MCPSession` actor itself is the unit of mutable-state isolation. This
/// split keeps `KBReader`'s synchronous SenkaniApp contract intact (it reads
/// `nonisolated let` fields on the actor) while still letting socket-server
/// connections that target different project roots receive distinct sessions.
public final class MCPSessionRegistry: @unchecked Sendable {
    public static let shared = MCPSessionRegistry()

    private let lock = NSLock()
    private var sessions: [String: MCPSession] = [:]
    private var defaultRoot: String?

    public init() {}

    /// Acquire (or lazily create) the session for `projectRoot`.
    ///
    /// `factory` runs synchronously while the registry lock is held, so
    /// keep it short — it's only invoked once per new project root. The
    /// first session created becomes the default for KBReader / KBObserver.
    func session(projectRoot: String, factory: () -> MCPSession) -> MCPSession {
        let normalized = URL(fileURLWithPath: projectRoot).standardized.path
        lock.lock()
        defer { lock.unlock() }
        if let existing = sessions[normalized] { return existing }
        let s = factory()
        sessions[normalized] = s
        if defaultRoot == nil { defaultRoot = normalized }
        return s
    }

    /// Return the default-process session if any has been registered.
    /// Used by `KBReader` and `KBObserver` to bridge into the SenkaniApp
    /// process context (one project, one default).
    func defaultSession() -> MCPSession? {
        lock.lock()
        defer { lock.unlock() }
        guard let root = defaultRoot else { return nil }
        return sessions[root]
    }

    /// Lazily create the default session from environment variables. Used by
    /// `KBReader` when SenkaniApp queries before any explicit bootstrap.
    /// Idempotent: subsequent calls return the cached default.
    func ensureDefaultSession() -> MCPSession {
        if let s = defaultSession() { return s }
        let bootstrapped = MCPSession.resolve()
        let resolvedRoot = bootstrapped.projectRoot
        return self.session(projectRoot: resolvedRoot) { bootstrapped }
    }

    /// Replace the default session (testing seam). Removes all previously
    /// registered sessions. NOT for production use.
    internal func _reset() {
        lock.lock()
        defer { lock.unlock() }
        sessions.removeAll()
        defaultRoot = nil
    }

    /// Test-only: count of currently registered sessions.
    internal var _count: Int {
        lock.lock()
        defer { lock.unlock() }
        return sessions.count
    }
}
