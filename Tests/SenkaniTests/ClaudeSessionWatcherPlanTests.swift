import Testing
import Foundation
@testable import Core

@Suite("ClaudeSessionWatcherPlan — burst-rotation drain plan")
struct ClaudeSessionWatcherPlanTests {

    private func mtimeMap(_ pairs: [(String, TimeInterval)]) -> (String) -> Date {
        let table = Dictionary(uniqueKeysWithValues: pairs.map { ($0.0, Date(timeIntervalSince1970: $0.1)) })
        return { path in table[path] ?? .distantPast }
    }

    @Test func emptyDirectoryReturnsEmptyPlan() {
        let plan = ClaudeSessionWatcherPlan.plan(
            directoryFiles: [],
            dirPath: "/d",
            currentWatched: nil,
            drainedFiles: [],
            mtime: { _ in .distantPast }
        )
        #expect(plan.toDrain == [])
        #expect(plan.newWatched == nil)
    }

    @Test func firstFileBecomesWatched_noDrain() {
        let plan = ClaudeSessionWatcherPlan.plan(
            directoryFiles: ["probe-1.jsonl"],
            dirPath: "/d",
            currentWatched: nil,
            drainedFiles: [],
            mtime: mtimeMap([("/d/probe-1.jsonl", 1)])
        )
        #expect(plan.toDrain == [])
        #expect(plan.newWatched == "/d/probe-1.jsonl")
    }

    @Test func indexFilesIgnored() {
        let plan = ClaudeSessionWatcherPlan.plan(
            directoryFiles: ["index.jsonl", "probe-1.jsonl"],
            dirPath: "/d",
            currentWatched: nil,
            drainedFiles: [],
            mtime: mtimeMap([
                ("/d/index.jsonl", 100),
                ("/d/probe-1.jsonl", 1),
            ])
        )
        // Even though index.jsonl has a later mtime, it must be filtered out.
        #expect(plan.newWatched == "/d/probe-1.jsonl")
        #expect(plan.toDrain == [])
    }

    @Test func nonJsonlFilesIgnored() {
        let plan = ClaudeSessionWatcherPlan.plan(
            directoryFiles: ["probe-1.jsonl", "README.md", "scratch.txt"],
            dirPath: "/d",
            currentWatched: nil,
            drainedFiles: [],
            mtime: mtimeMap([("/d/probe-1.jsonl", 1)])
        )
        #expect(plan.newWatched == "/d/probe-1.jsonl")
        #expect(plan.toDrain == [])
    }

    @Test func latestIsPickedByMtime_intermediatesDrain() {
        let plan = ClaudeSessionWatcherPlan.plan(
            directoryFiles: ["a.jsonl", "b.jsonl", "c.jsonl"],
            dirPath: "/d",
            currentWatched: nil,
            drainedFiles: [],
            mtime: mtimeMap([
                ("/d/a.jsonl", 100),
                ("/d/b.jsonl", 300),  // newest
                ("/d/c.jsonl", 200),
            ])
        )
        #expect(plan.newWatched == "/d/b.jsonl")
        #expect(plan.toDrain == ["/d/a.jsonl", "/d/c.jsonl"])
    }

    @Test func alreadyWatchingLatest_noChange() {
        let plan = ClaudeSessionWatcherPlan.plan(
            directoryFiles: ["probe-1.jsonl"],
            dirPath: "/d",
            currentWatched: "/d/probe-1.jsonl",
            drainedFiles: [],
            mtime: mtimeMap([("/d/probe-1.jsonl", 100)])
        )
        #expect(plan.newWatched == nil)
        #expect(plan.toDrain == [])
    }

    @Test func priorWatchedDrainsOnRotation() {
        let plan = ClaudeSessionWatcherPlan.plan(
            directoryFiles: ["probe-1.jsonl", "probe-2.jsonl"],
            dirPath: "/d",
            currentWatched: "/d/probe-1.jsonl",
            drainedFiles: [],
            mtime: mtimeMap([
                ("/d/probe-1.jsonl", 100),
                ("/d/probe-2.jsonl", 200),
            ])
        )
        #expect(plan.newWatched == "/d/probe-2.jsonl")
        #expect(plan.toDrain == ["/d/probe-1.jsonl"])
    }

    @Test func drainedFilesSkipped() {
        let plan = ClaudeSessionWatcherPlan.plan(
            directoryFiles: ["probe-1.jsonl", "probe-2.jsonl", "probe-3.jsonl"],
            dirPath: "/d",
            currentWatched: nil,
            drainedFiles: ["/d/probe-1.jsonl"],
            mtime: mtimeMap([
                ("/d/probe-1.jsonl", 100),
                ("/d/probe-2.jsonl", 200),
                ("/d/probe-3.jsonl", 300),
            ])
        )
        #expect(plan.newWatched == "/d/probe-3.jsonl")
        // probe-1 is in drainedFiles → not in plan. probe-2 stays.
        #expect(plan.toDrain == ["/d/probe-2.jsonl"])
    }

    @Test func priorAlreadyDrained_notReDrained() {
        let plan = ClaudeSessionWatcherPlan.plan(
            directoryFiles: ["probe-1.jsonl", "probe-2.jsonl"],
            dirPath: "/d",
            currentWatched: "/d/probe-1.jsonl",
            drainedFiles: ["/d/probe-1.jsonl"],
            mtime: mtimeMap([
                ("/d/probe-1.jsonl", 100),
                ("/d/probe-2.jsonl", 200),
            ])
        )
        #expect(plan.newWatched == "/d/probe-2.jsonl")
        #expect(plan.toDrain == [])
    }

    @Test func burst200Files_singleCall_drainsAll199Intermediates() {
        // Headline scenario: 200 probes created in a tight burst, all
        // visible by the time the watcher's first checkForNewSession runs.
        // Plan must drain probes 1..199 so silent-drop is impossible.
        var basenames: [String] = []
        var pairs: [(String, TimeInterval)] = []
        for i in 1...200 {
            let name = "probe-\(String(format: "%04d", i)).jsonl"
            basenames.append(name)
            pairs.append(("/d/" + name, TimeInterval(i)))
        }
        let plan = ClaudeSessionWatcherPlan.plan(
            directoryFiles: basenames,
            dirPath: "/d",
            currentWatched: nil,
            drainedFiles: [],
            mtime: mtimeMap(pairs)
        )
        #expect(plan.newWatched == "/d/probe-0200.jsonl")
        #expect(plan.toDrain.count == 199)
        #expect(plan.toDrain.first == "/d/probe-0001.jsonl")
        #expect(plan.toDrain.last == "/d/probe-0199.jsonl")
    }

    @Test func burst200Files_incremental_eachIntermediateDrainedExactlyOnce() {
        // Simulate dirSource firing per-file as the burst arrives.
        // After 200 calls, each non-final file should have been planned for
        // drain exactly once across the entire run — proving the
        // drainedFiles set fully amortizes the work.
        var basenames: [String] = []
        var pairs: [(String, TimeInterval)] = []
        var drained: Set<String> = []
        var watched: String? = nil
        var totalDrains = 0
        var perFileDrains: [String: Int] = [:]

        for i in 1...200 {
            let name = "probe-\(String(format: "%04d", i)).jsonl"
            basenames.append(name)
            pairs.append(("/d/" + name, TimeInterval(i)))

            let plan = ClaudeSessionWatcherPlan.plan(
                directoryFiles: basenames,
                dirPath: "/d",
                currentWatched: watched,
                drainedFiles: drained,
                mtime: mtimeMap(pairs)
            )
            for p in plan.toDrain {
                perFileDrains[p, default: 0] += 1
                drained.insert(p)
                totalDrains += 1
            }
            if let nw = plan.newWatched { watched = nw }
        }

        #expect(watched == "/d/probe-0200.jsonl")
        #expect(drained.count == 199)
        #expect(totalDrains == 199, "each non-latest file drains exactly once across all calls (got \(totalDrains))")
        #expect(perFileDrains.values.allSatisfy { $0 == 1 }, "no file should be drained twice")
        #expect(!drained.contains("/d/probe-0200.jsonl"), "current watched file is not in drainedFiles")
    }

    @Test func mtimeTie_pickerStillResolves() {
        // mtime ties are unlikely in practice (HFS+/APFS are nanosecond-
        // resolution) but the planner must still produce a valid plan
        // rather than dropping back to no-op.
        let plan = ClaudeSessionWatcherPlan.plan(
            directoryFiles: ["a.jsonl", "b.jsonl"],
            dirPath: "/d",
            currentWatched: nil,
            drainedFiles: [],
            mtime: { _ in Date(timeIntervalSince1970: 100) }
        )
        // Either file may win (Dictionary.max returns whichever it iterates
        // last); we just require ONE wins and the other drains.
        #expect(plan.newWatched != nil)
        #expect(plan.toDrain.count == 1)
        let won = plan.newWatched!
        let drained = plan.toDrain[0]
        #expect(Set([won, drained]) == Set(["/d/a.jsonl", "/d/b.jsonl"]))
    }
}
