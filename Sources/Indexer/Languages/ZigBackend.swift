import Foundation
import SwiftTreeSitter

/// Zig symbol-extraction backend.
///
/// Zig has three Zig-specific quirks worth calling out:
///
///   1. `function_declaration` doesn't expose a `name` field — the
///      function name is the first `identifier` child.
///   2. Type bindings live inside `variable_declaration` nodes
///      (`const Foo = struct { … };`). We only emit when the RHS is
///      a `struct_declaration` / `enum_declaration` / `union_declaration`;
///      plain constants (imports, integers) are skipped. Struct
///      bodies recurse so nested fields and methods emit; enum and
///      union bodies are not recursed in v1.
///   3. `container_field` nodes inside struct bodies emit as
///      `.property` only when typed (`name: type`), filtering out
///      enum variants which are bare identifiers.
///   4. `test_declaration` (`test "name" { … }`) emits as `.function`
///      with `container: nil` and the test's quoted name as `name`
///      (or the literal `"test"` if the name can't be extracted).
///
/// Node coverage:
///   - function_declaration   (.function/.method, identifier-child name)
///   - variable_declaration   (.struct/.enum for type bindings only)
///   - container_field        (.property when typed)
///   - test_declaration       (.function, quoted-string name)
internal enum ZigBackend: TreeSitterLanguageBackend {

    static func supports(_ language: String) -> Bool {
        language == "zig"
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
                if let nameNode = TreeSitterBackend.findChildByType(child, type: "identifier"),
                   let name = TreeSitterBackend.nodeText(nameNode, source: source) {
                    let kind: SymbolKind = container != nil ? .method : .function
                    entries.append(IndexEntry(
                        name: name, kind: kind, file: file,
                        startLine: TreeSitterBackend.startLine(of: child),
                        endLine: TreeSitterBackend.endLine(of: child),
                        signature: TreeSitterBackend.signatureText(lines: lines, line: TreeSitterBackend.startLine(of: child)),
                        container: container, engine: "tree-sitter"
                    ))
                }

            case "variable_declaration":
                walkVariableDeclaration(child, file: file, source: source, lines: lines, container: container, entries: &entries)

            case "container_field":
                if TreeSitterBackend.findChildByType(child, type: ":") != nil,
                   let nameNode = TreeSitterBackend.findChildByType(child, type: "identifier"),
                   let name = TreeSitterBackend.nodeText(nameNode, source: source) {
                    entries.append(IndexEntry(
                        name: name, kind: .property, file: file,
                        startLine: TreeSitterBackend.startLine(of: child),
                        endLine: TreeSitterBackend.endLine(of: child),
                        signature: TreeSitterBackend.signatureText(lines: lines, line: TreeSitterBackend.startLine(of: child)),
                        container: container, engine: "tree-sitter"
                    ))
                }

            case "test_declaration":
                let testName = extractTestName(child, source: source) ?? "test"
                entries.append(IndexEntry(
                    name: testName, kind: .function, file: file,
                    startLine: TreeSitterBackend.startLine(of: child),
                    endLine: TreeSitterBackend.endLine(of: child),
                    signature: TreeSitterBackend.signatureText(lines: lines, line: TreeSitterBackend.startLine(of: child)),
                    container: nil, engine: "tree-sitter"
                ))

            default:
                if child.childCount > 0 {
                    walk(child, file: file, source: source, lines: lines, container: container, entries: &entries)
                }
            }
        }
    }

    /// Walk a Zig `variable_declaration`. Detects type bindings
    /// (`const Foo = struct/enum/union { … }`) and emits a type
    /// entry; recurses into struct bodies for nested fields and
    /// methods. Skips plain constants.
    private static func walkVariableDeclaration(
        _ node: Node, file: String, source: NSString, lines: [String],
        container: String?, entries: inout [IndexEntry]
    ) {
        guard let nameNode = TreeSitterBackend.findChildByType(node, type: "identifier"),
              let name = TreeSitterBackend.nodeText(nameNode, source: source) else { return }

        var typeKind: SymbolKind? = nil
        var bodyNode: Node? = nil
        for i in 0..<Int(node.childCount) {
            guard let child = node.child(at: i) else { continue }
            switch child.nodeType ?? "" {
            case "struct_declaration":
                typeKind = .struct
                bodyNode = child
            case "enum_declaration":
                typeKind = .enum
                bodyNode = child
            case "union_declaration":
                typeKind = .struct
                bodyNode = child
            default:
                break
            }
        }

        guard let kind = typeKind else { return }

        entries.append(IndexEntry(
            name: name, kind: kind, file: file,
            startLine: TreeSitterBackend.startLine(of: node),
            endLine: TreeSitterBackend.endLine(of: node),
            signature: TreeSitterBackend.signatureText(lines: lines, line: TreeSitterBackend.startLine(of: node)),
            container: container, engine: "tree-sitter"
        ))

        if let body = bodyNode, body.nodeType == "struct_declaration" {
            walk(body, file: file, source: source, lines: lines, container: name, entries: &entries)
        }
    }

    /// Extract the quoted test name from a `test_declaration`'s
    /// `string` child. The string node is `"`, `string_content`, `"`.
    private static func extractTestName(_ node: Node, source: NSString) -> String? {
        guard let stringNode = TreeSitterBackend.findChildByType(node, type: "string") else { return nil }
        for i in 0..<Int(stringNode.childCount) {
            guard let child = stringNode.child(at: i) else { continue }
            if (child.nodeType ?? "") == "string_content" {
                return TreeSitterBackend.nodeText(child, source: source)
            }
        }
        return nil
    }
}
