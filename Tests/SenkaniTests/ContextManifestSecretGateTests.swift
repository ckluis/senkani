import Testing
import Foundation
import SQLite3
@testable import Core
@testable import Indexer
@testable import Bundle

// U.10a-2 — ContextManifest secret gate tests.
// Four behavioral checks:
//   1. Refusal: a manifest with a flagged item throws when no override.
//   2. Override + audit row: allowSecrets:true returns the manifest
//      AND fires a chained bundle.secret.allow row in token_events.
//   3. Dispatch row on every call: gated calls fire bundle.dispatch.
//   4. Chain integrity across 100 override rows: ChainVerifier.verifyTokenEvents
//      returns .ok after the 100 chained writes.

private let fixedDate = Date(timeIntervalSince1970: 1_713_360_000)

// `sk-ant-` followed by ≥20 url-safe chars hits the ANTHROPIC_API_KEY
// pattern in SecretDetector. We embed the marker inside a normal-
// looking README so the fixture mimics a realistic prompt-injected
// repo body without the test file itself carrying a real key.
private let secretMarker = "sk-ant-AAAAAAAAAAAAAAAAAAAAAAAA"
private let secretReadme = "# Repo\n\nNote to future devs: token = \(secretMarker)\n"

private func makeIndex() -> SymbolIndex {
    var idx = SymbolIndex()
    idx.projectRoot = "/tmp/u10a2-fixture"
    idx.generated = fixedDate
    idx.symbols = [
        IndexEntry(name: "Foo", kind: .class, file: "Sources/Foo.swift", startLine: 10),
    ]
    return idx
}

private func makeInputs(readme: String) -> BundleInputs {
    BundleInputs(
        index: makeIndex(),
        graph: nil,
        entities: [],
        readme: readme
    )
}

private func makeOptions(toolId: String? = nil) -> ManifestOptions {
    ManifestOptions(
        projectRoot: "/tmp/u10a2-fixture",
        modes: ContextMode.trivial,
        lanes: Set(ContextLane.allCases),
        now: fixedDate,
        toolId: toolId
    )
}

private func makeTempDB() -> (SessionDatabase, String) {
    let path = "/tmp/senkani-u10a2-test-\(UUID().uuidString).sqlite"
    return (SessionDatabase(path: path), path)
}

private func cleanupDB(_ path: String) {
    let fm = FileManager.default
    try? fm.removeItem(atPath: path)
    try? fm.removeItem(atPath: path + "-shm")
    try? fm.removeItem(atPath: path + "-wal")
}

// MARK: - 1. Refusal without override

@Suite("U.10a-2 secret gate refusal")
struct SecretGateRefusalTests {

    @Test("Flagged item without --allow-secrets throws ManifestSecretGateError")
    func refusalWithoutOverride() throws {
        let (db, path) = makeTempDB()
        defer { cleanupDB(path) }
        let recorder = DatabaseBundleAuditRecorder(database: db)
        let inputs = makeInputs(readme: secretReadme)

        // Sanity: the producer should flag the README item.
        let manifest = BundleComposer.composeManifest(
            options: makeOptions(), inputs: inputs)
        let flaggedFile = manifest.items.first { $0.lane == .file }
        #expect(flaggedFile?.sensitivity == .flagged,
                "README carrying sk-ant-… must surface as flagged")

        // Gate refuses.
        do {
            _ = try BundleComposer.composeManifestGated(
                options: makeOptions(),
                inputs: inputs,
                allowSecrets: false,
                preview: true,
                recorder: recorder,
                sessionId: "sid-refusal",
                projectRoot: "/tmp/u10a2-fixture"
            )
            Issue.record("expected ManifestSecretGateError on flagged item without override")
        } catch let e as ManifestSecretGateError {
            #expect(e.itemCount >= 1)
            #expect(e.lanesWithHits.contains("file"))
            // Description does NOT leak the secret content — only lane
            // name + count.
            #expect(!e.description.contains(secretMarker),
                    "refusal description must not echo the secret content")
        } catch {
            Issue.record("expected ManifestSecretGateError, got \(error)")
        }

        // Crucial invariant: no audit row fired on refusal. The
        // dispatch row is the "what was sent" trail and nothing was
        // sent.
        let rows = db.recentTokenEvents(
            projectRoot: "/tmp/u10a2-fixture", limit: 50)
        #expect(rows.filter { $0.feature == "bundle.dispatch" }.isEmpty,
                "refusal must not fire a bundle.dispatch row")
        #expect(rows.filter { $0.feature == "bundle.secret.allow" }.isEmpty,
                "refusal must not fire a bundle.secret.allow row")
    }
}

// MARK: - 2. Success with override + audit row

@Suite("U.10a-2 secret gate override")
struct SecretGateOverrideTests {

    @Test("allowSecrets:true returns the manifest and fires bundle.secret.allow")
    func successWithOverrideAndAuditRow() throws {
        let (db, path) = makeTempDB()
        defer { cleanupDB(path) }
        let recorder = DatabaseBundleAuditRecorder(database: db)
        let inputs = makeInputs(readme: secretReadme)

        let manifest = try BundleComposer.composeManifestGated(
            options: makeOptions(toolId: "test-tool"),
            inputs: inputs,
            allowSecrets: true,
            preview: true,
            recorder: recorder,
            sessionId: "sid-override",
            projectRoot: "/tmp/u10a2-fixture"
        )
        #expect(manifest.items.contains { $0.sensitivity == .flagged },
                "override path must still surface the flagged sensitivity")

        // queue.sync inside recentTokenEvents drains the recorder's writes.
        let rows = db.recentTokenEvents(
            projectRoot: "/tmp/u10a2-fixture", limit: 50)
        let allowRows = rows.filter { $0.feature == "bundle.secret.allow" }
        #expect(allowRows.count == 1, "expected exactly one bundle.secret.allow row")

        guard let row = allowRows.first else { return }
        #expect(row.source == "audit")
        #expect(row.toolName == "test-tool")
        let cmd = row.command ?? ""
        #expect(cmd.contains("\"item_count\""), "payload must record item_count")
        #expect(cmd.contains("\"lanes_with_hits\""), "payload must record lanes_with_hits")
        #expect(cmd.contains("\"file\""), "lane name 'file' must appear in the payload")
        // Payload never carries the secret content itself.
        #expect(!cmd.contains(secretMarker),
                "bundle.secret.allow payload must not echo secret content")
    }
}

// MARK: - 3. Dispatch row on every call

@Suite("U.10a-2 bundle.dispatch row")
struct BundleDispatchRowTests {

    @Test("Every gated call fires bundle.dispatch with per-lane + per-mode counts")
    func dispatchRowOnEveryCall() throws {
        let (db, path) = makeTempDB()
        defer { cleanupDB(path) }
        let recorder = DatabaseBundleAuditRecorder(database: db)
        // Clean readme — no flagged items, no override needed — proves
        // bundle.dispatch fires on the happy path too.
        let inputs = makeInputs(readme: "# Hello\n\nplain readme.\n")

        for _ in 0..<3 {
            _ = try BundleComposer.composeManifestGated(
                options: makeOptions(toolId: "test-tool"),
                inputs: inputs,
                allowSecrets: false,
                preview: true,
                recorder: recorder,
                sessionId: "sid-dispatch",
                projectRoot: "/tmp/u10a2-fixture"
            )
        }

        let rows = db.recentTokenEvents(
            projectRoot: "/tmp/u10a2-fixture", limit: 50)
        let dispatchRows = rows.filter { $0.feature == "bundle.dispatch" }
        #expect(dispatchRows.count == 3, "expected one bundle.dispatch row per call")

        guard let row = dispatchRows.first else { return }
        #expect(row.source == "audit")
        #expect(row.toolName == "test-tool")
        let cmd = row.command ?? ""
        #expect(cmd.contains("\"per_lane\""))
        #expect(cmd.contains("\"per_mode\""))
        #expect(cmd.contains("\"tokens_estimated_total\""))
        #expect(cmd.contains("\"preview\""))

        // No secret-allow rows on the clean path.
        let allowRows = rows.filter { $0.feature == "bundle.secret.allow" }
        #expect(allowRows.isEmpty,
                "clean inputs must not fire bundle.secret.allow")
    }
}

// MARK: - 4. Chain integrity across 100 override rows

@Suite("U.10a-2 chain integrity")
struct SecretGateChainIntegrityTests {

    @Test("ChainVerifier.verifyTokenEvents passes after 100 chained override rows")
    func chainIntegrityAcross100Rows() throws {
        let (db, path) = makeTempDB()
        defer { cleanupDB(path) }
        let recorder = DatabaseBundleAuditRecorder(database: db)
        let inputs = makeInputs(readme: secretReadme)

        for _ in 0..<100 {
            _ = try BundleComposer.composeManifestGated(
                options: makeOptions(toolId: "chain-test"),
                inputs: inputs,
                allowSecrets: true,
                preview: true,
                recorder: recorder,
                sessionId: "sid-chain",
                projectRoot: "/tmp/u10a2-fixture"
            )
        }

        // Drain the recorder writes — queue.sync on the chain verifier
        // serializes after every pending recordTokenEvent.
        let result = ChainVerifier.verifyTokenEvents(db)
        switch result {
        case .ok:
            // The 100 override calls produced ≥200 chained rows (one
            // secret.allow + one dispatch per call). All hash-linked.
            let rows = db.recentTokenEvents(
                projectRoot: "/tmp/u10a2-fixture", limit: 500)
            let allowCount = rows.filter { $0.feature == "bundle.secret.allow" }.count
            let dispatchCount = rows.filter { $0.feature == "bundle.dispatch" }.count
            #expect(allowCount == 100,
                    "expected 100 bundle.secret.allow rows, got \(allowCount)")
            #expect(dispatchCount == 100,
                    "expected 100 bundle.dispatch rows, got \(dispatchCount)")
        case .brokenAt(let table, let rowid, let expected, let actual):
            Issue.record("chain broken at \(table)#\(rowid): expected \(expected), actual \(actual)")
        case .noChain:
            Issue.record("expected a chain to have been built across 100 writes")
        }
    }
}
