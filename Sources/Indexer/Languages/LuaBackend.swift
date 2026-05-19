import Foundation
import SwiftTreeSitter

/// Lua symbol-extraction backend.
///
/// Lua's `function_declaration` covers three name shapes:
/// `function foo()`, `function M.greet()`, and `function M:say()`.
/// The shared `extractLuaFunctionName` helper unpacks them into a
/// `(name, container?)` pair; when a container is recovered the
/// symbol emits as `.method`, otherwise `.function`. The recovered
/// container is the table name, NOT the lexical container — Lua
/// declarations are top-level even when they bind into a table, so
/// we use that table as the container string and ignore any
/// outer-walk container.
///
/// Node coverage:
///   - function_declaration  (.function/.method via extractLuaFunctionName)
internal enum LuaBackend: TreeSitterLanguageBackend {

    static func supports(_ language: String) -> Bool {
        language == "lua"
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

    // Iterative work-stack of (node, container) tuples. Replaces a
    // recursive descent so AST depth no longer consumes Swift call
    // frames on the cooperative pool. Umbrella chain child of
    // `indexer-backends-iterative-walk-refactor-2026-05-11`
    // (alphabetical successor to KotlinBackend; closest precedent
    // GoBackend/BashBackend — single recursion site, no body-rebind
    // arms). LuaBackend's outer-walk container is never read by
    // emission — the `function_declaration` arm derives container
    // from the function-name shape via `extractLuaFunctionName`; the
    // iterative form passes `currentContainer` through unchanged on
    // the default-arm reverse-push but the emit arm ignores it,
    // matching the pre-refactor `container: luaContainer` at
    // emission.
    private static func walk(
        _ root: Node, file: String, source: NSString, lines: [String],
        container: String?, entries: inout [IndexEntry]
    ) {
        var stack: [(Node, String?)] = [(root, container)]
        while let (node, currentContainer) = stack.popLast() {
            let type = node.nodeType ?? ""

            switch type {
            case "function_declaration":
                if let (name, luaContainer) = TreeSitterBackend.extractLuaFunctionName(node, source: source) {
                    let kind: SymbolKind = luaContainer != nil ? .method : .function
                    entries.append(IndexEntry(
                        name: name, kind: kind, file: file,
                        startLine: TreeSitterBackend.startLine(of: node),
                        endLine: TreeSitterBackend.endLine(of: node),
                        signature: TreeSitterBackend.signatureText(lines: lines, line: TreeSitterBackend.startLine(of: node)),
                        container: luaContainer, engine: "tree-sitter"
                    ))
                }
                // No descent — matches pre-refactor "function_declaration
                // arm returns without recursing into the child".

            default:
                // Push children in reverse so LIFO pop preserves
                // left-to-right pre-order traversal — symbol-emission
                // order matches the pre-refactor recursive form exactly.
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
