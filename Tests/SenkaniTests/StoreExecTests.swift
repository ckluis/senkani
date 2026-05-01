import Testing
import Foundation
@testable import Core

/// Cleanup #17: three near-identical `exec(_:)` helpers in CommandStore,
/// SandboxStore, and ValidationStore now route through a single
/// `StoreExec.run(db:sql:scope:)`. These tests pin the helper's
/// contract directly so a future structured-field addition has a
/// single place to land — and a regression that swaps the scope token
/// surfaces here instead of through three callers.
@Suite("StoreExec — shared sqlite3_exec wrapper", .serialized)
struct StoreExecTests {

    final class Sink: @unchecked Sendable {
        private let lock = NSLock()
        private var _events: [(String, [String: LogValue])] = []

        func record(_ event: String, _ fields: [String: LogValue]) {
            lock.lock(); defer { lock.unlock() }
            _events.append((event, fields))
        }

        var events: [(String, [String: LogValue])] {
            lock.lock(); defer { lock.unlock() }
            return _events
        }

        func count(of name: String) -> Int {
            events.filter { $0.0 == name }.count
        }
    }

    private func withSink<T>(_ body: (Sink) throws -> T) rethrows -> T {
        let sink = Sink()
        Logger._setTestSink { event, fields in sink.record(event, fields) }
        defer { Logger._setTestSink(nil) }
        return try body(sink)
    }

    private func stringField(_ fields: [String: LogValue], _ key: String) -> String? {
        guard let v = fields[key] else { return nil }
        if case .string(let s) = v { return s }
        return nil
    }

    private func openTempDB() -> (SessionDatabase, String) {
        let path = "/tmp/senkani-storeexec-\(UUID().uuidString).sqlite"
        return (SessionDatabase(path: path), path)
    }

    private func cleanup(_ path: String) {
        let fm = FileManager.default
        try? fm.removeItem(atPath: path)
        try? fm.removeItem(atPath: path + "-wal")
        try? fm.removeItem(atPath: path + "-shm")
    }

    @Test func nilDBIsNoop() {
        withSink { sink in
            StoreExec.run(db: nil, sql: "SELECT 1;", scope: "command")
            #expect(sink.events.isEmpty,
                    "nil db must not emit; got \(sink.events.map(\.0))")
        }
    }

    @Test func successfulStatementEmitsNothing() {
        let (db, path) = openTempDB()
        defer { cleanup(path) }
        withSink { sink in
            StoreExec.run(db: db.db, sql: "SELECT 1;", scope: "command")
            #expect(sink.count(of: "db.command.sql_error") == 0)
        }
    }

    @Test func failedStatementEmitsScopedSqlError() {
        let (db, path) = openTempDB()
        defer { cleanup(path) }
        withSink { sink in
            StoreExec.run(db: db.db, sql: "NOT VALID SQL;", scope: "command")
            #expect(sink.count(of: "db.command.sql_error") == 1)
            let fields = sink.events.first { $0.0 == "db.command.sql_error" }?.1 ?? [:]
            #expect(stringField(fields, "outcome") == "error")
            #expect((stringField(fields, "error") ?? "").isEmpty == false)
        }
    }

    @Test func scopeTokenIsParameterized() {
        let (db, path) = openTempDB()
        defer { cleanup(path) }
        withSink { sink in
            StoreExec.run(db: db.db, sql: "NOT VALID SQL;", scope: "sandbox")
            StoreExec.run(db: db.db, sql: "NOT VALID SQL;", scope: "validation")
            #expect(sink.count(of: "db.sandbox.sql_error") == 1)
            #expect(sink.count(of: "db.validation.sql_error") == 1)
            #expect(sink.count(of: "db.command.sql_error") == 0)
        }
    }
}
