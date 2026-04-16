import Foundation
import SQLite3

/// Per-project SQLite FTS5 store for BM25-ranked symbol search.
/// Stored at `<projectRoot>/.senkani/index.db` alongside `index.json`.
///
/// Thread safety: each call opens and closes its own SQLite connection.
/// SQLite WAL mode handles concurrent readers + one writer without corruption.
public struct SymbolFTSStore {
    public let dbPath: String

    public init(projectRoot: String) {
        self.dbPath = projectRoot + "/.senkani/index.db"
    }

    // MARK: - Schema

    /// FTS5 table schema.
    ///
    /// `name`, `signature`, `container` are indexed for BM25.
    /// `kind`, `file`, `start_line` are UNINDEXED — stored for retrieval, not searched.
    private static let createTableSQL = """
        CREATE VIRTUAL TABLE IF NOT EXISTS symbols_fts USING fts5(
            name,
            signature,
            container,
            kind      UNINDEXED,
            file      UNINDEXED,
            start_line UNINDEXED,
            tokenize='unicode61'
        );
        """

    // MARK: - Connection

    private func openDB() throws -> OpaquePointer {
        let dir = (dbPath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        var db: OpaquePointer?
        guard sqlite3_open(dbPath, &db) == SQLITE_OK, let db else {
            throw FTSError.openFailed(dbPath)
        }
        // WAL mode: concurrent readers don't block writers
        exec(db, "PRAGMA journal_mode=WAL;")
        exec(db, "PRAGMA synchronous=NORMAL;")
        exec(db, SymbolFTSStore.createTableSQL)
        return db
    }

    @discardableResult
    private func exec(_ db: OpaquePointer, _ sql: String) -> Bool {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_DONE
    }

    // MARK: - Writes

    /// Replace the entire FTS index. Called after a full index rebuild.
    public func rebuild(entries: [IndexEntry]) throws {
        let db = try openDB()
        defer { sqlite3_close(db) }

        exec(db, "BEGIN;")
        exec(db, "DELETE FROM symbols_fts;")

        let sql = "INSERT INTO symbols_fts(name, signature, container, kind, file, start_line) VALUES (?,?,?,?,?,?);"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            exec(db, "ROLLBACK;")
            throw FTSError.prepareFailed("rebuild insert")
        }
        defer { sqlite3_finalize(stmt) }

        for entry in entries {
            sqlite3_reset(stmt)
            sqlite3_bind_text(stmt, 1, (entry.name as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 2, ((entry.signature ?? "") as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 3, ((entry.container ?? "") as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 4, (entry.kind.rawValue as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 5, (entry.file as NSString).utf8String, -1, nil)
            sqlite3_bind_int(stmt, 6, Int32(entry.startLine))
            sqlite3_step(stmt)
        }

        exec(db, "COMMIT;")
    }

    /// Update FTS for changed files: remove old symbols, insert new ones.
    /// Used by incremental index updates.
    public func update(removedFiles: Set<String>, addedEntries: [IndexEntry]) throws {
        guard !removedFiles.isEmpty || !addedEntries.isEmpty else { return }
        let db = try openDB()
        defer { sqlite3_close(db) }

        exec(db, "BEGIN;")

        if !removedFiles.isEmpty {
            let placeholders = removedFiles.map { _ in "?" }.joined(separator: ",")
            let delSQL = "DELETE FROM symbols_fts WHERE file IN (\(placeholders));"
            var delStmt: OpaquePointer?
            if sqlite3_prepare_v2(db, delSQL, -1, &delStmt, nil) == SQLITE_OK {
                for (i, file) in removedFiles.enumerated() {
                    sqlite3_bind_text(delStmt, Int32(i + 1), (file as NSString).utf8String, -1, nil)
                }
                sqlite3_step(delStmt)
                sqlite3_finalize(delStmt)
            }
        }

        if !addedEntries.isEmpty {
            let sql = "INSERT INTO symbols_fts(name, signature, container, kind, file, start_line) VALUES (?,?,?,?,?,?);"
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                defer { sqlite3_finalize(stmt) }
                for entry in addedEntries {
                    sqlite3_reset(stmt)
                    sqlite3_bind_text(stmt, 1, (entry.name as NSString).utf8String, -1, nil)
                    sqlite3_bind_text(stmt, 2, ((entry.signature ?? "") as NSString).utf8String, -1, nil)
                    sqlite3_bind_text(stmt, 3, ((entry.container ?? "") as NSString).utf8String, -1, nil)
                    sqlite3_bind_text(stmt, 4, (entry.kind.rawValue as NSString).utf8String, -1, nil)
                    sqlite3_bind_text(stmt, 5, (entry.file as NSString).utf8String, -1, nil)
                    sqlite3_bind_int(stmt, 6, Int32(entry.startLine))
                    sqlite3_step(stmt)
                }
            }
        }

        exec(db, "COMMIT;")
    }

    // MARK: - Search

    /// BM25-ranked symbol search. Results are ordered best-match-first.
    /// Returns up to `limit` (entry, 1-based rank) pairs.
    ///
    /// Filters `kind`, `file`, `container` are applied post-FTS in Swift
    /// (FTS5 UNINDEXED columns can't be used in MATCH expressions).
    public func search(
        query: String,
        kind: SymbolKind? = nil,
        file: String? = nil,
        container: String? = nil,
        limit: Int = 50
    ) throws -> [(entry: IndexEntry, bm25Rank: Int)] {
        let sanitized = Self.sanitizeFTS5Query(query)
        guard !sanitized.isEmpty else { return [] }

        let db = try openDB()
        defer { sqlite3_close(db) }

        let sql = """
            SELECT name, signature, container, kind, file, start_line
            FROM symbols_fts
            WHERE symbols_fts MATCH ?
            ORDER BY rank
            LIMIT ?;
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw FTSError.prepareFailed("search")
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, (sanitized as NSString).utf8String, -1, nil)
        // Fetch more than limit to allow post-FTS filtering
        sqlite3_bind_int(stmt, 2, Int32(min(limit * 3, 300)))

        var results: [(entry: IndexEntry, bm25Rank: Int)] = []
        var rawRank = 0
        while sqlite3_step(stmt) == SQLITE_ROW {
            rawRank += 1
            let name      = String(cString: sqlite3_column_text(stmt, 0))
            let sig       = sqlite3_column_text(stmt, 1).map { String(cString: $0) }.flatMap { $0.isEmpty ? nil : $0 }
            let cont      = sqlite3_column_text(stmt, 2).map { String(cString: $0) }.flatMap { $0.isEmpty ? nil : $0 }
            let kindStr   = String(cString: sqlite3_column_text(stmt, 3))
            let filePath  = String(cString: sqlite3_column_text(stmt, 4))
            let startLine = Int(sqlite3_column_int(stmt, 5))

            guard let symbolKind = SymbolKind(rawValue: kindStr) else { continue }

            // Post-FTS filters on UNINDEXED columns
            if let k = kind, symbolKind != k { continue }
            if let f = file, !filePath.lowercased().contains(f.lowercased()) { continue }
            if let c = container {
                guard let cont, cont.lowercased().contains(c.lowercased()) else { continue }
            }

            let entry = IndexEntry(
                name: name,
                kind: symbolKind,
                file: filePath,
                startLine: startLine,
                signature: sig,
                container: cont
            )
            results.append((entry: entry, bm25Rank: results.count + 1))
            if results.count >= limit { break }
        }
        return results
    }

    // MARK: - FTS5 Query Sanitization

    /// Strip FTS5 operators and quote each term to prevent query injection.
    /// Mirrors `SessionDatabase.sanitizeFTS5Query(_:)`.
    static func sanitizeFTS5Query(_ raw: String) -> String {
        let stripped = raw.unicodeScalars.filter { scalar in
            CharacterSet.alphanumerics.contains(scalar)
                || scalar == " " || scalar == "-" || scalar == "_" || scalar == "."
        }
        let cleaned = String(stripped)
        let ftsKeywords: Set<String> = ["AND", "OR", "NOT", "NEAR"]
        let terms = cleaned.split(separator: " ")
            .map { String($0) }
            .filter { !$0.isEmpty && !ftsKeywords.contains($0.uppercased()) }
        guard !terms.isEmpty else { return "" }
        // Trailing * enables prefix matching: "connect"* also finds "connectHelper".
        return terms.map { "\"\($0)\"*" }.joined(separator: " ")
    }
}

// MARK: - Errors

public enum FTSError: Error, Sendable {
    case openFailed(String)
    case prepareFailed(String)
}
