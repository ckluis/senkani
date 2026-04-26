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

    private static func walk(
        _ node: Node, file: String, source: NSString, lines: [String],
        container: String?, entries: inout [IndexEntry]
    ) {
        for i in 0..<Int(node.childCount) {
            guard let child = node.child(at: i) else { continue }
            let type = child.nodeType ?? ""

            switch type {
            case "function_declaration":
                if let (name, luaContainer) = TreeSitterBackend.extractLuaFunctionName(child, source: source) {
                    let kind: SymbolKind = luaContainer != nil ? .method : .function
                    entries.append(IndexEntry(
                        name: name, kind: kind, file: file,
                        startLine: TreeSitterBackend.startLine(of: child),
                        endLine: TreeSitterBackend.endLine(of: child),
                        signature: TreeSitterBackend.signatureText(lines: lines, line: TreeSitterBackend.startLine(of: child)),
                        container: luaContainer, engine: "tree-sitter"
                    ))
                }

            default:
                if child.childCount > 0 {
                    walk(child, file: file, source: source, lines: lines, container: container, entries: &entries)
                }
            }
        }
    }
}
