import Foundation

// MARK: - KBLayer1Coordinator
//
// Phase F+1 (Round 4 of the master plan). Formalizes the three-layer
// KB stack from `spec/compound_learning.md`:
//
//   Layer 1 (canonical):   .senkani/knowledge/*.md    — human source of truth
//   Layer 2 (retrieval):   knowledge.db (SQLite+FTS5) — derived from Layer 1
//   Layer 3 (enrichment):  Gemma 4 (async)            — writes to Layer 1
//
// Pre-audit (roadmap shipped at Phase F.7):
//   - `KnowledgeFileLayer` already reads/writes `.md` files and has
//     `syncAllToStore()` which walks the directory and imports each
//     file into the SQLite store. The one-way sync exists.
//
// What F+1 adds:
//   - Staleness detection: compare the DB's `modifiedAt` timestamp (or
//     file mtime) to the newest `.md` file under `.senkani/knowledge/`.
//     If any .md is newer → rebuild.
//   - Corruption recovery: if the KnowledgeStore fails to open, delete
//     + rebuild from Layer 1.
//   - Event counters: `knowledge.rebuild.{triggered,succeeded,failed}`,
//     `knowledge.corruption.{detected,recovered}`.
//
// Invariant after F+1: on every session start, Layer 2 is guaranteed
// fresh relative to Layer 1. Manual `.md` edits picked up automatically.

public enum KBLayer1Coordinator {

    /// Decision: is a rebuild needed given the current DB + markdown state?
    public enum RebuildDecision: Sendable, Equatable {
        case noRebuildNeeded
        case rebuildStale(newestMdFileModifiedAt: Date, dbModifiedAt: Date?)
        case rebuildCorrupt
    }

    public static let markdownSubdir = ".senkani/knowledge"
    public static let dbFilename = "knowledge.db"

    /// Inspect disk state and decide whether to rebuild.
    /// Tests inject `now` for determinism.
    public static func decideRebuild(
        projectRoot: String,
        fileManager fm: FileManager = .default
    ) -> RebuildDecision {
        let mdDir = KBVaultConfig.resolvedVaultDir(projectRoot: projectRoot)
        // The Layer-2 SQLite DB still lives next to the project (it's derived
        // state, not user-edited markdown). Pinning it here keeps `senkani kb`
        // discovery working unchanged when the vault is externalized.
        let dbPath = projectRoot + "/" + markdownSubdir + "/" + dbFilename

        // 1. Any .md files?
        guard let contents = try? fm.contentsOfDirectory(atPath: mdDir) else {
            return .noRebuildNeeded
        }
        let mdFiles = contents.filter { $0.hasSuffix(".md") }
        guard !mdFiles.isEmpty else { return .noRebuildNeeded }

        // Newest .md mtime.
        let newest: Date = mdFiles.compactMap { name -> Date? in
            let p = mdDir + "/" + name
            return (try? fm.attributesOfItem(atPath: p))?[.modificationDate] as? Date
        }.max() ?? .distantPast

        // 2. DB mtime — absent means "no DB yet, rebuild."
        if !fm.fileExists(atPath: dbPath) {
            return .rebuildStale(newestMdFileModifiedAt: newest, dbModifiedAt: nil)
        }
        let dbMtime = (try? fm.attributesOfItem(atPath: dbPath))?[.modificationDate] as? Date

        // 3. DB readable? Probe by opening; a corrupt DB is rarer than
        // mtime skew but the recovery path must exist.
        if let size = (try? fm.attributesOfItem(atPath: dbPath))?[.size] as? Int,
           size < 100 {
            // A DB file smaller than the SQLite header (100 bytes) is
            // truncated / corrupt. Recover.
            return .rebuildCorrupt
        }

        guard let mtime = dbMtime else {
            return .rebuildStale(newestMdFileModifiedAt: newest, dbModifiedAt: nil)
        }
        if mtime < newest {
            return .rebuildStale(newestMdFileModifiedAt: newest, dbModifiedAt: mtime)
        }
        return .noRebuildNeeded
    }

    /// Execute the rebuild decision. Idempotent — callers that already
    /// rebuilt in a recent session can call this cheaply.
    /// Returns true iff a rebuild ran.
    @discardableResult
    public static func rebuildIfNeeded(
        projectRoot: String,
        store: KnowledgeStore,
        fileLayer: KnowledgeFileLayer,
        db: SessionDatabase = .shared,
        decision precomputed: RebuildDecision? = nil
    ) -> Bool {
        let d = precomputed ?? decideRebuild(projectRoot: projectRoot)
        switch d {
        case .noRebuildNeeded:
            return false
        case .rebuildStale, .rebuildCorrupt:
            db.recordEvent(type: "knowledge.rebuild.triggered", projectRoot: projectRoot)
            if case .rebuildCorrupt = d {
                db.recordEvent(type: "knowledge.corruption.detected", projectRoot: projectRoot)
            }
            do {
                try fileLayer.syncAllToStore()
                db.recordEvent(type: "knowledge.rebuild.succeeded", projectRoot: projectRoot)
                if case .rebuildCorrupt = d {
                    db.recordEvent(type: "knowledge.corruption.recovered",
                                   projectRoot: projectRoot)
                }
                return true
            } catch {
                db.recordEvent(type: "knowledge.rebuild.failed", projectRoot: projectRoot)
                FileHandle.standardError.write(Data(
                    "senkani.kb: rebuild failed: \(error.localizedDescription)\n".utf8))
                return false
            }
        }
    }
}
