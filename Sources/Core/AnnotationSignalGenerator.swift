import Foundation

// MARK: - AnnotationSignalGenerator
//
// Phase V.6 round 1 — the read-side bridge from operator-tagged
// annotation rows to CompoundLearning Analyze. Pure aggregation:
// returns one `AnnotationEvidence` row per (target_kind, target_id)
// with verdict counts that downstream Propose steps (V.6 round 3+)
// can consume.
//
// Round 1 deliberately stops at evidence — no rule mutation, no
// auto-staging. The operator's `fails`/`works` calls are ground
// truth; this generator surfaces the rollup as Analyze input
// without inferring policy from it (Karpathy's red flag in the
// V.6 audit synthesis: "annotations are operator attestation, not
// agent inference — round 1 must read, not propose").

public enum AnnotationSignalGenerator {

    /// Aggregate annotation rows into evidence per target. Optionally
    /// filter by `targetKind`. Default order: most-recent activity
    /// first, then by `failsCount` descending so a problem skill
    /// floats above a quietly-working one.
    public static func analyze(
        db: SessionDatabase,
        targetKind: AnnotationTargetKind? = nil,
        minTotal: Int = 1,
        limit: Int = 100
    ) -> [AnnotationEvidence] {
        let rollups = db.annotationVerdictRollup(targetKind: targetKind)
        guard !rollups.isEmpty else { return [] }

        // Filter to targets with at least `minTotal` annotations and
        // bound the output. The store's verdict rollup already orders
        // by lastSeenAt DESC, failsCount DESC, worksCount DESC.
        let filtered = rollups.filter { $0.totalCount >= minTotal }
        let bounded = Array(filtered.prefix(max(0, limit)))

        return bounded.map { rollup in
            AnnotationEvidence(
                targetKind: rollup.targetKind,
                targetId: rollup.targetId,
                worksCount: rollup.worksCount,
                failsCount: rollup.failsCount,
                noteCount: rollup.noteCount,
                lastSeenAt: rollup.lastSeenAt,
                signalKind: Self.signalKind(for: rollup)
            )
        }
    }

    /// Coarse classification surfaced to the Analyze step. `failing`
    /// fires when fails outweigh works; `working` when works outweigh
    /// fails; `mixed` otherwise. Notes-only targets land in `mixed`.
    static func signalKind(for rollup: AnnotationVerdictRollup) -> AnnotationSignalKind {
        if rollup.failsCount > rollup.worksCount && rollup.failsCount > 0 {
            return .failing
        }
        if rollup.worksCount > rollup.failsCount && rollup.worksCount > 0 {
            return .working
        }
        return .mixed
    }
}

/// One row of evidence — the structured handoff CompoundLearning
/// Analyze receives from the annotation surface.
public struct AnnotationEvidence: Sendable, Equatable {
    public let targetKind: AnnotationTargetKind
    public let targetId: String
    public let worksCount: Int
    public let failsCount: Int
    public let noteCount: Int
    public let lastSeenAt: Date
    public let signalKind: AnnotationSignalKind

    public var totalCount: Int { worksCount + failsCount + noteCount }
}

public enum AnnotationSignalKind: String, Sendable, Equatable {
    case failing
    case working
    case mixed
}
