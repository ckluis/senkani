import Foundation
import SwiftTreeSitter
import TreeSitterSwiftParser
import TreeSitterPythonParser
import TreeSitterTypeScriptParser
import TreeSitterTSXParser
import TreeSitterJavaScriptParser
import TreeSitterGoParser
import TreeSitterRustParser
import TreeSitterJavaParser
import TreeSitterCParser
import TreeSitterCppParser
import TreeSitterCSharpParser
import TreeSitterRubyParser
import TreeSitterPhpParser
import TreeSitterKotlinParser
import TreeSitterBashParser
import TreeSitterLuaParser
import TreeSitterScalaParser
import TreeSitterElixirParser
import TreeSitterHaskellParser
import TreeSitterZigParser
import TreeSitterHtmlParser
import TreeSitterCssParser
import TreeSitterDartParser
import TreeSitterTomlParser
import TreeSitterGraphQLParser

/// AST-based indexer using tree-sitter for supported languages.
/// Provides accurate symbol extraction with proper container tracking
/// and exact end-line detection (no brace-depth estimation).
public enum TreeSitterBackend {

    /// Languages with vendored tree-sitter grammars.
    public static let supportedLanguages: Set<String> = ["swift", "python", "typescript", "tsx", "javascript", "go", "rust", "java", "c", "cpp", "csharp", "ruby", "php", "kotlin", "bash", "lua", "scala", "elixir", "haskell", "zig", "html", "css", "dart", "toml", "graphql"]

    /// Whether tree-sitter supports the given language.
    public static func supports(_ language: String) -> Bool {
        supportedLanguages.contains(language)
    }

    /// Return the tree-sitter Language for a given language identifier.
    /// Used by DependencyExtractor to share parser creation without duplicating the switch.
    public static func language(for lang: String) -> Language? {
        switch lang {
        case "swift":      return Language(language: tree_sitter_swift())
        case "python":     return Language(language: tree_sitter_python())
        case "typescript":  return Language(language: tree_sitter_typescript())
        case "tsx":        return Language(language: tree_sitter_tsx())
        case "javascript": return Language(language: tree_sitter_javascript())
        case "go":         return Language(language: tree_sitter_go())
        case "rust":       return Language(language: tree_sitter_rust())
        case "java":       return Language(language: tree_sitter_java())
        case "c":          return Language(language: tree_sitter_c())
        case "cpp":        return Language(language: tree_sitter_cpp())
        case "csharp":     return Language(language: tree_sitter_c_sharp())
        case "ruby":       return Language(language: tree_sitter_ruby())
        case "php":        return Language(language: tree_sitter_php())
        case "kotlin":     return Language(language: tree_sitter_kotlin())
        case "bash":       return Language(language: tree_sitter_bash())
        case "lua":        return Language(language: tree_sitter_lua())
        case "scala":      return Language(language: tree_sitter_scala())
        case "elixir":     return Language(language: tree_sitter_elixir())
        case "haskell":    return Language(language: tree_sitter_haskell())
        case "zig":        return Language(language: tree_sitter_zig())
        case "html":       return Language(language: tree_sitter_html())
        case "css":        return Language(language: tree_sitter_css())
        case "dart":       return Language(language: tree_sitter_dart())
        case "toml":       return Language(language: tree_sitter_toml())
        case "graphql":    return Language(language: tree_sitter_graphql())
        default:           return nil
        }
    }

    /// Extract symbols from a pre-parsed tree's root node.
    /// Used by IncrementalParser to re-extract symbols without re-parsing the file.
    public static func extractSymbols(
        from root: Node,
        source: String,
        language: String,
        file: String
    ) -> [IndexEntry] {
        let ns = source as NSString
        let lines = source.components(separatedBy: "\n")
        var entries: [IndexEntry] = []
        if let backend = backend(for: language) {
            backend.extractSymbols(from: root, file: file, source: ns, lines: lines, container: nil, entries: &entries)
        } else {
            walkNode(root, language: language, file: file, source: ns, lines: lines, container: nil, entries: &entries)
        }
        return entries
    }

    /// Pick the per-language backend for a given language id, if one exists.
    /// Languages that have not yet been migrated out of the central `walkNode`
    /// switch return `nil` here and fall through to the dispatcher.
    internal static func backend(for language: String) -> TreeSitterLanguageBackend.Type? {
        if TomlBackend.supports(language)       { return TomlBackend.self }
        if GraphQLBackend.supports(language)    { return GraphQLBackend.self }
        if SwiftBackend.supports(language)      { return SwiftBackend.self }
        if PythonBackend.supports(language)     { return PythonBackend.self }
        if TypeScriptBackend.supports(language) { return TypeScriptBackend.self }
        if KotlinBackend.supports(language)     { return KotlinBackend.self }
        if CBackend.supports(language)          { return CBackend.self }
        if CppBackend.supports(language)        { return CppBackend.self }
        if CSharpBackend.supports(language)     { return CSharpBackend.self }
        if JavaBackend.supports(language)       { return JavaBackend.self }
        if ScalaBackend.supports(language)      { return ScalaBackend.self }
        if RubyBackend.supports(language)       { return RubyBackend.self }
        if PhpBackend.supports(language)        { return PhpBackend.self }
        if BashBackend.supports(language)       { return BashBackend.self }
        if LuaBackend.supports(language)        { return LuaBackend.self }
        if ElixirBackend.supports(language)     { return ElixirBackend.self }
        if HaskellBackend.supports(language)    { return HaskellBackend.self }
        if ZigBackend.supports(language)        { return ZigBackend.self }
        return nil
    }

    /// Index files of a given language using tree-sitter AST parsing.
    /// When a `treeCache` is provided, parsed trees are stored for later incremental re-parsing.
    public static func index(files: [String], language: String, projectRoot: String, treeCache: TreeCache? = nil) -> [IndexEntry] {
        let parser = Parser()
        let tsLanguage: Language
        switch language {
        case "swift":
            tsLanguage = Language(language: tree_sitter_swift())
        case "python":
            tsLanguage = Language(language: tree_sitter_python())
        case "typescript":
            tsLanguage = Language(language: tree_sitter_typescript())
        case "tsx":
            tsLanguage = Language(language: tree_sitter_tsx())
        case "javascript":
            tsLanguage = Language(language: tree_sitter_javascript())
        case "go":
            tsLanguage = Language(language: tree_sitter_go())
        case "rust":
            tsLanguage = Language(language: tree_sitter_rust())
        case "java":
            tsLanguage = Language(language: tree_sitter_java())
        case "c":
            tsLanguage = Language(language: tree_sitter_c())
        case "cpp":
            tsLanguage = Language(language: tree_sitter_cpp())
        case "csharp":
            tsLanguage = Language(language: tree_sitter_c_sharp())
        case "ruby":
            tsLanguage = Language(language: tree_sitter_ruby())
        case "php":
            tsLanguage = Language(language: tree_sitter_php())
        case "kotlin":
            tsLanguage = Language(language: tree_sitter_kotlin())
        case "bash":
            tsLanguage = Language(language: tree_sitter_bash())
        case "lua":
            tsLanguage = Language(language: tree_sitter_lua())
        case "scala":
            tsLanguage = Language(language: tree_sitter_scala())
        case "elixir":
            tsLanguage = Language(language: tree_sitter_elixir())
        case "haskell":
            tsLanguage = Language(language: tree_sitter_haskell())
        case "zig":
            tsLanguage = Language(language: tree_sitter_zig())
        case "html":
            tsLanguage = Language(language: tree_sitter_html())
        case "css":
            tsLanguage = Language(language: tree_sitter_css())
        case "dart":
            tsLanguage = Language(language: tree_sitter_dart())
        case "toml":
            tsLanguage = Language(language: tree_sitter_toml())
        case "graphql":
            tsLanguage = Language(language: tree_sitter_graphql())
        default:
            return []
        }
        do { try parser.setLanguage(tsLanguage) } catch { return [] }

        var entries: [IndexEntry] = []

        for relativePath in files {
            let fullPath = projectRoot + "/" + relativePath
            guard let content = try? String(contentsOfFile: fullPath, encoding: .utf8) else { continue }
            guard let tree = parser.parse(content) else { continue }
            guard let root = tree.rootNode else { continue }

            // Populate cache for incremental re-parsing
            if let cache = treeCache {
                let hash = TreeCache.hash(content)
                cache.store(file: relativePath, tree: tree, content: content, contentHash: hash, language: language)
            }

            let source = content as NSString
            let lines = content.components(separatedBy: "\n")
            if let backend = backend(for: language) {
                backend.extractSymbols(from: root, file: relativePath, source: source, lines: lines, container: nil, entries: &entries)
            } else {
                walkNode(root, language: language, file: relativePath, source: source, lines: lines, container: nil, entries: &entries)
            }
        }

        return entries
    }

    // MARK: - AST Walking

    private static func walkNode(
        _ node: Node,
        language: String,
        file: String,
        source: NSString,
        lines: [String],
        container: String?,
        entries: inout [IndexEntry]
    ) {
        // After 10e, the only languages that still flow through
        // `walkNode` are Go, Rust, Dart, HTML, and CSS. GraphQL, TOML,
        // Swift, Python, TypeScript/TSX/JavaScript, Kotlin, C, C++,
        // C#, Java, Scala, Ruby, PHP, Bash, Lua, Elixir, Haskell, and
        // Zig are handled by per-language backends in
        // `Sources/Indexer/Languages/`. Both entry points
        // (`extractSymbols(from:source:language:file:)` and
        // `index(files:language:projectRoot:treeCache:)`) route to
        // those backends before calling `walkNode`, so `walkNode`
        // never observes those languages.
        for i in 0..<Int(node.childCount) {
            guard let child = node.child(at: i) else { continue }
            let type = child.nodeType ?? ""

            switch type {
            // function_declaration — Go top-level functions.
            // (Zig and Lua moved to per-language backends in 10e;
            //  PHP function_definition handling moved with PhpBackend.)
            case "function_declaration":
                if let entry = extractFunction(child, file: file, source: source, lines: lines, container: container) {
                    entries.append(entry)
                }

            // class_definition — Dart routes through here. (Python migrated
            //  to `PythonBackend`; Scala migrated to `ScalaBackend`.
            //  `extractPythonClass` is named for its first user but works
            //  for any grammar that puts the class name in a `name` field.)
            case "class_definition":
                if let (entry, body) = extractPythonClass(child, file: file, source: source, lines: lines, container: container) {
                    entries.append(entry)
                    if let body = body {
                        walkNode(body, language: language, file: file, source: source, lines: lines, container: entry.name, entries: &entries)
                    }
                }

            // Go method declarations (receiver-based containers).
            // (Java + C# + PHP all moved to per-language backends.)
            case "method_declaration":
                if language == "go" {
                    if let entry = extractGoMethod(child, file: file, source: source, lines: lines) {
                        entries.append(entry)
                    }
                }

            // enum_declaration — Dart uses this node type for enums
            // (`enum Color { Red, Green }`). PHP also used to route here
            // but moved to `PhpBackend` in 10e.
            case "enum_declaration":
                if let (entry, body) = extractTSDeclaration(child, kind: .enum, file: file, source: source, lines: lines, container: container) {
                    entries.append(entry)
                    if let body = body {
                        walkNode(body, language: language, file: file, source: source, lines: lines, container: entry.name, entries: &entries)
                    }
                }

            // Go type declarations (struct, interface, type alias)
            case "type_declaration":
                extractGoTypeDeclaration(child, file: file, source: source, lines: lines, entries: &entries)

            // Rust function items (top-level or inside impl blocks)
            case "function_item", "function_signature_item":
                if let entry = extractFunction(child, file: file, source: source, lines: lines, container: container) {
                    entries.append(entry)
                }

            // Rust struct items
            case "struct_item":
                if let name = nodeName(child, source: source) {
                    entries.append(IndexEntry(
                        name: name, kind: .struct, file: file,
                        startLine: startLine(of: child), endLine: endLine(of: child),
                        signature: signatureText(lines: lines, line: startLine(of: child)),
                        container: container, engine: "tree-sitter"
                    ))
                }

            // Rust enum items
            case "enum_item":
                if let name = nodeName(child, source: source) {
                    entries.append(IndexEntry(
                        name: name, kind: .enum, file: file,
                        startLine: startLine(of: child), endLine: endLine(of: child),
                        signature: signatureText(lines: lines, line: startLine(of: child)),
                        container: container, engine: "tree-sitter"
                    ))
                }

            // Rust trait items (mapped to .protocol)
            case "trait_item":
                if let name = nodeName(child, source: source) {
                    let body = findBody(child)
                    entries.append(IndexEntry(
                        name: name, kind: .protocol, file: file,
                        startLine: startLine(of: child), endLine: endLine(of: child),
                        signature: signatureText(lines: lines, line: startLine(of: child)),
                        container: container, engine: "tree-sitter"
                    ))
                    if let body = body {
                        walkNode(body, language: language, file: file, source: source, lines: lines, container: name, entries: &entries)
                    }
                }

            // Rust type aliases
            case "type_item":
                if let name = nodeName(child, source: source) {
                    entries.append(IndexEntry(
                        name: name, kind: .type, file: file,
                        startLine: startLine(of: child), endLine: endLine(of: child),
                        signature: signatureText(lines: lines, line: startLine(of: child)),
                        container: container, engine: "tree-sitter"
                    ))
                }

            // Rust impl blocks — extract type name and walk body with it as container
            case "impl_item":
                let implContainer = extractRustImplType(child, source: source)
                if let body = findBody(child) {
                    walkNode(body, language: language, file: file, source: source, lines: lines, container: implContainer, entries: &entries)
                }

            // (Java's `record_declaration`, `annotation_type_declaration`,
            //  `constructor_declaration`, and the C# variants —
            //  `destructor_declaration`, `struct_declaration`,
            //  `delegate_declaration`, `namespace_declaration`,
            //  `file_scoped_namespace_declaration` — moved to
            //  `JavaBackend` / `CSharpBackend` in 10d. Ruby's `class`,
            //  `module`, `method`, `singleton_method` moved to
            //  `RubyBackend` in 10e; PHP's `class_declaration`,
            //  `interface_declaration`, `enum_declaration`,
            //  `trait_declaration`, `property_declaration`, and
            //  `namespace_definition` moved to `PhpBackend`; Bash's
            //  `function_definition` moved to `BashBackend`; Lua's
            //  `function_declaration` to `LuaBackend`; Elixir's `call`
            //  to `ElixirBackend`; Haskell's `declarations` /
            //  `class_declarations` / `instance_declarations` to
            //  `HaskellBackend`; Zig's `function_declaration`,
            //  `variable_declaration`, `container_field`, and
            //  `test_declaration` to `ZigBackend`.)

            // (TOML's `table` / `table_array_element` / `pair` cases used
            // to live here; they moved to `TomlBackend`. Other languages
            // with these node types fall through to `default:` and are
            // recursed — same behavior as before, since the TOML cases
            // were language-gated no-ops for non-TOML.)

            // Dart function_signature (top-level functions + class methods; method_signature wraps this)
            case "function_signature":
                if language == "dart", let name = nodeName(child, source: source) {
                    let kind: SymbolKind = container != nil ? .method : .function
                    entries.append(IndexEntry(
                        name: name, kind: kind, file: file,
                        startLine: startLine(of: child), endLine: endLine(of: child),
                        signature: signatureText(lines: lines, line: startLine(of: child)),
                        container: container, engine: "tree-sitter"
                    ))
                } else if child.childCount > 0 {
                    walkNode(child, language: language, file: file, source: source, lines: lines, container: container, entries: &entries)
                }

            // Dart getter/setter signatures (emit as property-like methods)
            case "getter_signature", "setter_signature":
                if language == "dart", let name = nodeName(child, source: source) {
                    let kind: SymbolKind = container != nil ? .property : .variable
                    entries.append(IndexEntry(
                        name: name, kind: kind, file: file,
                        startLine: startLine(of: child), endLine: endLine(of: child),
                        signature: signatureText(lines: lines, line: startLine(of: child)),
                        container: container, engine: "tree-sitter"
                    ))
                }

            // Dart extension_declaration (extension Foo on Bar { ... })
            case "extension_declaration":
                if language == "dart" {
                    let nameOpt = nodeName(child, source: source)
                    let name = nameOpt ?? "extension"
                    entries.append(IndexEntry(
                        name: name, kind: .extension, file: file,
                        startLine: startLine(of: child), endLine: endLine(of: child),
                        signature: signatureText(lines: lines, line: startLine(of: child)),
                        container: container, engine: "tree-sitter"
                    ))
                    if let body = findBody(child) {
                        walkNode(body, language: language, file: file, source: source, lines: lines, container: name, entries: &entries)
                    }
                }

            // Dart mixin_declaration (mixin Foo { ... })
            case "mixin_declaration":
                if language == "dart", let name = nodeName(child, source: source) {
                    entries.append(IndexEntry(
                        name: name, kind: .class, file: file,
                        startLine: startLine(of: child), endLine: endLine(of: child),
                        signature: signatureText(lines: lines, line: startLine(of: child)),
                        container: container, engine: "tree-sitter"
                    ))
                    if let body = findBody(child) {
                        walkNode(body, language: language, file: file, source: source, lines: lines, container: name, entries: &entries)
                    }
                }

            // (TOML's `table` / `table_array_element` / `pair` cases used to
            // live here; they moved to `TomlBackend`. Other languages with
            // these node types fall through to `default:` and are recursed
            // — same behavior as before, since the TOML cases were
            // language-gated no-ops for non-TOML.)

            default:
                // Recurse into non-declaration nodes (decorated_definition, export_statement, block, etc.)
                if child.childCount > 0 {
                    walkNode(child, language: language, file: file, source: source, lines: lines, container: container, entries: &entries)
                }
            }
        }
    }

    // (Shared / Swift / Python / TypeScript / Go / Rust / Lua / C / C++
    // extractors plus all generic node helpers (`nodeText`, `nodeName`,
    // `findChildByType`, `findBody`, `startLine`, `endLine`,
    // `signatureText`, `extensionTypeName`, `findFirstIdentifier`) live
    // in `Sources/Indexer/Languages/Helpers.swift` as an `extension
    // TreeSitterBackend`. They are `internal` there so per-language
    // backends in `Sources/Indexer/Languages/` can call them; existing
    // call sites here continue to use the bare names unchanged.
    //
    // Elixir / Haskell / Zig once kept their helper functions
    // (`extractElixirModuleName`, `walkHaskellDeclarations`,
    // `walkZigVariableDeclaration`, …) here. They moved into
    // `ElixirBackend`, `HaskellBackend`, and `ZigBackend` as
    // private statics in 10e.)

}
