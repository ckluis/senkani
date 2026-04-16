import SwiftUI
import Core
import MCPServer

/// Canvas-based 1-hop force-directed relations graph.
/// Edges and node circles rendered in Canvas (non-interactive).
/// Transparent Button overlays in ZStack provide tap-to-navigate and labels.
struct RelationsGraphView: View {
    let nodes: [GraphNode]
    let edges: [GraphEdge]
    let selectedEntityName: String
    var onSelect: (String) -> Void

    var body: some View {
        ZStack {
            if nodes.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "circle.dashed")
                        .font(.system(size: 22))
                        .foregroundStyle(SenkaniTheme.textTertiary)
                    Text("No relations")
                        .font(.system(size: 11))
                        .foregroundStyle(SenkaniTheme.textTertiary)
                    Text("Add [[EntityName]] wiki-links to the understanding\nto create relations.")
                        .font(.system(size: 9))
                        .foregroundStyle(SenkaniTheme.textTertiary.opacity(0.7))
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // Layer 1: Canvas for edges + node circles (non-interactive, fast)
                Canvas { ctx, _ in
                    // Edges
                    for edge in edges {
                        guard let src = nodes.first(where: { $0.id == edge.sourceId }),
                              let dst = nodes.first(where: { $0.name == edge.targetName })
                        else { continue }

                        var path = Path()
                        path.move(to: src.position)
                        path.addLine(to: dst.position)
                        ctx.stroke(path,
                                   with: .color(SenkaniTheme.inactiveBorder.opacity(0.7)),
                                   lineWidth: 0.75)

                        // Named relation label at midpoint
                        if let rel = edge.relation {
                            let mid = CGPoint(x: (src.position.x + dst.position.x) / 2,
                                             y: (src.position.y + dst.position.y) / 2)
                            ctx.draw(
                                Text(rel)
                                    .font(.system(size: 7, design: .monospaced))
                                    .foregroundColor(SenkaniTheme.textTertiary.opacity(0.6)),
                                at: mid
                            )
                        }
                    }

                    // Node circles
                    for node in nodes {
                        let r: CGFloat = node.isRoot ? 10 : 7
                        let rect = CGRect(x: node.position.x - r, y: node.position.y - r,
                                         width: r * 2, height: r * 2)
                        ctx.fill(Path(ellipseIn: rect), with: .color(nodeColor(node)))
                        if node.isRoot {
                            ctx.stroke(
                                Path(ellipseIn: rect.insetBy(dx: -1.5, dy: -1.5)),
                                with: .color(SenkaniTheme.accentKnowledgeBase.opacity(0.35)),
                                lineWidth: 1.5
                            )
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                // Layer 2: Interactive overlays — transparent tap targets + name labels
                ForEach(nodes) { node in
                    VStack(spacing: 2) {
                        Button {
                            if !node.isRoot { onSelect(node.name) }
                        } label: {
                            Color.clear.frame(width: 22, height: 22)
                        }
                        .buttonStyle(.plain)
                        .disabled(node.isRoot)

                        Text(node.name)
                            .font(.system(size: 8, design: .monospaced))
                            .foregroundStyle(node.isRoot
                                ? SenkaniTheme.accentKnowledgeBase
                                : SenkaniTheme.textSecondary)
                            .lineLimit(1)
                            .frame(maxWidth: 80)
                    }
                    .position(x: node.position.x, y: node.position.y + 8)
                }
            }
        }
        .background(SenkaniTheme.paneBody)
    }

    private func nodeColor(_ node: GraphNode) -> Color {
        if node.isRoot { return SenkaniTheme.accentKnowledgeBase }
        switch node.entityType {
        case "class":   return SenkaniTheme.accentKnowledgeBase.opacity(0.6)
        case "struct":  return SenkaniTheme.accentTerminal.opacity(0.7)
        case "func":    return SenkaniTheme.accentPreview.opacity(0.7)
        case "file":    return Color.purple.opacity(0.6)
        default:        return SenkaniTheme.textSecondary.opacity(0.6)
        }
    }
}
