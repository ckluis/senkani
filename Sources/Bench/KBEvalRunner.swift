import Foundation
import Core

/// Computes KB health gates from KnowledgeStore without running bench tasks.
public enum KBGateComputer {

    public static func computeGates(projectRoot: String) -> [QualityGate] {
        let dbPath = projectRoot + "/.senkani/knowledge.db"
        guard FileManager.default.fileExists(atPath: dbPath) else {
            // Vacuous pass — no KB yet (threshold 0, actual 0 → passed)
            return [QualityGate(name: "kb.populated", category: "kb",
                                threshold: 0, actual: 0)]
        }
        let store = KnowledgeStore(projectRoot: projectRoot)
        let all = store.allEntities()
        var gates: [QualityGate] = []

        // Gate 1: populated (≥1 entity)
        gates.append(QualityGate(name: "kb.populated", category: "kb",
                                 threshold: 1, actual: Double(all.count)))

        // Gate 2: freshness — % entities with stalenessScore < 0.3 ≥ 70%
        let fresh = all.filter { $0.stalenessScore < 0.3 }.count
        let freshPct = all.isEmpty ? 1.0 : Double(fresh) / Double(all.count)
        gates.append(QualityGate(name: "kb.freshness", category: "kb",
                                 threshold: 0.70, actual: freshPct))

        // Gate 3: enrichment coverage — of entities with mentionCount≥3, ≥50% enriched
        let candidates = all.filter { $0.mentionCount >= 3 }
        if candidates.isEmpty {
            // Vacuous pass — no high-mention entities yet
            gates.append(QualityGate(name: "kb.enrichment", category: "kb",
                                     threshold: 0, actual: 0))
        } else {
            let enriched = candidates.filter { $0.lastEnriched != nil }.count
            let enrichPct = Double(enriched) / Double(candidates.count)
            gates.append(QualityGate(name: "kb.enrichment", category: "kb",
                                     threshold: 0.50, actual: enrichPct))
        }

        return gates
    }
}
