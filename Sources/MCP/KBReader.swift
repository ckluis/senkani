import Core

/// Public read bridge: exposes the registry's default-session KB properties
/// to SenkaniApp. `MCPSession` is internal to MCPServer — KBReader is the
/// only safe crossing point.
///
/// Phase B-iii follow-up will migrate these getters to `async`. Until then,
/// reads are synchronous via the `nonisolated let` fields on the underlying
/// actor (Phase A foundation).
public enum KBReader {
    public static var store: KnowledgeStore      { MCPSessionRegistry.shared.ensureDefaultSession().knowledgeStore }
    public static var tracker: EntityTracker     { MCPSessionRegistry.shared.ensureDefaultSession().entityTracker }
    public static var layer: KnowledgeFileLayer? { MCPSessionRegistry.shared.ensureDefaultSession().knowledgeLayer }
    public static var projectRoot: String        { MCPSessionRegistry.shared.ensureDefaultSession().projectRoot }
}
