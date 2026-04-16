import Foundation
import CoreGraphics

// MARK: - Graph types (shared between KBPaneViewModel and tests)

public struct GraphNode: Identifiable, Sendable {
    public let id: Int64
    public let name: String
    public let entityType: String
    public let isRoot: Bool
    public var position: CGPoint

    public init(id: Int64, name: String, entityType: String, isRoot: Bool,
                position: CGPoint = .zero) {
        self.id = id; self.name = name
        self.entityType = entityType; self.isRoot = isRoot
        self.position = position
    }
}

public struct GraphEdge: Identifiable, Sendable {
    public let id: UUID
    public let sourceId: Int64
    public let targetName: String
    public let relation: String?

    public init(sourceId: Int64, targetName: String, relation: String?) {
        self.id = UUID()
        self.sourceId = sourceId
        self.targetName = targetName
        self.relation = relation
    }
}

// MARK: - Fruchterman-Reingold spring layout

/// Off-main-thread pure computation. Root node is pinned to its initial position.
public func springLayout(
    nodes inputNodes: [GraphNode],
    edges: [GraphEdge],
    size: CGSize,
    iterations: Int = 150
) -> [GraphNode] {
    guard inputNodes.count > 1 else { return inputNodes }
    var nodes = inputNodes
    let n = nodes.count
    let k = (Double(size.width * size.height) / Double(n)).squareRoot()
    var temp = Double(size.width) / 10.0

    let idToIdx   = Dictionary(uniqueKeysWithValues: nodes.enumerated().map { ($1.id, $0) })
    let nameToIdx = Dictionary(uniqueKeysWithValues: nodes.enumerated().map { ($1.name, $0) })
    let edgePairs: [(Int, Int)] = edges.compactMap { e in
        guard let si = idToIdx[e.sourceId], let ti = nameToIdx[e.targetName] else { return nil }
        return (si, ti)
    }

    for _ in 0..<iterations {
        var dx = [Double](repeating: 0, count: n)
        var dy = [Double](repeating: 0, count: n)

        for v in 0..<n {
            for u in 0..<n where u != v {
                let ddx = Double(nodes[v].position.x - nodes[u].position.x)
                let ddy = Double(nodes[v].position.y - nodes[u].position.y)
                let dist = max(0.1, (ddx*ddx + ddy*ddy).squareRoot())
                let f = k * k / dist
                dx[v] += (ddx / dist) * f
                dy[v] += (ddy / dist) * f
            }
        }

        for (si, ti) in edgePairs {
            let ddx = Double(nodes[si].position.x - nodes[ti].position.x)
            let ddy = Double(nodes[si].position.y - nodes[ti].position.y)
            let dist = max(0.1, (ddx*ddx + ddy*ddy).squareRoot())
            let f = dist * dist / k
            dx[si] -= (ddx / dist) * f; dy[si] -= (ddy / dist) * f
            dx[ti] += (ddx / dist) * f; dy[ti] += (ddy / dist) * f
        }

        for v in 0..<n {
            guard !nodes[v].isRoot else { continue }
            let mag = max(0.1, (dx[v]*dx[v] + dy[v]*dy[v]).squareRoot())
            let factor = min(mag, temp) / mag
            nodes[v].position.x = max(40, min(size.width  - 40,
                nodes[v].position.x + CGFloat(dx[v] * factor)))
            nodes[v].position.y = max(40, min(size.height - 40,
                nodes[v].position.y + CGFloat(dy[v] * factor)))
        }
        temp *= 0.93
    }
    return nodes
}

// MARK: - Wiki-link completion helpers

public enum WikiLinkHelpers {
    /// Extract partial name after the last unclosed [[ in text.
    /// Returns nil if no open [[ or if it is already closed with ]].
    public static func extractWikiLinkQuery(_ text: String) -> String? {
        guard let openRange = text.range(of: "[[", options: .backwards) else { return nil }
        let suffix = String(text[openRange.upperBound...])
        guard !suffix.contains("]]") else { return nil }
        return suffix
    }

    /// Replace last open [[ + partial name with [[candidate]]  in text.
    public static func applyCompletion(_ candidate: String, to text: String) -> String {
        guard let range = text.range(of: "[[", options: .backwards) else { return text }
        return String(text[text.startIndex..<range.lowerBound]) + "[[\(candidate)]] "
    }
}
