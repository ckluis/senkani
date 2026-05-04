import Foundation
import SQLite3

/// Shared wrapper around `sqlite3_exec` for store helpers that emit a
/// `db.<scope>.sql_error` Logger event on failure. CommandStore,
/// SandboxStore, and ValidationStore previously inlined three
/// near-identical 11-line copies; routing through this helper means a
/// future structured-field addition (e.g. a `sql:` field with the
/// failed statement) is a one-place change.
enum StoreExec {
    static func run(db: OpaquePointer?, sql: String, scope: String) {
        guard let db else { return }
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "unknown"
            Logger.log("db.\(scope).sql_error", fields: [
                "error": .string(msg),
                "outcome": .string("error"),
            ])
            sqlite3_free(err)
        }
    }
}
