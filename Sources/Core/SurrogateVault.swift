import Foundation
import CryptoKit
import SQLite3

/// T.2c-1 — per-engagement surrogate ledger backed by a SQLite
/// file at `~/.senkani/surrogates/<engagement-id>.sqlite` (mode
/// 0600). Original PII values are AES-GCM-sealed at rest using the
/// engagement's `SymmetricKey`; only `surrogate_id` + `category`
/// live in plaintext columns.
///
/// Surrogate naming: `<CATEGORY>_<NNN>` (monotonic per engagement
/// per category — `PRIVATE_PERSON_001`, `PRIVATE_EMAIL_001`, …).
/// Second mention of the same original value WITHIN AN ENGAGEMENT
/// reuses the prior surrogate (allocation idempotency).
///
/// Engagement isolation: two engagements scrubbing the same
/// original value produce disjoint vaults each starting at
/// `_001` against their own counter, with disjoint encryption keys.
/// A leak of one vault cannot deanonymize another.
public actor SurrogateVault {

    /// Marker for SQLite-layer failures the actor surfaces upward.
    /// Vault corruption is treated as fatal — there is no recovery
    /// path that preserves the privacy property.
    public struct VaultError: Error, CustomStringConvertible {
        public let message: String
        public init(_ message: String) { self.message = message }
        public var description: String { "SurrogateVault: \(message)" }
    }

    private nonisolated(unsafe) var db: OpaquePointer?
    private let path: URL
    private let key: SymmetricKey
    private let engagementID: String

    /// In-memory allocation cache. Loaded from disk on init; kept in
    /// lockstep with disk writes via the actor barrier.
    private var indexByValue: [String: [String: String]] = [:]
    private var originalBySurrogateID: [String: String] = [:]
    private var counters: [String: Int] = [:]

    /// Initialize, opening (and migrating) the per-engagement SQLite
    /// vault. Idempotent — re-opening the same path on the same
    /// engagement key restores prior allocations.
    public init(
        context: EngagementContext,
        keySource: EngagementKeySource
    ) throws {
        self.path = context.vaultPath
        self.key = context.key
        self.engagementID = context.id
        try Self.ensureFileSecurity(at: path)

        var db: OpaquePointer? = nil
        try Self.openDB(path: path, db: &db)
        try Self.migrate(db: db)
        try Self.seedMeta(db: db, engagementID: engagementID, keySource: keySource)
        let loaded = try Self.loadAllocations(db: db, key: key)
        self.db = db
        self.originalBySurrogateID = loaded.originals
        self.indexByValue = loaded.indexByValue
        self.counters = loaded.counters
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    // MARK: - File security (nonisolated, only touches FileManager)

    private static func ensureFileSecurity(at path: URL) throws {
        let fm = FileManager.default
        let dir = path.deletingLastPathComponent()
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(
                at: dir,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        if !fm.fileExists(atPath: path.path) {
            fm.createFile(
                atPath: path.path,
                contents: Data(),
                attributes: [.posixPermissions: 0o600]
            )
        } else {
            try fm.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: path.path
            )
        }
    }

    // MARK: - Schema (nonisolated static — drive a passed-in db)

    private static func openDB(path: URL, db: inout OpaquePointer?) throws {
        if sqlite3_open(path.path, &db) != SQLITE_OK {
            let err = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            throw VaultError("open(\(path.path)) failed: \(err)")
        }
        try execOn(db: db, "PRAGMA journal_mode=WAL;")
        try execOn(db: db, "PRAGMA foreign_keys=ON;")
    }

    private static func migrate(db: OpaquePointer?) throws {
        try execOn(db: db, """
            CREATE TABLE IF NOT EXISTS surrogates (
              surrogate_id TEXT PRIMARY KEY,
              original_value_encrypted BLOB NOT NULL,
              category TEXT NOT NULL,
              first_seen REAL NOT NULL,
              last_seen REAL NOT NULL
            );
            """)
        try execOn(db: db, """
            CREATE TABLE IF NOT EXISTS meta (
              key TEXT PRIMARY KEY,
              value TEXT
            );
            """)
        try execOn(db: db, "CREATE INDEX IF NOT EXISTS surrogates_category_idx ON surrogates(category);")
    }

    private static func seedMeta(
        db: OpaquePointer?,
        engagementID: String,
        keySource: EngagementKeySource
    ) throws {
        try setMetaOn(db: db, key: "engagement_id", value: engagementID)
        if try getMetaOn(db: db, key: "created_at") == nil {
            try setMetaOn(db: db, key: "created_at", value: Self.isoNow())
        }
        try setMetaOn(db: db, key: "key_source", value: keySource.rawValue)
    }

    private struct LoadedAllocations {
        var originals: [String: String]
        var indexByValue: [String: [String: String]]
        var counters: [String: Int]
    }

    private static func loadAllocations(
        db: OpaquePointer?,
        key: SymmetricKey
    ) throws -> LoadedAllocations {
        var stmt: OpaquePointer?
        let sql = "SELECT surrogate_id, original_value_encrypted, category FROM surrogates ORDER BY first_seen ASC;"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw VaultError("prepare load failed")
        }
        defer { sqlite3_finalize(stmt) }
        var originals: [String: String] = [:]
        var indexByValue: [String: [String: String]] = [:]
        var counters: [String: Int] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            let surrogateID = String(cString: sqlite3_column_text(stmt, 0))
            let blobLen = Int(sqlite3_column_bytes(stmt, 1))
            let blobPtr = sqlite3_column_blob(stmt, 1)
            let encrypted = Data(bytes: blobPtr!, count: blobLen)
            let category = String(cString: sqlite3_column_text(stmt, 2))
            let original = try openCipher(encrypted: encrypted, key: key)
            originals[surrogateID] = original
            var byValue = indexByValue[category] ?? [:]
            byValue[original] = surrogateID
            indexByValue[category] = byValue
            if let suffix = surrogateID.split(separator: "_").last,
               let n = Int(suffix) {
                counters[category] = max(counters[category] ?? 0, n)
            }
        }
        return LoadedAllocations(
            originals: originals,
            indexByValue: indexByValue,
            counters: counters
        )
    }

    // MARK: - Public surface (actor-isolated)

    /// Allocate (or reuse) a surrogate for `originalValue` within
    /// `category`. Reuse is per-engagement-per-category by exact
    /// match of the original value; touches `last_seen` on reuse.
    @discardableResult
    public func allocate(originalValue: String, category: String) throws -> String {
        if let existing = indexByValue[category]?[originalValue] {
            try Self.updateLastSeenOn(db: db, surrogateID: existing)
            return existing
        }
        let next = (counters[category] ?? 0) + 1
        counters[category] = next
        let surrogateID = String(format: "\(category)_%03d", next)
        let sealed = try Self.sealOn(plaintext: originalValue, key: key)
        let now = Date()
        try Self.insertOn(
            db: db,
            surrogateID: surrogateID,
            encrypted: sealed,
            category: category,
            firstSeen: now,
            lastSeen: now
        )
        var byValue = indexByValue[category] ?? [:]
        byValue[originalValue] = surrogateID
        indexByValue[category] = byValue
        originalBySurrogateID[surrogateID] = originalValue
        return surrogateID
    }

    /// Map a surrogate id back to its original value. Returns nil
    /// for unknown ids — caller treats the token as not-a-surrogate
    /// and leaves it untouched in the rewrite-back text.
    public func original(for surrogateID: String) -> String? {
        originalBySurrogateID[surrogateID]
    }

    /// Snapshot of every surrogate id known to this vault. The
    /// rewrite-back path uses this to constrain its token-boundary
    /// scan to vetted ids — never touches arbitrary `<WORD>_<DIGITS>`
    /// tokens in the model's output.
    public func knownSurrogateIDs() -> [String: String] {
        originalBySurrogateID
    }

    /// Diagnostic for the test that proves engagement isolation —
    /// the next id the named category would mint.
    public func peekNextCounter(category: String) -> Int {
        (counters[category] ?? 0) + 1
    }

    /// Diagnostic — total rows in the vault. Cheap; used by tests.
    public func count() throws -> Int {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM surrogates;", -1, &stmt, nil) == SQLITE_OK else {
            throw VaultError("prepare count failed")
        }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    public func getMeta(_ key: String) throws -> String? {
        try Self.getMetaOn(db: db, key: key)
    }

    // MARK: - Crypto (nonisolated, pure functions of plaintext+key)

    private static func sealOn(plaintext: String, key: SymmetricKey) throws -> Data {
        let box = try AES.GCM.seal(Data(plaintext.utf8), using: key)
        guard let combined = box.combined else {
            throw VaultError("AES.GCM.seal produced no combined payload")
        }
        return combined
    }

    private static func openCipher(encrypted: Data, key: SymmetricKey) throws -> String {
        let box = try AES.GCM.SealedBox(combined: encrypted)
        let plain = try AES.GCM.open(box, using: key)
        guard let s = String(data: plain, encoding: .utf8) else {
            throw VaultError("decrypted bytes not UTF-8")
        }
        return s
    }

    // MARK: - SQL helpers (nonisolated, take a db handle as parameter)

    private static func execOn(db: OpaquePointer?, _ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let msg = err.flatMap { String(cString: $0) } ?? "unknown"
            sqlite3_free(err)
            throw VaultError("exec failed: \(msg)")
        }
    }

    private static func insertOn(
        db: OpaquePointer?,
        surrogateID: String,
        encrypted: Data,
        category: String,
        firstSeen: Date,
        lastSeen: Date
    ) throws {
        var stmt: OpaquePointer?
        let sql = "INSERT INTO surrogates (surrogate_id, original_value_encrypted, category, first_seen, last_seen) VALUES (?, ?, ?, ?, ?);"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw VaultError("prepare insert failed")
        }
        defer { sqlite3_finalize(stmt) }
        let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, surrogateID, -1, SQLITE_TRANSIENT)
        encrypted.withUnsafeBytes { raw in
            _ = sqlite3_bind_blob(stmt, 2, raw.baseAddress, Int32(raw.count), SQLITE_TRANSIENT)
        }
        sqlite3_bind_text(stmt, 3, category, -1, SQLITE_TRANSIENT)
        sqlite3_bind_double(stmt, 4, firstSeen.timeIntervalSince1970)
        sqlite3_bind_double(stmt, 5, lastSeen.timeIntervalSince1970)
        if sqlite3_step(stmt) != SQLITE_DONE {
            let err = String(cString: sqlite3_errmsg(db))
            throw VaultError("insert step failed: \(err)")
        }
    }

    private static func updateLastSeenOn(
        db: OpaquePointer?,
        surrogateID: String
    ) throws {
        var stmt: OpaquePointer?
        let sql = "UPDATE surrogates SET last_seen = ? WHERE surrogate_id = ?;"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw VaultError("prepare updateLastSeen failed")
        }
        defer { sqlite3_finalize(stmt) }
        let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_double(stmt, 1, Date().timeIntervalSince1970)
        sqlite3_bind_text(stmt, 2, surrogateID, -1, SQLITE_TRANSIENT)
        if sqlite3_step(stmt) != SQLITE_DONE {
            throw VaultError("updateLastSeen step failed")
        }
    }

    private static func setMetaOn(
        db: OpaquePointer?,
        key: String,
        value: String
    ) throws {
        var stmt: OpaquePointer?
        let sql = "INSERT INTO meta (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value;"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw VaultError("prepare setMeta failed")
        }
        defer { sqlite3_finalize(stmt) }
        let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, key, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, value, -1, SQLITE_TRANSIENT)
        if sqlite3_step(stmt) != SQLITE_DONE {
            throw VaultError("setMeta step failed")
        }
    }

    private static func getMetaOn(
        db: OpaquePointer?,
        key: String
    ) throws -> String? {
        var stmt: OpaquePointer?
        let sql = "SELECT value FROM meta WHERE key = ? LIMIT 1;"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw VaultError("prepare getMeta failed")
        }
        defer { sqlite3_finalize(stmt) }
        let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, key, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return String(cString: sqlite3_column_text(stmt, 0))
    }

    private static func isoNow() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: Date())
    }
}
