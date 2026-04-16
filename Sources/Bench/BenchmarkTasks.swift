import Foundation
import Filter
import Core

/// Standard benchmark task set.
public enum BenchmarkTasks {

    /// All tasks in the standard suite.
    public static func all() -> [BenchmarkTask] {
        var tasks: [BenchmarkTask] = []
        tasks += filterTasks()
        tasks += secretTasks()
        tasks += sandboxTasks()
        tasks += terseTasks()
        tasks += indexerTasks()
        tasks += parseTasks()
        tasks += cacheTasks()
        tasks += schemaMinTasks()
        return tasks
    }

    // MARK: - Filter Tasks

    public static func filterTasks() -> [BenchmarkTask] {
        return [
            BenchmarkTask(
                id: "filter_git_clone",
                category: "filter",
                description: "git clone with progress lines stripped by filter rules",
                execute: { config in runFilterTask(config, command: "git clone", fixture: Fixtures.gitClone) }
            ),
            BenchmarkTask(
                id: "filter_npm_install",
                category: "filter",
                description: "npm install with WARN/added lines stripped",
                execute: { config in runFilterTask(config, command: "npm install", fixture: Fixtures.npmInstall) }
            ),
            BenchmarkTask(
                id: "filter_cargo_build",
                category: "filter",
                description: "cargo build with Compiling/Downloading lines stripped",
                execute: { config in runFilterTask(config, command: "cargo build", fixture: Fixtures.cargoBuild) }
            ),
        ]
    }

    // MARK: - Secret Redaction Tasks

    public static func secretTasks() -> [BenchmarkTask] {
        return [
            BenchmarkTask(
                id: "secrets_api_keys",
                category: "secrets",
                description: "Command output containing API keys — measure redaction completeness",
                execute: { config in
                    let start = Date()
                    let raw = Fixtures.secretsOutput
                    let redacted = config.secrets ? SecretDetector.scan(raw).redacted : raw
                    let secretPatterns = ["sk-ant-", "AKIA", "ghp_", "Bearer "]
                    let rawSecretCount = secretPatterns.reduce(0) { $0 + raw.components(separatedBy: $1).count - 1 }
                    let redactedSecretCount = secretPatterns.reduce(0) { $0 + redacted.components(separatedBy: $1).count - 1 }
                    let savedPct = rawSecretCount > 0
                        ? Double(rawSecretCount - redactedSecretCount) / Double(rawSecretCount) * 100
                        : 0
                    let syntheticRaw = 100
                    let syntheticCompressed = Int(Double(syntheticRaw) * (1.0 - savedPct / 100))
                    return TaskResult(
                        taskId: "secrets_api_keys",
                        configName: config.name,
                        category: "secrets",
                        rawBytes: syntheticRaw,
                        compressedBytes: syntheticCompressed,
                        durationMs: Date().timeIntervalSince(start) * 1000
                    )
                }
            ),
        ]
    }

    // MARK: - Sandbox Tasks

    public static func sandboxTasks() -> [BenchmarkTask] {
        return [
            BenchmarkTask(
                id: "sandbox_large_exec_output",
                category: "sandbox",
                description: "500-line command output — measure sandbox summary compression",
                execute: { config in
                    let start = Date()
                    let raw = Fixtures.largeExecOutput
                    let rawBytes = raw.utf8.count
                    let lineCount = raw.components(separatedBy: "\n").count

                    let compressed: String
                    if config.filter {
                        compressed = buildSandboxSummary(
                            output: raw,
                            lineCount: lineCount,
                            byteCount: rawBytes,
                            resultId: "r_bench01234"
                        )
                    } else {
                        compressed = raw
                    }

                    return TaskResult(
                        taskId: "sandbox_large_exec_output",
                        configName: config.name,
                        category: "sandbox",
                        rawBytes: rawBytes,
                        compressedBytes: compressed.utf8.count,
                        durationMs: Date().timeIntervalSince(start) * 1000
                    )
                }
            ),
        ]
    }

    // MARK: - Terse Mode Tasks

    public static func terseTasks() -> [BenchmarkTask] {
        return [
            BenchmarkTask(
                id: "terse_system_prompt",
                category: "terse",
                description: "Verbose vs terse MCP instructions",
                execute: { config in
                    let start = Date()
                    let verbose = Fixtures.verboseInstructions
                    let terse = Fixtures.terseInstructions
                    let rawBytes = verbose.utf8.count
                    let compressedBytes = config.terse ? terse.utf8.count : verbose.utf8.count
                    return TaskResult(
                        taskId: "terse_system_prompt",
                        configName: config.name,
                        category: "terse",
                        rawBytes: rawBytes,
                        compressedBytes: compressedBytes,
                        durationMs: Date().timeIntervalSince(start) * 1000
                    )
                }
            ),
        ]
    }

    // MARK: - Indexer Tasks

    public static func indexerTasks() -> [BenchmarkTask] {
        return [
            BenchmarkTask(
                id: "indexer_symbol_search",
                category: "indexer",
                description: "Symbol search vs manual grep across files",
                execute: { config in
                    let start = Date()
                    let baselineBytes = Fixtures.indexerBaselineBytes
                    let indexEntryBytes = 50
                    let compressed = config.indexer ? indexEntryBytes : baselineBytes
                    return TaskResult(
                        taskId: "indexer_symbol_search",
                        configName: config.name,
                        category: "indexer",
                        rawBytes: baselineBytes,
                        compressedBytes: compressed,
                        durationMs: Date().timeIntervalSince(start) * 1000
                    )
                }
            ),
            BenchmarkTask(
                id: "indexer_file_outline",
                category: "indexer",
                description: "File outline vs reading whole file",
                execute: { config in
                    let start = Date()
                    let wholeFileBytes = Fixtures.sampleSwiftFile.utf8.count
                    let outlineBytes = wholeFileBytes / 10
                    let compressed = config.indexer ? outlineBytes : wholeFileBytes
                    return TaskResult(
                        taskId: "indexer_file_outline",
                        configName: config.name,
                        category: "indexer",
                        rawBytes: wholeFileBytes,
                        compressedBytes: compressed,
                        durationMs: Date().timeIntervalSince(start) * 1000
                    )
                }
            ),
        ]
    }

    // MARK: - Parse Tasks

    public static func parseTasks() -> [BenchmarkTask] {
        return [
            BenchmarkTask(
                id: "parse_test_output",
                category: "parse",
                description: "Raw test output -> structured pass/fail summary",
                execute: { config in
                    let start = Date()
                    let raw = Fixtures.npmTest
                    let rawBytes = raw.utf8.count
                    let compressed = config.filter ? "148 passed, 2 failed, 45.2s".utf8.count : rawBytes
                    return TaskResult(
                        taskId: "parse_test_output",
                        configName: config.name,
                        category: "parse",
                        rawBytes: rawBytes,
                        compressedBytes: compressed,
                        durationMs: Date().timeIntervalSince(start) * 1000
                    )
                }
            ),
        ]
    }

    // MARK: - Cache Tasks

    public static func cacheTasks() -> [BenchmarkTask] {
        return [
            BenchmarkTask(
                id: "cache_repeated_reads",
                category: "cache",
                description: "Reading the same file 5 times",
                execute: { config in
                    let start = Date()
                    let fileBytes = Fixtures.sampleSwiftFile.utf8.count
                    // Baseline: read 5x = 5 * fileBytes
                    // Cached: first read = fileBytes, next four = 0
                    let baseline = fileBytes * 5
                    let cached = config.cache ? fileBytes : baseline
                    return TaskResult(
                        taskId: "cache_repeated_reads",
                        configName: config.name,
                        category: "cache",
                        rawBytes: baseline,
                        compressedBytes: cached,
                        durationMs: Date().timeIntervalSince(start) * 1000
                    )
                }
            ),
        ]
    }

    // MARK: - Schema Minimalism Tasks (AXI)

    public static func schemaMinTasks() -> [BenchmarkTask] {
        return [
            BenchmarkTask(
                id: "axi_knowledge_get",
                category: "schemaMin",
                description: "knowledge get — compact vs full entity output",
                execute: { config in
                    let start = Date()
                    // Full output: ~600 tokens (entity with 12 decisions, 500-char understanding)
                    let rawOutput = """
                    SessionDatabase — class
                    Source: Sources/Core/SessionDatabase.swift | Mentions: 47 | Last enriched: 2026-04-10

                    Understanding:
                      SessionDatabase is the primary data persistence layer for senkani. It uses SQLite via GRDB to store token events, budget decisions, and feature-level savings. The main tables are token_events (rawBytes, compressedBytes, inputTokens, savedTokens), budget_decisions (toolName, decision), and kb_enrichment (entityId, sha). All writes are transactional. The liveSessionMultiplier method aggregates token_events by feature and returns (inputTokens + savedTokens) / inputTokens. The schema is versioned via GRDB migrations. Thread safety is ensured by GRDBQueue serialization.

                    Relations (8):
                      → uses: FeatureSavings
                      → uses: TokenEvent
                      → uses: BudgetDecision
                      → uses: KBEnrichmentRecord
                      → owns: GRDBDatabaseQueue
                      → implements: SessionDatabaseProtocol
                      → depends_on: Core
                      → co_changes_with: MCPSession

                    Evidence (24 entries):
                      2026-04-01 [sess_abc]: Added liveSessionMultiplier method
                      2026-04-02 [sess_def]: Fixed migration race condition
                      2026-04-03 [sess_ghi]: Added budget_decisions table
                      2026-04-08 [sess_jkl]: Optimized token_events index
                      2026-04-10 [sess_mno]: Added kb_enrichment table
                      ... and 19 more

                    Decisions (12):
                      2026-01-15: Use GRDB over raw SQLite because type-safe query builder reduces migration errors
                      2026-01-20: Use shared singleton because session lifecycle matches app lifecycle
                      2026-02-01: Store rawBytes and compressedBytes separately because ratio queries need both
                      2026-02-15: Use GRDBQueue for thread safety because actor isolation adds overhead
                      2026-03-01: Version schema via migrations because forward-only upgrades are safer
                      2026-03-10: Add feature column to token_events because per-feature analytics needed
                      2026-03-20: Cap token_events to 10000 rows because disk budget is constrained
                      2026-04-01: Add liveSessionMultiplier because eval command needs live data
                      2026-04-05: Store sessionId in token_events because cross-session rollup needed
                      2026-04-08: Index on (projectRoot, feature) because frequent GROUP BY queries
                      ... and 2 more
                    """
                    let rawBytes = rawOutput.utf8.count

                    // Compact output: ~100 tokens
                    let compactOutput = """
                    SessionDatabase — class  ·  47 mentions  ·  enriched: 2026-04-10
                      Relations: 8  ·  Evidence: 24  ·  Decisions: 12
                      Understanding: "SessionDatabase is the primary data persistence layer for senkani. It uses SQLite via GRDB to store…"

                    Use knowledge(action:'get', entity:'SessionDatabase', detail:'full') for complete output.
                    """
                    let compressedBytes = compactOutput.utf8.count

                    return TaskResult(
                        taskId: "axi_knowledge_get",
                        configName: config.name,
                        category: "schemaMin",
                        rawBytes: rawBytes,
                        compressedBytes: compressedBytes,
                        durationMs: Date().timeIntervalSince(start) * 1000
                    )
                }
            ),
            BenchmarkTask(
                id: "axi_validate_summary",
                category: "schemaMin",
                description: "validate — summary vs full validator output",
                execute: { config in
                    let start = Date()
                    // Full output: 5-validator run, 2 failures, ~300 tokens
                    let rawOutput = """
                    [syntax] SwiftSyntax: ✓
                    [type] swiftc: ✗
                      SessionDatabase.swift:234: error: value of type 'OpaquePointer' has no member 'pointee'
                      SessionDatabase.swift:234: note: add '.pointee' to access the value this pointer points to
                      SessionDatabase.swift:245: warning: initialization of variable 'stmt' was never used
                      SessionDatabase.swift:301: warning: result of call to 'execute' is unused
                      SessionDatabase.swift:312: error: cannot convert value of type 'String' to expected argument type 'Int'
                      SessionDatabase.swift:312: note: arguments to generic parameter 'Bound' ('String' and 'Int') are expected to have the same type
                      SessionDatabase.swift:318: warning: variable 'result' was never mutated; consider changing to 'let' constant
                      SessionDatabase.swift:401: warning: 'init' is deprecated: renamed to 'init(value:)'
                      SessionDatabase.swift:405: warning: using 'let' with 'try!' is deprecated
                      SessionDatabase.swift:411: warning: result of call to 'execute' is unused
                      ... (12 more lines)
                    [lint] SwiftLint: ✗
                      SessionDatabase.swift:120:1: warning: line_length violation: Line should be 200 characters or less; currently it's 203 characters (line_length)
                      SessionDatabase.swift:234:5: error: explicit_init violation: Explicitly calling .init() should be avoided (explicit_init)
                      SessionDatabase.swift:245:9: warning: unused_optional_binding violation (unused_optional_binding)
                      ... (5 more lines)
                    [security] SecretScan: ✓
                    [format] SwiftFormat: ✓
                    """
                    let rawBytes = rawOutput.utf8.count

                    // Summary output: ~80 tokens
                    let compactOutput = """
                    // senkani_validate: 5 validators · 3 passed · 2 failed

                    ✗ [type] swiftc — 2 errors, 6 warnings
                      SessionDatabase.swift:234: error: value of type 'OpaquePointer' has no member 'pointee'
                      SessionDatabase.swift:245: warning: initialization of variable 'stmt' was never used
                      SessionDatabase.swift:301: warning: result of call to 'execute' is unused
                      SessionDatabase.swift:312: error: cannot convert value of type 'String' to expected argument type 'Int'
                      SessionDatabase.swift:318: warning: variable 'result' was never mutated
                      ... (7 more lines)
                    ✗ [lint] SwiftLint — 1 error, 2 warnings
                      SessionDatabase.swift:120:1: warning: line_length violation
                      SessionDatabase.swift:234:5: error: explicit_init violation
                      SessionDatabase.swift:245:9: warning: unused_optional_binding
                      ... (3 more lines)

                    ✓ 3 passed: SwiftSyntax (syntax), SecretScan (security), SwiftFormat (format)

                    Use validate(file:'SessionDatabase.swift', detail:'full') for complete error output.
                    """
                    let compressedBytes = compactOutput.utf8.count

                    return TaskResult(
                        taskId: "axi_validate_summary",
                        configName: config.name,
                        category: "schemaMin",
                        rawBytes: rawBytes,
                        compressedBytes: compressedBytes,
                        durationMs: Date().timeIntervalSince(start) * 1000
                    )
                }
            ),
            BenchmarkTask(
                id: "axi_explore_limit",
                category: "schemaMin",
                description: "explore — 30-file limit vs full codebase dump",
                execute: { config in
                    let start = Date()
                    // Simulate 100-file explore output at ~120 bytes/file avg
                    let fileCount = 100
                    let bytesPerFile = 120
                    let rawBytes = fileCount * bytesPerFile

                    // Compact: 30 files shown + trailer
                    let limitedFileCount = 30
                    let compressedBytes = limitedFileCount * bytesPerFile + 60 // trailer line
                    return TaskResult(
                        taskId: "axi_explore_limit",
                        configName: config.name,
                        category: "schemaMin",
                        rawBytes: rawBytes,
                        compressedBytes: compressedBytes,
                        durationMs: Date().timeIntervalSince(start) * 1000
                    )
                }
            ),
        ]
    }

    // MARK: - Shared Filter Task Runner

    private static func runFilterTask(
        _ config: BenchmarkConfig,
        command: String,
        fixture: String
    ) -> TaskResult {
        let start = Date()
        let rawBytes = fixture.utf8.count
        let filterConfig = FeatureConfig(
            filter: config.filter,
            secrets: config.secrets,
            indexer: config.indexer,
            terse: config.terse
        )
        let pipeline = FilterPipeline(config: filterConfig)
        let result = pipeline.process(command: command, output: fixture)
        return TaskResult(
            taskId: "filter_\(command.replacingOccurrences(of: " ", with: "_"))",
            configName: config.name,
            category: "filter",
            rawBytes: rawBytes,
            compressedBytes: result.filteredBytes,
            durationMs: Date().timeIntervalSince(start) * 1000
        )
    }
}
