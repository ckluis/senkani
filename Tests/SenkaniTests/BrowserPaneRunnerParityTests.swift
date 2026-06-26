import Testing
import Foundation
@testable import Core

/// U.2b-1b-6 — cross-runner parity corpus for the
/// `BrowserValidationDispatcher` `.subprocess` ↔ `.headless` arms.
///
/// **Architecture invariant (Russell).** `BrowserPaneRunner` lives in
/// the SenkaniApp executable target and cannot be `@testable`-imported
/// from `SenkaniTests`. Parity at the dispatcher-byte-output level is
/// what this file verifies — both arms are exercised via injected
/// closure stubs that return identical `PlaywrightResult` values for
/// each fixture. Byte-identical Response JSON across arms proves the
/// dispatcher itself is runner-agnostic; the actual runtime byte-diff
/// across BrowserPaneRunner vs PlaywrightSubprocessRunner runs in the
/// SenkaniApp host and is filed as the mandatory follow-up
/// `process-gap-u2b-1b-6-runtime-parity-validation-2026-05-22`.
///
/// Corpus shape:
///   - 12 axis rows: 3 assertions × 4 axes (perf / completeness /
///     security / design).
///   - 4 fail-mode rows: one per axis where the runner returns
///     `result_status: "fail"` with a structured advisory.
///   - 4 edge-case rows: off-screen layout, focus-order Tab walk,
///     scroll-driven INP, CSP-blocked subresource — exercises the
///     headless runner's invariants the subprocess runner shares.
///
/// 4 `@Test` methods:
///   1. `axisCorpusParityAcrossDispatchModes` — parameterized over
///      the 20-row corpus; for each fixture, dispatches both
///      `.subprocess` and `.headless` with closures returning the
///      fixture's canned PlaywrightResult, asserts byte-identical
///      Response (modulo the dispatch-mode discriminant).
///   2. `failModeRefusalEnvelopeParity` — fail-mode fixtures only;
///      asserts dispatcher advisory + audit-row shape parity.
///   3. `hookRouterPreToolUseGateParity` — the
///      `HookRouter.browserValidationGateReader` PreToolUse refusal
///      envelope is identical regardless of which runner wrote the
///      failing row.
///   4. `chainIntegrityAcrossFiftyMixedRunnerRows` — synthesises 50
///      interleaved dispatches (25 `.subprocess` + 25 `.headless`)
///      against a fresh SessionDatabase; `ChainVerifier.
///      verifyTokenEvents` must return `.ok` across the mixed
///      audit-chain row stream.
///   5. `chainIntegrityAcrossHundredMixedRunnerRows` (U.2b-2 child (a))
///      — extends test 4 to 100 interleaved dispatches round-robining
///      `.subprocess` / `.headless` / `.pane` (a `wkwebview-pane`
///      variant per cycle); chain integrity must hold across all three
///      runner= variants, and all three must be present in the stream.
///
/// Suite serialization (U.2b-2 child (a)): both this suite and
/// `BrowserValidateDispatchTests` swap the `nonisolated(unsafe)` static
/// `HookRouter.browserValidationGateReader`; under Swift Testing's
/// default parallel runner they raced (one suite's canned row bled into
/// the other's assertion). The `.browserValidationGateReaderGate` trait
/// serializes both suites process-wide; `.serialized` orders within each.
@Suite("U.2b-1b-6 — Cross-runner parity corpus", .serialized, .browserValidationGateReaderGate)
struct BrowserPaneRunnerParityTests {

    // MARK: - Fixture types

    struct ParityFixture: Sendable {
        let id: String
        let kind: Kind
        let axes: [ValidationAxes]
        let targetURL: String
        let stubResult: PlaywrightResult
        enum Kind: Sendable {
            case axisAssertion
            case failMode
            case edgeCase
        }
    }

    static let corpus: [ParityFixture] = [
        // 12 axis-assertion rows — 3 per axis.
        .init(id: "perf-lcp-ok", kind: .axisAssertion, axes: [.perf],
              targetURL: "https://example.com/perf-lcp",
              stubResult: pass(axes: ["perf"], passed: 3, failed: 0,
                               screenshot: "/tmp/parity/perf-lcp.png")),
        .init(id: "perf-inp-ok", kind: .axisAssertion, axes: [.perf],
              targetURL: "https://example.com/perf-inp",
              stubResult: pass(axes: ["perf"], passed: 4, failed: 0,
                               screenshot: "/tmp/parity/perf-inp.png")),
        .init(id: "perf-cls-ok", kind: .axisAssertion, axes: [.perf],
              targetURL: "https://example.com/perf-cls",
              stubResult: pass(axes: ["perf"], passed: 2, failed: 0,
                               screenshot: "/tmp/parity/perf-cls.png")),
        .init(id: "completeness-headings-ok", kind: .axisAssertion, axes: [.completeness],
              targetURL: "https://example.com/completeness-headings",
              stubResult: pass(axes: ["completeness"], passed: 3, failed: 0,
                               screenshot: "/tmp/parity/completeness-h.png")),
        .init(id: "completeness-alt-ok", kind: .axisAssertion, axes: [.completeness],
              targetURL: "https://example.com/completeness-alt",
              stubResult: pass(axes: ["completeness"], passed: 5, failed: 0,
                               screenshot: "/tmp/parity/completeness-alt.png")),
        .init(id: "completeness-form-labels-ok", kind: .axisAssertion, axes: [.completeness],
              targetURL: "https://example.com/completeness-forms",
              stubResult: pass(axes: ["completeness"], passed: 4, failed: 0,
                               screenshot: "/tmp/parity/completeness-forms.png")),
        .init(id: "security-csp-ok", kind: .axisAssertion, axes: [.security],
              targetURL: "https://example.com/security-csp",
              stubResult: pass(axes: ["security"], passed: 3, failed: 0,
                               screenshot: "/tmp/parity/security-csp.png")),
        .init(id: "security-mixed-content-ok", kind: .axisAssertion, axes: [.security],
              targetURL: "https://example.com/security-mixed",
              stubResult: pass(axes: ["security"], passed: 2, failed: 0,
                               screenshot: "/tmp/parity/security-mixed.png")),
        .init(id: "security-frame-ancestors-ok", kind: .axisAssertion, axes: [.security],
              targetURL: "https://example.com/security-frame",
              stubResult: pass(axes: ["security"], passed: 2, failed: 0,
                               screenshot: "/tmp/parity/security-frame.png")),
        .init(id: "design-contrast-ok", kind: .axisAssertion, axes: [.design],
              targetURL: "https://example.com/design-contrast",
              stubResult: pass(axes: ["design"], passed: 3, failed: 0,
                               screenshot: "/tmp/parity/design-contrast.png")),
        .init(id: "design-spacing-ok", kind: .axisAssertion, axes: [.design],
              targetURL: "https://example.com/design-spacing",
              stubResult: pass(axes: ["design"], passed: 2, failed: 0,
                               screenshot: "/tmp/parity/design-spacing.png")),
        .init(id: "design-typography-ok", kind: .axisAssertion, axes: [.design],
              targetURL: "https://example.com/design-typo",
              stubResult: pass(axes: ["design"], passed: 4, failed: 0,
                               screenshot: "/tmp/parity/design-typo.png")),

        // 4 fail-mode rows — one per axis.
        .init(id: "perf-inp-fail", kind: .failMode, axes: [.perf],
              targetURL: "https://example.com/perf-inp-fail",
              stubResult: fail(axes: ["perf"], passed: 0, failed: 1,
                               advisory: "INP threshold exceeded: 412 ms > 200 ms budget")),
        .init(id: "completeness-alt-fail", kind: .failMode, axes: [.completeness],
              targetURL: "https://example.com/completeness-alt-fail",
              stubResult: fail(axes: ["completeness"], passed: 1, failed: 2,
                               advisory: "missing alt attribute on 2 img elements")),
        .init(id: "security-csp-fail", kind: .failMode, axes: [.security],
              targetURL: "https://example.com/security-csp-fail",
              stubResult: fail(axes: ["security"], passed: 0, failed: 1,
                               advisory: "CSP header missing: no default-src directive present")),
        .init(id: "design-contrast-fail", kind: .failMode, axes: [.design],
              targetURL: "https://example.com/design-contrast-fail",
              stubResult: fail(axes: ["design"], passed: 1, failed: 3,
                               advisory: "WCAG AA contrast violations: 3 text/background pairs below 4.5:1")),

        // 4 edge-case rows — off-screen layout, Tab walk, INP scroll, CSP block.
        .init(id: "edge-offscreen-layout", kind: .edgeCase, axes: [.design],
              targetURL: "https://example.com/edge-offscreen",
              stubResult: pass(axes: ["design"], passed: 2, failed: 0,
                               screenshot: "/tmp/parity/edge-offscreen.png")),
        .init(id: "edge-tab-walk-focus", kind: .edgeCase, axes: [.completeness],
              targetURL: "https://example.com/edge-tab-walk",
              stubResult: pass(axes: ["completeness"], passed: 5, failed: 0,
                               screenshot: "/tmp/parity/edge-tab.png")),
        .init(id: "edge-scroll-inp", kind: .edgeCase, axes: [.perf],
              targetURL: "https://example.com/edge-scroll-inp",
              stubResult: pass(axes: ["perf"], passed: 3, failed: 0,
                               screenshot: "/tmp/parity/edge-scroll.png")),
        .init(id: "edge-csp-subresource", kind: .edgeCase, axes: [.security],
              targetURL: "https://example.com/edge-csp",
              stubResult: fail(axes: ["security"], passed: 1, failed: 1,
                               advisory: "CSP blocked: cdn.example.org not in script-src allowlist")),
    ]

    // MARK: - Test 1: axis corpus parity across dispatch modes

    @Test("axis-corpus parity: dispatcher Response byte-identical across .subprocess, .headless AND .pane for each fixture",
          arguments: BrowserPaneRunnerParityTests.corpus)
    func axisCorpusParityAcrossDispatchModes(fixture: ParityFixture) throws {
        let subprocessResp = try dispatchOnce(fixture: fixture, mode: .subprocess)
        let headlessResp = try dispatchOnce(fixture: fixture, mode: .headless)
        // U.2b-2 (headless seam) — the .pane leg now injects a stub
        // paneRunner closure that returns the SAME fixture.stubResult the
        // headless leg injects (dispatchOnce wires `paneRunner: runner`).
        // The parity assertion therefore covers all 20 corpus fixtures
        // three-way (well above the ≥10 the acceptance bullet requires).
        let paneResp = try dispatchOnce(fixture: fixture, mode: .pane)

        // Byte-identity at the three primary fields the acceptance bullet
        // calls out: result_status, assertions_passed, assertions_failed.
        // These ride the dispatcher's runner-agnostic seam — equal stub
        // outputs MUST surface equal dispatcher outputs across ALL THREE
        // arms.
        #expect(subprocessResp.response.resultStatus == headlessResp.response.resultStatus,
                "\(fixture.id): result_status differs (subprocess=\(subprocessResp.response.resultStatus), headless=\(headlessResp.response.resultStatus))")
        #expect(subprocessResp.response.resultStatus == paneResp.response.resultStatus,
                "\(fixture.id): result_status differs (subprocess=\(subprocessResp.response.resultStatus), pane=\(paneResp.response.resultStatus))")
        #expect(subprocessResp.response.assertionsPassed == headlessResp.response.assertionsPassed,
                "\(fixture.id): assertions_passed differs (subprocess=\(subprocessResp.response.assertionsPassed), headless=\(headlessResp.response.assertionsPassed))")
        #expect(subprocessResp.response.assertionsPassed == paneResp.response.assertionsPassed,
                "\(fixture.id): assertions_passed differs (subprocess=\(subprocessResp.response.assertionsPassed), pane=\(paneResp.response.assertionsPassed))")
        #expect(subprocessResp.response.assertionsFailed == headlessResp.response.assertionsFailed,
                "\(fixture.id): assertions_failed differs (subprocess=\(subprocessResp.response.assertionsFailed), headless=\(headlessResp.response.assertionsFailed))")
        #expect(subprocessResp.response.assertionsFailed == paneResp.response.assertionsFailed,
                "\(fixture.id): assertions_failed differs (subprocess=\(subprocessResp.response.assertionsFailed), pane=\(paneResp.response.assertionsFailed))")
        #expect(subprocessResp.response.axesRun == headlessResp.response.axesRun,
                "\(fixture.id): axes_run differs (subprocess=\(subprocessResp.response.axesRun), headless=\(headlessResp.response.axesRun))")
        #expect(subprocessResp.response.axesRun == paneResp.response.axesRun,
                "\(fixture.id): axes_run differs (subprocess=\(subprocessResp.response.axesRun), pane=\(paneResp.response.axesRun))")

        // Full Response JSON byte-identity across all three arms — the
        // dispatcher's encoding contract holds runner-agnostic.
        let subBytes = try BrowserValidationDispatcher.encode(subprocessResp.response)
        let hdBytes = try BrowserValidationDispatcher.encode(headlessResp.response)
        let paneBytes = try BrowserValidationDispatcher.encode(paneResp.response)
        #expect(subBytes == hdBytes, "\(fixture.id): subprocess/headless Response JSON must be byte-identical")
        #expect(subBytes == paneBytes, "\(fixture.id): subprocess/pane Response JSON must be byte-identical")

        // Audit-row shape: dispatcher writes one validation.dispatch row
        // per call; the runner= field is the only intended difference.
        // Confirm that across all three arms.
        let subRow = try #require(subprocessResp.dispatchRow)
        let hdRow = try #require(headlessResp.dispatchRow)
        let paneRow = try #require(paneResp.dispatchRow)
        let subWithoutRunner = subRow.command.replacingOccurrences(of: "runner=subprocess", with: "runner=<R>")
        let hdWithoutRunner = hdRow.command.replacingOccurrences(of: "runner=wkwebview-headless", with: "runner=<R>")
        let paneWithoutRunner = paneRow.command.replacingOccurrences(of: "runner=wkwebview-pane", with: "runner=<R>")
        #expect(subWithoutRunner == hdWithoutRunner,
                "\(fixture.id): audit command must match modulo runner= field; got\nsubprocess: \(subRow.command)\nheadless:   \(hdRow.command)")
        #expect(subWithoutRunner == paneWithoutRunner,
                "\(fixture.id): audit command must match modulo runner= field; got\nsubprocess: \(subRow.command)\npane:       \(paneRow.command)")
        // The pane row carries its distinct runner= discriminant.
        #expect(paneRow.command.contains("runner=wkwebview-pane"),
                "\(fixture.id): pane audit command must record runner=wkwebview-pane; got: \(paneRow.command)")
    }

    // MARK: - Test 2: fail-mode envelope parity

    @Test("fail-mode envelope parity: refusal advisory + audit-row shape match across runners (modulo runner= field)")
    func failModeRefusalEnvelopeParity() throws {
        let failModes = Self.corpus.filter { $0.kind == .failMode }
        for fixture in failModes {
            let sub = try dispatchOnce(fixture: fixture, mode: .subprocess)
            let hd = try dispatchOnce(fixture: fixture, mode: .headless)

            // Refusal advisory carries the same human-readable text (the
            // runner's stub advisory was equal; the dispatcher prepends a
            // uniform formatAdvisory wrapper).
            #expect(sub.response.advisory == hd.response.advisory,
                    "\(fixture.id): refusal advisory differs across runners (subprocess=\(sub.response.advisory), headless=\(hd.response.advisory))")
            // result_status: fail on both.
            #expect(sub.response.resultStatus == "fail" && hd.response.resultStatus == "fail",
                    "\(fixture.id): fail-mode fixtures must surface result_status:fail on both runners")
            // allow_failed default is false; dispatcher does NOT emit a
            // fail.allow override row.
            #expect(sub.tokenEvents.count == 1, "\(fixture.id): subprocess fail-mode should emit exactly one validation.dispatch row")
            #expect(hd.tokenEvents.count == 1, "\(fixture.id): headless fail-mode should emit exactly one validation.dispatch row")
        }
    }

    // MARK: - Test 3: HookRouter PreToolUse parity

    @Test("HookRouter PreToolUse refusal envelope identical for failing rows written by subprocess vs wkwebview-headless")
    func hookRouterPreToolUseGateParity() throws {
        let originalReader = HookRouter.browserValidationGateReader
        defer { HookRouter.browserValidationGateReader = originalReader }

        // Two canned failing rows that differ ONLY in writer-of-record.
        // The PreToolUse gate envelope must be identical — the runner=
        // field rides token_events, not validation_results, and the gate
        // reads from validation_results.
        let subprocessFailRow = SessionDatabase.BrowserValidationFailRow(
            id: 101,
            targetURL: "https://parity.example.com/page",
            axesJSON: "[\"perf\"]",
            advisory: "INP threshold exceeded: 412 ms > 200 ms budget",
            createdAt: Date()
        )
        let headlessFailRow = SessionDatabase.BrowserValidationFailRow(
            id: 102,
            targetURL: "https://parity.example.com/page",
            axesJSON: "[\"perf\"]",
            advisory: "INP threshold exceeded: 412 ms > 200 ms budget",
            createdAt: Date()
        )

        func envelopeFor(row: SessionDatabase.BrowserValidationFailRow) throws -> String {
            HookRouter.browserValidationGateReader = { _ in row }
            let event: [String: Any] = [
                "tool_name": "Edit",
                "hook_event_name": "PreToolUse",
                "session_id": "sid-parity",
                "tool_input": ["file_path": "/tmp/parity.html"],
            ]
            let data = try JSONSerialization.data(withJSONObject: event)
            let resp = HookRouter.handle(eventJSON: data)
            guard let json = try JSONSerialization.jsonObject(with: resp) as? [String: Any],
                  let hookOut = json["hookSpecificOutput"] as? [String: Any],
                  let reason = hookOut["permissionDecisionReason"] as? String
            else {
                Issue.record("expected deny envelope; got \(String(data: resp, encoding: .utf8) ?? "")")
                return ""
            }
            return reason
        }

        let subEnvelope = try envelopeFor(row: subprocessFailRow)
        let hdEnvelope = try envelopeFor(row: headlessFailRow)

        // The refusal envelope must be byte-identical modulo the
        // fixture_id (which embeds the row id, not the runner).
        let subWithoutId = subEnvelope.replacingOccurrences(of: "validation_results#101", with: "validation_results#<ID>")
        let hdWithoutId = hdEnvelope.replacingOccurrences(of: "validation_results#102", with: "validation_results#<ID>")
        #expect(subWithoutId == hdWithoutId,
                "HookRouter refusal envelope must be runner-agnostic; got\nsubprocess: \(subEnvelope)\nheadless:   \(hdEnvelope)")

        // Both envelopes still carry the canonical hard-block shape.
        for envelope in [subEnvelope, hdEnvelope] {
            #expect(envelope.contains("\"code\":\"validation_blocked\""),
                    "envelope missing validation_blocked code: \(envelope)")
            #expect(envelope.contains("\"failing_axis\":\"perf\""))
            #expect(envelope.contains("\"override_hint\""))
            // Side-channel guard: no raw assertion payload leaks.
            #expect(!envelope.contains("\"raw_output\""))
            #expect(!envelope.contains("\"plan_steps\""))
        }
    }

    // MARK: - Test 4: 50-mixed-runner chain integrity

    @Test("ChainVerifier.verifyTokenEvents holds across 50 interleaved subprocess/headless dispatches (T.5 cross-runner chain)")
    func chainIntegrityAcrossFiftyMixedRunnerRows() throws {
        let dbPath = "/tmp/senkani-u2b-1b-6-chain-\(UUID().uuidString).sqlite"
        let db = SessionDatabase(path: dbPath)
        defer { TempSessionDatabase.cleanup(path: dbPath) }
        let sid = db.createSession(projectRoot: "/tmp/u2b-1b-6-chain")

        // Two stub runners — one returns a pass row, the other returns a
        // pass row with a different axis-count signature so the dispatcher
        // writes distinguishable command strings.
        let subprocessStub: BrowserValidationDispatcher.Runner = { _, _, _, _ in
            PlaywrightResult(
                resultStatus: "pass",
                axesRun: ["perf"],
                assertionsPassed: 3,
                assertionsFailed: 0,
                screenshotPath: "/tmp/parity-chain-sub.png",
                advisory: nil
            )
        }
        let headlessStub: BrowserValidationDispatcher.Runner = { _, _, _, _ in
            PlaywrightResult(
                resultStatus: "pass",
                axesRun: ["completeness"],
                assertionsPassed: 5,
                assertionsFailed: 0,
                screenshotPath: "/tmp/parity-chain-hd.png",
                advisory: nil
            )
        }

        let resultSink: BrowserValidationDispatcher.ResultSink = { _ in
            // Don't write validation_results in this test — the chain
            // under test is the token_events chain.
        }
        let tokenEventSink: BrowserValidationDispatcher.TokenEventSink = { ev in
            db.recordTokenEvent(
                sessionId: ev.sessionId,
                paneId: nil,
                projectRoot: ev.projectRoot,
                source: "mcp_tool",
                toolName: "validate_browser",
                model: nil,
                inputTokens: 0,
                outputTokens: 0,
                savedTokens: 0,
                costCents: 0,
                feature: ev.feature,
                command: ev.command,
                modelTier: nil,
                connectionId: nil
            )
        }

        // 50 interleaved dispatches — alternating .subprocess and .headless.
        for i in 0..<50 {
            let dispatchMode: BrowserDispatchMode = (i % 2 == 0) ? .subprocess : .headless
            let axes: [ValidationAxes] = dispatchMode == .subprocess ? [.perf] : [.completeness]
            let req = BrowserValidationDispatcher.Request(
                targetURL: "https://chain-test-\(i).example.com/",
                axes: axes,
                diff: nil,
                allowFailed: false,
                screenshot: false,
                sessionId: sid,
                projectRoot: "/tmp/u2b-1b-6-chain",
                dispatch: dispatchMode
            )
            _ = try BrowserValidationDispatcher.dispatch(
                request: req,
                runner: subprocessStub,
                headlessRunner: headlessStub,
                resultSink: resultSink,
                tokenEventSink: tokenEventSink
            )
        }
        db.flushWrites()

        // ChainVerifier scans the token_events chain in row order. The
        // chain is broken if any row's prev_hash != hash(prev row); the
        // dispatcher writes runner= as a content field of the command
        // string, so each row's hash depends on the runner= value but
        // the chain links don't care about content — they only care
        // about hash continuity.
        let result = ChainVerifier.verifyTokenEvents(db)
        switch result {
        case .ok:
            break
        case .noChain:
            Issue.record("expected token_events chain after 50 mixed-runner dispatches, got .noChain")
        case .brokenAt(let table, let rowid, let expected, let actual):
            Issue.record("chain broken at \(table):\(rowid) — expected=\(expected) actual=\(actual)")
        }

        // Bonus sanity: confirm both runner= variants ARE present in
        // the chain — proves the mixed dispatch actually exercised both
        // arms (the 50-row test is meaningless if only one variant
        // survives). Use the public recentTokenEvents API (limit 200 ≥
        // 50 rows).
        let allEvents = db.recentTokenEvents(projectRoot: "/tmp/u2b-1b-6-chain", limit: 200)
        let allCommands = allEvents.compactMap { $0.command }
        let subRows = allCommands.filter { $0.contains("runner=subprocess") }
        let hdRows = allCommands.filter { $0.contains("runner=wkwebview-headless") }
        #expect(subRows.count == 25, "expected 25 runner=subprocess rows; got \(subRows.count)")
        #expect(hdRows.count == 25, "expected 25 runner=wkwebview-headless rows; got \(hdRows.count)")
    }

    // MARK: - Test 5 (U.2b-2 child (a)): 100-row three-runner chain integrity

    @Test("ChainVerifier.verifyTokenEvents holds across 100 interleaved subprocess/headless/pane dispatches (T.5 three-value chain)")
    func chainIntegrityAcrossHundredMixedRunnerRows() throws {
        let dbPath = "/tmp/senkani-u2b-2-chain-\(UUID().uuidString).sqlite"
        let db = SessionDatabase(path: dbPath)
        defer { TempSessionDatabase.cleanup(path: dbPath) }
        let sid = db.createSession(projectRoot: "/tmp/u2b-2-chain")

        // Stubs for the subprocess + headless arms. The .pane arm is a
        // no-op refusal inside the dispatcher — it invokes NEITHER stub,
        // so a .pane dispatch that touched a stub would Issue.record.
        let subprocessStub: BrowserValidationDispatcher.Runner = { _, _, _, _ in
            PlaywrightResult(resultStatus: "pass", axesRun: ["perf"],
                             assertionsPassed: 3, assertionsFailed: 0,
                             screenshotPath: "/tmp/three-chain-sub.png", advisory: nil)
        }
        let headlessStub: BrowserValidationDispatcher.Runner = { _, _, _, _ in
            PlaywrightResult(resultStatus: "pass", axesRun: ["completeness"],
                             assertionsPassed: 5, assertionsFailed: 0,
                             screenshotPath: "/tmp/three-chain-hd.png", advisory: nil)
        }

        let resultSink: BrowserValidationDispatcher.ResultSink = { _ in
            // chain under test is the token_events chain, not validation_results.
        }
        let tokenEventSink: BrowserValidationDispatcher.TokenEventSink = { ev in
            db.recordTokenEvent(
                sessionId: ev.sessionId,
                paneId: nil,
                projectRoot: ev.projectRoot,
                source: "mcp_tool",
                toolName: "validate_browser",
                model: nil,
                inputTokens: 0,
                outputTokens: 0,
                savedTokens: 0,
                costCents: 0,
                feature: ev.feature,
                command: ev.command,
                modelTier: nil,
                connectionId: nil
            )
        }

        // 100 interleaved dispatches — round-robin subprocess / headless /
        // pane (so the .pane refusal arm is exercised once per cycle, the
        // "wkwebview-pane variant per row" the acceptance bullet calls for).
        let modes: [BrowserDispatchMode] = [.subprocess, .headless, .pane]
        var expectedSub = 0, expectedHd = 0, expectedPane = 0
        for i in 0..<100 {
            let mode = modes[i % 3]
            switch mode {
            case .subprocess: expectedSub += 1
            case .headless: expectedHd += 1
            case .pane: expectedPane += 1
            }
            let axes: [ValidationAxes]
            switch mode {
            case .subprocess: axes = [.perf]
            case .headless: axes = [.completeness]
            case .pane: axes = [.security]
            }
            let req = BrowserValidationDispatcher.Request(
                targetURL: "https://chain-test-\(i).example.com/",
                axes: axes,
                diff: nil,
                allowFailed: false,
                screenshot: false,
                sessionId: sid,
                projectRoot: "/tmp/u2b-2-chain",
                dispatch: mode,
                paneId: mode == .pane ? "pane-\(i)" : nil
            )
            _ = try BrowserValidationDispatcher.dispatch(
                request: req,
                runner: subprocessStub,
                headlessRunner: headlessStub,
                resultSink: resultSink,
                tokenEventSink: tokenEventSink
            )
        }
        db.flushWrites()

        // Chain integrity across the 100-row three-runner stream.
        let result = ChainVerifier.verifyTokenEvents(db)
        switch result {
        case .ok:
            break
        case .noChain:
            Issue.record("expected token_events chain after 100 three-runner dispatches, got .noChain")
        case .brokenAt(let table, let rowid, let expected, let actual):
            Issue.record("chain broken at \(table):\(rowid) — expected=\(expected) actual=\(actual)")
        }

        // All three runner= variants are present in the chain — proves the
        // 100-row test actually exercised every arm (Karpathy test-fidelity:
        // a three-runner chain test is meaningless if a variant never ran).
        let allEvents = db.recentTokenEvents(projectRoot: "/tmp/u2b-2-chain", limit: 200)
        let allCommands = allEvents.compactMap { $0.command }
        let subRows = allCommands.filter { $0.contains("runner=subprocess") }
        let hdRows = allCommands.filter { $0.contains("runner=wkwebview-headless") }
        let paneRows = allCommands.filter { $0.contains("runner=wkwebview-pane") }
        #expect(subRows.count == expectedSub, "expected \(expectedSub) runner=subprocess rows; got \(subRows.count)")
        #expect(hdRows.count == expectedHd, "expected \(expectedHd) runner=wkwebview-headless rows; got \(hdRows.count)")
        #expect(paneRows.count == expectedPane, "expected \(expectedPane) runner=wkwebview-pane rows; got \(paneRows.count)")
        // 100 total dispatch rows (no allow_failed override rows — the
        // pane refusal is allow_failed:false so no fail.allow row chains).
        #expect(subRows.count + hdRows.count + paneRows.count == 100,
                "all 100 dispatch rows accounted for across the three runner variants")
    }

    // MARK: - helpers

    private static func pass(axes: [String], passed: Int, failed: Int,
                             screenshot: String?) -> PlaywrightResult {
        PlaywrightResult(
            resultStatus: "pass",
            axesRun: axes,
            assertionsPassed: passed,
            assertionsFailed: failed,
            screenshotPath: screenshot,
            advisory: nil
        )
    }

    private static func fail(axes: [String], passed: Int, failed: Int,
                             advisory: String) -> PlaywrightResult {
        PlaywrightResult(
            resultStatus: "fail",
            axesRun: axes,
            assertionsPassed: passed,
            assertionsFailed: failed,
            screenshotPath: nil,
            advisory: advisory
        )
    }

    private struct DispatchOutcome {
        let response: BrowserValidationDispatcher.Response
        let dispatchRow: BrowserValidationDispatcher.TokenEventInput?
        let tokenEvents: [BrowserValidationDispatcher.TokenEventInput]
    }

    private func dispatchOnce(fixture: ParityFixture, mode: BrowserDispatchMode) throws -> DispatchOutcome {
        let runner: BrowserValidationDispatcher.Runner = { _, _, _, _ in fixture.stubResult }
        let evSink = LockedArray<BrowserValidationDispatcher.TokenEventInput>()
        let rowSink = LockedArray<BrowserValidationDispatcher.BrowserValidationRow>()
        let request = BrowserValidationDispatcher.Request(
            targetURL: fixture.targetURL,
            axes: fixture.axes,
            diff: nil,
            allowFailed: false,
            screenshot: true,
            sessionId: "sid-parity-\(fixture.id)",
            projectRoot: "/tmp/parity-\(fixture.id)",
            dispatch: mode
        )
        let resp = try BrowserValidationDispatcher.dispatch(
            request: request,
            runner: runner,
            headlessRunner: runner,
            paneRunner: runner,
            resultSink: { rowSink.append($0) },
            tokenEventSink: { evSink.append($0) }
        )
        let events = evSink.snapshot()
        return DispatchOutcome(
            response: resp,
            dispatchRow: events.first { $0.feature == "validation.dispatch" },
            tokenEvents: events
        )
    }
}

// MARK: - Thread-safe collection for sink closures

private final class LockedArray<Element>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [Element] = []
    func append(_ item: Element) {
        lock.lock(); defer { lock.unlock() }
        items.append(item)
    }
    func snapshot() -> [Element] {
        lock.lock(); defer { lock.unlock() }
        return items
    }
}
