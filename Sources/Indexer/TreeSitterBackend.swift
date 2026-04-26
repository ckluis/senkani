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
///
/// After the 10a–10f decomposition this type is a thin dispatcher:
/// it owns parser creation (`language(for:)`) and routing
/// (`backend(for:)`). All per-language symbol-extraction logic lives
/// in `Sources/Indexer/Languages/<Lang>Backend.swift` and conforms
/// to `TreeSitterLanguageBackend`. Shared helpers (`extractFunction`,
/// `nodeName`, `findBody`, `extractRustImplType`, …) live in
/// `Languages/Helpers.swift` as an `extension TreeSitterBackend`.
///
/// To add a 26th language: see the "Adding a language" section in
/// `spec/tree_sitter.md` and the worked examples
/// `Languages/TomlBackend.swift` (minimal recursive walker) or
/// `Languages/JavaBackend.swift` (uniform `name`-field grammar).
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
    ///
    /// Throws `IndexError.unsupportedLanguage(language)` if no backend
    /// is registered for the given language identifier.
    public static func extractSymbols(
        from root: Node,
        source: String,
        language: String,
        file: String
    ) throws -> [IndexEntry] {
        guard let backend = backend(for: language) else {
            throw IndexError.unsupportedLanguage(language)
        }
        let ns = source as NSString
        let lines = source.components(separatedBy: "\n")
        var entries: [IndexEntry] = []
        backend.extractSymbols(from: root, file: file, source: ns, lines: lines, container: nil, entries: &entries)
        return entries
    }

    /// Pick the per-language backend for a given language id, if one exists.
    /// Every language in `supportedLanguages` has a backend after 10f;
    /// this returns `nil` only for unsupported languages.
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
        if RustBackend.supports(language)       { return RustBackend.self }
        if GoBackend.supports(language)         { return GoBackend.self }
        if DartBackend.supports(language)       { return DartBackend.self }
        if HtmlBackend.supports(language)       { return HtmlBackend.self }
        if CssBackend.supports(language)        { return CssBackend.self }
        return nil
    }

    /// Index files of a given language using tree-sitter AST parsing.
    /// When a `treeCache` is provided, parsed trees are stored for later incremental re-parsing.
    ///
    /// Throws `IndexError.unsupportedLanguage(language)` if the language
    /// has no tree-sitter grammar or no per-language backend registered,
    /// or `IndexError.parseFailed(...)` if parser setup itself fails.
    /// Per-file errors inside the batch (file unreadable, parse returned
    /// nil) are silently skipped — one bad file shouldn't fail the
    /// whole batch — but the setup-level failures above are surfaced
    /// so callers can tell "language not supported" from "language
    /// supported but no symbols found."
    public static func index(files: [String], language: String, projectRoot: String, treeCache: TreeCache? = nil) throws -> [IndexEntry] {
        guard let tsLanguage = self.language(for: language) else {
            throw IndexError.unsupportedLanguage(language)
        }
        guard let backend = backend(for: language) else {
            throw IndexError.unsupportedLanguage(language)
        }

        let parser = Parser()
        do {
            try parser.setLanguage(tsLanguage)
        } catch {
            throw IndexError.parseFailed(file: "<tree-sitter setup>", reason: "setLanguage(\(language)) failed: \(error)")
        }

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
            backend.extractSymbols(from: root, file: relativePath, source: source, lines: lines, container: nil, entries: &entries)
        }

        return entries
    }

    // MARK: - Notes
    //
    // The legacy `walkNode(...)` central dispatcher is gone after 10f.
    // Per-language symbol extraction lives in
    // `Sources/Indexer/Languages/<Lang>Backend.swift` (one backend per
    // grammar; TypeScriptBackend serves the ts/tsx/js triple).
    //
    // Shared extractors and node helpers (`extractFunction`,
    // `extractTSDeclaration`, `extractPythonClass`, `extractGoMethod`,
    // `extractGoTypeDeclaration`, `extractRustImplType`, `nodeText`,
    // `nodeName`, `findChildByType`, `findBody`, `startLine`,
    // `endLine`, `signatureText`, `extensionTypeName`,
    // `findFirstIdentifier`, …) live in `Languages/Helpers.swift` as
    // an `extension TreeSitterBackend`. They are `internal` so the
    // per-language backends can call them.
}
