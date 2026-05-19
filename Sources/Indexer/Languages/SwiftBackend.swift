import Foundation
import SwiftTreeSitter

/// Swift symbol-extraction backend.
///
/// Owns the AST walk for Swift source: classes, structs, enums,
/// actors, extensions, protocols, free functions, methods,
/// initializers, and properties (incl. protocol property
/// requirements).
///
/// `class_declaration` is Swift's catch-all for class / struct /
/// enum / actor / extension; the kind is decided by inspecting the
/// declaration keyword in `extractSwiftClassLike`. `extension`
/// names come from `extensionTypeName` since they have no `name`
/// field.
internal enum SwiftBackend: TreeSitterLanguageBackend {

    static func supports(_ language: String) -> Bool {
        language == "swift"
    }

    static func extractSymbols(
        from root: Node,
        file: String,
        source: NSString,
        lines: [String],
        container: String?,
        entries: inout [IndexEntry]
    ) {
        walk(root, file: file, source: source, lines: lines, container: container, entries: &entries)
    }

    // MARK: - Walk

    // Iterative work-stack of (node, container) tuples. Replaces a
    // recursive descent so AST depth no longer consumes Swift call
    // frames on the cooperative pool. Umbrella chain child of
    // `indexer-backends-iterative-walk-refactor-2026-05-11`
    // (alphabetical successor to ScalaBackend; closest precedent
    // ScalaBackend's three-body-rebind-arm pattern — Swift has two
    // body-rebind arms instead of three but otherwise structurally
    // similar, and uses the shared `extractSwiftClassLike` /
    // `extractProtocol` helpers). Two body-rebind arms
    // (`class_declaration` via `extractSwiftClassLike`,
    // `protocol_declaration` via `extractProtocol`) each emit and
    // then push the body with container re-bound to the declared
    // name. Leaf-emit arms (`function_declaration` /
    // `protocol_function_declaration` via `extractFunction`,
    // `init_declaration` via direct `IndexEntry` construction with
    // `name: "init"` + `.method`, `property_declaration` /
    // `protocol_property_declaration` via `extractProperty`) emit
    // without descent. The default arm reverse-pushes children with
    // currentContainer preserved so LIFO pop reproduces left-to-right
    // pre-order — symbol-emission order matches pre-refactor exactly.
    private static func walk(
        _ root: Node, file: String, source: NSString, lines: [String],
        container: String?, entries: inout [IndexEntry]
    ) {
        var stack: [(Node, String?)] = [(root, container)]
        while let (node, currentContainer) = stack.popLast() {
            let type = node.nodeType ?? ""

            switch type {
            // Swift class / struct / enum / actor / extension all parse as
            // `class_declaration`; kind is decided from the keyword child.
            case "class_declaration":
                if let (entry, body) = TreeSitterBackend.extractSwiftClassLike(
                    node, file: file, source: source, lines: lines, container: currentContainer
                ) {
                    entries.append(entry)
                    if let body = body {
                        // Re-bind container to entry.name for the body's
                        // descendants — matches pre-refactor line 52's
                        // `walk(body, ..., container: entry.name)`.
                        stack.append((body, entry.name))
                    }
                }

            case "protocol_declaration":
                if let (entry, body) = TreeSitterBackend.extractProtocol(
                    node, file: file, source: source, lines: lines, container: currentContainer
                ) {
                    entries.append(entry)
                    if let body = body {
                        // Re-bind container to entry.name for the body's
                        // descendants — matches pre-refactor line 62's
                        // `walk(body, ..., container: entry.name)`.
                        stack.append((body, entry.name))
                    }
                }

            case "function_declaration", "protocol_function_declaration":
                if let entry = TreeSitterBackend.extractFunction(
                    node, file: file, source: source, lines: lines, container: currentContainer
                ) {
                    entries.append(entry)
                }

            case "init_declaration":
                let start = TreeSitterBackend.startLine(of: node)
                let end = TreeSitterBackend.endLine(of: node)
                let sig = TreeSitterBackend.signatureText(lines: lines, line: start)
                entries.append(IndexEntry(
                    name: "init",
                    kind: .method,
                    file: file,
                    startLine: start,
                    endLine: end,
                    signature: sig,
                    container: currentContainer,
                    engine: "tree-sitter"
                ))

            case "property_declaration", "protocol_property_declaration":
                if let entry = TreeSitterBackend.extractProperty(
                    node, file: file, source: source, lines: lines, container: currentContainer
                ) {
                    entries.append(entry)
                }

            default:
                // Push children in reverse so LIFO pop preserves
                // left-to-right pre-order traversal — symbol-emission
                // order matches the pre-refactor recursive form
                // exactly. The pre-refactor default arm guarded with
                // `if child.childCount > 0`; the iterative form's
                // `guard count > 0 else continue` reproduces that —
                // childless leaves popped here fall through as a
                // no-op exactly as the pre-refactor's guard skipped
                // them.
                let count = Int(node.childCount)
                guard count > 0 else { continue }
                for i in stride(from: count - 1, through: 0, by: -1) {
                    if let child = node.child(at: i) {
                        stack.append((child, currentContainer))
                    }
                }
            }
        }
    }
}
