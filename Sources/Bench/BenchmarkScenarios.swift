import Foundation

/// A simulated tool call within a scenario.
public struct SimulatedCall: Sendable, Codable, Identifiable {
    public let id: String
    public let tool: String
    public let description: String
    public let rawBytes: Int
    public let optimizedBytes: Int
    public let feature: String
    public let isReRead: Bool

    public init(id: String, tool: String, description: String,
                rawBytes: Int, optimizedBytes: Int, feature: String, isReRead: Bool = false) {
        self.id = id
        self.tool = tool
        self.description = description
        self.rawBytes = rawBytes
        self.optimizedBytes = optimizedBytes
        self.feature = feature
        self.isReRead = isReRead
    }

    public var savedBytes: Int { max(0, rawBytes - optimizedBytes) }
    public var savedPct: Double { rawBytes > 0 ? Double(savedBytes) / Double(rawBytes) * 100 : 0 }
}

/// A complete scenario modeling a common developer workflow.
public struct Scenario: Sendable, Codable, Identifiable {
    public let id: String
    public let name: String
    public let description: String
    public let icon: String
    public let calls: [SimulatedCall]

    public init(id: String, name: String, description: String, icon: String, calls: [SimulatedCall]) {
        self.id = id
        self.name = name
        self.description = description
        self.icon = icon
        self.calls = calls
    }

    public var totalRaw: Int { calls.reduce(0) { $0 + $1.rawBytes } }
    public var totalOptimized: Int { calls.reduce(0) { $0 + $1.optimizedBytes } }
    public var multiplier: Double { totalOptimized > 0 ? Double(totalRaw) / Double(totalOptimized) : 1.0 }
    public var totalSaved: Int { max(0, totalRaw - totalOptimized) }
    public var callCount: Int { calls.count }
    public var rawCostCents: Double { Double(totalRaw) / 4.0 / 1_000_000.0 * 300.0 }
    public var optimizedCostCents: Double { Double(totalOptimized) / 4.0 / 1_000_000.0 * 300.0 }

    public var featureBreakdown: [(feature: String, savedBytes: Int, callCount: Int, savedPct: Double)] {
        var grouped: [String: (saved: Int, raw: Int, count: Int)] = [:]
        for call in calls {
            var entry = grouped[call.feature] ?? (0, 0, 0)
            entry.saved += call.savedBytes
            entry.raw += call.rawBytes
            entry.count += 1
            grouped[call.feature] = entry
        }
        return grouped.map { (feature: $0.key, savedBytes: $0.value.saved, callCount: $0.value.count,
                              savedPct: $0.value.raw > 0 ? Double($0.value.saved) / Double($0.value.raw) * 100 : 0) }
            .sorted { $0.savedBytes > $1.savedBytes }
    }
}

/// The six built-in scenarios.
///
/// Byte counts are grounded in measured ratios from the Mode 1 fixture bench:
/// - Filter: ~98% on aggressive commands, ~50% on moderate commands
/// - Cache: 100% on re-reads (second read of unchanged file = 0 bytes)
/// - Indexer search: ~99% (50 bytes vs 5000 bytes)
/// - Indexer outline: ~90% (200 bytes vs 2000 bytes)
/// - Sandbox: ~97% (150 bytes summary vs 5000 bytes)
/// - Re-read suppression: 100% (tool call eliminated entirely)
///
/// File sizes: small ~2KB, medium ~3-5KB, large ~10KB
public enum BenchmarkScenarios {

    public static let all: [Scenario] = [
        exploreCB, debugBug, refactorModule, addFeature, codeReview, ciPipeline
    ]

    // MARK: - 1. Explore Codebase

    static let exploreCB = Scenario(
        id: "explore_codebase",
        name: "Explore Codebase",
        description: "Onboard to a new project — read key files, grep for patterns, outline modules",
        icon: "folder.badge.questionmark",
        calls: {
            var c: [SimulatedCall] = []
            for i in 0..<12 {
                c.append(SimulatedCall(id: "read_\(i)", tool: "read", description: "Read source file #\(i+1) (~3KB)",
                                       rawBytes: 3000, optimizedBytes: 3000, feature: "read"))
            }
            for i in 0..<3 {
                c.append(SimulatedCall(id: "reread_\(i)", tool: "read", description: "Re-read file #\(i+1) (cache hit)",
                                       rawBytes: 3000, optimizedBytes: 0, feature: "cache", isReRead: true))
            }
            for i in 0..<5 {
                c.append(SimulatedCall(id: "search_\(i)", tool: "search", description: "Search for symbol #\(i+1)",
                                       rawBytes: 5000, optimizedBytes: 50, feature: "indexer"))
            }
            for i in 0..<2 {
                c.append(SimulatedCall(id: "outline_\(i)", tool: "outline", description: "Outline module #\(i+1)",
                                       rawBytes: 4000, optimizedBytes: 400, feature: "indexer"))
            }
            c.append(SimulatedCall(id: "deps_0", tool: "deps", description: "Query: what imports AuthService?",
                                   rawBytes: 10000, optimizedBytes: 200, feature: "indexer"))
            return c
        }()
    )

    // MARK: - 2. Debug a Bug

    static let debugBug = Scenario(
        id: "debug_bug",
        name: "Debug a Bug",
        description: "Read logs, trace through code, run tests repeatedly, validate fixes",
        icon: "ladybug",
        calls: {
            var c: [SimulatedCall] = []
            for i in 0..<7 {
                c.append(SimulatedCall(id: "read_\(i)", tool: "read", description: "Read source file #\(i+1) (~3KB)",
                                       rawBytes: 3000, optimizedBytes: 3000, feature: "read"))
            }
            for i in 0..<3 {
                c.append(SimulatedCall(id: "reread_\(i)", tool: "read", description: "Re-read file #\(i+1) during debugging (cache hit)",
                                       rawBytes: 3000, optimizedBytes: 0, feature: "cache", isReRead: true))
            }
            for i in 0..<2 {
                c.append(SimulatedCall(id: "suppressed_\(i)", tool: "read", description: "Re-read suppressed — file unchanged",
                                       rawBytes: 3000, optimizedBytes: 0, feature: "reread_suppression", isReRead: true))
            }
            for i in 0..<3 {
                c.append(SimulatedCall(id: "test_\(i)", tool: "exec", description: "Run test suite (500 lines output)",
                                       rawBytes: 15000, optimizedBytes: 450, feature: "sandbox"))
            }
            c.append(SimulatedCall(id: "gitlog", tool: "exec", description: "git log --oneline -20",
                                   rawBytes: 2000, optimizedBytes: 1000, feature: "filter"))
            c.append(SimulatedCall(id: "gitdiff", tool: "exec", description: "git diff (200 lines)",
                                   rawBytes: 8000, optimizedBytes: 4000, feature: "filter"))
            for i in 0..<2 {
                c.append(SimulatedCall(id: "validate_\(i)", tool: "validate", description: "Type-check edited file",
                                       rawBytes: 1000, optimizedBytes: 50, feature: "validate"))
            }
            return c
        }()
    )

    // MARK: - 3. Refactor Module

    static let refactorModule = Scenario(
        id: "refactor_module",
        name: "Refactor Module",
        description: "Rename symbols, move code, re-read files after each edit, run tests",
        icon: "arrow.triangle.2.circlepath",
        calls: {
            var c: [SimulatedCall] = []
            for i in 0..<8 {
                c.append(SimulatedCall(id: "read_\(i)", tool: "read", description: "Read file #\(i+1) (~4KB)",
                                       rawBytes: 4000, optimizedBytes: 4000, feature: "read"))
            }
            for i in 0..<4 {
                c.append(SimulatedCall(id: "cache_\(i)", tool: "read", description: "Re-read after edit #\(i+1) (cache hit)",
                                       rawBytes: 4000, optimizedBytes: 0, feature: "cache", isReRead: true))
            }
            for i in 0..<4 {
                c.append(SimulatedCall(id: "suppressed_\(i)", tool: "read", description: "Re-read suppressed — file just written",
                                       rawBytes: 4000, optimizedBytes: 0, feature: "reread_suppression", isReRead: true))
            }
            for i in 0..<2 {
                c.append(SimulatedCall(id: "search_\(i)", tool: "search", description: "Find references to renamed symbol",
                                       rawBytes: 5000, optimizedBytes: 50, feature: "indexer"))
            }
            c.append(SimulatedCall(id: "deps_0", tool: "deps", description: "What imports this module?",
                                   rawBytes: 8000, optimizedBytes: 150, feature: "indexer"))
            for i in 0..<3 {
                c.append(SimulatedCall(id: "test_\(i)", tool: "exec", description: "Run tests after refactor step \(i+1)",
                                       rawBytes: 15000, optimizedBytes: 450, feature: "sandbox"))
            }
            return c
        }()
    )

    // MARK: - 4. Add Feature

    static let addFeature = Scenario(
        id: "add_feature",
        name: "Add Feature",
        description: "Understand the area, write code, search for patterns, build and test",
        icon: "plus.rectangle.on.rectangle",
        calls: {
            var c: [SimulatedCall] = []
            for i in 0..<8 {
                c.append(SimulatedCall(id: "read_\(i)", tool: "read", description: "Read existing file #\(i+1) (~3KB)",
                                       rawBytes: 3000, optimizedBytes: 3000, feature: "read"))
            }
            for i in 0..<3 {
                c.append(SimulatedCall(id: "search_\(i)", tool: "search", description: "Find similar patterns in codebase",
                                       rawBytes: 5000, optimizedBytes: 50, feature: "indexer"))
            }
            for i in 0..<2 {
                c.append(SimulatedCall(id: "deps_\(i)", tool: "deps", description: "Check dependency graph",
                                       rawBytes: 8000, optimizedBytes: 150, feature: "indexer"))
            }
            c.append(SimulatedCall(id: "outline_0", tool: "outline", description: "Outline target module",
                                   rawBytes: 4000, optimizedBytes: 400, feature: "indexer"))
            for i in 0..<2 {
                c.append(SimulatedCall(id: "build_\(i)", tool: "exec", description: "Build project",
                                       rawBytes: 12000, optimizedBytes: 600, feature: "filter"))
            }
            for i in 0..<2 {
                c.append(SimulatedCall(id: "test_\(i)", tool: "exec", description: "Run test suite",
                                       rawBytes: 15000, optimizedBytes: 450, feature: "sandbox"))
            }
            return c
        }()
    )

    // MARK: - 5. Code Review

    static let codeReview = Scenario(
        id: "code_review",
        name: "Code Review",
        description: "Read many files, check diffs, outline each module, grep for patterns",
        icon: "eye.circle",
        calls: {
            var c: [SimulatedCall] = []
            for i in 0..<12 {
                c.append(SimulatedCall(id: "read_\(i)", tool: "read", description: "Read changed file #\(i+1) (~3KB)",
                                       rawBytes: 3000, optimizedBytes: 3000, feature: "read"))
            }
            c.append(SimulatedCall(id: "reread_0", tool: "read", description: "Re-read key file (cache hit)",
                                   rawBytes: 3000, optimizedBytes: 0, feature: "cache", isReRead: true))
            for i in 0..<2 {
                c.append(SimulatedCall(id: "diff_\(i)", tool: "exec", description: "git diff on changed module (~400 lines)",
                                       rawBytes: 16000, optimizedBytes: 8000, feature: "filter"))
            }
            for i in 0..<6 {
                c.append(SimulatedCall(id: "outline_\(i)", tool: "outline", description: "Outline file #\(i+1)",
                                       rawBytes: 3000, optimizedBytes: 300, feature: "indexer"))
            }
            for i in 0..<3 {
                c.append(SimulatedCall(id: "search_\(i)", tool: "search", description: "Search for usage of changed API",
                                       rawBytes: 5000, optimizedBytes: 50, feature: "indexer"))
            }
            return c
        }()
    )

    // MARK: - 6. CI / Build Pipeline

    static let ciPipeline = Scenario(
        id: "ci_pipeline",
        name: "CI / Build Pipeline",
        description: "Lint, build, test, deploy — many large command outputs, heavy sandbox use",
        icon: "gearshape.2",
        calls: {
            var c: [SimulatedCall] = []
            for i in 0..<3 {
                c.append(SimulatedCall(id: "read_\(i)", tool: "read", description: "Read config file #\(i+1) (~1KB)",
                                       rawBytes: 1000, optimizedBytes: 1000, feature: "read"))
            }
            for i in 0..<2 {
                c.append(SimulatedCall(id: "lint_\(i)", tool: "exec", description: "Run linter (300 lines output)",
                                       rawBytes: 10000, optimizedBytes: 300, feature: "sandbox"))
            }
            for i in 0..<3 {
                c.append(SimulatedCall(id: "build_\(i)", tool: "exec", description: "Build step \(i+1) (200 lines output)",
                                       rawBytes: 12000, optimizedBytes: 600, feature: "filter"))
            }
            for i in 0..<4 {
                c.append(SimulatedCall(id: "test_\(i)", tool: "exec", description: "Test suite \(i+1) (500 lines output)",
                                       rawBytes: 15000, optimizedBytes: 450, feature: "sandbox"))
            }
            for i in 0..<2 {
                c.append(SimulatedCall(id: "deploy_\(i)", tool: "exec", description: "Deploy step \(i+1)",
                                       rawBytes: 5000, optimizedBytes: 2500, feature: "filter"))
            }
            c.append(SimulatedCall(id: "validate_0", tool: "validate", description: "Final type-check",
                                   rawBytes: 1000, optimizedBytes: 50, feature: "validate"))
            return c
        }()
    )
}
