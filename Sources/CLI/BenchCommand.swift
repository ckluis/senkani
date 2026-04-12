import ArgumentParser
import Foundation
import Bench

struct BenchCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "bench",
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
