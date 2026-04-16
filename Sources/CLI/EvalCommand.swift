import ArgumentParser
import Foundation
import Core
import Bench

struct Eval: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "eval",
        abstract: "Run quality gates: bench savings + KB health + regression check."
    )

    @Option(name: .long, help: "Project root directory.")
    var root: String?

    @Flag(name: .long, help: "Save current results as the new baseline.")
    var updateBaseline = false

    @Flag(name: .long, help: "Exit 1 if ANY gate fails (default: only on savings regression).")
    var strict = false

    @Flag(name: .long, help: "Print the full report as JSON.")
    var json = false

    @Option(name: .long, help: "Live multiplier lookback window in days (default: 7).")
    var since: Int = 7

    @Option(name: .long, help: "Filter live stats to a specific agent type (e.g. claude_code, cursor, cline).")
    var agent: String?

    func run() throws {
        let projectRoot = root ?? FileManager.default.currentDirectoryPath

        // 1. Run bench savings tasks
        print("Running bench tasks…")
        var report = SavingsTestRunner.run(tasks: BenchmarkTasks.all())

        // 2. KB health gates
        let kbGates = KBGateComputer.computeGates(projectRoot: projectRoot)
        report = report.appending(gates: kbGates)

        // 3. Regression gates (when a baseline exists)
        var hasBaseline = false
        if let baseline = BenchBaseline.load(projectRoot: projectRoot) {
            hasBaseline = true
            let regressionGates = BenchBaseline.computeRegressionGates(
                results: report.results, baseline: baseline)
            report = report.appending(gates: regressionGates)
        }

        // 4. Live multiplier from real token_events
        let lookback = Date().addingTimeInterval(-Double(since) * 86400)
        let liveMultiplier = SessionDatabase.shared.liveSessionMultiplier(
            projectRoot: projectRoot, since: lookback)

        // 4b. Per-agent breakdown (always shown in text mode when data exists)
        let agentStats = SessionDatabase.shared.tokenStatsByAgent(
            projectRoot: projectRoot,
            since: lookback
        )

        // 5. Output
        if json {
            if let data = try? BenchmarkReporter.jsonReport(report),
               var obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                obj["fixtureMultiplier"] = report.overallMultiplier
                obj["liveMultiplier"] = liveMultiplier ?? 0
                obj["liveSinceDays"] = since
                if let merged = try? JSONSerialization.data(withJSONObject: obj, options: .prettyPrinted),
                   let str = String(data: merged, encoding: .utf8) {
                    print(str)
                }
            } else if let data = try? BenchmarkReporter.jsonReport(report),
                      let str = String(data: data, encoding: .utf8) {
                print(str)
            }
        } else {
            print(BenchmarkReporter.textReport(report))
            printExtraGates(report.gates)
            if !hasBaseline {
                print("(No baseline — run with --update-baseline after first passing eval)")
            }
            let liveStr = liveMultiplier.map { String(format: "%.1fx", $0) } ?? "no data"
            print(String(format: "multiplier  fixture: %.2fx  live: %@  (%dd window)",
                         report.overallMultiplier, liveStr, since))

            // Agent breakdown (filtered by --agent if provided)
            let filtered = agent.flatMap { AgentType(rawValue: $0) }
                .map { type_ in agentStats.filter { $0.agentType == type_ } }
                ?? agentStats
            if !filtered.isEmpty {
                print("")
                print("Agent breakdown (\(since)d window):")
                for stat in filtered {
                    let name = stat.agentType.displayName.padding(toLength: 20, withPad: " ", startingAt: 0)
                    print("  \(name)  \(stat.sessionCount) sessions  saved: \(stat.savedTokens) tokens  [\(stat.agentType.methodologyLabel)]")
                }
            }
        }

        // 5. Persist baseline if requested
        if updateBaseline {
            try BenchBaseline.save(BenchBaseline.from(report: report), projectRoot: projectRoot)
            print("\nBaseline saved: \(projectRoot)/.senkani/bench-baseline.json")
        }

        // 6. Exit code: always block on regression; --strict blocks on any failure
        let failedRegressions = report.gates.filter { $0.category == "regression" && !$0.passed }
        if strict && !report.allGatesPassed { throw ExitCode.failure }
        if !failedRegressions.isEmpty { throw ExitCode.failure }
    }

    /// Print KB and regression gates below the standard bench report.
    private func printExtraGates(_ gates: [QualityGate]) {
        let extra = gates.filter { $0.category == "kb" || $0.category == "regression" }
        guard !extra.isEmpty else { return }
        let separator = String(repeating: "─", count: 63)
        print("Extra Gates")
        print(separator)
        for g in extra {
            let mark = g.passed ? "✓" : "✗"
            let name = g.name.padding(toLength: 28, withPad: " ", startingAt: 0)
            let actual    = String(format: "%6.2f", g.actual)
            let threshold = String(format: "%6.2f", g.threshold)
            print("  \(mark) \(name) \(actual) (threshold: \(threshold))")
        }
        print(separator)
        let passed = extra.filter(\.passed).count
        print("  \(passed)/\(extra.count) extra gates passed")
        print("")
    }
}
