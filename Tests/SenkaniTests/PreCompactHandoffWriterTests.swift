import Testing
import Foundation
@testable import Core

@Suite("PreCompactHandoffWriter — W.4 handoff card I/O")
struct PreCompactHandoffWriterTests {

    private func tempRoot() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("senkani-handoff-\(UUID().uuidString)", isDirectory: true)
    }

    private func tempDB() -> (SessionDatabase, String) {
        let path = "/tmp/senkani-handoff-db-\(UUID().uuidString).sqlite"
        return (SessionDatabase(path: path), path)
    }

    private func cleanup(db path: String) {
        try? FileManager.default.removeItem(atPath: path)
        try? FileManager.default.removeItem(atPath: path + "-wal")
        try? FileManager.default.removeItem(atPath: path + "-shm")
    }

    private func cleanup(root: URL) {
        try? FileManager.default.removeItem(at: root)
    }

    @Test("HandoffCard round-trips through Codable with all fields")
    func cardCodableRoundTrip() throws {
        let card = HandoffCard(
            sessionId: "sess-1",
            savedAt: Date(timeIntervalSince1970: 1_700_000_000),
            contextPercent: 0.72,
            openFiles: ["Sources/Core/Foo.swift", "Tests/Bar.swift"],
            currentIntent: "wire up the saturation gate",
            lastValidation: .init(outcome: "advisory", filePath: "Foo.swift", advisory: "shadowed variable"),
            nextActionHint: "rerun swift test --filter ContextSaturation",
            recentTraceKeys: ["k1", "k2", "k3"]
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(card)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let back = try decoder.decode(HandoffCard.self, from: data)

        #expect(back == card)
    }

    @Test("write lands a JSON file under <root>/<sessionId>.json")
    func writeLandsFile() throws {
        let root = tempRoot()
        defer { cleanup(root: root) }

        let card = HandoffCard(
            sessionId: "sess-write",
            savedAt: Date(),
            currentIntent: "land the writer"
        )
        let dest = try PreCompactHandoffWriter.write(card, rootDir: root)
        #expect(FileManager.default.fileExists(atPath: dest.path))
        #expect(dest.lastPathComponent == "sess-write.json")
        let bytes = try Data(contentsOf: dest)
        let decoded = try JSONDecoder.iso().decode(HandoffCard.self, from: bytes)
        #expect(decoded.currentIntent == "land the writer")
    }

    @Test("write replaces an existing card atomically (no half-file leak)")
    func writeOverwritesAtomically() throws {
        let root = tempRoot()
        defer { cleanup(root: root) }

        let v1 = HandoffCard(sessionId: "sess-overwrite", savedAt: Date(), currentIntent: "v1")
        try PreCompactHandoffWriter.write(v1, rootDir: root)

        let v2 = HandoffCard(sessionId: "sess-overwrite", savedAt: Date(), currentIntent: "v2")
        try PreCompactHandoffWriter.write(v2, rootDir: root)

        let entries = try FileManager.default.contentsOfDirectory(atPath: root.path)
        let cards = entries.filter { $0.hasSuffix(".json") }
        let leftovers = entries.filter { $0.hasSuffix(".tmp") }
        #expect(cards.count == 1)
        #expect(leftovers.isEmpty, "leftovers: \(leftovers)")

        let loaded = PreCompactHandoffLoader.load(sessionId: "sess-overwrite", rootDir: root)
        #expect(loaded?.currentIntent == "v2")
    }

    @Test("write completes well under the 1 s SLO")
    func writeSLO() throws {
        let root = tempRoot()
        defer { cleanup(root: root) }

        let card = HandoffCard(
            sessionId: "sess-slo",
            savedAt: Date(),
            contextPercent: 0.81,
            openFiles: Array(repeating: "Sources/Core/Foo.swift", count: 50),
            currentIntent: "stress the writer",
            lastValidation: .init(outcome: "advisory", filePath: "Foo.swift", advisory: String(repeating: "x", count: 4_000)),
            nextActionHint: "ship",
            recentTraceKeys: (0..<10).map { "k\($0)" }
        )
        let start = Date()
        try PreCompactHandoffWriter.write(card, rootDir: root)
        let elapsed = Date().timeIntervalSince(start)
        #expect(elapsed < 1.0, "write took \(elapsed) s — SLO is <1s")
    }

    @Test("compose pulls recent trace keys + last validation from SessionDatabase")
    func composeReadsFromDB() {
        let (db, path) = tempDB()
        defer { cleanup(db: path) }

        // Seed two trace rows for pane=kb (newest first ordering).
        db.recordAgentTraceEvent(.init(
            idempotencyKey: "old", pane: "kb", project: "/p", model: "m",
            tier: nil, feature: "f", result: "success",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            completedAt: Date(timeIntervalSince1970: 1_700_000_001),
            latencyMs: 1, tokensIn: 10, tokensOut: 10
        ))
        db.recordAgentTraceEvent(.init(
            idempotencyKey: "new", pane: "kb", project: "/p", model: "m",
            tier: nil, feature: "f", result: "success",
            startedAt: Date(timeIntervalSince1970: 1_700_001_000),
            completedAt: Date(timeIntervalSince1970: 1_700_001_001),
            latencyMs: 1, tokensIn: 10, tokensOut: 10
        ))

        // Seed one validation row for the session.
        db.insertValidationResult(
            sessionId: "sess-compose",
            filePath: "Sources/Foo.swift",
            validatorName: "swift-format",
            category: "syntax",
            exitCode: 1,
            rawOutput: nil,
            advisory: "trailing whitespace",
            durationMs: 5,
            outcome: "advisory",
            reason: nil
        )

        let card = PreCompactHandoffWriter.compose(
            database: db,
            sessionId: "sess-compose",
            currentIntent: "audit chain wiring",
            openFiles: ["Sources/Core/ChainHasher.swift"],
            nextActionHint: "swift test --filter ChainHasher",
            contextPercent: 0.42,
            pane: "kb",
            project: "/p"
        )

        #expect(card.sessionId == "sess-compose")
        #expect(card.currentIntent == "audit chain wiring")
        #expect(card.openFiles == ["Sources/Core/ChainHasher.swift"])
        #expect(card.nextActionHint == "swift test --filter ChainHasher")
        #expect(card.contextPercent == 0.42)
        #expect(card.recentTraceKeys.first == "new", "newest key first; got \(card.recentTraceKeys)")
        #expect(card.recentTraceKeys.contains("old"))
        #expect(card.lastValidation?.outcome == "advisory")
        #expect(card.lastValidation?.filePath == "Sources/Foo.swift")
        #expect(card.lastValidation?.advisory == "trailing whitespace")
    }

    @Test("loader returns nil when the card file is missing")
    func loadMissingReturnsNil() {
        let root = tempRoot()
        defer { cleanup(root: root) }
        #expect(PreCompactHandoffLoader.load(sessionId: "nope", rootDir: root) == nil)
    }

    @Test("loader returns nil on corrupt JSON rather than crashing")
    func loadCorruptReturnsNil() throws {
        let root = tempRoot()
        defer { cleanup(root: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = PreCompactHandoffWriter.cardURL(sessionId: "broken", rootDir: root)
        try Data("not json{".utf8).write(to: url)
        #expect(PreCompactHandoffLoader.load(sessionId: "broken", rootDir: root) == nil)
    }

    @Test("loader returns nil for cards written under an unknown schema version")
    func loadFutureSchemaReturnsNil() throws {
        let root = tempRoot()
        defer { cleanup(root: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let future = HandoffCard(
            schemaVersion: 99,
            sessionId: "future",
            savedAt: Date(),
            currentIntent: "from the future"
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(future)
        let url = PreCompactHandoffWriter.cardURL(sessionId: "future", rootDir: root)
        try data.write(to: url)

        #expect(PreCompactHandoffLoader.load(sessionId: "future", rootDir: root) == nil)
    }

    @Test("loadLatest picks the most-recently-written card under the root dir")
    func loadLatestPicksNewest() throws {
        let root = tempRoot()
        defer { cleanup(root: root) }

        try PreCompactHandoffWriter.write(.init(
            sessionId: "sess-old", savedAt: Date(timeIntervalSince1970: 1_700_000_000),
            currentIntent: "old"
        ), rootDir: root)

        // Sleep briefly so the mtime ordering is deterministic.
        Thread.sleep(forTimeInterval: 0.05)
        try PreCompactHandoffWriter.write(.init(
            sessionId: "sess-new", savedAt: Date(),
            currentIntent: "new"
        ), rootDir: root)

        let latest = PreCompactHandoffLoader.loadLatest(rootDir: root)
        #expect(latest?.sessionId == "sess-new")
        #expect(latest?.currentIntent == "new")
    }
}

private extension JSONDecoder {
    static func iso() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
