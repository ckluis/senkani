import Foundation
import SQLite3

// MARK: - Public Types

public struct KnowledgeEntity: Sendable, Equatable {
    public let id: Int64
    public let name: String
    public let entityType: String           // class|struct|func|file|concept
    public let sourcePath: String?          // relative to project root
    public let markdownPath: String         // .senkani/knowledge/<Name>.md
    public let contentHash: String          // SHA-256 of markdown file
    public let compiledUnderstanding: String
    public let lastEnriched: Date?
    public let mentionCount: Int
    public let sessionMentions: Int
    public let stalenessScore: Double       // 0.0 (fresh) → 1.0 (stale)
    public let createdAt: Date
    public let modifiedAt: Date
    /// Phase V.5 round 1 — provenance tag. `nil` ONLY for rows
    /// read out of pre-V.5 history (column was NULL); never set to
    /// nil when constructing a new entity in code. New inserts
    /// route through `AuthorshipTracker` and carry an explicit
    /// `AuthorshipTag`. See `Sources/Core/AuthorshipTag.swift`.
    public let authorship: AuthorshipTag?

    public init(
        id: Int64 = 0,
        name: String,
        entityType: String = "class",
        sourcePath: String? = nil,
        markdownPath: String,
        contentHash: String = "",
        compiledUnderstanding: String = "",
        lastEnriched: Date? = nil,
        mentionCount: Int = 0,
        sessionMentions: Int = 0,
        stalenessScore: Double = 0.0,
        createdAt: Date = Date(),
        modifiedAt: Date = Date(),
        authorship: AuthorshipTag? = nil
    ) {
        self.id = id; self.name = name; self.entityType = entityType
        self.sourcePath = sourcePath; self.markdownPath = markdownPath
        self.contentHash = contentHash; self.compiledUnderstanding = compiledUnderstanding
        self.lastEnriched = lastEnriched; self.mentionCount = mentionCount
        self.sessionMentions = sessionMentions; self.stalenessScore = stalenessScore
        self.createdAt = createdAt; self.modifiedAt = modifiedAt
        self.authorship = authorship
    }
}

public enum EntitySort: Sendable {
    case mentionCountDesc, nameAsc, stalenessDesc, lastEnrichedDesc
}

public struct KnowledgeSearchResult: Sendable {
    public let entity: KnowledgeEntity
    public let snippet: String      // excerpt with «match» markers
    public let bm25Rank: Double     // lower = better
}

public struct EntityLink: Sendable, Equatable {
    public let id: Int64
    public let sourceId: Int64
    public let targetName: String
    public let targetId: Int64?
    public let relation: String?    // depends_on|used_by|co_changes_with|concept
    public let confidence: Double
    public let lineNumber: Int?
    public let createdAt: Date

    public init(
        id: Int64 = 0, sourceId: Int64, targetName: String,
        targetId: Int64? = nil, relation: String? = nil,
        confidence: Double = 1.0, lineNumber: Int? = nil, createdAt: Date = Date()
    ) {
        self.id = id; self.sourceId = sourceId; self.targetName = targetName
        self.targetId = targetId; self.relation = relation
        self.confidence = confidence; self.lineNumber = lineNumber; self.createdAt = createdAt
    }
}

public struct DecisionRecord: Sendable {
    public let id: Int64
    public let entityId: Int64?
    public let entityName: String
    public let decision: String
    public let rationale: String
    public let source: String       // git_commit|annotation|cli|agent
    public let commitHash: String?
    public let createdAt: Date
    public let validUntil: Date?

    public init(
        id: Int64 = 0, entityId: Int64? = nil, entityName: String,
        decision: String, rationale: String, source: String,
        commitHash: String? = nil, createdAt: Date = Date(), validUntil: Date? = nil
    ) {
        self.id = id; self.entityId = entityId; self.entityName = entityName
        self.decision = decision; self.rationale = rationale; self.source = source
        self.commitHash = commitHash; self.createdAt = createdAt; self.validUntil = validUntil
    }
}

public struct EvidenceEntry: Sendable {
    public let id: Int64
    public let entityId: Int64
    public let sessionId: String
    public let whatWasLearned: String
    public let source: String       // enrichment|git_archaeology|annotation|cli
    public let createdAt: Date

    public init(
        id: Int64 = 0, entityId: Int64, sessionId: String,
        whatWasLearned: String, source: String, createdAt: Date = Date()
    ) {
        self.id = id; self.entityId = entityId; self.sessionId = sessionId
        self.whatWasLearned = whatWasLearned; self.source = source; self.createdAt = createdAt
    }
}

public struct CouplingEntry: Sendable {
    public let id: Int64
    public let entityA: String
    public let entityB: String
    public let commitCount: Int
    public let totalCommits: Int
    public let couplingScore: Double
    public let lastComputed: Date

    public init(
        id: Int64 = 0, entityA: String, entityB: String,
        commitCount: Int, totalCommits: Int, couplingScore: Double, lastComputed: Date = Date()
    ) {
        self.id = id; self.entityA = entityA; self.entityB = entityB
        self.commitCount = commitCount; self.totalCommits = totalCommits
        self.couplingScore = couplingScore; self.lastComputed = lastComputed
    }
}

// MARK: - KnowledgeStore (façade)

// MARK: - Split history (Luminary P1, closed 2026-04-25)
//
// `KnowledgeStore` is the compatibility façade for the per-project knowledge
// vault (`.senkani/vault.db`). Table-owned behavior lives in focused stores
// under `Sources/Core/KnowledgeStore/` that share this connection and queue:
//
//   EntityStore     — knowledge_entities + knowledge_fts (FTS5 + 3 triggers)
//   LinkStore       — entity_links
//   DecisionStore   — decision_records
//   EnrichmentStore — evidence_timeline + co_change_coupling
//
// What stays on this façade:
//   - Connection / queue lifecycle (`db`, `queue`, WAL + foreign_keys pragmas).
//   - Construction order: enable WAL → instantiate stores → call setupSchema
//     on each (idempotent; no cross-store DDL today).
//   - The four `+API` extension files next to this one hold the public
//     forwarders so callsites keep the pre-split shape.

/// Project-scoped SQLite+FTS5 knowledge base.
/// Opens <projectRoot>/.senkani/vault.db — isolated from SessionDatabase.
/// All DB access is serialized through `queue` (NSLock-free, dispatch-based).
public final class KnowledgeStore: @unchecked Sendable {

    // `internal` (not `private`) so that extracted stores under
    // `Sources/Core/KnowledgeStore/` can share the connection + queue without
    // opening a second handle. External callers still go through the public
    // forwarding API — they never see the raw SQLite pointer.
    internal var db: OpaquePointer?
    internal let queue = DispatchQueue(label: "com.senkani.knowledgestore", qos: .utility)

    // Extracted stores. Each owns its tables end-to-end and shares this
    // façade's connection + queue.
    internal var entityStore: EntityStore!
    internal var linkStore: LinkStore!
    internal var decisionStore: DecisionStore!
    internal var enrichmentStore: EnrichmentStore!

    // MARK: - Init

    public init(projectRoot: String) {
        let dir = projectRoot + "/.senkani"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        openDB(path: dir + "/vault.db")
    }

    /// Testable init — pass a /tmp/... path.
    public init(path: String) {
        let dir = (path as NSString).deletingLastPathComponent
        if !dir.isEmpty {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
        openDB(path: path)
    }

    private func openDB(path: String) {
        if sqlite3_open(path, &db) != SQLITE_OK {
            let err = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            fputs("[KnowledgeStore] Failed to open \(path): \(err)\n", stderr)
            db = nil
        }
        enableWAL()
        // Order matters only insofar as `entity_links`, `decision_records`, and
        // `evidence_timeline` carry FK references to `knowledge_entities`.
        // SQLite resolves FKs at row-write time, not at CREATE TABLE time, so
        // the per-store CREATE order is interchangeable with foreign_keys=ON.
        // Tables stay together in their owning store either way.
        entityStore = EntityStore(parent: self)
        linkStore = LinkStore(parent: self)
        decisionStore = DecisionStore(parent: self)
        enrichmentStore = EnrichmentStore(parent: self)
        entityStore.setupSchema()
        linkStore.setupSchema()
        decisionStore.setupSchema()
        enrichmentStore.setupSchema()
    }

    deinit {
        queue.sync { if let db { sqlite3_close(db) } }
    }

    public func close() {
        queue.sync { if let db { sqlite3_close(db) }; self.db = nil }
    }

    // MARK: - WAL + foreign keys

    private func enableWAL() {
        guard let db else { return }
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "PRAGMA journal_mode=WAL;", -1, &stmt, nil) == SQLITE_OK {
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
        // Enable foreign key enforcement.
        var fkStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "PRAGMA foreign_keys=ON;", -1, &fkStmt, nil) == SQLITE_OK {
            sqlite3_step(fkStmt)
        }
        sqlite3_finalize(fkStmt)
    }
}
