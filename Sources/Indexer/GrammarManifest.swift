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
    /// SHA-256 of the vendored C payload (parser.c, then scanner.c
    /// concatenated when present). Verified by
    /// `tools/verify-grammar-hashes.sh` and emitted into the release
    /// SBOM. Tampering with vendored grammar code changes this hash.
    public let contentHash: String

    public init(
        language: String,
        version: String,
        repo: String,
        vendoredDate: String,
        targetName: String,
        contentHash: String
    ) {
        self.language = language
        self.version = version
        self.repo = repo
        self.vendoredDate = vendoredDate
        self.targetName = targetName
        self.contentHash = contentHash
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
            targetName: "TreeSitterSwiftParser",
            contentHash: "5470143473df6c41441ba52084f05a44252f0d33583e51822bc07251ecf82faf"
        ),
        "python": GrammarInfo(
            language: "python",
            version: "0.23.6",
            repo: "tree-sitter/tree-sitter-python",
            vendoredDate: "2026-04-10",
            targetName: "TreeSitterPythonParser",
            contentHash: "185c61c39f73e817f6f4fb189b434801255cb92490a60db5b2b90fa4cd10dc1e"
        ),
        "typescript": GrammarInfo(
            language: "typescript",
            version: "0.23.2",
            repo: "tree-sitter/tree-sitter-typescript",
            vendoredDate: "2026-04-10",
            targetName: "TreeSitterTypeScriptParser",
            contentHash: "e204d0be48a00ac84aa0348d27809a00d54901a879f22e1613777607592f9184"
        ),
        "tsx": GrammarInfo(
            language: "tsx",
            version: "0.23.2",
            repo: "tree-sitter/tree-sitter-typescript",
            vendoredDate: "2026-04-10",
            targetName: "TreeSitterTSXParser",
            contentHash: "8dad60072c34e1112534ce5ea47db0f7595ee402bad347dc3bc6c0d3ec6a4010"
        ),
        "javascript": GrammarInfo(
            language: "javascript",
            version: "0.25.0",
            repo: "tree-sitter/tree-sitter-javascript",
            vendoredDate: "2026-04-10",
            targetName: "TreeSitterJavaScriptParser",
            contentHash: "12593d6cd7237858fbf484f0dde25df2327c21e64f389ec30cf79ccb57fbbc8e"
        ),
        "go": GrammarInfo(
            language: "go",
            version: "0.25.0",
            repo: "tree-sitter/tree-sitter-go",
            vendoredDate: "2026-04-10",
            targetName: "TreeSitterGoParser",
            contentHash: "3dbf6ed1238b5dfcf2be4d2f2d4cb27a14d34f34d7784eccccbfd532fd4a6d85"
        ),
        "rust": GrammarInfo(
            language: "rust",
            version: "0.24.2",
            repo: "tree-sitter/tree-sitter-rust",
            vendoredDate: "2026-04-10",
            targetName: "TreeSitterRustParser",
            contentHash: "d75fc9e348c8e6ba1a40ffb23ae693a0a6e32aa1780a2f322a04bf59f7456440"
        ),
        "java": GrammarInfo(
            language: "java",
            version: "0.23.5",
            repo: "tree-sitter/tree-sitter-java",
            vendoredDate: "2026-04-10",
            targetName: "TreeSitterJavaParser",
            contentHash: "4add5150cf4531eb5dd97f3343dcf65cd11704c84711348b328582b83424a0e4"
        ),
        "c": GrammarInfo(
            language: "c",
            version: "0.24.1",
            repo: "tree-sitter/tree-sitter-c",
            vendoredDate: "2026-04-10",
            targetName: "TreeSitterCParser",
            contentHash: "e1b618bc80b8983b43893f98ce1bd8a23a3ccc7d726bed6624b5c4c6c85d5e1c"
        ),
        "cpp": GrammarInfo(
            language: "cpp",
            version: "0.23.4",
            repo: "tree-sitter/tree-sitter-cpp",
            vendoredDate: "2026-04-10",
            targetName: "TreeSitterCppParser",
            contentHash: "e9b3fdc4459e29ce4869132d55eba2906d97346fa25cbcf6260204076c5e020c"
        ),
        "csharp": GrammarInfo(
            language: "csharp",
            version: "0.23.1",
            repo: "tree-sitter/tree-sitter-c-sharp",
            vendoredDate: "2026-04-10",
            targetName: "TreeSitterCSharpParser",
            contentHash: "77a60724eddec5d8f5c7a577fe5dc125de29381c10b1dc31bb91d93cc466a1f0"
        ),
        "ruby": GrammarInfo(
            language: "ruby",
            version: "0.23.1",
            repo: "tree-sitter/tree-sitter-ruby",
            vendoredDate: "2026-04-10",
            targetName: "TreeSitterRubyParser",
            contentHash: "55223bb5e12dacc469b5b74ff25da6e58f786998ad5eb846930343970fadc8f0"
        ),
        "php": GrammarInfo(
            language: "php",
            version: "0.23.12",
            repo: "tree-sitter/tree-sitter-php",
            vendoredDate: "2026-04-10",
            targetName: "TreeSitterPhpParser",
            contentHash: "61ee7d50749855072610ae0d8bb1649a1c06b083898ae7eabc6568e2152ef1f4"
        ),
        "kotlin": GrammarInfo(
            language: "kotlin",
            version: "0.3.8",
            repo: "fwcd/tree-sitter-kotlin",
            vendoredDate: "2026-04-11",
            targetName: "TreeSitterKotlinParser",
            contentHash: "0d6d9216297e031fe2aa56ef4e9fa1786f7a9c40fe3bf9c517ff94dd72953a8a"
        ),
        "bash": GrammarInfo(
            language: "bash",
            version: "0.25.1",
            repo: "tree-sitter/tree-sitter-bash",
            vendoredDate: "2026-04-11",
            targetName: "TreeSitterBashParser",
            contentHash: "b20c41faa447407213ffa54c9656f8d104bc5a053734147f60546d0b94e338d4"
        ),
        "lua": GrammarInfo(
            language: "lua",
            version: "0.5.0",
            repo: "tree-sitter-grammars/tree-sitter-lua",
            vendoredDate: "2026-04-11",
            targetName: "TreeSitterLuaParser",
            contentHash: "a8af53a08a5be7dc99c7858ce06aa5c61ff716d6ac67116b20cccf40e5731a4d"
        ),
        "scala": GrammarInfo(
            language: "scala",
            version: "0.25.0",
            repo: "tree-sitter/tree-sitter-scala",
            vendoredDate: "2026-04-11",
            targetName: "TreeSitterScalaParser",
            contentHash: "fbe22426cdaa00415438d9f1c7ec9876ebd8f54af7fb375452ffb34ef1f8966e"
        ),
        "elixir": GrammarInfo(
            language: "elixir",
            version: "0.3.5",
            repo: "elixir-lang/tree-sitter-elixir",
            vendoredDate: "2026-04-11",
            targetName: "TreeSitterElixirParser",
            contentHash: "8613d23d9d512ebd0b82759d1c07c51256971f506612c78611e0f42a4ed960a1"
        ),
        "haskell": GrammarInfo(
            language: "haskell",
            version: "0.23.1",
            repo: "tree-sitter/tree-sitter-haskell",
            vendoredDate: "2026-04-11",
            targetName: "TreeSitterHaskellParser",
            contentHash: "dc7ddae7d2d896bad2977d5f3089a05f788017b78513da724873835095f9e752"
        ),
        "zig": GrammarInfo(
            language: "zig",
            version: "1.1.2",
            repo: "tree-sitter-grammars/tree-sitter-zig",
            vendoredDate: "2026-04-11",
            targetName: "TreeSitterZigParser",
            contentHash: "5449f98eb876939fcb12be76891ecb0c99b78be3bfe843e140d64c680b66ae63"
        ),
        "html": GrammarInfo(
            language: "html",
            version: "0.23.2",
            repo: "tree-sitter/tree-sitter-html",
            vendoredDate: "2026-04-13",
            targetName: "TreeSitterHtmlParser",
            contentHash: "5a9b05feac70715199ea1406ab7e3565709d64a09ae0e57e406237cb6f047309"
        ),
        "css": GrammarInfo(
            language: "css",
            version: "0.25.0",
            repo: "tree-sitter/tree-sitter-css",
            vendoredDate: "2026-04-13",
            targetName: "TreeSitterCssParser",
            contentHash: "29d7afc8f4707294b67247e9c76d32778d3721035f06fd8962d485879ef9bf85"
        ),
        "dart": GrammarInfo(
            language: "dart",
            version: "1.0.0",
            repo: "UserNobody14/tree-sitter-dart",
            vendoredDate: "2026-04-18",
            targetName: "TreeSitterDartParser",
            contentHash: "12ee1b3558a87696a042db8b4914883408d9b58a4f4bdd4f434869f1a47d2978"
        ),
        "toml": GrammarInfo(
            language: "toml",
            version: "0.7.0",
            repo: "tree-sitter-grammars/tree-sitter-toml",
            vendoredDate: "2026-04-18",
            targetName: "TreeSitterTomlParser",
            contentHash: "cbed879994e9d45cd3c6448136ad68bb50129b5ebdb8ab4aca7bbd938ce34564"
        ),
        "graphql": GrammarInfo(
            language: "graphql",
            version: "0.0.1",
            repo: "bkegley/tree-sitter-graphql",
            vendoredDate: "2026-04-18",
            targetName: "TreeSitterGraphQLParser",
            contentHash: "b2ee5d6f514ea72dddd8f34516ef57ec50329d7171c60c03b088f5f5f39cc390"
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
