import Foundation
import Core

/// Mines git history to populate co_change_coupling.
/// Returns (pairs written, commits analyzed). Idempotent — upsertCoupling is ON CONFLICT UPDATE.
enum ChangeSetMiner {

    @discardableResult
    static func mine(
        projectRoot: String,
        store: KnowledgeStore,
        commitLimit: Int = 200
    ) -> (pairs: Int, commits: Int) {
        guard FileManager.default.fileExists(atPath: projectRoot + "/.git") else { return (0, 0) }

        // 1. Build path index: repo-relative file path → [entity names]
        let entities = store.allEntities()
        let pathIndex = buildPathIndex(entities, projectRoot: projectRoot)
        guard !pathIndex.isEmpty else { return (0, 0) }

        // 2. Run git log
        let log = gitLog(at: projectRoot, limit: commitLimit)
        guard !log.isEmpty else { return (0, 0) }

        // 3. Parse log → [Set<entityName>] per commit
        let commits = parseLog(log, pathIndex: pathIndex)
        let totalCommits = commits.count
        guard totalCommits >= 2 else { return (0, totalCommits) }

        // 4. Count co-change pairs
        var counts: [String: Int] = [:]
        for entitySet in commits {
            let sorted = entitySet.sorted()
            for i in 0..<sorted.count {
                for j in (i + 1)..<sorted.count {
                    counts["\(sorted[i])|\(sorted[j])", default: 0] += 1
                }
            }
        }

        // 5. Upsert significant pairs (≥2 co-changes AND score ≥ 5%)
        var pairCount = 0
        for (key, count) in counts {
            guard count >= 2 else { continue }
            let score = Double(count) / Double(totalCommits)
            guard score >= 0.05 else { continue }
            let parts = key.split(separator: "|", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            store.upsertCoupling(CouplingEntry(
                entityA: parts[0], entityB: parts[1],
                commitCount: count, totalCommits: totalCommits,
                couplingScore: score
            ))
            pairCount += 1
        }
        return (pairCount, totalCommits)
    }

    // MARK: - Internal (testable)

    static func buildPathIndex(
        _ entities: [KnowledgeEntity],
        projectRoot: String
    ) -> [String: [String]] {
        let prefix = projectRoot.hasSuffix("/") ? projectRoot : projectRoot + "/"
        var index: [String: [String]] = [:]
        for entity in entities {
            guard let sp = entity.sourcePath else { continue }
            // Normalize absolute paths to repo-relative
            let norm = sp.hasPrefix("/") && sp.hasPrefix(prefix)
                ? String(sp.dropFirst(prefix.count))
                : sp
            index[norm, default: []].append(entity.name)
        }
        return index
    }

    static func parseLog(
        _ log: String,
        pathIndex: [String: [String]]
    ) -> [Set<String>] {
        var commits: [Set<String>] = []
        var current: Set<String> = []
        for line in log.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("commit ") {
                if !current.isEmpty { commits.append(current); current = [] }
            } else if !trimmed.isEmpty {
                if let names = pathIndex[trimmed] { current.formUnion(names) }
            }
        }
        if !current.isEmpty { commits.append(current) }
        return commits
    }

    // MARK: - Private

    private static func gitLog(at root: String, limit: Int) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["log", "--no-merges", "--format=commit %H",
                             "--name-only", "-\(limit)"]
        process.currentDirectoryURL = URL(fileURLWithPath: root)
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return "" }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return "" }
        return String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }
}
