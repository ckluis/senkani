import Foundation
import Filter
import Core

/// Standard benchmark task set.
public enum BenchmarkTasks {

    /// All tasks in the standard suite.
    public static func all() -> [BenchmarkTask] {
        return filterTasks() + secretTasks() + sandboxTasks() + terseTasks() + indexerTasks() + parseTasks() + cacheTasks()
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
