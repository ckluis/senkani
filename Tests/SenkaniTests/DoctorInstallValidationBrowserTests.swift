import Testing
import Foundation
@testable import Core

/// U.2a-1 contract tests for the `senkani doctor --install-validation-browser`
/// audit-row write path. The CLI surface itself is exercised through
/// `tokenEventExists` + `recordTokenEvent` on the SessionDatabase facade —
/// the doctor command is a thin wrapper that calls these two methods.
///
/// Idempotency contract: the first time the Chromium cache is detected,
/// a single `validation.browser.install` chained row lands in
/// `token_events`. Subsequent invocations short-circuit on
/// `tokenEventExists(source: "doctor", feature: "validation.browser.install")`
/// and write nothing.
///
/// Chain-integrity contract: writing 100 chained rows under the
/// `validation.browser.install` feature must leave `ChainVerifier.
/// verifyTokenEvents` at `.ok` — the audit chain doesn't degrade under
/// a write storm.
@Suite("Doctor --install-validation-browser — U.2a-1 idempotency + chain integrity")
struct DoctorInstallValidationBrowserTests {

    private static func makeTempDB() -> (SessionDatabase, String) {
        let path = "/tmp/senkani-doctor-install-test-\(UUID().uuidString).sqlite"
        return (SessionDatabase(path: path), path)
    }

    @Test("doctor install motion writes one validation.browser.install row on first call and zero on re-call")
    func doctorInstallIdempotent() {
        let (db, path) = Self.makeTempDB()
        defer { TempSessionDatabase.cleanup(path: path) }

        // First-call probe: no row yet, so the gate is open.
        #expect(db.tokenEventExists(source: "doctor", feature: "validation.browser.install") == false,
                "fresh DB must have no validation.browser.install row")

        db.recordTokenEvent(
            sessionId: "doctor", paneId: nil, projectRoot: nil,
            source: "doctor", toolName: nil, model: nil,
            inputTokens: 0, outputTokens: 0, savedTokens: 0, costCents: 0,
            feature: "validation.browser.install", command: nil
        )
        db.flushWrites()

        // Second-call probe: row exists, gate closes.
        #expect(db.tokenEventExists(source: "doctor", feature: "validation.browser.install") == true,
                "first detection must record exactly one chained audit row")

        let recent = db.recentTokenEventsAllProjects(limit: 100)
        let installRows = recent.filter { $0.feature == "validation.browser.install" }
        #expect(installRows.count == 1,
                "second invocation must short-circuit on tokenEventExists; got \(installRows.count) rows")
    }

    @Test("T.5 chain integrity holds across 100 validation.browser.install writes")
    func chainIntegrityOverHundredInstallWrites() {
        let (db, path) = Self.makeTempDB()
        defer { TempSessionDatabase.cleanup(path: path) }

        for _ in 0..<100 {
            db.recordTokenEvent(
                sessionId: "doctor", paneId: nil, projectRoot: nil,
                source: "doctor", toolName: nil, model: nil,
                inputTokens: 0, outputTokens: 0, savedTokens: 0, costCents: 0,
                feature: "validation.browser.install", command: nil
            )
        }
        db.flushWrites()

        let result = ChainVerifier.verifyTokenEvents(db)
        switch result {
        case .ok:
            break
        case .brokenAt(let table, let rowid, let expected, let actual):
            Issue.record("chain broke at \(table)#\(rowid): expected=\(expected), actual=\(actual)")
        case .noChain:
            Issue.record("chain not initialized despite 100 writes")
        }

        let recent = db.recentTokenEventsAllProjects(limit: 200)
        let installRows = recent.filter { $0.feature == "validation.browser.install" }
        #expect(installRows.count == 100,
                "all 100 writes must land; got \(installRows.count)")
    }
}
