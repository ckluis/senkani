import Foundation

// MARK: - Bounded context: Instruction patches (Phase H+2c)
//
// `LearnedInstructionPatch` is the third polymorphic artifact. Each
// patch is a hint targeted at a specific MCP tool, e.g. "when calling
// `kb_search` prefer the `--mode=fast` flag for transient lookups".
// Lifecycle mirrors the others:
//
//   recurring → staged → applied   (operator-confirmed apply only)
//   recurring → staged → rejected
//
// Dedup key for re-observation: `(toolName, hint)` — same hint for the
// same tool is the same observation.
//
// Schneier constraint: `applyInstructionPatch` only fires when the
// operator confirms. There is no auto-apply path anywhere. The state
// machine enforces this at `case .staged` only.
//
// The `LearnedInstructionPatch` struct itself lives at
// `Sources/Core/LearnedInstructionPatch.swift`. This file owns only
// the lifecycle mutations on the shared `LearnedRulesStore` cache.

extension LearnedRulesStore {

    /// Merge-on-duplicate observation for instruction patches. Dedup
    /// key is `(toolName, hint)` — same hint for the same tool is the
    /// same observation. Respects `.rejected` stickiness.
    public static func observeInstructionPatch(_ patch: LearnedInstructionPatch) throws {
        var file = load() ?? .empty
        var didMerge = false
        for (idx, artifact) in file.artifacts.enumerated() {
            guard case .instructionPatch(var existing) = artifact else { continue }
            guard existing.toolName == patch.toolName,
                  existing.hint == patch.hint else { continue }
            switch existing.status {
            case .rejected: return
            case .recurring, .staged, .applied:
                existing.recurrenceCount += 1
                existing.lastSeenAt = patch.lastSeenAt
                for s in patch.sources where !existing.sources.contains(s) {
                    existing.sources.append(s)
                }
                existing.sessionCount = max(existing.sessionCount, patch.sessionCount)
                file.artifacts[idx] = .instructionPatch(existing)
                didMerge = true
            }
            break
        }
        if !didMerge { file.artifacts.append(.instructionPatch(patch)) }
        try save(file)
        shared = file
    }

    public static func promoteInstructionPatchToStaged(id: String) throws {
        try mutateInstructionPatch(id: id) { p in
            guard p.status == .recurring else { return }
            p.status = .staged
        }
    }

    /// Apply ONLY fires when operator confirms — no auto-apply path
    /// anywhere. Schneier constraint enforced at the state machine.
    public static func applyInstructionPatch(id: String) throws {
        try mutateInstructionPatch(id: id) { p in
            guard p.status == .staged else { return }
            p.status = .applied
        }
    }

    public static func rejectInstructionPatch(id: String) throws {
        try mutateInstructionPatch(id: id) { p in p.status = .rejected }
    }

    public static func instructionPatches(inStatus status: LearnedRuleStatus) -> [LearnedInstructionPatch] {
        (load() ?? .empty).instructionPatches
            .filter { $0.status == status }
            .sorted { $0.lastSeenAt > $1.lastSeenAt }
    }

    public static func appliedInstructionPatches() -> [LearnedInstructionPatch] {
        instructionPatches(inStatus: .applied)
    }

    // MARK: - Private — file-local mutation helper

    private static func mutateInstructionPatch(
        id: String,
        _ mutate: (inout LearnedInstructionPatch) -> Void
    ) throws {
        var file = load() ?? .empty
        for (idx, artifact) in file.artifacts.enumerated() {
            guard case .instructionPatch(var p) = artifact, p.id == id else { continue }
            mutate(&p)
            file.artifacts[idx] = .instructionPatch(p)
            try save(file)
            shared = file
            return
        }
    }
}
