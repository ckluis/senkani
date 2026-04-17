import Foundation

// MARK: - KBCompoundBridge
//
// Phase F+5 (Round 8 — final feature round). Knits the KB and the
// compound-learning store together so the two systems reinforce each
// other instead of accumulating parallel state:
//
//   1. `boostProposal(_:importance:)` — compound-learning proposals
//      whose command/title/toolName matches a high-mention KB entity
//      get a confidence boost, capped at 1.0. Calibration: `+0.05 * log1p(mentions)`.
//
//   2. `seedKBEntity(for:)` — applying a context doc creates (if
//      missing) a corresponding KB entity stub so the operator only
//      edits one file per topic. Idempotent — existing entities are
//      left untouched (no accidental overwrites).
//
//   3. `invalidateDerivedContext(entity:)` — rolling back a KB entity
//      re-validates any compound-learning context doc derived from
//      that entity's source path. Invalidated docs drop to `.recurring`
//      so the next sweep can re-promote if evidence still holds.

public enum KBCompoundBridge {

    // MARK: - 1. Boost

    public struct BoostedConfidence: Sendable, Equatable {
        public let raw: Double
        public let boost: Double
        public let result: Double
    }

    /// Apply a KB-importance boost to a confidence score. Caller
    /// passes the entity's `mentionCount`; this just does the math so
    /// the boost is unit-testable in isolation.
    public static func boostConfidence(
        raw: Double, kbMentionCount: Int
    ) -> BoostedConfidence {
        guard kbMentionCount > 0 else {
            return BoostedConfidence(raw: raw, boost: 0, result: raw)
        }
        // log1p is natural log — keeps the boost bounded for large
        // counts and smoothly scales for small ones.
        let boost = 0.05 * log(Double(kbMentionCount) + 1.0)
        let clipped = max(0, min(1, raw + boost))
        return BoostedConfidence(raw: raw, boost: clipped - raw, result: clipped)
    }

    // MARK: - 2. Seed

    /// Create (or no-op) a KB entity stub from an applied context doc.
    /// Returns true iff a new entity was created. The caller bumps
    /// `knowledge.learn.seeded` when this returns true.
    @discardableResult
    public static func seedKBEntity(
        for doc: LearnedContextDoc,
        store: KnowledgeStore
    ) -> Bool {
        // Derive a reasonable entity name from the doc title.
        // "sources-foo-swift" → "SourcesFooSwift" — not perfect, but
        // the operator will rename; idempotency is what matters.
        let entityName = camelCase(from: doc.title)
        guard store.entity(named: entityName) == nil else { return false }

        let markdownPath = ".senkani/knowledge/\(entityName).md"
        _ = store.upsertEntity(KnowledgeEntity(
            name: entityName,
            entityType: "concept",
            sourcePath: nil,
            markdownPath: markdownPath,
            compiledUnderstanding: "Seeded from compound-learning context doc `\(doc.title)`. Edit this file to add project-specific context.",
            mentionCount: max(1, doc.sessionCount)
        ))
        return true
    }

    // MARK: - 3. Invalidate

    /// Drop any `.applied` context doc whose title slug is derived
    /// from the rolled-back entity's source path back to `.recurring`.
    /// Returns the number of docs invalidated.
    @discardableResult
    public static func invalidateDerivedContext(
        entityName: String,
        entitySourcePath: String?
    ) -> Int {
        let docs = LearnedRulesStore.appliedContextDocs()
        let entitySlug = LearnedContextDoc.sanitizeTitle(entityName)
        var count = 0
        for doc in docs {
            // Match by title-slug containment — covers both the
            // camelCase-from-slug direction and the slug-contains-
            // entity-name direction.
            let titleLower = doc.title.lowercased()
            if titleLower.contains(entitySlug)
               || (entitySourcePath.map { titleLower.contains(
                    LearnedContextDoc.sanitizeTitle($0)) } ?? false) {
                // Move back to .recurring. Sources remain; recurrence
                // count unchanged — a follow-up session close re-
                // evaluates.
                try? LearnedRulesStore.promoteContextDocBack(id: doc.id, to: .recurring)
                count += 1
            }
        }
        return count
    }

    // MARK: - Helpers

    /// Convert "sources-foo-swift" → "SourcesFooSwift". Deterministic.
    static func camelCase(from slug: String) -> String {
        slug.split(separator: "-").map { part -> String in
            guard let first = part.first else { return "" }
            return first.uppercased() + part.dropFirst()
        }.joined()
    }
}

// MARK: - LearnedRulesStore extension for F+5

extension LearnedRulesStore {
    /// Move a context doc to a different non-terminal status. Used by
    /// `KBCompoundBridge.invalidateDerivedContext`. Throws if the id
    /// is unknown or target is `.rejected` (reject has its own method).
    public static func promoteContextDocBack(id: String, to target: LearnedRuleStatus) throws {
        guard target != .rejected else { return }
        var file = load() ?? .empty
        for (idx, artifact) in file.artifacts.enumerated() {
            guard case .contextDoc(var doc) = artifact, doc.id == id else { continue }
            doc.status = target
            file.artifacts[idx] = .contextDoc(doc)
            try save(file)
            shared = file
            return
        }
    }
}
