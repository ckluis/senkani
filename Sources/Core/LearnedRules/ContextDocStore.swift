import Foundation

// MARK: - Bounded context: Context docs (Phase H+2b)
//
// `LearnedContextDoc` is the second polymorphic artifact alongside
// filter rules. It carries a freeform body the agent can splice into a
// session-brief prompt at apply time. Lifecycle mirrors filter rules:
//
//   recurring → staged → applied   (happy path)
//   recurring → staged → rejected  (operator says no)
//
// Dedup key for re-observation: `title` (filesystem-safe slug). On
// re-observation the body is re-sanitized so a refined generator pass
// can update the prose without losing the recurrence aggregate.
//
// The `LearnedContextDoc` struct itself lives at
// `Sources/Core/LearnedContextDoc.swift`. This file owns only the
// lifecycle mutations on the shared `LearnedRulesStore` cache.

extension LearnedRulesStore {

    /// Phase H+2b analogue of `observe(_:)` for context docs. Merges by
    /// `title` (filesystem-safe slug), respects `.rejected` stickiness,
    /// appends a fresh `.recurring` doc when absent.
    public static func observeContextDoc(_ doc: LearnedContextDoc) throws {
        var file = load() ?? .empty
        var didMerge = false
        for (idx, artifact) in file.artifacts.enumerated() {
            guard case .contextDoc(var existing) = artifact else { continue }
            guard existing.title == doc.title else { continue }
            switch existing.status {
            case .rejected:
                return
            case .recurring, .staged, .applied:
                existing.recurrenceCount += 1
                existing.lastSeenAt = doc.lastSeenAt
                for s in doc.sources where !existing.sources.contains(s) {
                    existing.sources.append(s)
                }
                existing.sessionCount = max(existing.sessionCount, doc.sessionCount)
                // Body update on re-observation lets the generator
                // accumulate more evidence over time. Re-sanitize.
                if !doc.body.isEmpty {
                    existing.body = LearnedContextDoc.sanitizeBody(doc.body)
                }
                file.artifacts[idx] = .contextDoc(existing)
                didMerge = true
            }
            break
        }
        if !didMerge {
            file.artifacts.append(.contextDoc(doc))
        }
        try save(file)
        shared = file
    }

    /// Promote a context doc from `.recurring` → `.staged`. No-op for
    /// other statuses / unknown ids.
    public static func promoteContextDocToStaged(id: String) throws {
        try mutateContextDoc(id: id) { doc in
            guard doc.status == .recurring else { return }
            doc.status = .staged
        }
    }

    /// Move a staged context doc to applied status.
    public static func applyContextDoc(id: String) throws {
        try mutateContextDoc(id: id) { doc in
            guard doc.status == .staged else { return }
            doc.status = .applied
        }
    }

    /// Move a context doc to rejected (from any non-terminal state).
    public static func rejectContextDoc(id: String) throws {
        try mutateContextDoc(id: id) { doc in
            doc.status = .rejected
        }
    }

    /// Read-only: context docs in a given status (sorted by lastSeenAt desc).
    public static func contextDocs(inStatus status: LearnedRuleStatus) -> [LearnedContextDoc] {
        (load() ?? .empty).contextDocs
            .filter { $0.status == status }
            .sorted { $0.lastSeenAt > $1.lastSeenAt }
    }

    /// Read-only: applied context docs (sorted by lastSeenAt desc, most
    /// recent first). Used by the session-brief integration — the
    /// agent's context is fed by what's currently applied.
    public static func appliedContextDocs() -> [LearnedContextDoc] {
        contextDocs(inStatus: .applied)
    }

    // MARK: - Private — file-local mutation helper

    private static func mutateContextDoc(
        id: String,
        _ mutate: (inout LearnedContextDoc) -> Void
    ) throws {
        var file = load() ?? .empty
        for (idx, artifact) in file.artifacts.enumerated() {
            guard case .contextDoc(var doc) = artifact, doc.id == id else { continue }
            mutate(&doc)
            file.artifacts[idx] = .contextDoc(doc)
            try save(file)
            shared = file
            return
        }
    }
}
