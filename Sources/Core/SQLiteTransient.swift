import Foundation
import SQLite3

/// SQLite's `SQLITE_TRANSIENT` destructor sentinel — `(sqlite3_destructor_type)(-1)`.
///
/// Passed as the 5th argument to `sqlite3_bind_text` / `sqlite3_bind_blob`
/// to instruct SQLite to copy the bound bytes during the bind call.
///
/// Required for any bound pointer whose backing storage is a Swift String,
/// NSString temporary, or string literal — the bridge does not guarantee
/// pointer lifetime past the bind expression. The default `nil`
/// (`SQLITE_STATIC`) assumes the caller keeps the pointer valid until
/// `sqlite3_step` returns, which transient bridges cannot.
///
/// Originating audit: `sqlite-bind-static-dangling-pointer-audit-2026-05-21`.
internal let SQLITE_TRANSIENT_DESTRUCTOR: sqlite3_destructor_type =
    unsafeBitCast(OpaquePointer(bitPattern: -1), to: sqlite3_destructor_type.self)
