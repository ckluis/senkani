// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "senkani",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(name: "senkani", targets: ["CLI"]),
        .executable(name: "senkani-mcp", targets: ["SenkaniMCP"]),
        .executable(name: "senkani-hook", targets: ["SenkaniHook"]),
        .executable(name: "senkani-mig-helper", targets: ["SenkaniMigHelper"]),
        .library(name: "MCPServer", targets: ["MCPServer"]),
        .library(name: "SenkaniFilter", targets: ["Filter"]),
        .library(name: "SenkaniCore", targets: ["Core"]),
        .library(name: "SenkaniIndexer", targets: ["Indexer"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
        .package(url: "https://github.com/apple/swift-testing.git", from: "0.12.0"),
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.9.0"),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm.git", branch: "main"),
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.2.0"),
        .package(url: "https://github.com/ChimeHQ/SwiftTreeSitter.git", from: "0.10.0"),
    ],
    targets: [
        .target(
            name: "Filter",
            dependencies: [],
            path: "Sources/Shared/TokenFilter"
        ),
        .target(
            name: "TreeSitterSwiftParser",
            dependencies: [],
            path: "Sources/TreeSitterSwiftParser",
            exclude: ["VERSION"],
            publicHeadersPath: "include",
            cSettings: [.headerSearchPath(".")]
        ),
        .target(
            name: "TreeSitterPythonParser",
            dependencies: [],
            path: "Sources/TreeSitterPythonParser",
            exclude: ["VERSION"],
            publicHeadersPath: "include",
            cSettings: [.headerSearchPath(".")]
        ),
        .target(
            name: "TreeSitterTypeScriptParser",
            dependencies: [],
            path: "Sources/TreeSitterTypeScriptParser",
            exclude: ["VERSION"],
            sources: ["parser.c", "scanner.c"],
            publicHeadersPath: "include",
            cSettings: [.headerSearchPath("."), .headerSearchPath("include")]
        ),
        .target(
            name: "TreeSitterTSXParser",
            dependencies: [],
            path: "Sources/TreeSitterTSXParser",
            exclude: ["VERSION"],
            sources: ["parser.c", "scanner.c"],
            publicHeadersPath: "include",
            cSettings: [.headerSearchPath("."), .headerSearchPath("include")]
        ),
        .target(
            name: "TreeSitterJavaScriptParser",
            dependencies: [],
            path: "Sources/TreeSitterJavaScriptParser",
            exclude: ["VERSION"],
            sources: ["parser.c", "scanner.c"],
            publicHeadersPath: "include",
            cSettings: [.headerSearchPath("."), .headerSearchPath("include")]
        ),
        .target(
            name: "TreeSitterGoParser",
            dependencies: [],
            path: "Sources/TreeSitterGoParser",
            exclude: ["VERSION"],
            sources: ["parser.c"],
            publicHeadersPath: "include",
            cSettings: [.headerSearchPath("."), .headerSearchPath("include")]
        ),
        .target(
            name: "TreeSitterRustParser",
            dependencies: [],
            path: "Sources/TreeSitterRustParser",
            exclude: ["VERSION"],
            sources: ["parser.c", "scanner.c"],
            publicHeadersPath: "include",
            cSettings: [.headerSearchPath("."), .headerSearchPath("include")]
        ),
        .target(
            name: "TreeSitterJavaParser",
            dependencies: [],
            path: "Sources/TreeSitterJavaParser",
            exclude: ["VERSION"],
            sources: ["parser.c"],
            publicHeadersPath: "include",
            cSettings: [.headerSearchPath("."), .headerSearchPath("include")]
        ),
        .target(
            name: "TreeSitterCParser",
            dependencies: [],
            path: "Sources/TreeSitterCParser",
            exclude: ["VERSION"],
            sources: ["parser.c"],
            publicHeadersPath: "include",
            cSettings: [.headerSearchPath("."), .headerSearchPath("include")]
        ),
        .target(
            name: "TreeSitterCppParser",
            dependencies: [],
            path: "Sources/TreeSitterCppParser",
            exclude: ["VERSION"],
            sources: ["parser.c", "scanner.c"],
            publicHeadersPath: "include",
            cSettings: [.headerSearchPath("."), .headerSearchPath("include")]
        ),
        .target(
            name: "TreeSitterCSharpParser",
            dependencies: [],
            path: "Sources/TreeSitterCSharpParser",
            exclude: ["VERSION"],
            sources: ["parser.c", "scanner.c"],
            publicHeadersPath: "include",
            cSettings: [.headerSearchPath("."), .headerSearchPath("include")]
        ),
        .target(
            name: "TreeSitterRubyParser",
            dependencies: [],
            path: "Sources/TreeSitterRubyParser",
            exclude: ["VERSION"],
            sources: ["parser.c", "scanner.c"],
            publicHeadersPath: "include",
            cSettings: [.headerSearchPath("."), .headerSearchPath("include")]
        ),
        .target(
            name: "TreeSitterPhpParser",
            dependencies: [],
            path: "Sources/TreeSitterPhpParser",
            exclude: ["VERSION"],
            sources: ["parser.c", "scanner.c"],
            publicHeadersPath: "include",
            cSettings: [.headerSearchPath("."), .headerSearchPath("include")]
        ),
        .target(
            name: "TreeSitterKotlinParser",
            dependencies: [],
            path: "Sources/TreeSitterKotlinParser",
            exclude: ["VERSION"],
            sources: ["parser.c", "scanner.c"],
            publicHeadersPath: "include",
            cSettings: [.headerSearchPath("."), .headerSearchPath("include")]
        ),
        .target(
            name: "TreeSitterBashParser",
            dependencies: [],
            path: "Sources/TreeSitterBashParser",
            exclude: ["VERSION"],
            sources: ["parser.c", "scanner.c"],
            publicHeadersPath: "include",
            cSettings: [.headerSearchPath("."), .headerSearchPath("include")]
        ),
        .target(
            name: "TreeSitterLuaParser",
            dependencies: [],
            path: "Sources/TreeSitterLuaParser",
            exclude: ["VERSION"],
            sources: ["parser.c", "scanner.c"],
            publicHeadersPath: "include",
            cSettings: [.headerSearchPath("."), .headerSearchPath("include")]
        ),
        .target(
            name: "TreeSitterScalaParser",
            dependencies: [],
            path: "Sources/TreeSitterScalaParser",
            exclude: ["VERSION"],
            sources: ["parser.c", "scanner.c"],
            publicHeadersPath: "include",
            cSettings: [.headerSearchPath("."), .headerSearchPath("include")]
        ),
        .target(
            name: "TreeSitterElixirParser",
            dependencies: [],
            path: "Sources/TreeSitterElixirParser",
            exclude: ["VERSION"],
            sources: ["parser.c", "scanner.c"],
            publicHeadersPath: "include",
            cSettings: [.headerSearchPath("."), .headerSearchPath("include")]
        ),
        .target(
            name: "TreeSitterHaskellParser",
            dependencies: [],
            path: "Sources/TreeSitterHaskellParser",
            exclude: ["VERSION"],
            sources: ["parser.c", "scanner.c"],
            publicHeadersPath: "include",
            cSettings: [.headerSearchPath("."), .headerSearchPath("include")]
        ),
        .target(
            name: "TreeSitterZigParser",
            dependencies: [],
            path: "Sources/TreeSitterZigParser",
            exclude: ["VERSION"],
            sources: ["parser.c"],
            publicHeadersPath: "include",
            cSettings: [.headerSearchPath("."), .headerSearchPath("include")]
        ),
        .target(
            name: "TreeSitterHtmlParser",
            dependencies: [],
            path: "Sources/TreeSitterHtmlParser",
            exclude: ["VERSION"],
            sources: ["parser.c", "scanner.c"],
            publicHeadersPath: "include",
            cSettings: [.headerSearchPath("."), .headerSearchPath("include")]
        ),
        .target(
            name: "TreeSitterCssParser",
            dependencies: [],
            path: "Sources/TreeSitterCssParser",
            exclude: ["VERSION"],
            sources: ["parser.c", "scanner.c"],
            publicHeadersPath: "include",
            cSettings: [.headerSearchPath("."), .headerSearchPath("include")]
        ),
        .target(
            name: "TreeSitterDartParser",
            dependencies: [],
            path: "Sources/TreeSitterDartParser",
            exclude: ["VERSION"],
            sources: ["parser.c", "scanner.c"],
            publicHeadersPath: "include",
            cSettings: [.headerSearchPath("."), .headerSearchPath("include")]
        ),
        .target(
            name: "TreeSitterTomlParser",
            dependencies: [],
            path: "Sources/TreeSitterTomlParser",
            exclude: ["VERSION"],
            sources: ["parser.c", "scanner.c"],
            publicHeadersPath: "include",
            cSettings: [.headerSearchPath("."), .headerSearchPath("include")]
        ),
        .target(
            name: "TreeSitterGraphQLParser",
            dependencies: [],
            path: "Sources/TreeSitterGraphQLParser",
            exclude: ["VERSION"],
            sources: ["parser.c"],
            publicHeadersPath: "include",
            cSettings: [.headerSearchPath("."), .headerSearchPath("include")]
        ),
        .target(
            name: "Indexer",
            dependencies: [
                .product(name: "SwiftTreeSitter", package: "SwiftTreeSitter"),
                "TreeSitterSwiftParser",
                "TreeSitterPythonParser",
                "TreeSitterTypeScriptParser",
                "TreeSitterTSXParser",
                "TreeSitterJavaScriptParser",
                "TreeSitterGoParser",
                "TreeSitterRustParser",
                "TreeSitterJavaParser",
                "TreeSitterCParser",
                "TreeSitterCppParser",
                "TreeSitterCSharpParser",
                "TreeSitterRubyParser",
                "TreeSitterPhpParser",
                "TreeSitterKotlinParser",
                "TreeSitterBashParser",
                "TreeSitterLuaParser",
                "TreeSitterScalaParser",
                "TreeSitterElixirParser",
                "TreeSitterHaskellParser",
                "TreeSitterZigParser",
                "TreeSitterHtmlParser",
                "TreeSitterCssParser",
                "TreeSitterDartParser",
                "TreeSitterTomlParser",
                "TreeSitterGraphQLParser",
            ],
            path: "Sources/Indexer"
        ),
        .target(
            name: "HookRelay",
            dependencies: [],
            path: "Sources/HookRelay"
        ),
        .target(
            name: "Core",
            dependencies: ["Filter"],
            path: "Sources/Core"
        ),
        .target(
            name: "Bench",
            dependencies: [
                "Core",
                "Filter",
                "Indexer",
            ],
            path: "Sources/Bench"
        ),
        .target(
            name: "Bundle",
            dependencies: [
                "Core",
                "Filter",
                "Indexer",
            ],
            path: "Sources/Bundle"
        ),
        .executableTarget(
            name: "CLI",
            dependencies: [
                "Core",
                "Filter",
                "Indexer",
                "Bench",
                "Bundle",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/CLI"
        ),
        .target(
            name: "MCPServer",
            dependencies: [
                "Core",
                "Filter",
                "Indexer",
                "Bundle",
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "MLXEmbedders", package: "mlx-swift-lm"),
                .product(name: "MLXVLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
            ],
            path: "Sources/MCP"
        ),
        .executableTarget(
            name: "SenkaniMCP",
            dependencies: [
                "MCPServer",
            ],
            path: "Sources/MCPMain"
        ),
        .executableTarget(
            name: "SenkaniHook",
            dependencies: ["HookRelay"],
            path: "Sources/Hook"
        ),
        .executableTarget(
            name: "SenkaniMigHelper",
            dependencies: ["Core"],
            path: "tools/migration-runner"
        ),
        .executableTarget(
            name: "SenkaniApp",
            dependencies: [
                "Core",
                "Filter",
                "Indexer",
                "Bench",
                "MCPServer",
                "HookRelay",
                .product(name: "SwiftTerm", package: "SwiftTerm"),
                .product(name: "SwiftTreeSitter", package: "SwiftTreeSitter"),
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "MLXEmbedders", package: "mlx-swift-lm"),
                .product(name: "MLXVLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
            ],
            path: "SenkaniApp",
            exclude: ["Info.plist", "Senkani.entitlements"],
            resources: [.copy("Themes"), .process("Assets.xcassets")]
        ),
        .testTarget(
            name: "SenkaniTests",
            dependencies: [
                "Filter",
                "Core",
                "Indexer",
                "Bench",
                "Bundle",
                "MCPServer",
                "CLI",
                "HookRelay",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Testing", package: "swift-testing"),
            ],
            path: "Tests/SenkaniTests"
        ),
    ]
)
