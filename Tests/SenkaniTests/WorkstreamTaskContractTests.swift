import Testing
import Foundation
import SQLite3
@testable import Core

/// U.11a-1 — `WorkstreamTaskContract` foundation tests.
///
/// 4 tests covering the 4 acceptance bullets:
///   1. Codable round-trip is byte-identical across 3 fixtures.
///   2. v39 migration creates `workstream_contracts` with declared
///      FK + index, and ledger advances v38 → v39.
///   3. SQLite persist → query-back is field-by-field equal across
///      the 11 contract fields (covers the FK clause via
///      `PRAGMA foreign_key_list`).
///   4. `contract.attach` + `contract.advance` writers land chained
///      rows that verify cleanly through `ChainVerifier`.
@Suite("WorkstreamTaskContract (U.11a-1)")
struct WorkstreamTaskContractTests {

    // MARK: - Helpers

    private static func canonicalEncoder() -> JSONEncoder {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        return enc
    }

    private static func canonicalDecoder() -> JSONDecoder {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return dec
    }

    private static func tempDBPath() -> String {
        let dir = NSTemporaryDirectory() + "senkani-u11a1-tests/"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir + "contract-\(UUID().uuidString).db"
    }

    private static func uuidBytes(_ uuid: UUID) -> Data {
        withUnsafeBytes(of: uuid.uuid) { Data($0) }
    }

    private static func bytesToUUID(_ stmt: OpaquePointer, _ col: Int32) -> UUID? {
        guard let blob = sqlite3_column_blob(stmt, col) else { return nil }
        let n = Int(sqlite3_column_bytes(stmt, col))
        guard n == 16 else { return nil }
        var u = uuid_t(0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        withUnsafeMutableBytes(of: &u) { raw in
            raw.copyBytes(from: UnsafeRawBufferPointer(start: blob, count: 16))
        }
        return UUID(uuid: u)
    }

    private static func columnText(_ stmt: OpaquePointer, _ col: Int32) -> String? {
        guard let raw = sqlite3_column_text(stmt, col) else { return nil }
        return String(cString: raw)
    }

    private static func fixtures() -> [WorkstreamTaskContract] {
        // Three deterministic fixtures: one minimal (empty lists,
        // nil stale_spec_at), one full (every field populated), one
        // mid-sized (some lists populated, nil stale_spec_at) — same
        // contour as WorkstreamLifecycleTests' three fixtures.
        let wsA = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        let wsB = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
        let wsC = UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!

        let minimal = WorkstreamTaskContract(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            workstreamID: wsA,
            objective: "build:minimal",
            fileScope: [],
            allowedTools: [],
            dependencies: [],
            staleSpecAt: nil,
            budget: ContractBudget(tokensMax: 0, wallClockMaxS: 0),
            commands: [],
            acceptance: [],
            reviewLevel: .none
        )
        let full = WorkstreamTaskContract(
            id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            workstreamID: wsB,
            objective: "refactor:everything",
            fileScope: ["Sources/**/*.swift", "Tests/**/*.swift"],
            allowedTools: ["fs.read", "fs.write", "swift.test"],
            dependencies: [
                UUID(uuidString: "DEADBEEF-0000-0000-0000-000000000001")!,
                UUID(uuidString: "DEADBEEF-0000-0000-0000-000000000002")!,
            ],
            staleSpecAt: Date(timeIntervalSince1970: 1_720_000_000),
            budget: ContractBudget(tokensMax: 250_000, wallClockMaxS: 3600),
            commands: ["swift build", "swift test --filter MySuite"],
            acceptance: [
                UUID(uuidString: "BEEF0000-0000-0000-0000-000000000001")!,
                UUID(uuidString: "BEEF0000-0000-0000-0000-000000000002")!,
            ],
            reviewLevel: .operatorReview
        )
        let mid = WorkstreamTaskContract(
            id: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
            workstreamID: wsC,
            objective: "doc:rewrite",
            fileScope: ["docs/**/*.md"],
            allowedTools: ["fs.write"],
            dependencies: [],
            staleSpecAt: nil,
            budget: ContractBudget(tokensMax: 10_000, wallClockMaxS: 600),
            commands: ["echo done"],
            acceptance: [],
            reviewLevel: .selfReview
        )
        return [minimal, full, mid]
    }

    // MARK: - Tests

    @Test("Codable round-trip is byte-identical across three fixtures")
    func codableRoundTripByteIdentical() throws {
        let enc = Self.canonicalEncoder()
        let dec = Self.canonicalDecoder()
        for original in Self.fixtures() {
            let firstPass = try enc.encode(original)
            let decoded = try dec.decode(WorkstreamTaskContract.self, from: firstPass)
            #expect(decoded == original,
                    "round-trip equality failed for id=\(original.id)")
            let secondPass = try enc.encode(decoded)
            #expect(firstPass == secondPass,
                    "second encode must be byte-identical for id=\(original.id)")
        }
    }

    @Test("v39 migration creates workstream_contracts table + FK + index, ledger advances")
    func v39CreatesTableAndAdvancesLedger() throws {
        let path = Self.tempDBPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let session = SessionDatabase(path: path)
        defer { session.close() }

        var db: OpaquePointer?
        #expect(sqlite3_open(path, &db) == SQLITE_OK)
        defer { if let db = db { sqlite3_close(db) } }
        guard let db = db else { return }

        // Table + index exist
        func exists(_ kind: String, _ name: String) -> Bool {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(
                db,
                "SELECT 1 FROM sqlite_master WHERE type=? AND name=?;",
                -1, &stmt, nil
            ) == SQLITE_OK else { return false }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, (kind as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 2, (name as NSString).utf8String, -1, nil)
            return sqlite3_step(stmt) == SQLITE_ROW
        }
        #expect(exists("table", "workstream_contracts"))
        #expect(exists("index", "idx_workstream_contracts_workstream_id"))

        // FK clause is declared (verified via PRAGMA — SQLite returns
        // one row per FK column with the parent table + child column).
        var fkStmt: OpaquePointer?
        #expect(sqlite3_prepare_v2(
            db,
            "PRAGMA foreign_key_list('workstream_contracts');",
            -1, &fkStmt, nil
        ) == SQLITE_OK)
        defer { sqlite3_finalize(fkStmt) }
        var foundFK = false
        while sqlite3_step(fkStmt) == SQLITE_ROW {
            let parentTable = String(cString: sqlite3_column_text(fkStmt, 2))
            let fromColumn = String(cString: sqlite3_column_text(fkStmt, 3))
            let toColumn = String(cString: sqlite3_column_text(fkStmt, 4))
            if parentTable == "workstreams"
                && fromColumn == "workstream_id"
                && toColumn == "id" {
                foundFK = true
            }
        }
        #expect(foundFK,
                "expected workstream_id → workstreams(id) FK declaration")

        // Ledger row for v39 exists, with the expected description text.
        var stmt: OpaquePointer?
        #expect(sqlite3_prepare_v2(
            db,
            "SELECT COUNT(*), MAX(description) FROM schema_migrations WHERE version = 39;",
            -1, &stmt, nil
        ) == SQLITE_OK)
        defer { sqlite3_finalize(stmt) }
        #expect(sqlite3_step(stmt) == SQLITE_ROW)
        let count = Int(sqlite3_column_int(stmt, 0))
        let desc = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
        #expect(count == 1, "expected exactly one v39 ledger row, got \(count)")
        #expect(desc.contains("workstream_contracts"),
                "v39 description should reference 'workstream_contracts', got '\(desc)'")
    }

    @Test("workstream_contracts persist → query-back is field-by-field equal")
    func workstreamContractsRoundTripSQL() throws {
        let path = Self.tempDBPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let session = SessionDatabase(path: path)
        defer { session.close() }

        var db: OpaquePointer?
        #expect(sqlite3_open(path, &db) == SQLITE_OK)
        defer { if let db = db { sqlite3_close(db) } }
        guard let db = db else { return }

        let enc = Self.canonicalEncoder()
        let dec = Self.canonicalDecoder()

        // Seed parent workstream rows so the (declarative) FK references
        // resolve. Even with `PRAGMA foreign_keys = OFF` we plant them so
        // a future enable doesn't break this test in isolation.
        let workstreamSeed: [(UUID, String)] = [
            (UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!, "ws-a"),
            (UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!, "ws-b"),
            (UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!, "ws-c"),
        ]
        for (wsID, slug) in workstreamSeed {
            var ins: OpaquePointer?
            let sql = "INSERT INTO workstreams (id, slug, state, created_at) VALUES (?, ?, ?, ?);"
            #expect(sqlite3_prepare_v2(db, sql, -1, &ins, nil) == SQLITE_OK)
            defer { sqlite3_finalize(ins) }
            var bytes = Self.uuidBytes(wsID)
            bytes.withUnsafeBytes { raw in
                _ = sqlite3_bind_blob(ins, 1, raw.baseAddress, Int32(raw.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            }
            _ = sqlite3_bind_text(ins, 2, (slug as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            _ = sqlite3_bind_text(ins, 3, ("staged" as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            _ = sqlite3_bind_int64(ins, 4, 1_700_000_000)
            #expect(sqlite3_step(ins) == SQLITE_DONE)
        }

        let fixtures = Self.fixtures()
        // Insert each contract by encoding list-typed + budget fields
        // to JSON TEXT columns; primitives bound directly.
        for c in fixtures {
            let insertSQL = """
                INSERT INTO workstream_contracts
                (id, workstream_id, objective, file_scope, allowed_tools, dependencies,
                 stale_spec_at, budget, commands, acceptance, review_level)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """
            var ins: OpaquePointer?
            #expect(sqlite3_prepare_v2(db, insertSQL, -1, &ins, nil) == SQLITE_OK)
            defer { sqlite3_finalize(ins) }
            var idBytes = Self.uuidBytes(c.id)
            idBytes.withUnsafeBytes { raw in
                _ = sqlite3_bind_blob(ins, 1, raw.baseAddress, Int32(raw.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            }
            var wsBytes = Self.uuidBytes(c.workstreamID)
            wsBytes.withUnsafeBytes { raw in
                _ = sqlite3_bind_blob(ins, 2, raw.baseAddress, Int32(raw.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            }
            let fileScopeJSON = String(data: try enc.encode(c.fileScope), encoding: .utf8)!
            let allowedToolsJSON = String(data: try enc.encode(c.allowedTools), encoding: .utf8)!
            let dependenciesJSON = String(data: try enc.encode(c.dependencies), encoding: .utf8)!
            let budgetJSON = String(data: try enc.encode(c.budget), encoding: .utf8)!
            let commandsJSON = String(data: try enc.encode(c.commands), encoding: .utf8)!
            let acceptanceJSON = String(data: try enc.encode(c.acceptance), encoding: .utf8)!
            _ = sqlite3_bind_text(ins, 3, (c.objective as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            _ = sqlite3_bind_text(ins, 4, (fileScopeJSON as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            _ = sqlite3_bind_text(ins, 5, (allowedToolsJSON as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            _ = sqlite3_bind_text(ins, 6, (dependenciesJSON as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            if let stale = c.staleSpecAt {
                _ = sqlite3_bind_double(ins, 7, stale.timeIntervalSince1970)
            } else {
                _ = sqlite3_bind_null(ins, 7)
            }
            _ = sqlite3_bind_text(ins, 8, (budgetJSON as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            _ = sqlite3_bind_text(ins, 9, (commandsJSON as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            _ = sqlite3_bind_text(ins, 10, (acceptanceJSON as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            _ = sqlite3_bind_text(ins, 11, (c.reviewLevel.rawValue as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            #expect(sqlite3_step(ins) == SQLITE_DONE,
                    "insert failed for id=\(c.id): \(String(cString: sqlite3_errmsg(db)))")
        }

        // Read each contract back; rebuild via JSON decode + raw column
        // binds; field-by-field equality.
        for c in fixtures {
            let selectSQL = """
                SELECT workstream_id, objective, file_scope, allowed_tools, dependencies,
                       stale_spec_at, budget, commands, acceptance, review_level
                  FROM workstream_contracts
                 WHERE id = ?;
            """
            var selPtr: OpaquePointer?
            #expect(sqlite3_prepare_v2(db, selectSQL, -1, &selPtr, nil) == SQLITE_OK)
            defer { sqlite3_finalize(selPtr) }
            guard let sel = selPtr else {
                Issue.record("prepare returned NULL statement for id=\(c.id)")
                continue
            }
            var idBytes = Self.uuidBytes(c.id)
            idBytes.withUnsafeBytes { raw in
                _ = sqlite3_bind_blob(sel, 1, raw.baseAddress, Int32(raw.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            }
            #expect(sqlite3_step(sel) == SQLITE_ROW, "row missing for id=\(c.id)")

            guard let wsBack = Self.bytesToUUID(sel, 0) else {
                Issue.record("workstream_id blob unreadable")
                continue
            }
            let objective = Self.columnText(sel, 1) ?? ""
            let fileScopeJSON = Self.columnText(sel, 2) ?? ""
            let allowedToolsJSON = Self.columnText(sel, 3) ?? ""
            let dependenciesJSON = Self.columnText(sel, 4) ?? ""
            let staleSpec: Date? = sqlite3_column_type(sel, 5) == SQLITE_NULL
                ? nil : Date(timeIntervalSince1970: sqlite3_column_double(sel, 5))
            let budgetJSON = Self.columnText(sel, 6) ?? ""
            let commandsJSON = Self.columnText(sel, 7) ?? ""
            let acceptanceJSON = Self.columnText(sel, 8) ?? ""
            let reviewLevelRaw = Self.columnText(sel, 9) ?? ""

            let fileScope = try dec.decode([String].self, from: Data(fileScopeJSON.utf8))
            let allowedTools = try dec.decode([String].self, from: Data(allowedToolsJSON.utf8))
            let dependencies = try dec.decode([UUID].self, from: Data(dependenciesJSON.utf8))
            let budget = try dec.decode(ContractBudget.self, from: Data(budgetJSON.utf8))
            let commands = try dec.decode([String].self, from: Data(commandsJSON.utf8))
            let acceptance = try dec.decode([UUID].self, from: Data(acceptanceJSON.utf8))
            let reviewLevel = ReviewLevel(rawValue: reviewLevelRaw)!

            let rebuilt = WorkstreamTaskContract(
                id: c.id,
                workstreamID: wsBack,
                objective: objective,
                fileScope: fileScope,
                allowedTools: allowedTools,
                dependencies: dependencies,
                staleSpecAt: staleSpec,
                budget: budget,
                commands: commands,
                acceptance: acceptance,
                reviewLevel: reviewLevel
            )
            #expect(rebuilt == c,
                    "rebuilt contract did not match original for id=\(c.id)")
        }
    }

    @Test("contract.attach + contract.advance writers land chained rows; ChainVerifier passes")
    func contractEventWritersChainCleanly() throws {
        let path = "/tmp/senkani-u11a1-contract-events-\(UUID().uuidString).sqlite"
        let db = SessionDatabase(path: path)
        defer { TempSessionDatabase.close(db, path: path) }

        let contractID = UUID()
        let workstreamID = UUID()

        db.recordContractEvent(
            contractID: contractID,
            workstreamID: workstreamID,
            event: .attach)
        db.recordContractEvent(
            contractID: contractID,
            workstreamID: workstreamID,
            event: .advance)
        db.recordContractEvent(
            contractID: contractID,
            workstreamID: workstreamID,
            event: .advance)

        // Flush the writer queue.
        _ = db.tokenEventExists(source: "u11a1-flush", feature: "noop")

        // Count + order check
        var rows: [(source: String, tool: String, feature: String)] = []
        db.unsafeQueueSync { rawDB in
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(
                rawDB,
                """
                SELECT source, tool_name, feature
                  FROM token_events
                 WHERE source LIKE 'contract.%'
                 ORDER BY id ASC;
                """,
                -1, &stmt, nil
            ) == SQLITE_OK else {
                Issue.record("source listing prepare failed")
                return
            }
            defer { sqlite3_finalize(stmt) }
            while sqlite3_step(stmt) == SQLITE_ROW {
                let src = String(cString: sqlite3_column_text(stmt, 0))
                let tool = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
                let feat = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? ""
                rows.append((src, tool, feat))
            }
        }
        #expect(rows.count == 3, "expected 3 contract.* rows; got \(rows.count)")
        #expect(rows.map { $0.source } == ["contract.attach", "contract.advance", "contract.advance"])
        let contractStr = contractID.uuidString
        let workstreamStr = workstreamID.uuidString
        for row in rows {
            #expect(row.tool == contractStr,
                    "tool_name must hold contract UUID; got '\(row.tool)'")
            #expect(row.feature == workstreamStr,
                    "feature must hold workstream UUID; got '\(row.feature)'")
        }

        // Chain integrity holds end to end.
        let result = ChainVerifier.verifyTokenEvents(db)
        switch result {
        case .ok:
            break
        default:
            Issue.record("expected .ok after contract.attach/advance writes; got \(result)")
        }
    }
}
