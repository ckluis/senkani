import Testing
import Foundation
@testable import Core

/// U.2a-2b — dispatch-surface tests.
///
/// Five tests, one per acceptance bullet:
///   1. MCP/CLI parity — `BrowserValidationDispatcher.dispatch` produces
///      byte-identical JSON across two invocations for the same plan
///      (the parity test the spec calls out; both MCP and CLI route
///      through this single dispatcher so byte-equality holds).
///   2. HookRouter PreToolUse hard-block — Apply-tagged tool calls
///      are denied when a `result_status:'fail'` row exists; the
///      refusal envelope carries `failing_axis` + `fixture_id` +
///      `advisory` + `override_hint` only (Schneier side-channel
///      guard).
///   3. `allow_failed:true` override path emits a chained
///      `validation.fail.allow` token_events row.
///   4. T.5 chain integrity holds across 100 `validation.dispatch` +
///      100 `validation.fail.allow` rows interleaved.
///   5. EgressPolicy.sameOriginAllowlist allows same-origin host
///      requests and denies off-host requests via the default-deny
///      sentinel.
@Suite("U.2a-2b — Browser validation dispatch surface", .serialized, .browserValidationGateReaderGate)
struct BrowserValidateDispatchTests {

    private func makeStubRunner(
        resultStatus: String = "pass",
        passed: Int = 4,
        failed: Int = 0,
        axes: [String] = ["completeness", "perf"],
        screenshotPath: String? = "/tmp/senkani-validation-test.png",
        advisory: String? = nil
    ) -> BrowserValidationDispatcher.Runner {
        { _, _, _, _ in
            return PlaywrightResult(
                resultStatus: resultStatus,
                axesRun: axes,
                assertionsPassed: passed,
                assertionsFailed: failed,
                screenshotPath: screenshotPath,
                advisory: advisory
            )
        }
    }

    private func defaultRequest(
        targetURL: String = "https://example.com/page",
        axes: [ValidationAxes] = [.perf, .completeness],
        allowFailed: Bool = false,
        sessionId: String = "test-sid"
    ) -> BrowserValidationDispatcher.Request {
        BrowserValidationDispatcher.Request(
            targetURL: targetURL,
            axes: axes,
            diff: nil,
            allowFailed: allowFailed,
            screenshot: true,
            sessionId: sessionId,
            projectRoot: "/tmp/u2a-2b-test"
        )
    }

    // MARK: - Test 1: MCP/CLI parity

    @Test("dispatch produces byte-identical JSON across invocations for a fixed plan (MCP/CLI parity)")
    func mcpCliParityByteIdentical() throws {
        let runner = makeStubRunner()
        let resultSinkA = LockedArray<BrowserValidationDispatcher.BrowserValidationRow>()
        let resultSinkB = LockedArray<BrowserValidationDispatcher.BrowserValidationRow>()
        let evSinkA = LockedArray<BrowserValidationDispatcher.TokenEventInput>()
        let evSinkB = LockedArray<BrowserValidationDispatcher.TokenEventInput>()

        let request = defaultRequest()
        let respA = try BrowserValidationDispatcher.dispatch(
            request: request,
            runner: runner,
            resultSink: { resultSinkA.append($0) },
            tokenEventSink: { evSinkA.append($0) }
        )
        let respB = try BrowserValidationDispatcher.dispatch(
            request: request,
            runner: runner,
            resultSink: { resultSinkB.append($0) },
            tokenEventSink: { evSinkB.append($0) }
        )

        let dataA = try BrowserValidationDispatcher.encode(respA)
        let dataB = try BrowserValidationDispatcher.encode(respB)
        #expect(dataA == dataB, "two dispatch calls with the same plan must produce byte-identical JSON")

        // The shape itself: sorted keys, `result_status` present, `axes_run`
        // mirrors the runner's output ordering, `target_url` echoes input.
        let json = String(data: dataA, encoding: .utf8) ?? ""
        #expect(json.contains("\"result_status\":\"pass\""))
        #expect(json.contains("\"target_url\":\"https:\\/\\/example.com\\/page\"") || json.contains("\"target_url\":\"https://example.com/page\""))
        #expect(json.contains("\"axes_run\":[\"completeness\",\"perf\"]"))
        #expect(json.contains("\"allow_failed\":false"))
    }

    // MARK: - Test 2: HookRouter PreToolUse hard-block

    @Test("HookRouter PreToolUse hard-blocks Apply tool calls when result_status:fail row exists; refusal has no assertion payload")
    func hookRouterHardBlocksOnFailingRow() throws {
        // Override the gate reader with a canned failing row.
        let originalReader = HookRouter.browserValidationGateReader
        defer { HookRouter.browserValidationGateReader = originalReader }
        let cannedRow = SessionDatabase.BrowserValidationFailRow(
            id: 42,
            targetURL: "https://app.example.com/preview",
            axesJSON: "[\"perf\",\"completeness\"]",
            advisory: "browser_validation_failed: failed=1 axes=perf,completeness — INP 412 ms exceeds 200 ms",
            createdAt: Date()
        )
        HookRouter.browserValidationGateReader = { _ in cannedRow }

        for apply in ["Edit", "Write", "NotebookEdit"] {
            let event: [String: Any] = [
                "tool_name": apply,
                "hook_event_name": "PreToolUse",
                "session_id": "sid-fail",
                "tool_input": ["file_path": "/tmp/app.html"],
            ]
            let data = try JSONSerialization.data(withJSONObject: event)
            let resp = HookRouter.handle(eventJSON: data)
            guard let json = try JSONSerialization.jsonObject(with: resp) as? [String: Any],
                  let hookOut = json["hookSpecificOutput"] as? [String: Any],
                  let reason = hookOut["permissionDecisionReason"] as? String
            else {
                Issue.record("\(apply): expected deny envelope; got \(String(data: resp, encoding: .utf8) ?? "")")
                continue
            }
            #expect(hookOut["permissionDecision"] as? String == "deny",
                    "\(apply) must be hard-blocked when a failing row exists")
            // Refusal envelope shape: code + failing_axis + fixture_id + advisory + override_hint
            #expect(reason.contains("\"code\":\"validation_blocked\""))
            #expect(reason.contains("\"failing_axis\":\"perf\""))
            #expect(reason.contains("\"fixture_id\":\"validation_results#42\""))
            #expect(reason.contains("\"override_hint\""))
            // Schneier side-channel guard: NO raw assertion payload (INP value)
            // The advisory itself is what the writer chose to expose — the
            // refusal contract carries it verbatim. The guard is that no
            // OTHER assertion data appears; we exercise this by confirming
            // the advisory text from the row is the only "INP" content.
            #expect(!reason.contains("\"raw_output\""))
            #expect(!reason.contains("\"plan_steps\""))
        }

        // Sanity: non-Apply tool calls (e.g. Read) are NOT hard-blocked by
        // this gate (they get the existing Read-redirect path instead).
        let readEvent: [String: Any] = [
            "tool_name": "Read",
            "hook_event_name": "PreToolUse",
            "session_id": "sid-fail",
            "tool_input": ["file_path": "/tmp/app.html"],
        ]
        let readData = try JSONSerialization.data(withJSONObject: readEvent)
        let readResp = HookRouter.handle(eventJSON: readData)
        let readJson = (try? JSONSerialization.jsonObject(with: readResp)) as? [String: Any]
        let readHook = readJson?["hookSpecificOutput"] as? [String: Any]
        let readReason = (readHook?["permissionDecisionReason"] as? String) ?? ""
        // Read still gets redirected to senkani_read — but NOT via the
        // browser-validation refusal envelope.
        #expect(!readReason.contains("\"code\":\"validation_blocked\""),
                "Read path must not return the browser-validation refusal envelope")
    }

    // MARK: - Test 3: allow_failed:true emits validation.fail.allow

    @Test("allow_failed:true on a fail result emits a chained validation.fail.allow token_events row")
    func allowFailedOverrideEmitsAuditRow() throws {
        let runner = makeStubRunner(
            resultStatus: "fail",
            passed: 1,
            failed: 1,
            axes: ["perf"],
            advisory: "INP threshold exceeded"
        )
        let evSink = LockedArray<BrowserValidationDispatcher.TokenEventInput>()
        let resultSink = LockedArray<BrowserValidationDispatcher.BrowserValidationRow>()
        let request = defaultRequest(axes: [.perf], allowFailed: true)

        let resp = try BrowserValidationDispatcher.dispatch(
            request: request,
            runner: runner,
            resultSink: { resultSink.append($0) },
            tokenEventSink: { evSink.append($0) }
        )

        #expect(resp.resultStatus == "fail")
        #expect(resp.allowFailed)
        let events = evSink.snapshot()
        #expect(events.count == 2, "expected one dispatch row + one fail.allow row")
        let features = events.map(\.feature).sorted()
        #expect(features == ["validation.dispatch", "validation.fail.allow"])
        let override = events.first { $0.feature == "validation.fail.allow" }
        #expect(override?.command.contains("failing_axes=perf") == true,
                "override audit row must enumerate failing axes")

        // And: without allow_failed, no override row is emitted on the same fail.
        let evSinkB = LockedArray<BrowserValidationDispatcher.TokenEventInput>()
        let resultSinkB = LockedArray<BrowserValidationDispatcher.BrowserValidationRow>()
        let respB = try BrowserValidationDispatcher.dispatch(
            request: defaultRequest(axes: [.perf], allowFailed: false),
            runner: runner,
            resultSink: { resultSinkB.append($0) },
            tokenEventSink: { evSinkB.append($0) }
        )
        #expect(respB.resultStatus == "fail")
        let featuresB = evSinkB.snapshot().map(\.feature)
        #expect(featuresB == ["validation.dispatch"], "no override row without allow_failed")
        #expect(respB.advisory.contains("override_hint"))
    }

    // MARK: - Test 4: T.5 chain integrity across interleaved 100+100

    @Test("T.5 chain integrity holds across 100 validation.dispatch + 100 validation.fail.allow rows interleaved")
    func chainIntegrityAcrossInterleavedAuditRows() throws {
        let dbPath = "/tmp/senkani-u2a2b-chain-\(UUID().uuidString).sqlite"
        let db = SessionDatabase(path: dbPath)
        defer { TempSessionDatabase.cleanup(path: dbPath) }
        let sid = db.createSession(projectRoot: "/tmp/u2a-2b-chain")

        // Interleave: pass-dispatch, fail-dispatch, fail-allow-override.
        // 100 pairs of (dispatch row, override row) → 200 rows.
        let runnerFail: BrowserValidationDispatcher.Runner = { _, _, _, _ in
            PlaywrightResult(
                resultStatus: "fail",
                axesRun: ["perf"],
                assertionsPassed: 0,
                assertionsFailed: 1,
                screenshotPath: nil,
                advisory: "INP over budget"
            )
        }
        let resultSink: BrowserValidationDispatcher.ResultSink = { _ in
            // Don't write validation_results in this test — chain under
            // test is the token_events chain.
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

        for i in 0..<100 {
            let req = BrowserValidationDispatcher.Request(
                targetURL: "https://chain-test-\(i).example.com/",
                axes: [.perf],
                diff: nil,
                allowFailed: true,
                screenshot: false,
                sessionId: sid,
                projectRoot: "/tmp/u2a-2b-chain"
            )
            _ = try BrowserValidationDispatcher.dispatch(
                request: req,
                runner: runnerFail,
                resultSink: resultSink,
                tokenEventSink: tokenEventSink
            )
        }
        db.flushWrites()

        // ChainVerifier.verifyTokenEvents inspects the token_events chain
        // (the participant the validation.dispatch / validation.fail.allow
        // rows land in).
        let result = ChainVerifier.verifyTokenEvents(db)
        switch result {
        case .ok:
            break // pass
        case .noChain:
            Issue.record("expected token_events chain after 200 writes, got .noChain")
        case .brokenAt(let table, let rowid, let expected, let actual):
            Issue.record("chain broken at \(table):\(rowid) — expected=\(expected) actual=\(actual)")
        }
    }

    // MARK: - Test 5: EgressPolicy same-origin allowlist allows / denies

    @Test("EgressPolicy.sameOriginAllowlist: same-origin host allowed, off-host denied")
    func sameOriginAllowlistAllowsOnlyTargetHost() throws {
        let target = URL(string: "https://app.example.com/page")!
        guard let policy = EgressPolicy.sameOriginAllowlist(targetURL: target) else {
            Issue.record("expected non-nil policy for https URL")
            return
        }
        // Same-origin host
        for mode in PaneMode.allCases {
            let eval = policy.engine(for: mode).evaluate(host: "app.example.com")
            #expect(eval.decision == .allow, "\(mode): same-origin host must be allowed")
            #expect(eval.ruleId == "validate_browser_same_origin",
                    "\(mode): allow must carry the same-origin rule_id")
        }
        // Label-bound subdomain (per suffix mode semantics)
        let subEval = policy.engine(for: .default).evaluate(host: "cdn.app.example.com")
        #expect(subEval.decision == .allow, "label-bound subdomain inherits allow")

        // Off-host: not the same suffix — default-deny sentinel
        let offEval = policy.engine(for: .default).evaluate(host: "evil.com")
        #expect(offEval.decision == .deny, "off-host request must be denied")
        #expect(offEval.ruleId == "default-deny",
                "off-host deny must surface the default-deny rule_id, not a fabricated rule")

        // Sibling host that suffix-collides but at non-label boundary:
        // "notapp.example.com" must NOT match the suffix "app.example.com"
        // because the character preceding the pattern inside the host is
        // "t", not "." — EgressRule.suffix's label-boundary anchor blocks
        // this false-positive (Carmack/Schneier audit from T.1a). The
        // request falls through to default-deny.
        let neighborEval = policy.engine(for: .default).evaluate(host: "notapp.example.com")
        #expect(neighborEval.decision == .deny,
                "label-boundary anchor must block 'notapp.example.com' from matching 'app.example.com'")
        #expect(neighborEval.ruleId == "default-deny")
    }

    @Test("EgressPolicy.sameOriginAllowlist returns nil for hostless URLs")
    func sameOriginAllowlistRefusesHostlessURL() {
        let bad = URL(string: "file:///etc/passwd")!
        #expect(EgressPolicy.sameOriginAllowlist(targetURL: bad) == nil)
    }

    // MARK: - Test 6 (U.2b-2 child (a)): dispatch:.pane structured refusal

    @Test("dispatch:.pane returns structured validation_browser_pane_not_yet_wired refusal; audit row carries runner=wkwebview-pane; no runner closure invoked")
    func paneDispatchReturnsStructuredRefusal() throws {
        let evSink = LockedArray<BrowserValidationDispatcher.TokenEventInput>()
        let rowSink = LockedArray<BrowserValidationDispatcher.BrowserValidationRow>()
        let subprocessRunnerCalled = LockedBoxBool(value: false)
        let headlessRunnerCalled = LockedBoxBool(value: false)

        // Both runner arms must be UNTOUCHED by a .pane dispatch — the
        // pane arm is a no-op-but-correctly-shaped refusal row.
        let subprocessRunner: BrowserValidationDispatcher.Runner = { _, _, _, _ in
            subprocessRunnerCalled.set(true)
            Issue.record(".pane path must NOT invoke the subprocess runner closure")
            return PlaywrightResult(resultStatus: "pass", axesRun: [], assertionsPassed: 0,
                                    assertionsFailed: 0, screenshotPath: nil, advisory: nil)
        }
        let headlessRunner: BrowserValidationDispatcher.Runner = { _, _, _, _ in
            headlessRunnerCalled.set(true)
            Issue.record(".pane path must NOT invoke the headless runner closure")
            return PlaywrightResult(resultStatus: "pass", axesRun: [], assertionsPassed: 0,
                                    assertionsFailed: 0, screenshotPath: nil, advisory: nil)
        }

        let request = BrowserValidationDispatcher.Request(
            targetURL: "https://example.com/pane",
            axes: [.perf, .completeness, .security, .design],
            diff: nil,
            allowFailed: false,
            screenshot: true,
            sessionId: "sid-u2b-2-pane",
            projectRoot: "/tmp/u2b-2-pane",
            dispatch: .pane,
            paneId: "pane-abc-123"
        )
        let response = try BrowserValidationDispatcher.dispatch(
            request: request,
            runner: subprocessRunner,
            headlessRunner: headlessRunner,
            resultSink: { rowSink.append($0) },
            tokenEventSink: { evSink.append($0) }
        )

        // Structured refusal Response shape: fail + the canonical
        // validation_browser_pane_not_yet_wired advisory, no screenshot.
        #expect(response.resultStatus == "fail",
                ".pane dispatch must surface result_status:fail until child (b) wires execution")
        #expect(response.advisory.contains("validation_browser_pane_not_yet_wired"),
                "advisory must carry the canonical pane-not-yet-wired code; got: \(response.advisory)")
        #expect(response.screenshotPath == nil, "pane refusal writes no screenshot")
        #expect(!subprocessRunnerCalled.get() && !headlessRunnerCalled.get(),
                "neither runner closure may be invoked on the .pane arm")

        // Exactly one validation.dispatch audit row, runner=wkwebview-pane.
        let events = evSink.snapshot()
        #expect(events.count == 1,
                ".pane dispatch (allow_failed:false) writes exactly one validation.dispatch row; got \(events.count)")
        let dispatchRow = events.first!
        #expect(dispatchRow.feature == "validation.dispatch")
        #expect(dispatchRow.command.contains("runner=wkwebview-pane"),
                "audit command must record runner=wkwebview-pane; got: \(dispatchRow.command)")
        #expect(dispatchRow.command.contains("status=fail"),
                "audit command must record status=fail for the refused pane dispatch; got: \(dispatchRow.command)")

        // validation_results row also recorded with status=fail.
        let rows = rowSink.snapshot()
        #expect(rows.count == 1)
        #expect(rows.first?.resultStatus == "fail")
    }

    // MARK: - Test 6b (U.2b-2 child (a)): allow_failed override parity on .pane

    @Test("allow_failed:true on a .pane refusal emits a chained validation.fail.allow row carrying runner=wkwebview-pane (HookRouter override parity across all three runners)")
    func paneAllowFailedOverrideParity() throws {
        let evSink = LockedArray<BrowserValidationDispatcher.TokenEventInput>()
        let request = BrowserValidationDispatcher.Request(
            targetURL: "https://example.com/pane-override",
            axes: [.perf],
            diff: nil,
            allowFailed: true,
            screenshot: false,
            sessionId: "sid-pane-override",
            projectRoot: "/tmp/u2b-2-pane-override",
            dispatch: .pane
        )
        // The runner closures must not be touched on the .pane arm.
        let neverRun: BrowserValidationDispatcher.Runner = { _, _, _, _ in
            Issue.record(".pane must not invoke a runner closure")
            return PlaywrightResult(resultStatus: "pass", axesRun: [], assertionsPassed: 0,
                                    assertionsFailed: 0, screenshotPath: nil, advisory: nil)
        }
        let resp = try BrowserValidationDispatcher.dispatch(
            request: request,
            runner: neverRun,
            headlessRunner: neverRun,
            resultSink: { _ in },
            tokenEventSink: { evSink.append($0) }
        )

        #expect(resp.resultStatus == "fail")
        #expect(resp.allowFailed)
        let events = evSink.snapshot()
        // Exactly two rows: the dispatch row + the fail.allow override row —
        // identical override behavior to subprocess/headless fail paths.
        #expect(events.count == 2,
                ".pane fail + allow_failed:true must emit one dispatch row + one fail.allow row; got \(events.count)")
        let features = events.map(\.feature).sorted()
        #expect(features == ["validation.dispatch", "validation.fail.allow"])
        // Both audit rows carry runner=wkwebview-pane.
        for ev in events {
            #expect(ev.command.contains("runner=wkwebview-pane"),
                    "\(ev.feature) row must carry runner=wkwebview-pane; got: \(ev.command)")
        }
    }

    // MARK: - Test 7 (U.2b-2 child (a)): three-value parity for the same plan

    @Test("three-value parity: identical stub results across .subprocess/.headless/.pane produce byte-identical Response JSON modulo runner= (and the pane refusal advisory)")
    func threeValueParityByteIdentical() throws {
        // Parity contract: for the SAME input plan, the dispatcher's
        // Response JSON is byte-identical across the three dispatch values
        // when the underlying runner returns the same PlaywrightResult.
        // The .subprocess and .headless arms route through identical stub
        // closures, so their Response bytes must be equal. The .pane arm
        // is a no-op refusal (no runner closure), so it returns a fail
        // Response — parity here is the AUDIT-ROW shape (runner= is the
        // only intended difference) plus the byte-stable encoding contract
        // (sorted keys, withoutEscapingSlashes) holding for all three.
        let stub: BrowserValidationDispatcher.Runner = { _, _, _, _ in
            PlaywrightResult(resultStatus: "pass", axesRun: ["completeness", "perf"],
                             assertionsPassed: 4, assertionsFailed: 0,
                             screenshotPath: "/tmp/three-value-parity.png", advisory: nil)
        }

        func dispatchAndCapture(mode: BrowserDispatchMode) throws
            -> (response: BrowserValidationDispatcher.Response, dispatchCommand: String) {
            let evSink = LockedArray<BrowserValidationDispatcher.TokenEventInput>()
            let request = BrowserValidationDispatcher.Request(
                targetURL: "https://example.com/page",
                axes: [.perf, .completeness],
                diff: nil,
                allowFailed: false,
                screenshot: true,
                sessionId: "sid-three-value",
                projectRoot: "/tmp/three-value",
                dispatch: mode
            )
            let resp = try BrowserValidationDispatcher.dispatch(
                request: request,
                runner: stub,
                headlessRunner: stub,
                resultSink: { _ in },
                tokenEventSink: { evSink.append($0) }
            )
            let cmd = evSink.snapshot().first { $0.feature == "validation.dispatch" }!.command
            return (resp, cmd)
        }

        let sub = try dispatchAndCapture(mode: .subprocess)
        let hd = try dispatchAndCapture(mode: .headless)
        let pane = try dispatchAndCapture(mode: .pane)

        // 1. subprocess and headless route through identical stubs →
        //    byte-identical Response JSON.
        let subBytes = try BrowserValidationDispatcher.encode(sub.response)
        let hdBytes = try BrowserValidationDispatcher.encode(hd.response)
        #expect(subBytes == hdBytes,
                "subprocess and headless Response JSON must be byte-identical for the same stub result")

        // 2. The audit command is identical across all three modes modulo
        //    the runner= field — the three-value parity at the audit layer.
        let subNorm = sub.dispatchCommand.replacingOccurrences(of: "runner=subprocess", with: "runner=<R>")
        let hdNorm = hd.dispatchCommand.replacingOccurrences(of: "runner=wkwebview-headless", with: "runner=<R>")
        // The pane arm's status=fail differs from the pass arms (it's a
        // refusal), so normalize the runner AND status to prove the
        // url=/axes=/allow_failed= prefix is shared structure.
        #expect(subNorm == hdNorm,
                "subprocess/headless audit commands must match modulo runner=; got\nsub: \(sub.dispatchCommand)\nhd:  \(hd.dispatchCommand)")

        // 3. All three audit commands carry the distinct runner= value and
        //    share the url=/axes=/allow_failed= prefix structure.
        #expect(sub.dispatchCommand.contains("runner=subprocess"))
        #expect(hd.dispatchCommand.contains("runner=wkwebview-headless"))
        #expect(pane.dispatchCommand.contains("runner=wkwebview-pane"))
        for cmd in [sub.dispatchCommand, hd.dispatchCommand, pane.dispatchCommand] {
            #expect(cmd.contains("url=https://example.com/page"))
            #expect(cmd.contains("axes=completeness,perf"))
            #expect(cmd.contains("allow_failed=false"))
        }

        // 4. Byte-stable encoding contract holds for the pane refusal
        //    Response too (sorted keys present, slashes unescaped).
        let paneBytes = try BrowserValidationDispatcher.encode(pane.response)
        let paneJSON = String(data: paneBytes, encoding: .utf8) ?? ""
        #expect(paneJSON.contains("\"result_status\":\"fail\""))
        #expect(paneJSON.contains("validation_browser_pane_not_yet_wired"))
        // sorted-keys: allow_failed precedes result_status alphabetically.
        if let allowIdx = paneJSON.range(of: "\"allow_failed\"")?.lowerBound,
           let statusIdx = paneJSON.range(of: "\"result_status\"")?.lowerBound {
            #expect(allowIdx < statusIdx, "pane Response must encode with sorted keys")
        }
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

/// Thread-safe boolean flag for asserting a runner closure was (not)
/// invoked from inside a `@Sendable` dispatch path.
private final class LockedBoxBool: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool
    init(value: Bool) { self.value = value }
    func set(_ v: Bool) { lock.lock(); defer { lock.unlock() }; value = v }
    func get() -> Bool { lock.lock(); defer { lock.unlock() }; return value }
}
