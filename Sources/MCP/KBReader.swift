import Core

/// Public read bridge: exposes the registry's default-session KB properties
/// to SenkaniApp. `MCPSession` is internal to MCPServer — KBReader is the
/// only safe crossing point.
///
/// All getters are `async`: the actor isolation IS the SenkaniApp contract.
/// The underlying reads currently land on `nonisolated let` fields of
/// `MCPSession` (the references themselves are immutable Sendable; the
/// referenced types manage their own thread safety), so the async hop is a
/// contract guarantee rather than a real suspension. If a future
/// multi-project daemon ever moves these fields to actor-isolated storage,
/// the SenkaniApp surface won't break.
public enum KBReader {
    public static var store: KnowledgeStore {
        get async { MCPSessionRegistry.shared.ensureDefaultSession().knowledgeStore }
    }
    public static var tracker: EntityTracker {
        get async { MCPSessionRegistry.shared.ensureDefaultSession().entityTracker }
    }
    public static var layer: KnowledgeFileLayer? {
        get async { MCPSessionRegistry.shared.ensureDefaultSession().knowledgeLayer }
    }
    public static var projectRoot: String {
        get async { MCPSessionRegistry.shared.ensureDefaultSession().projectRoot }
    }
}
