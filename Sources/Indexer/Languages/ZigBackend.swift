import Foundation
import SwiftTreeSitter

/// Zig symbol-extraction backend.
///
/// Zig has four Zig-specific quirks worth calling out:
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

    // Iterative work-stack of (node, container) tuples. Replaces a
    // recursive descent (`walk` + `walkVariableDeclaration` re-entering
    // `walk` for struct bodies) so AST depth no longer consumes Swift
    // call frames on the cooperative pool. Umbrella chain child of
    // `indexer-backends-iterative-walk-refactor-2026-05-11`
    // (alphabetical successor to TypeScriptBackend). Zig's substrate
    // novelty: FIRST chain child whose pre-refactor walk delegated to a
    // private helper that re-entered the same `walk` — the
    // `walkVariableDeclaration` helper called `walk(body, …, container:
    // name)` when the variable's RHS was a `struct_declaration`. Two
    // recursion sites in two functions (pre-refactor line 95 default
    // arm + line 142 struct-body recurse inside the helper); both
    // eliminated here. The helper's emit-and-push semantics are
    // inlined into the `variable_declaration` arm: extract the
    // variable name, scan direct children for `struct_declaration` /
    // `enum_declaration` / `union_declaration`, emit the type entry,
    // then push the body onto the stack with container re-bound to
    // the variable name — ONLY when the body is `struct_declaration`
    // (enum and union bodies are not pushed, preserving the v1
    // docstring invariant). Leaf-emit arms (`function_declaration`,
    // `container_field`, `test_declaration`) emit without descent.
    // The default arm reverse-pushes children with `currentContainer`
    // preserved via `stride(from: count - 1, through: 0, by: -1)` so
    // LIFO pop reproduces left-to-right pre-order — matches
    // pre-refactor line 95's `walk(child, …, container: container)`
    // exactly; the `guard count > 0 else continue` reproduces the
    // pre-refactor `if child.childCount > 0` skip semantics. Closest
    // precedent is PhpBackend's namespace_definition arm in that it
    // computes a container-rebind value before pushing the body; the
    // shape of "scan children for a body subtree, emit a type entry,
    // push the body with rebind" matches every prior chain child's
    // body-rebind arm. The helper-inlining choice (vs. keeping
    // `walkVariableDeclaration` as a pure non-recursive helper
    // returning `(IndexEntry?, Node?)`) is preferred here because the
    // helper had only one call site and its full body fits comfortably
    // inside the match arm.
    private static func walk(
        _ root: Node, file: String, source: NSString, lines: [String],
        container: String?, entries: inout [IndexEntry]
    ) {
        var stack: [(Node, String?)] = [(root, container)]
        while let (node, currentContainer) = stack.popLast() {
            let type = node.nodeType ?? ""

            switch type {
            case "function_declaration":
                if let nameNode = TreeSitterBackend.findChildByType(node, type: "identifier"),
                   let name = TreeSitterBackend.nodeText(nameNode, source: source) {
                    let kind: SymbolKind = currentContainer != nil ? .method : .function
                    entries.append(IndexEntry(
                        name: name, kind: kind, file: file,
                        startLine: TreeSitterBackend.startLine(of: node),
                        endLine: TreeSitterBackend.endLine(of: node),
                        signature: TreeSitterBackend.signatureText(lines: lines, line: TreeSitterBackend.startLine(of: node)),
                        container: currentContainer, engine: "tree-sitter"
                    ))
                }
                // No descent — matches pre-refactor.

            case "variable_declaration":
                // Inlined from the pre-refactor's
                // `walkVariableDeclaration` helper. Type bindings
                // (`const Foo = struct/enum/union {…}`) emit; plain
                // constants are skipped silently. Only struct bodies
                // are pushed onto the stack with rebind — matches
                // pre-refactor line 142's `walk(body, …, container:
                // name)`. Enum and union bodies are not pushed
                // (v1 docstring invariant).
                guard let nameNode = TreeSitterBackend.findChildByType(node, type: "identifier"),
                      let name = TreeSitterBackend.nodeText(nameNode, source: source) else { continue }
                var typeKind: SymbolKind? = nil
                var bodyNode: Node? = nil
                let varChildCount = Int(node.childCount)
                for i in 0..<varChildCount {
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
                guard let kind = typeKind else { continue }
                entries.append(IndexEntry(
                    name: name, kind: kind, file: file,
                    startLine: TreeSitterBackend.startLine(of: node),
                    endLine: TreeSitterBackend.endLine(of: node),
                    signature: TreeSitterBackend.signatureText(lines: lines, line: TreeSitterBackend.startLine(of: node)),
                    container: currentContainer, engine: "tree-sitter"
                ))
                if let body = bodyNode, body.nodeType == "struct_declaration" {
                    stack.append((body, name))
                }

            case "container_field":
                if TreeSitterBackend.findChildByType(node, type: ":") != nil,
                   let nameNode = TreeSitterBackend.findChildByType(node, type: "identifier"),
                   let name = TreeSitterBackend.nodeText(nameNode, source: source) {
                    entries.append(IndexEntry(
                        name: name, kind: .property, file: file,
                        startLine: TreeSitterBackend.startLine(of: node),
                        endLine: TreeSitterBackend.endLine(of: node),
                        signature: TreeSitterBackend.signatureText(lines: lines, line: TreeSitterBackend.startLine(of: node)),
                        container: currentContainer, engine: "tree-sitter"
                    ))
                }
                // No descent — matches pre-refactor.

            case "test_declaration":
                let testName = extractTestName(node, source: source) ?? "test"
                entries.append(IndexEntry(
                    name: testName, kind: .function, file: file,
                    startLine: TreeSitterBackend.startLine(of: node),
                    endLine: TreeSitterBackend.endLine(of: node),
                    signature: TreeSitterBackend.signatureText(lines: lines, line: TreeSitterBackend.startLine(of: node)),
                    container: nil, engine: "tree-sitter"
                ))
                // No descent — hardcoded container: nil (tests are
                // top-level even inside a struct body).

            default:
                // source_file, struct_declaration body, block, etc.
                // Push children in reverse so LIFO pop preserves
                // left-to-right pre-order — symbol-emission order
                // matches the pre-refactor recursive form exactly.
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
