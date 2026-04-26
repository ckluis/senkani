import Foundation
import SwiftTreeSitter

/// Haskell symbol-extraction backend.
///
/// Haskell groups its declarations under three node types: top-level
/// `declarations`, type-class `class_declarations`, and instance
/// `instance_declarations`. All three are walked the same way, with
/// per-scope deduplication that handles two Haskell-specific cases:
///
///   1. Multi-equation functions — `f 0 = …` followed by `f n = …`
///      both parse as `function` nodes with the same name. Only the
///      first emits.
///   2. Signature + definition pairs — a `signature` node like
///      `f :: Int -> Int` paired with a `function` node `f n = …`.
///      The function emits, the signature is suppressed.
///   3. Signature-only declarations (abstract methods inside
///      `class` bodies) emit through the pending-signatures pass.
///
/// Node coverage:
///   - declarations / class_declarations / instance_declarations
///       → walkHaskellDeclarations
///   - inside which: signature, function, bind, data_type, newtype,
///                   type_synomym, class, instance
internal enum HaskellBackend: TreeSitterLanguageBackend {

    static func supports(_ language: String) -> Bool {
        language == "haskell"
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
            case "declarations", "class_declarations", "instance_declarations":
                walkDeclarations(child, file: file, source: source, lines: lines, container: container, entries: &entries)

            default:
                if child.childCount > 0 {
                    walk(child, file: file, source: source, lines: lines, container: container, entries: &entries)
                }
            }
        }
    }

    /// Walk a Haskell declarations scope with multi-equation and
    /// signature-pair deduplication.
    private static func walkDeclarations(
        _ node: Node, file: String, source: NSString, lines: [String],
        container: String?, entries: inout [IndexEntry]
    ) {
        var emittedNames = Set<String>()
        var pendingSignatures: [(name: String, node: Node)] = []

        for i in 0..<Int(node.childCount) {
            guard let child = node.child(at: i) else { continue }
            let type = child.nodeType ?? ""

            switch type {
            case "signature":
                if let name = TreeSitterBackend.nodeName(child, source: source), !emittedNames.contains(name) {
                    pendingSignatures.append((name, child))
                }

            case "function", "bind":
                if let name = TreeSitterBackend.nodeName(child, source: source), !emittedNames.contains(name) {
                    emittedNames.insert(name)
                    pendingSignatures.removeAll { $0.name == name }
                    let kind: SymbolKind = container != nil ? .method : .function
                    entries.append(IndexEntry(
                        name: name, kind: kind, file: file,
                        startLine: TreeSitterBackend.startLine(of: child),
                        endLine: TreeSitterBackend.endLine(of: child),
                        signature: TreeSitterBackend.signatureText(lines: lines, line: TreeSitterBackend.startLine(of: child)),
                        container: container, engine: "tree-sitter"
                    ))
                }

            case "data_type", "newtype", "type_synomym":
                if let name = TreeSitterBackend.nodeName(child, source: source) {
                    entries.append(IndexEntry(
                        name: name, kind: .type, file: file,
                        startLine: TreeSitterBackend.startLine(of: child),
                        endLine: TreeSitterBackend.endLine(of: child),
                        signature: TreeSitterBackend.signatureText(lines: lines, line: TreeSitterBackend.startLine(of: child)),
                        container: container, engine: "tree-sitter"
                    ))
                }

            case "class":
                if let name = TreeSitterBackend.nodeName(child, source: source) {
                    entries.append(IndexEntry(
                        name: name, kind: .protocol, file: file,
                        startLine: TreeSitterBackend.startLine(of: child),
                        endLine: TreeSitterBackend.endLine(of: child),
                        signature: TreeSitterBackend.signatureText(lines: lines, line: TreeSitterBackend.startLine(of: child)),
                        container: container, engine: "tree-sitter"
                    ))
                    if let body = TreeSitterBackend.findChildByType(child, type: "class_declarations") {
                        walkDeclarations(body, file: file, source: source, lines: lines, container: name, entries: &entries)
                    }
                }

            case "instance":
                if let name = TreeSitterBackend.nodeName(child, source: source) {
                    entries.append(IndexEntry(
                        name: name, kind: .extension, file: file,
                        startLine: TreeSitterBackend.startLine(of: child),
                        endLine: TreeSitterBackend.endLine(of: child),
                        signature: TreeSitterBackend.signatureText(lines: lines, line: TreeSitterBackend.startLine(of: child)),
                        container: container, engine: "tree-sitter"
                    ))
                    if let body = TreeSitterBackend.findChildByType(child, type: "instance_declarations") {
                        walkDeclarations(body, file: file, source: source, lines: lines, container: name, entries: &entries)
                    }
                }

            default:
                break
            }
        }

        for sig in pendingSignatures where !emittedNames.contains(sig.name) {
            emittedNames.insert(sig.name)
            let kind: SymbolKind = container != nil ? .method : .function
            entries.append(IndexEntry(
                name: sig.name, kind: kind, file: file,
                startLine: TreeSitterBackend.startLine(of: sig.node),
                endLine: TreeSitterBackend.endLine(of: sig.node),
                signature: TreeSitterBackend.signatureText(lines: lines, line: TreeSitterBackend.startLine(of: sig.node)),
                container: container, engine: "tree-sitter"
            ))
        }
    }
}
