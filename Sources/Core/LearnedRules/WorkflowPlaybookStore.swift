import Foundation

// MARK: - Bounded context: Workflow playbooks (Phase H+2c)
//
// `LearnedWorkflowPlaybook` is the fourth polymorphic artifact. Each
// playbook captures a multi-step recipe the agent has observed
// recurring across sessions, e.g. "build → test → deploy" with a
// specific argument shape. Lifecycle mirrors the others:
//
//   recurring → staged → applied
//   recurring → staged → rejected
//
// Dedup key for re-observation: `title` (same recipe shape produces the
// same slug). On re-observation the description and steps are
// refreshed so a refined generator pass can update them, but the
// recurrence aggregate is preserved.
//
// The `LearnedWorkflowPlaybook` struct itself lives at
// `Sources/Core/LearnedWorkflowPlaybook.swift`. This file owns only
// the lifecycle mutations on the shared `LearnedRulesStore` cache.

extension LearnedRulesStore {

    /// Dedup by `title` (same recipe shape produces same slug). Respects
    /// `.rejected` stickiness.
    public static func observeWorkflowPlaybook(_ playbook: LearnedWorkflowPlaybook) throws {
        var file = load() ?? .empty
        var didMerge = false
        for (idx, artifact) in file.artifacts.enumerated() {
            guard case .workflowPlaybook(var existing) = artifact else { continue }
            guard existing.title == playbook.title else { continue }
            switch existing.status {
            case .rejected: return
            case .recurring, .staged, .applied:
                existing.recurrenceCount += 1
                existing.lastSeenAt = playbook.lastSeenAt
                for s in playbook.sources where !existing.sources.contains(s) {
                    existing.sources.append(s)
                }
                existing.sessionCount = max(existing.sessionCount, playbook.sessionCount)
                // Refresh steps/description on re-observation so a
                // refined generator pass can update them.
                if !playbook.description.isEmpty {
                    existing.description = LearnedWorkflowPlaybook.sanitizeDescription(playbook.description)
                }
                if !playbook.steps.isEmpty {
                    existing.steps = Array(playbook.steps.prefix(LearnedWorkflowPlaybook.maxSteps))
                }
                file.artifacts[idx] = .workflowPlaybook(existing)
                didMerge = true
            }
            break
        }
        if !didMerge { file.artifacts.append(.workflowPlaybook(playbook)) }
        try save(file)
        shared = file
    }

    public static func promoteWorkflowPlaybookToStaged(id: String) throws {
        try mutateWorkflowPlaybook(id: id) { w in
            guard w.status == .recurring else { return }
            w.status = .staged
        }
    }

    public static func applyWorkflowPlaybook(id: String) throws {
        try mutateWorkflowPlaybook(id: id) { w in
            guard w.status == .staged else { return }
            w.status = .applied
        }
    }

    public static func rejectWorkflowPlaybook(id: String) throws {
        try mutateWorkflowPlaybook(id: id) { w in w.status = .rejected }
    }

    public static func workflowPlaybooks(inStatus status: LearnedRuleStatus) -> [LearnedWorkflowPlaybook] {
        (load() ?? .empty).workflowPlaybooks
            .filter { $0.status == status }
            .sorted { $0.lastSeenAt > $1.lastSeenAt }
    }

    // MARK: - Private — file-local mutation helper

    private static func mutateWorkflowPlaybook(
        id: String,
        _ mutate: (inout LearnedWorkflowPlaybook) -> Void
    ) throws {
        var file = load() ?? .empty
        for (idx, artifact) in file.artifacts.enumerated() {
            guard case .workflowPlaybook(var w) = artifact, w.id == id else { continue }
            mutate(&w)
            file.artifacts[idx] = .workflowPlaybook(w)
            try save(file)
            shared = file
            return
        }
    }
}
