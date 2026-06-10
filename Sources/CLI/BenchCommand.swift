import ArgumentParser
import Foundation
import Bench

/// `senkani bench` — benchmark host. Per docs/cli-conventions.md the
/// parent does no work itself; it hosts two verbs:
///
///   • `savings` (DEFAULT — bare `senkani bench` keeps its historical
///     behavior + flags): the token-savings suite, 10 tasks × 7 configs.
///   • `pii` (phase-t2-pii-bench-target-2026-06-09): headless
///     PII-classifier bench with an injected stub backend.
///
/// The parent declares NO options. ArgumentParser binds parent-declared
/// option names greedily even when they appear after a subcommand name,
/// so a parent-level `--json` would shadow the subcommands' `--json` —
/// that is why the savings flags live on the `Savings` subcommand.
struct BenchCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "bench",
        abstract: "Run the Senkani benchmark suites.",
        subcommands: [Savings.self, Pii.self],
        defaultSubcommand: Savings.self
    )

    /// The original `senkani bench` body — token-savings suite.
    struct Savings: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "savings",
            abstract: "Run the Senkani token savings benchmark suite."
        )

        @Option(name: .long, help: "Write the report as JSON to this file.")
        var json: String?

        @Option(name: .long, help: "Comma-separated task categories to run (e.g. 'filter,cache'). Runs all if omitted.")
        var categories: String?

        @Flag(name: .long, help: "Exit with non-zero status if any quality gate fails.")
        var strict = false

        func run() throws {
            let allTasks = BenchmarkTasks.all()

            let tasks: [BenchmarkTask]
            if let filter = categories {
                let wanted = Set(filter.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
                tasks = allTasks.filter { wanted.contains($0.category) }
                guard !tasks.isEmpty else {
                    print("No tasks match categories: \(filter)")
                    print("Available categories: \(Set(allTasks.map(\.category)).sorted().joined(separator: ", "))")
                    throw ExitCode.failure
                }
            } else {
                tasks = allTasks
            }

            let report = SavingsTestRunner.run(tasks: tasks)

            // Print text report
            print(BenchmarkReporter.textReport(report))

            // Optionally write JSON
            if let jsonPath = json {
                let data = try BenchmarkReporter.jsonReport(report)
                let url = URL(fileURLWithPath: jsonPath)
                try data.write(to: url)
                print("JSON report written to \(jsonPath)")
            }

            // Exit with failure if strict mode and any gate failed
            if strict && !report.allGatesPassed {
                throw ExitCode.failure
            }
        }
    }

    /// `senkani bench pii` — headless PII-classifier bench
    /// (T.2 carve child A, `phase-t2-pii-bench-target-2026-06-09`).
    /// Times the classifier decode path with the injected STUB backend
    /// (synthetic one-hot logits through the real BIOES/Viterbi
    /// decoder): no MLX model load, no network, no weights on disk.
    /// Emits cold/warm/shape rows in the standard Bench report format.
    /// Real-model perf stays the operator leg of
    /// `phase-t2-pii-classifier-backend-wiring`.
    struct Pii: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "pii",
            abstract: "Headless PII-classifier bench: cold/warm/shape rows via an injected stub backend (no model load)."
        )

        @Option(name: .long, help: "Warm reuse-call iterations after the cold call (default 32).")
        var warmIterations: Int = PIIBenchRunner.defaultWarmIterations

        @Option(name: .long, help: "PII softmax floor handed to the backend (default 0.85).")
        var threshold: Double = PIIBenchRunner.defaultThreshold

        @Option(name: .long, help: "Write the report as JSON to this file.")
        var json: String?

        @Flag(name: .long, help: "Exit with non-zero status if the output-shape gate fails.")
        var strict = false

        func run() throws {
            let measurement = try PIIBenchRunner.run(
                backend: PIIBenchRunner.stubBackend(),
                threshold: threshold,
                warmIterations: warmIterations
            )
            let report = PIIBenchRunner.report(measurement: measurement)

            print(BenchmarkReporter.textReport(report))

            if let jsonPath = json {
                let data = try BenchmarkReporter.jsonReport(report)
                try data.write(to: URL(fileURLWithPath: jsonPath))
                print("JSON report written to \(jsonPath)")
            }

            if strict && !report.allGatesPassed {
                throw ExitCode.failure
            }
        }
    }
}
