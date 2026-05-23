import Foundation
import SQLite3

// MARK: - SprintReviewViewModel
//
// GUI-facing counterpart to `senkani learn review` (CLI) and the
// quarterly `senkani learn audit` surfaces. Lives in Core so the
// SwiftUI pane (SenkaniApp target) and the SenkaniTests target can
// both reach it — SenkaniTests does not depend on SenkaniApp, so
// anything testable about the review surface must sit here.
//
// Shape: a snapshot of typed rows grouped by artifact kind, plus a
// list of staleness flags surfaced from the quarterly audit. The
// pane renders the snapshot; accept/reject routes back through
// kind-dispatched `accept` / `reject` on this namespace.

public enum SprintReviewArtifactKind: String, Sendable, Codable, CaseIterable {
    case filterRule
    case contextDoc
    case instructionPatch
    case workflowPlaybook
}

public struct SprintReviewRow: Sendable, Identifiable, Equatable {
    public let id: String
    public let kind: SprintReviewArtifactKind
    /// Primary label. For filter rules, the command/sub invocation; for
    /// context docs + playbooks, the sanitized title; for instruction
    /// patches, the target MCP tool name.
    public let title: String
    /// Secondary label — rationale / hint / step count.
    public let subtitle: String
    public let recurrenceCount: Int
    /// Laplace-smoothed posterior confidence, as stored by the
    /// signal generators (bounded [0, 1]).
    public let confidence: Double
    public let lastSeenAt: Date

    public init(
        id: String,
        kind: SprintReviewArtifactKind,
        title: String,
        subtitle: String,
        recurrenceCount: Int,
        confidence: Double,
        lastSeenAt: Date
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.recurrenceCount = recurrenceCount
        self.confidence = confidence
        self.lastSeenAt = lastSeenAt
    }
}

public struct SprintReviewSection: Sendable, Identifiable, Equatable {
    public var id: SprintReviewArtifactKind { kind }
    public let kind: SprintReviewArtifactKind
    public let rows: [SprintReviewRow]

    public init(kind: SprintReviewArtifactKind, rows: [SprintReviewRow]) {
        self.kind = kind
        self.rows = rows
    }
}

public struct SprintReviewSnapshot: Sendable, Equatable {
    public let sections: [SprintReviewSection]
    public let stalenessFlags: [SprintReviewStalenessFlag]
    public let windowDays: Int

    public var totalCount: Int { sections.reduce(0) { $0 + $1.rows.count } }
    public var isEmpty: Bool { totalCount == 0 && stalenessFlags.isEmpty }

    public init(
        sections: [SprintReviewSection],
        stalenessFlags: [SprintReviewStalenessFlag],
        windowDays: Int
    ) {
        self.sections = sections
        self.stalenessFlags = stalenessFlags
        self.windowDays = windowDays
    }
}

/// Mirror of `CompoundLearningReview.StalenessFlag` with fields
/// reshaped for row rendering. Kept separate so the pane doesn't
/// need to import the review enum internals.
public struct SprintReviewStalenessFlag: Sendable, Identifiable, Equatable {
    public var id: String { artifactId }
    public let artifactId: String
    public let kind: SprintReviewArtifactKind
    public let idleDays: Int
    public let note: String

    public init(
        artifactId: String,
        kind: SprintReviewArtifactKind,
        idleDays: Int,
        note: String
    ) {
        self.artifactId = artifactId
        self.kind = kind
        self.idleDays = idleDays
        self.note = note
    }
}

public enum SprintReviewViewModel {

    /// Default window for the sprint-review pane. The CLI defaults to
    /// 7 days (one sprint); the pane widens to 14 so a missed sprint
    /// doesn't silently drop stale proposals off the UI.
    public static let defaultWindowDays: Int = 14

    /// Default idle cutoff for the quarterly audit — matches
    /// `CompoundLearningReview.quarterlyAuditFlags` default.
    public static let defaultAppliedIdleDays: Int = 60

    /// Default retention window for `sprint_review_snapshots` rows,
    /// in days. Each `snapshot(db:now:snapshot:)` call deletes rows
    /// older than `now - retentionDays * 86400 * 1000` ms. Override
    /// per-call via env `SENKANI_SPRINT_REVIEW_RETENTION_DAYS=<N>`
    /// (parse-fail / negative → fall back to this default; N=0
    /// deletes ALL prior snapshots).
    public static let retentionDays: Int = 30

    public static let retentionEnvVarName = "SENKANI_SPRINT_REVIEW_RETENTION_DAYS"

    static func resolvedRetentionDays(env: [String: String]?) -> Int {
        let raw: String?
        if let env {
            raw = env[retentionEnvVarName]
        } else {
            raw = ProcessInfo.processInfo.environment[retentionEnvVarName]
        }
        guard let s = raw, let n = Int(s), n >= 0 else { return retentionDays }
        return n
    }

    /// Assemble a snapshot of staged artifacts + staleness flags.
    /// Pure read by default; when `recordSnapshot: true`, the
    /// assembled snapshot is also persisted to
    /// `sprint_review_snapshots` for lineage replay
    /// (V.9a follow-up sub-2). Callers that only want the read —
    /// tests, programmatic readers — leave `recordSnapshot` at its
    /// `false` default so they don't pollute history.
    public static func load(
        windowDays: Int = defaultWindowDays,
        appliedIdleDays: Int = defaultAppliedIdleDays,
        liveToolNames: Set<String> = [],
        now: Date = Date(),
        recordSnapshot: Bool = false,
        db: SessionDatabase = .shared,
        env: [String: String]? = nil
    ) -> SprintReviewSnapshot {
        let set = CompoundLearningReview.sprintReviewSet(
            windowDays: windowDays, now: now)
        let flags = CompoundLearningReview.quarterlyAuditFlags(
            appliedIdleDays: appliedIdleDays,
            liveToolNames: liveToolNames,
            now: now
        )

        var sections: [SprintReviewSection] = []

        if !set.filterRules.isEmpty {
            let rows = set.filterRules.map { rule -> SprintReviewRow in
                let sub = rule.subcommand.map { "/\($0)" } ?? ""
                let subtitle = rule.rationale.isEmpty
                    ? rule.ops.joined(separator: ", ")
                    : rule.rationale
                return SprintReviewRow(
                    id: rule.id,
                    kind: .filterRule,
                    title: rule.command + sub,
                    subtitle: subtitle,
                    recurrenceCount: rule.recurrenceCount,
                    confidence: rule.confidence,
                    lastSeenAt: rule.lastSeenAt
                )
            }
            sections.append(SprintReviewSection(kind: .filterRule, rows: rows))
        }
        if !set.contextDocs.isEmpty {
            let rows = set.contextDocs.map { doc in
                SprintReviewRow(
                    id: doc.id,
                    kind: .contextDoc,
                    title: doc.title,
                    subtitle: "\(doc.sessionCount) session"
                        + (doc.sessionCount == 1 ? "" : "s"),
                    recurrenceCount: doc.recurrenceCount,
                    confidence: doc.confidence,
                    lastSeenAt: doc.lastSeenAt
                )
            }
            sections.append(SprintReviewSection(kind: .contextDoc, rows: rows))
        }
        if !set.instructionPatches.isEmpty {
            let rows = set.instructionPatches.map { patch in
                SprintReviewRow(
                    id: patch.id,
                    kind: .instructionPatch,
                    title: patch.toolName,
                    subtitle: String(patch.hint.prefix(160)),
                    recurrenceCount: patch.recurrenceCount,
                    confidence: patch.confidence,
                    lastSeenAt: patch.lastSeenAt
                )
            }
            sections.append(SprintReviewSection(
                kind: .instructionPatch, rows: rows))
        }
        if !set.workflowPlaybooks.isEmpty {
            let rows = set.workflowPlaybooks.map { w in
                SprintReviewRow(
                    id: w.id,
                    kind: .workflowPlaybook,
                    title: w.title,
                    subtitle: "\(w.steps.count) step"
                        + (w.steps.count == 1 ? "" : "s"),
                    recurrenceCount: w.recurrenceCount,
                    confidence: w.confidence,
                    lastSeenAt: w.lastSeenAt
                )
            }
            sections.append(SprintReviewSection(
                kind: .workflowPlaybook, rows: rows))
        }

        let mappedFlags: [SprintReviewStalenessFlag] = flags.map { f in
            SprintReviewStalenessFlag(
                artifactId: f.artifactId,
                kind: Self.kind(from: f.reason),
                idleDays: f.idleDays,
                note: f.note
            )
        }

        let snap = SprintReviewSnapshot(
            sections: sections,
            stalenessFlags: mappedFlags,
            windowDays: windowDays
        )

        if recordSnapshot {
            snapshot(db: db, now: now, snapshot: snap, env: env)
        }

        return snap
    }

    /// Persist one row per `SprintReviewRow` in `snapshot` to the
    /// `sprint_review_snapshots` table (migration v34). All rows in
    /// a single call share `captured_at` (millis since epoch). After
    /// the batch insert, snapshots older than the resolved retention
    /// window are pruned. Best-effort: a failed insert or prune is
    /// logged-via-swallow — the in-memory snapshot the caller will
    /// render is the authoritative read.
    public static func snapshot(
        db: SessionDatabase,
        now: Date,
        snapshot: SprintReviewSnapshot,
        env: [String: String]? = nil
    ) {
        let capturedAtMs = Int64(now.timeIntervalSince1970 * 1000)
        let windowDays = snapshot.windowDays
        let retentionMs = Int64(resolvedRetentionDays(env: env)) * 86_400 * 1000

        db.queue.sync {
            guard let handle = db.db else { return }

            let insertSQL = """
                INSERT INTO sprint_review_snapshots
                    (snapshot_id, captured_at, kind, row_id, title, subtitle,
                     recurrence_count, confidence, last_seen_at, window_days)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """
            for section in snapshot.sections {
                for row in section.rows {
                    var stmt: OpaquePointer?
                    guard sqlite3_prepare_v2(handle, insertSQL, -1, &stmt, nil) == SQLITE_OK else { continue }
                    var uuid = UUID().uuid
                    let uuidBytes = withUnsafeBytes(of: &uuid) { Data($0) }
                    _ = uuidBytes.withUnsafeBytes { rawBuf in
                        sqlite3_bind_blob(stmt, 1, rawBuf.baseAddress, Int32(rawBuf.count), SQLITE_TRANSIENT_DESTRUCTOR)
                    }
                    sqlite3_bind_int64(stmt, 2, capturedAtMs)
                    sqlite3_bind_text(stmt, 3, (row.kind.rawValue as NSString).utf8String, -1, SQLITE_TRANSIENT_DESTRUCTOR)
                    sqlite3_bind_text(stmt, 4, (row.id as NSString).utf8String, -1, SQLITE_TRANSIENT_DESTRUCTOR)
                    sqlite3_bind_text(stmt, 5, (row.title as NSString).utf8String, -1, SQLITE_TRANSIENT_DESTRUCTOR)
                    sqlite3_bind_text(stmt, 6, (row.subtitle as NSString).utf8String, -1, SQLITE_TRANSIENT_DESTRUCTOR)
                    sqlite3_bind_int64(stmt, 7, Int64(row.recurrenceCount))
                    sqlite3_bind_double(stmt, 8, row.confidence)
                    sqlite3_bind_int64(stmt, 9, Int64(row.lastSeenAt.timeIntervalSince1970 * 1000))
                    sqlite3_bind_int64(stmt, 10, Int64(windowDays))
                    _ = sqlite3_step(stmt)
                    sqlite3_finalize(stmt)
                }
            }

            // Retention prune. A retention of 0 deletes every row
            // (operator power-user knob — disables history entirely).
            let cutoffMs = capturedAtMs - retentionMs
            let pruneSQL = "DELETE FROM sprint_review_snapshots WHERE captured_at < ?;"
            var pruneStmt: OpaquePointer?
            if sqlite3_prepare_v2(handle, pruneSQL, -1, &pruneStmt, nil) == SQLITE_OK {
                sqlite3_bind_int64(pruneStmt, 1, cutoffMs)
                _ = sqlite3_step(pruneStmt)
            }
            sqlite3_finalize(pruneStmt)
        }
    }

    /// Accept (promote staged → applied) a row. Filter-rule accept has
    /// no filesystem side effects; the other three kinds write their
    /// canonical on-disk representation under `projectRoot`.
    public static func accept(
        rowId: String,
        kind: SprintReviewArtifactKind,
        projectRoot: String,
        db: SessionDatabase = .shared
    ) throws {
        switch kind {
        case .filterRule:
            try LearnedRulesStore.apply(id: rowId)
        case .contextDoc:
            try CompoundLearning.applyContextDoc(
                id: rowId, projectRoot: projectRoot, db: db)
        case .instructionPatch:
            try CompoundLearning.applyInstructionPatch(
                id: rowId, db: db, projectRoot: projectRoot)
        case .workflowPlaybook:
            try CompoundLearning.applyWorkflowPlaybook(
                id: rowId, projectRoot: projectRoot, db: db)
        }
        OnboardingMilestoneStore.record(.firstStagedProposalReviewed)
    }

    /// Reject a staged row — state-only transition. No filesystem side
    /// effects: a rejected artifact never touched .senkani/.
    public static func reject(
        rowId: String,
        kind: SprintReviewArtifactKind
    ) throws {
        switch kind {
        case .filterRule:
            try LearnedRulesStore.reject(id: rowId)
        case .contextDoc:
            try LearnedRulesStore.rejectContextDoc(id: rowId)
        case .instructionPatch:
            try LearnedRulesStore.rejectInstructionPatch(id: rowId)
        case .workflowPlaybook:
            try LearnedRulesStore.rejectWorkflowPlaybook(id: rowId)
        }
        OnboardingMilestoneStore.record(.firstStagedProposalReviewed)
    }

    // MARK: - Helpers

    private static func kind(
        from reason: CompoundLearningReview.StaleReason
    ) -> SprintReviewArtifactKind {
        switch reason {
        case .filterRuleNotFired: return .filterRule
        case .contextDocNotReferenced: return .contextDoc
        case .instructionPatchToolMissing: return .instructionPatch
        case .workflowPlaybookNotObserved: return .workflowPlaybook
        }
    }
}
