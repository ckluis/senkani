import Foundation

/// Metadata for a vendored tree-sitter grammar.
public struct GrammarInfo: Sendable, Equatable {
    /// Language identifier (e.g. "swift", "python").
    public let language: String
    /// Vendored version string (e.g. "0.7.1").
    public let version: String
    /// GitHub repository in "owner/repo" format.
    public let repo: String
    /// Date the grammar was vendored into the project.
    public let vendoredDate: String
    /// SPM target name for this grammar's C sources.
    public let targetName: String

    public init(
        language: String,
        version: String,
        repo: String,
        vendoredDate: String,
        targetName: String
    ) {
        self.language = language
        self.version = version
        self.repo = repo
        self.vendoredDate = vendoredDate
        self.targetName = targetName
    }
}

/// Central registry of all vendored tree-sitter grammars.
/// Adding a new language? Add an entry here.
public enum GrammarManifest {
    /// All vendored grammars, keyed by language identifier.
    public static let grammars: [String: GrammarInfo] = [
        "swift": GrammarInfo(
            language: "swift",
            version: "0.7.1",
            repo: "alex-pinkus/tree-sitter-swift",
            vendoredDate: "2026-04-10",
            targetName: "TreeSitterSwiftParser"
        ),
        "python": GrammarInfo(
            language: "python",
            version: "0.23.6",
            repo: "tree-sitter/tree-sitter-python",
            vendoredDate: "2026-04-10",
            targetName: "TreeSitterPythonParser"
        ),
        "typescript": GrammarInfo(
            language: "typescript",
            version: "0.23.2",
            repo: "tree-sitter/tree-sitter-typescript",
            vendoredDate: "2026-04-10",
            targetName: "TreeSitterTypeScriptParser"
        ),
        "tsx": GrammarInfo(
            language: "tsx",
            version: "0.23.2",
            repo: "tree-sitter/tree-sitter-typescript",
            vendoredDate: "2026-04-10",
            targetName: "TreeSitterTSXParser"
        ),
        "javascript": GrammarInfo(
            language: "javascript",
            version: "0.25.0",
            repo: "tree-sitter/tree-sitter-javascript",
            vendoredDate: "2026-04-10",
            targetName: "TreeSitterJavaScriptParser"
        ),
        "go": GrammarInfo(
            language: "go",
            version: "0.25.0",
            repo: "tree-sitter/tree-sitter-go",
            vendoredDate: "2026-04-10",
            targetName: "TreeSitterGoParser"
        ),
        "rust": GrammarInfo(
            language: "rust",
            version: "0.24.2",
            repo: "tree-sitter/tree-sitter-rust",
            vendoredDate: "2026-04-10",
            targetName: "TreeSitterRustParser"
        ),
        "java": GrammarInfo(
            language: "java",
            version: "0.23.5",
            repo: "tree-sitter/tree-sitter-java",
            vendoredDate: "2026-04-10",
            targetName: "TreeSitterJavaParser"
        ),
        "c": GrammarInfo(
            language: "c",
            version: "0.24.1",
            repo: "tree-sitter/tree-sitter-c",
            vendoredDate: "2026-04-10",
            targetName: "TreeSitterCParser"
        ),
        "cpp": GrammarInfo(
            language: "cpp",
            version: "0.23.4",
            repo: "tree-sitter/tree-sitter-cpp",
            vendoredDate: "2026-04-10",
            targetName: "TreeSitterCppParser"
        ),
        "csharp": GrammarInfo(
            language: "csharp",
            version: "0.23.1",
            repo: "tree-sitter/tree-sitter-c-sharp",
            vendoredDate: "2026-04-10",
            targetName: "TreeSitterCSharpParser"
        ),
        "ruby": GrammarInfo(
            language: "ruby",
            version: "0.23.1",
            repo: "tree-sitter/tree-sitter-ruby",
            vendoredDate: "2026-04-10",
            targetName: "TreeSitterRubyParser"
        ),
        "php": GrammarInfo(
            language: "php",
            version: "0.23.12",
            repo: "tree-sitter/tree-sitter-php",
            vendoredDate: "2026-04-10",
            targetName: "TreeSitterPhpParser"
        ),
        "kotlin": GrammarInfo(
            language: "kotlin",
            version: "0.3.8",
            repo: "fwcd/tree-sitter-kotlin",
            vendoredDate: "2026-04-11",
            targetName: "TreeSitterKotlinParser"
        ),
        "bash": GrammarInfo(
            language: "bash",
            version: "0.25.1",
            repo: "tree-sitter/tree-sitter-bash",
            vendoredDate: "2026-04-11",
            targetName: "TreeSitterBashParser"
        ),
        "lua": GrammarInfo(
            language: "lua",
            version: "0.5.0",
            repo: "tree-sitter-grammars/tree-sitter-lua",
            vendoredDate: "2026-04-11",
            targetName: "TreeSitterLuaParser"
        ),
        "scala": GrammarInfo(
            language: "scala",
            version: "0.25.0",
            repo: "tree-sitter/tree-sitter-scala",
            vendoredDate: "2026-04-11",
            targetName: "TreeSitterScalaParser"
        ),
        "elixir": GrammarInfo(
            language: "elixir",
            version: "0.3.5",
            repo: "elixir-lang/tree-sitter-elixir",
            vendoredDate: "2026-04-11",
            targetName: "TreeSitterElixirParser"
        ),
        "haskell": GrammarInfo(
            language: "haskell",
            version: "0.23.1",
            repo: "tree-sitter/tree-sitter-haskell",
            vendoredDate: "2026-04-11",
            targetName: "TreeSitterHaskellParser"
        ),
        "zig": GrammarInfo(
            language: "zig",
            version: "1.1.2",
            repo: "tree-sitter-grammars/tree-sitter-zig",
            vendoredDate: "2026-04-11",
            targetName: "TreeSitterZigParser"
        ),
        "html": GrammarInfo(
            language: "html",
            version: "0.23.2",
            repo: "tree-sitter/tree-sitter-html",
            vendoredDate: "2026-04-13",
            targetName: "TreeSitterHtmlParser"
        ),
        "css": GrammarInfo(
            language: "css",
            version: "0.25.0",
            repo: "tree-sitter/tree-sitter-css",
            vendoredDate: "2026-04-13",
            targetName: "TreeSitterCssParser"
        ),
    ]

    /// Sorted list of all grammar infos for display.
    public static var sorted: [GrammarInfo] {
        grammars.values.sorted { $0.language < $1.language }
    }

    /// Look up a grammar by language.
    public static func grammar(for language: String) -> GrammarInfo? {
        grammars[language]
    }

    /// Compare two semver version strings. Returns:
    /// -  1 if `a > b`
    /// -  0 if `a == b`
    /// - -1 if `a < b`
    public static func compareSemver(_ a: String, _ b: String) -> Int {
        let partsA = a.split(separator: ".").compactMap { Int($0) }
        let partsB = b.split(separator: ".").compactMap { Int($0) }

        let maxLen = max(partsA.count, partsB.count)
        for i in 0..<maxLen {
            let va = i < partsA.count ? partsA[i] : 0
            let vb = i < partsB.count ? partsB[i] : 0
            if va > vb { return 1 }
            if va < vb { return -1 }
        }
        return 0
    }
}
