import Foundation

/// V.12a — code-review annotations attached to diff hunks.
///
/// Distinct from `Annotation` (V.6, in `Stores/AnnotationStore.swift`),
/// which records operator verdicts on skill / KB-entity *artifacts*.
/// `DiffAnnotation` is the *code-review* surface: a comment pinned to
/// a hunk in `DiffViewerPane`, tagged with a severity from a frozen
/// four-value vocabulary.
///
/// The vocabulary is frozen as part of V.12a. Adding or renaming a
/// case is a schema break — V.12b (HookRouter denials) and any future
/// store both encode the rawValue, so a rename mis-routes existing
/// rows. If the operator wants a different taxonomy, change it
/// *before* this round ships, not after.
public struct DiffAnnotation: Sendable, Equatable, Identifiable {
    public let id: UUID
    /// Which hunk this annotation is pinned to. `DiffHunk.id` is a
    /// session-scoped UUID; persistence layers (V.12b+) translate it
    /// to `(file, originalStartLine, modifiedStartLine)` before write.
    public let hunkId: UUID
    public let severity: DiffAnnotationSeverity
    /// Free-text body. May be empty for rate-cap suppression rows
    /// (V.12b) where the severity tag itself is the message.
    public let body: String
    /// Free-text identifier of who wrote the annotation
    /// ("agent:senkani", an operator handle, "hookrouter:trust", …).
    public let authoredBy: String
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        hunkId: UUID,
        severity: DiffAnnotationSeverity,
        body: String,
        authoredBy: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.hunkId = hunkId
        self.severity = severity
        self.body = body
        self.authoredBy = authoredBy
        self.createdAt = createdAt
    }
}

/// Frozen severity vocabulary for `DiffAnnotation`. Persisted by
/// rawValue — renaming a case is a schema break.
///
/// The four tags are *not* a priority ladder; they're four distinct
/// kinds of feedback. A reviewer picks the tag that names the *kind*
/// of comment, not how loud it is.
public enum DiffAnnotationSeverity: String, Sendable, Codable, Equatable, CaseIterable {
    /// "This must be fixed before merge." Blocks landing. Use for
    /// correctness, security, data-loss, or invariant violations.
    case mustFix = "must-fix"
    /// "Consider this alternative." Non-blocking; the reviewer is
    /// proposing a different approach, not rejecting the current one.
    case suggestion
    /// "I don't understand this — explain or clarify." The reviewer
    /// is asking the author for context, not asserting a problem.
    case question
    /// "Trivial polish." Style, naming, comment-grammar — never
    /// blocks merge. Authors may ignore at their discretion.
    case nit

    /// Human-readable label rendered in the severity badge UI.
    public var label: String {
        switch self {
        case .mustFix:    return "must-fix"
        case .suggestion: return "suggestion"
        case .question:   return "question"
        case .nit:        return "nit"
        }
    }

    /// SF Symbol glyph paired with the label so colorblind operators
    /// can disambiguate severities without reading the color.
    public var glyphName: String {
        switch self {
        case .mustFix:    return "exclamationmark.octagon.fill"
        case .suggestion: return "lightbulb"
        case .question:   return "questionmark.circle"
        case .nit:        return "scribble"
        }
    }

    /// Visual weight ordering for sorting annotations within a hunk.
    /// Higher = more attention. NOT a priority ladder for the author
    /// — it's only a render-order hint.
    public var visualWeight: Int {
        switch self {
        case .mustFix:    return 3
        case .suggestion: return 2
        case .question:   return 1
        case .nit:        return 0
        }
    }
}

/// Pure helpers for arranging `DiffAnnotation` records against a list
/// of hunks. Lifted out of the view layer so the ordering / grouping
/// invariants are unit-testable.
public enum DiffAnnotationLayout {

    /// Group annotations by `hunkId`, dropping any whose `hunkId`
    /// doesn't appear in `hunks`. Returns dictionary keyed by hunk
    /// id; stable order within a group is severity-weight DESC, then
    /// `createdAt` ASC (older annotations float above newer of the
    /// same severity so threaded review reads top-to-bottom).
    public static func groupByHunk(
        _ annotations: [DiffAnnotation],
        hunks: [DiffHunk]
    ) -> [UUID: [DiffAnnotation]] {
        let valid = Set(hunks.map(\.id))
        var grouped: [UUID: [DiffAnnotation]] = [:]
        for a in annotations where valid.contains(a.hunkId) {
            grouped[a.hunkId, default: []].append(a)
        }
        for key in grouped.keys {
            grouped[key]?.sort { lhs, rhs in
                if lhs.severity.visualWeight != rhs.severity.visualWeight {
                    return lhs.severity.visualWeight > rhs.severity.visualWeight
                }
                return lhs.createdAt < rhs.createdAt
            }
        }
        return grouped
    }

    /// Flat sidebar order: walk hunks top-to-bottom (the order
    /// `DiffEngine.computeHunks` returns them), then within each hunk
    /// follow `groupByHunk`'s severity-weight ordering. Click handling
    /// uses this list, so what the operator sees == what's clickable.
    public static func sidebarOrder(
        _ annotations: [DiffAnnotation],
        hunks: [DiffHunk]
    ) -> [DiffAnnotation] {
        let grouped = groupByHunk(annotations, hunks: hunks)
        return hunks.flatMap { grouped[$0.id] ?? [] }
    }

    /// Counts per severity across the full annotation list. The pane
    /// uses this for the header chip row; tests use it to assert the
    /// frozen vocab renders all four counts.
    public static func severityCounts(
        _ annotations: [DiffAnnotation]
    ) -> [DiffAnnotationSeverity: Int] {
        var counts: [DiffAnnotationSeverity: Int] = [:]
        for sev in DiffAnnotationSeverity.allCases { counts[sev] = 0 }
        for a in annotations { counts[a.severity, default: 0] += 1 }
        return counts
    }
}
