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
        // # Pin rationale — mlx-swift-lm
        //
        // HOLD on revision "2a296f1…". This SHA is the verified-working
        // starting point: the full test suite (2445 tests) was green
        // against it when the pin was introduced (2026-05-04).
        //
        // Upstream publishes tagged releases (latest seen: 3.31.3) and
        // `main` is past this SHA, so the pin is destined to go stale.
        // We accept that staleness over the alternative (silent drift on
        // `branch: "main"`) because:
        //   1. MLX inference is a heavy behavioral surface — tokenizer,
        //      sampler defaults, and model loaders can shift between tags
        //      and require real-machine validation budget that build-
        //      config rounds don't have.
        //   2. The verified SHA is byte-identical to what we ship today;
        //      bumping inside an infra round risks regressions whose
        //      blast radius (hosted-LLM users) is wider than the round's
        //      test envelope.
        //
        // Next-revisit trigger: RELEASE-CUT GATE. The next senkani
        // release ceremony (v0.4.0 cut and onward) MUST run an
        // mlx-swift-lm pin-bump pass:
        //   • compare this revision to upstream's latest release tag,
        //   • if newer, bump revision (or move to `from: "<tag>"`),
        //     re-resolve, run `./tools/test-safe.sh` AND on-real-machine
        //     MLX inference smoke tests,
        //   • if green, ship the bump in the same release; otherwise
        //     refresh this rationale block with the regression that
        //     blocked the bump and the next trigger.
        //
        // The release-cut checklist owns enforcement; a follow-up
        // backlog item (`release-checklist-mlx-pin-bump-row`) wires the
        // row into the v0.4.0 cut.
        //
        // Release-cut gate was chosen over (a) calendar cadence (silently
        // skippable) and (b) upstream-tag-watch automation (setup cost
        // exceeds the round's budget; not yet justified at senkani's
        // scale). Revisit the trigger choice if the gate misfires twice.
        .package(url: "https://github.com/ml-explore/mlx-swift-lm.git", revision: "2a296f145c3129fea4290bb6e4a0a5fb458efa06"),
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
            path: "Sources/Core",
            resources: [
                .copy("Presets/Defaults/log-rotation.json"),
                .copy("Presets/Defaults/morning-brief.json"),
                .copy("Presets/Defaults/autoresearch.json"),
                .copy("Presets/Defaults/competitive-scan.json"),
                .copy("Presets/Defaults/senkani-improve.json"),
            ]
        ),
        .target(
            name: "Bench",
            dependencies: [
                "Core",
                "Filter",
                "Indexer",
            ],
            path: "Sources/Bench",
            resources: [
                .copy("Resources/MLEvalImages"),
            ]
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
                "Bench",
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
            path: "Tests/SenkaniTests",
            resources: [
                .copy("Fixtures/secrets-adversarial"),
                .copy("Fixtures/routing-corpus.json"),
                .copy("Fixtures/context-plan-corpus.json"),
            ]
        ),
    ]
)
