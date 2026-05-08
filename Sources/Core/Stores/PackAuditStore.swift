import Foundation
import SQLite3

/// Owns `pack_audits` end-to-end: schema (migration v20), chained
/// writes, recent-row reads. Mirrors `EgressDecisionStore`'s shape so
/// the chain mechanics are uniform across participants.
///
/// V.11a — SkillPack install/uninstall provenance. One row per
/// `install`, `uninstall`, or `force_override` event.
public final class PackAuditStore: @unchecked Sendable {
    private unowned let parent: SessionDatabase
    private let chain = ChainState(table: "pack_audits")

    init(parent: SessionDatabase) {
        self.parent = parent
    }

    /// Drop the chain cache after a `--repair-chain` motion. Caller
    /// must already be on `parent.queue`.
    func invalidateChainCache() { chain.invalidate() }

    /// Record an install/uninstall/force_override event. Synchronous-on-queue
    /// so a CLI call sees the row immediately when it queries back.
    @discardableResult
    public func record(
        packName: String,
        packVersion: String,
        event: String,
        sourcePath: String,
        sha256: String?,
        appliedSkills: [String]
    ) -> Bool {
        let now = Date().timeIntervalSince1970
        let appliedSkillsJSON: String = {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            if let data = try? encoder.encode(appliedSkills),
               let s = String(data: data, encoding: .utf8) {
                return s
            }
            return "[]"
        }()

        return parent.queue.sync { [parent, chain] in
            guard let db = parent.db else { return false }
            let anchorId = chain.resolveAnchorId(db: db)
            let prevHash = chain.latestEntryHash(db: db, anchorId: anchorId)

            let columns: [String: ChainHasher.CanonicalValue] = [
                "pack_name":       .text(packName),
                "pack_version":    .text(packVersion),
                "event":           .text(event),
                "at":              .real(now),
                "source_path":     .text(sourcePath),
                "sha256":          sha256.map { .text($0) } ?? .null,
                "applied_skills":  .text(appliedSkillsJSON),
            ]
            let entryHash = ChainHasher.entryHash(
                table: "pack_audits", columns: columns, prev: prevHash
            )

            let sql = """
                INSERT INTO pack_audits
                    (pack_name, pack_version, event, at, source_path, sha256,
                     applied_skills, prev_hash, entry_hash, chain_anchor_id)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, (packName as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 2, (packVersion as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 3, (event as NSString).utf8String, -1, nil)
            sqlite3_bind_double(stmt, 4, now)
            sqlite3_bind_text(stmt, 5, (sourcePath as NSString).utf8String, -1, nil)
            if let sha256 {
                sqlite3_bind_text(stmt, 6, (sha256 as NSString).utf8String, -1, nil)
            } else {
                sqlite3_bind_null(stmt, 6)
            }
            sqlite3_bind_text(stmt, 7, (appliedSkillsJSON as NSString).utf8String, -1, nil)
            if let prevHash {
                sqlite3_bind_text(stmt, 8, (prevHash as NSString).utf8String, -1, nil)
            } else {
                sqlite3_bind_null(stmt, 8)
            }
            sqlite3_bind_text(stmt, 9, (entryHash as NSString).utf8String, -1, nil)
            sqlite3_bind_int64(stmt, 10, anchorId)

            guard sqlite3_step(stmt) == SQLITE_DONE else { return false }
            chain.recordWrite(anchorId: anchorId, entryHash: entryHash)
            return true
        }
    }

    public struct Row: Sendable, Equatable {
        public let id: Int64
        public let packName: String
        public let packVersion: String
        public let event: String
        public let at: Date
        public let sourcePath: String
        public let sha256: String?
        public let appliedSkills: [String]
    }

    public func recent(limit: Int = 100) -> [Row] {
        return parent.queue.sync {
            guard let db = parent.db else { return [] }
            let sql = """
                SELECT id, pack_name, pack_version, event, at, source_path,
                       sha256, applied_skills
                  FROM pack_audits
                 ORDER BY id DESC
                 LIMIT ?;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int(stmt, 1, Int32(limit))
            var out: [Row] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let id = sqlite3_column_int64(stmt, 0)
                let name = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
                let version = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? ""
                let event = sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? ""
                let at = sqlite3_column_double(stmt, 4)
                let source = sqlite3_column_text(stmt, 5).map { String(cString: $0) } ?? ""
                let sha: String? = sqlite3_column_type(stmt, 6) == SQLITE_NULL
                    ? nil
                    : sqlite3_column_text(stmt, 6).map { String(cString: $0) }
                let skillsJSON = sqlite3_column_text(stmt, 7).map { String(cString: $0) } ?? "[]"
                let skills: [String] = (try? JSONDecoder().decode(
                    [String].self, from: Data(skillsJSON.utf8))) ?? []
                out.append(Row(
                    id: id, packName: name, packVersion: version, event: event,
                    at: Date(timeIntervalSince1970: at),
                    sourcePath: source, sha256: sha, appliedSkills: skills
                ))
            }
            return out
        }
    }

    public func count() -> Int64 {
        return parent.queue.sync {
            guard let db = parent.db else { return 0 }
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM pack_audits;", -1, &stmt, nil) == SQLITE_OK else {
                return 0
            }
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
            return sqlite3_column_int64(stmt, 0)
        }
    }
}
