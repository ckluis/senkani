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
    ],
    targets: [
        .target(
            name: "Filter",
            dependencies: [],
            path: "Sources/Shared/TokenFilter"
        ),
        .target(
            name: "Indexer",
            dependencies: [],
            path: "Sources/Indexer"
        ),
        .target(
            name: "Core",
            dependencies: ["Filter"],
            path: "Sources/Core"
        ),
        .executableTarget(
            name: "CLI",
            dependencies: [
                "Core",
                "Filter",
                "Indexer",
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
            name: "SenkaniApp",
            dependencies: [
                "Core",
                "Filter",
                "Indexer",
                "MCPServer",
                .product(name: "SwiftTerm", package: "SwiftTerm"),
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "MLXEmbedders", package: "mlx-swift-lm"),
                .product(name: "MLXVLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
            ],
            path: "SenkaniApp",
            exclude: ["SenkaniApp.xcodeproj"]
        ),
        .testTarget(
            name: "SenkaniTests",
            dependencies: [
                "Filter",
                "Core",
                "Indexer",
                .product(name: "Testing", package: "swift-testing"),
            ],
            path: "Tests/SenkaniTests"
        ),
    ]
)
