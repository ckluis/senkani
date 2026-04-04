import ArgumentParser
import Foundation
import Core

struct Stats: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "View session metrics."
    )

    @Flag(name: .long, help: "Show the last completed session.")
    var last = false

    @Flag(name: .long, help: "Compare two most recent sessions (filtered vs unfiltered).")
    var compare = false

    @Option(name: .long, help: "Path to metrics file.")
    var file: String?

    func run() throws {
        if compare {
            try runCompare()
            return
        }

        let targetPath = try resolveMetricsPath()
        let summary = try loadSummary(from: targetPath)
        printSummary(summary, path: targetPath)
    }

    private func runCompare() throws {
        let files = try findMetricsFiles()
        guard files.count >= 2 else {
            print("Need at least 2 session files to compare.")
            print("Run sessions with SENKANI_MODE=filter and SENKANI_MODE=passthrough, then compare.")
            return
        }

        let a = try loadSummary(from: files[0].path)
        let b = try loadSummary(from: files[1].path)

        // Determine which is filtered vs passthrough by savings
        let (filtered, baseline) = a.savings > b.savings ? (a, b) : (b, a)
        let (filteredPath, baselinePath) = a.savings > b.savings
            ? (files[0].path, files[1].path)
            : (files[1].path, files[0].path)

        print("")
        print("Session comparison")
        print("═══════════════════════════════════════════════════")
        print("  Baseline:  \(baselinePath)")
        print("    Commands: \(baseline.count), Raw: \(formatBytes(baseline.raw)), Savings: \(String(format: "%.0f", baseline.savings))%")
        print("")
        print("  Filtered:  \(filteredPath)")
        print("    Commands: \(filtered.count), Raw: \(formatBytes(filtered.raw)), Savings: \(String(format: "%.0f", filtered.savings))%")
        print("")
        print("  Delta")
        print("  ─────")
        let deltaBytes = filtered.totalFiltered < baseline.totalFiltered
            ? baseline.totalFiltered - filtered.totalFiltered
            : 0
        let deltaPct = filtered.savings - baseline.savings
        print("    Additional bytes saved: \(formatBytes(deltaBytes))")
        print("    Savings improvement:    \(String(format: "+%.1f", deltaPct)) percentage points")
        if baseline.raw > 0 && filtered.raw > 0 {
            let ratio = Double(baseline.totalFiltered) / Double(max(1, filtered.totalFiltered))
            print("    Compression ratio:      \(String(format: "%.1f", ratio))x")
        }
        print("")
    }

    private func resolveMetricsPath() throws -> String {
        if let f = file { return f }

        if last {
            let files = try findMetricsFiles()
            guard let latest = files.first else {
                throw ValidationError("No session metrics found in /tmp/")
            }
            return latest.path
        }

        return ProcessInfo.processInfo.environment["SENKANI_METRICS_FILE"]
            ?? "/tmp/senkani-session-\(ProcessInfo.processInfo.processIdentifier).jsonl"
    }

    private func findMetricsFiles() throws -> [(path: String, date: Date)] {
        let tmpDir = "/tmp"
        return try FileManager.default.contentsOfDirectory(atPath: tmpDir)
            .filter { $0.hasPrefix("senkani-session-") && $0.hasSuffix(".jsonl") }
            .compactMap { name -> (path: String, date: Date)? in
                let path = tmpDir + "/" + name
                guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                      let date = attrs[.modificationDate] as? Date else { return nil }
                return (path, date)
            }
            .sorted { $0.date > $1.date }
    }

    struct MetricsSummary {
        let count: Int
        let raw: Int
        let totalFiltered: Int
        let breakdown: [(command: String, raw: Int, filtered: Int, count: Int)]

        var savings: Double {
            guard raw > 0 else { return 0 }
            return Double(raw - totalFiltered) / Double(raw) * 100
        }
    }

    private func loadSummary(from path: String) throws -> MetricsSummary {
        guard FileManager.default.fileExists(atPath: path) else {
            throw ValidationError("No metrics file at \(path)")
        }
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else {
            throw ValidationError("Could not read \(path)")
        }

        let decoder = JSONDecoder()
        var totalRaw = 0
        var totalFiltered = 0
        var count = 0
        var byCommand: [String: (raw: Int, filtered: Int, count: Int)] = [:]

        for line in content.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let m = try? decoder.decode(SessionMetrics.CommandMetric.self, from: data) else { continue }
            totalRaw += m.rawBytes
            totalFiltered += m.filteredBytes
            count += 1

            let base = m.command.split(separator: " ").first.map(String.init) ?? m.command
            let e = byCommand[base, default: (0, 0, 0)]
            byCommand[base] = (e.raw + m.rawBytes, e.filtered + m.filteredBytes, e.count + 1)
        }

        let breakdown = byCommand
            .map { (command: $0.key, raw: $0.value.raw, filtered: $0.value.filtered, count: $0.value.count) }
            .sorted { a, b in
                let aPct = a.raw > 0 ? Double(a.raw - a.filtered) / Double(a.raw) : 0
                let bPct = b.raw > 0 ? Double(b.raw - b.filtered) / Double(b.raw) : 0
                return aPct > bPct
            }

        return MetricsSummary(count: count, raw: totalRaw, totalFiltered: totalFiltered, breakdown: breakdown)
    }

    private func printSummary(_ s: MetricsSummary, path: String) {
        guard s.count > 0 else {
            print("Metrics file is empty.")
            return
        }

        print("")
        print("Session metrics (\(path))")
        print("  Commands: \(s.count)")
        print("  Raw output:  \(formatBytes(s.raw))")
        print("  Filtered:    \(formatBytes(s.totalFiltered)) (\(String(format: "%.0f", s.savings))% reduction)")
        print("")
        print("  Per-command breakdown:")
        for item in s.breakdown {
            let pct = item.raw > 0 ? String(format: "%.0f", Double(item.raw - item.filtered) / Double(item.raw) * 100) : "0"
            print("    \(item.command.padding(toLength: 16, withPad: " ", startingAt: 0))→ \(pct)% saved (\(item.count) calls)")
        }
        print("")
    }

    private func formatBytes(_ bytes: Int) -> String {
        if bytes >= 1_000_000 { return String(format: "%.1fM bytes", Double(bytes) / 1_000_000) }
        if bytes >= 1_000 { return String(format: "%.1fK bytes", Double(bytes) / 1_000) }
        return "\(bytes) bytes"
    }
}
