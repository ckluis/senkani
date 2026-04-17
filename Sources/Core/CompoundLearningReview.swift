import Foundation

// MARK: - CompoundLearningReview
//
// Phase H+2d — sprint + quarterly cadence surfaces. These are the
// human-gated checkpoints in the four-cadence model (immediate /
// daily / sprint / quarterly).
//
// Sprint review: surface the week's staged proposals across all four
// artifact types. CLI: `senkani learn review` — prompts `a/r/s` per
// item. Stdlib only; no external UI.
//
// Quarterly audit: surface applied artifacts that may have gone stale.
// Heuristics:
//   - Filter rule not fired in the last `appliedIdleDays` (default 60)
//   - Context doc whose on-disk .md hasn't been re-read by any session
//   - Instruction patch whose `toolName` no longer matches any live tool
//   - Playbook whose sequence fires in <10% of sessions
//
// Round 3 ships the data-model + query-layer scaffolding. Actual
// interactive loops live in the CLI (`senkani learn review/audit`).

public enum CompoundLearningReview {

    // MARK: - Sprint review

    /// Aggregate of all staged artifacts from the last `windowDays`,
    /// grouped by type. This is what the sprint-review CLI iterates.
    public struct SprintReviewSet: Sendable {
        public let filterRules: [LearnedFilterRule]
        public let contextDocs: [LearnedContextDoc]
        public let instructionPatches: [LearnedInstructionPatch]
        public let workflowPlaybooks: [LearnedWorkflowPlaybook]

        public var totalCount: Int {
            filterRules.count + contextDocs.count
                + instructionPatches.count + workflowPlaybooks.count
        }
        public var isEmpty: Bool { totalCount == 0 }
    }

    /// Return everything staged in the last `windowDays`. Sprint
    /// review typically uses 7 days; the operator can widen.
    public static func sprintReviewSet(
        windowDays: Int = 7,
        now: Date = Date()
    ) -> SprintReviewSet {
        let cutoff = now.addingTimeInterval(-Double(windowDays) * 86400)
        let file = LearnedRulesStore.load() ?? .empty
        func stagedInWindow<T>(_ items: [T], lastSeen: (T) -> Date, status: (T) -> LearnedRuleStatus) -> [T] {
            items.filter { status($0) == .staged && lastSeen($0) >= cutoff }
        }
        return SprintReviewSet(
            filterRules: stagedInWindow(file.rules, lastSeen: { $0.lastSeenAt }, status: { $0.status }),
            contextDocs: stagedInWindow(file.contextDocs, lastSeen: { $0.lastSeenAt }, status: { $0.status }),
            instructionPatches: stagedInWindow(file.instructionPatches, lastSeen: { $0.lastSeenAt }, status: { $0.status }),
            workflowPlaybooks: stagedInWindow(file.workflowPlaybooks, lastSeen: { $0.lastSeenAt }, status: { $0.status })
        )
    }

    // MARK: - Quarterly audit

    public enum StaleReason: String, Sendable, Codable {
        case filterRuleNotFired
        case contextDocNotReferenced
        case instructionPatchToolMissing
        case workflowPlaybookNotObserved
    }

    public struct StalenessFlag: Sendable {
        public let artifactId: String
        public let reason: StaleReason
        public let idleDays: Int
        public let note: String
    }

    /// Audit all applied artifacts for staleness indicators. Returns a
    /// list of flags the operator should review and either retire
    /// (reject) or keep.
    ///
    /// `liveToolNames` is the set of tool names currently exposed by
    /// the router — callers pass `ToolRouter.allTools().map(\.name)`
    /// (or an empty set to skip the instruction-patch check).
    public static func quarterlyAuditFlags(
        appliedIdleDays: Int = 60,
        liveToolNames: Set<String> = [],
        now: Date = Date()
    ) -> [StalenessFlag] {
        var flags: [StalenessFlag] = []
        let idleCutoff = now.addingTimeInterval(-Double(appliedIdleDays) * 86400)
        let file = LearnedRulesStore.load() ?? .empty

        // Filter rules: applied but lastSeenAt older than idle cutoff.
        for rule in file.rules where rule.status == .applied {
            let days = daysBetween(rule.lastSeenAt, and: now)
            if rule.lastSeenAt < idleCutoff {
                flags.append(StalenessFlag(
                    artifactId: rule.id,
                    reason: .filterRuleNotFired,
                    idleDays: days,
                    note: "Filter rule for `\(rule.command)` hasn't re-occurred in \(days) days — remove if the command is no longer noisy."
                ))
            }
        }

        // Context docs: applied docs whose lastSeenAt predates cutoff.
        for doc in file.contextDocs where doc.status == .applied {
            let days = daysBetween(doc.lastSeenAt, and: now)
            if doc.lastSeenAt < idleCutoff {
                flags.append(StalenessFlag(
                    artifactId: doc.id,
                    reason: .contextDocNotReferenced,
                    idleDays: days,
                    note: "Context doc `\(doc.title)` not observed in \(days) days — project may have drifted."
                ))
            }
        }

        // Instruction patches: applied patches targeting tools no
        // longer exposed.
        if !liveToolNames.isEmpty {
            for patch in file.instructionPatches where patch.status == .applied {
                if !liveToolNames.contains(patch.toolName) {
                    flags.append(StalenessFlag(
                        artifactId: patch.id,
                        reason: .instructionPatchToolMissing,
                        idleDays: daysBetween(patch.lastSeenAt, and: now),
                        note: "Instruction patch targets `\(patch.toolName)` which is no longer registered."
                    ))
                }
            }
        }

        // Workflow playbooks: applied playbooks whose lastSeenAt
        // predates the cutoff (pair hasn't been observed recently).
        for w in file.workflowPlaybooks where w.status == .applied {
            let days = daysBetween(w.lastSeenAt, and: now)
            if w.lastSeenAt < idleCutoff {
                flags.append(StalenessFlag(
                    artifactId: w.id,
                    reason: .workflowPlaybookNotObserved,
                    idleDays: days,
                    note: "Playbook `\(w.title)` not observed in \(days) days."
                ))
            }
        }

        return flags
    }

    // MARK: - Helpers

    private static func daysBetween(_ a: Date, and b: Date) -> Int {
        max(0, Int(b.timeIntervalSince(a) / 86400))
    }
}
