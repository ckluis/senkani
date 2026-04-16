import Core

/// Public read bridge: exposes MCPSession.shared's KB properties to SenkaniApp.
/// MCPSession is internal to MCPServer — KBReader is the only safe crossing point.
public enum KBReader {
    public static var store: KnowledgeStore      { MCPSession.shared.knowledgeStore }
    public static var tracker: EntityTracker     { MCPSession.shared.entityTracker }
    public static var layer: KnowledgeFileLayer? { MCPSession.shared.knowledgeLayer }
    public static var projectRoot: String        { MCPSession.shared.projectRoot }
}
