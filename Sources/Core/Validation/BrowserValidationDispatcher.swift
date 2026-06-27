import Foundation

/// U.2a-2b — single dispatch surface for browser validation. Both the
/// `senkani_validate_browser` MCP tool and the `senkani validate --browser`
/// CLI subcommand call this dispatcher, which guarantees byte-identical
/// JSON output for the same input plan.
///
/// Layering (Bach separation-of-concerns):
///   - `ValidationPlanner.plan(...)` produces the step list (pure).
///   - The runner executes the plan against Chromium (injectable seam).
///   - `ValidationStore.insertBrowserValidationResult(...)` persists the
///     structured outcome to `validation_results` (v22 columns).
///   - `TokenEventStore.recordTokenEvent(feature:"validation.dispatch")`
///     writes one chained dispatch row per call.
///   - When `allow_failed: true` and the run failed, a second chained
///     `validation.fail.allow` row is written (Russell no-silent-acceptance).
///
/// Refusal-contract (Schneier side-channel guard): when the run returns
/// `result_status:"fail"` the response advisory carries `failing_axis`,
/// `assertion counts`, and the operator-runnable override hint — but NEVER
/// the failed assertion's payload. The HookRouter PreToolUse gate that
/// reads `validation_results.result_status:fail` rows mirrors the same
/// guard.
public enum BrowserValidationDispatcher {

    /// Inputs to a single dispatch call. Both MCP tool and CLI normalize
    /// their arguments into this shape before calling `dispatch`.
    public struct Request: Sendable, Equatable {
        public let targetURL: String
        public let axes: [ValidationAxes]
        public let diff: DiffRequest?
        public let allowFailed: Bool
        public let screenshot: Bool
        public let sessionId: String
        public let projectRoot: String?
        /// U.2b-1a — runner selector. `.subprocess` invokes the runner
        /// closure; `.headless` invokes the injected `headlessRunner`
        /// closure (or a `headless_not_yet_implemented` refusal when none
        /// is registered); `.pane` invokes the injected `paneRunner`
        /// closure (or a fail-closed `validation_browser_pane_no_runner`
        /// refusal when none is registered — never a fabricated pass). The
        /// visible-pane WKWebView execution + SwiftUI refusal-banner
        /// overlay + input-lock are the operator Cowork/GUI half that
        /// registers the pane factory.
        public let dispatch: BrowserDispatchMode
        /// U.2b-2 child (a) — visible-pane selector. Identifies which
        /// `BrowserPane` a `dispatch: .pane` call targets. `nil` resolves
        /// to the most-recently-focused pane once child (b) wires the
        /// pane registry; non-nil pins a specific pane id. Default-safe:
        /// callers on the `.subprocess` / `.headless` arms leave this
        /// `nil` and observe no behavioral change. Until child (b) lands,
        /// the value is carried but not yet consulted — the `.pane` arm
        /// refuses uniformly regardless of `paneId`.
        public let paneId: String?
        /// Optional EgressProxy URL the spawned Chromium subprocess should
        /// route through (e.g. `"http://127.0.0.1:18080"`). When set, the
        /// dispatcher computes a same-origin allowlist for `targetURL`,
        /// writes it to a temp policy file the daemon (or test stub) reads
        /// via `SENKANI_EGRESS_POLICY_OVERRIDE`, and passes both the proxy
        /// URL and the override path to the runner closure. Wired in
        /// `process-gap-validate-browser-runner-egress-not-wired-2026-05-19`.
        public let egressProxyURL: String?

        /// V.18a-5 — tool-call id paired with this dispatch. Caller-
        /// supplied so the cross-cutting JOIN against
        /// `agent_trace_event` is keyed correctly. Defaults to a
        /// dispatcher-synthesized UUID when callers don't have one
        /// (CLI invocations outside an MCP tool-call context); the
        /// MCP tool wires its envelope's call_id.
        public let toolCallId: String

        public init(
            targetURL: String,
            axes: [ValidationAxes],
            diff: DiffRequest?,
            allowFailed: Bool,
            screenshot: Bool,
            sessionId: String,
            projectRoot: String?,
            dispatch: BrowserDispatchMode = .subprocess,
            paneId: String? = nil,
            egressProxyURL: String? = nil,
            toolCallId: String = UUID().uuidString
        ) {
            self.targetURL = targetURL
            self.axes = axes
            self.diff = diff
            self.allowFailed = allowFailed
            self.screenshot = screenshot
            self.sessionId = sessionId
            self.projectRoot = projectRoot
            self.dispatch = dispatch
            self.paneId = paneId
            self.egressProxyURL = egressProxyURL
            self.toolCallId = toolCallId
        }
    }

    /// Byte-stable response shape returned to MCP + CLI callers. Encoded
    /// with `[.sortedKeys, .withoutEscapingSlashes]` so the parity test
    /// can compare the two surfaces byte-for-byte.
    public struct Response: Codable, Sendable, Equatable {
        public let resultStatus: String
        public let axesRun: [String]
        public let assertionsPassed: Int
        public let assertionsFailed: Int
        public let screenshotPath: String?
        public let advisory: String
        public let targetUrl: String
        public let allowFailed: Bool

        enum CodingKeys: String, CodingKey {
            case resultStatus = "result_status"
            case axesRun = "axes_run"
            case assertionsPassed = "assertions_passed"
            case assertionsFailed = "assertions_failed"
            case screenshotPath = "screenshot_path"
            case advisory
            case targetUrl = "target_url"
            case allowFailed = "allow_failed"
        }
    }

    /// Closure shape for the runner. Production wires
    /// `PlaywrightSubprocessRunner.run`; tests inject a deterministic
    /// closure that returns canned `PlaywrightResult` values.
    ///
    /// Arguments: `(plan, targetURL, screenshot, egressPolicyOverridePath)`.
    /// The 4th argument is nil unless `Request.egressProxyURL` was set —
    /// in that case the dispatcher computes the per-target same-origin
    /// allowlist via `EgressPolicy.sameOriginAllowlist`, writes it to a
    /// temp file, and passes the path here. Production closures pass it
    /// straight through to `PlaywrightSubprocessRunner.run`; tests can
    /// assert the path is non-nil and read the file off disk.
    public typealias Runner = @Sendable ([ValidationStep], String, Bool, String?) throws -> PlaywrightResult

    /// Sink for `validation_results` rows. Production wires
    /// `SessionDatabase.shared.insertBrowserValidationResult`; tests
    /// capture into an array.
    public typealias ResultSink = @Sendable (BrowserValidationRow) -> Void

    /// Sink for chained `token_events` rows (`validation.dispatch` and
    /// `validation.fail.allow`). Production wires
    /// `SessionDatabase.shared.recordTokenEvent`; tests capture into
    /// an array.
    public typealias TokenEventSink = @Sendable (TokenEventInput) -> Void

    /// V.18a-5 — sink for the OTLP span emitted on every dispatch.
    /// Production wires `SessionDatabase.shared.runtimeTelemetryStore.
    /// insertSpan(datasetId: <active>, span:)`; tests capture into an
    /// array. Default `noopSpanSink` drops the span — keeps existing
    /// callers source-compatible while the receiver/dataset wiring
    /// stabilises across V.18b-1 / V.18b-2.
    public typealias SpanSink = @Sendable (DispatchSpan) -> Void

    /// V.18a-5 — minimal span shape emitted on dispatch. One per
    /// dispatch (not per ValidationStep) — per-step granularity is a
    /// follow-up (Majors audit: per-dispatch is sufficient for the
    /// V.18a-7 Agent Timeline badge story; per-step adds noise on a
    /// 4-axis plan). Attributes carry only metadata (axes list,
    /// result status, assertion counts) — Schneier guard, no payload.
    public struct DispatchSpan: Sendable, Equatable {
        public let validationRunId: String
        public let sessionId: String
        public let toolCallId: String
        public let traceId: String
        public let spanId: String
        public let name: String
        public let startUnixNs: Int64
        public let endUnixNs: Int64
        public let statusCode: Int  // OTLP: 0=Unset, 1=Ok, 2=Error
        public let attributesJson: String
        public init(validationRunId: String, sessionId: String, toolCallId: String, traceId: String, spanId: String, name: String, startUnixNs: Int64, endUnixNs: Int64, statusCode: Int, attributesJson: String) {
            self.validationRunId = validationRunId
            self.sessionId = sessionId
            self.toolCallId = toolCallId
            self.traceId = traceId
            self.spanId = spanId
            self.name = name
            self.startUnixNs = startUnixNs
            self.endUnixNs = endUnixNs
            self.statusCode = statusCode
            self.attributesJson = attributesJson
        }
    }

    /// Drop-the-span default. Existing callers (MCP tool + CLI) keep
    /// working until V.18b ramps the dataset selection wiring; tests
    /// override with a capturing closure.
    public static let noopSpanSink: SpanSink = { _ in }

    /// One validation_results row's worth of input data.
    public struct BrowserValidationRow: Sendable, Equatable {
        public let sessionId: String
        public let targetURL: String
        public let axes: [String]
        public let planSteps: [ValidationStep]
        public let resultStatus: String
        public let assertionsPassed: Int
        public let assertionsFailed: Int
        public let advisory: String
        public let screenshotPath: String?
        /// V.18a-5 — populated on every dispatch. Threads through to the
        /// `validation_results.validation_run_id` column so the JOIN
        /// against `runtime_telemetry_span` returns the run's spans.
        public let validationRunId: String
        /// V.18a-5 — `tool_call_id` paired with this dispatch. Sourced
        /// from caller (MCP tool / CLI) so the cross-cutting JOIN
        /// against `agent_trace_event` is keyed correctly.
        public let toolCallId: String
    }

    /// One token_events row's worth of input data.
    public struct TokenEventInput: Sendable, Equatable {
        public let sessionId: String
        public let projectRoot: String?
        public let feature: String
        public let command: String
    }

    /// Errors raised when dispatch fails before producing a structured
    /// response. The runner's `PlaywrightRunnerError.validationBrowserMissing`
    /// is caught and translated into a structured `Response` rather than
    /// thrown — operators get a uniform JSON envelope.
    public enum DispatchError: Error, Equatable {
        case invalidTargetURL(String)
        case noAxesRequested
    }

    /// Single entry point. Throws only for caller-error cases
    /// (invalid URL, empty axes); runner failure is caught and
    /// translated into a `Response` with `result_status:"fail"`.
    ///
    /// V.18a-5 — `spanSink` defaults to `noopSpanSink`, preserving
    /// existing MCP + CLI call shapes. Tests pass a capturing closure
    /// to assert the emitted span carries the dispatch's
    /// `validation_run_id` + `(session_id, tool_call_id)` tuple.
    @discardableResult
    public static func dispatch(
        request: Request,
        runner: Runner,
        headlessRunner: Runner? = nil,
        paneRunner: Runner? = nil,
        resultSink: ResultSink,
        tokenEventSink: TokenEventSink,
        spanSink: SpanSink = noopSpanSink
    ) throws -> Response {
        guard !request.axes.isEmpty else {
            throw DispatchError.noAxesRequested
        }
        guard URL(string: request.targetURL) != nil else {
            throw DispatchError.invalidTargetURL(request.targetURL)
        }

        // V.18a-5 — `validation_run_id` is generated up-front so the
        // OTLP span emit + the resultSink row + the audit token_events
        // row all reference the same id. UUID per dispatch — Schneier:
        // dispatcher-synthesized, never caller-supplied.
        let validationRunId = UUID().uuidString
        let traceId = Self.randomTraceId()
        let spanId = Self.randomSpanId()
        let startNs = Self.nowUnixNs()

        let plan = buildPlan(diff: request.diff, axes: request.axes, targetURL: request.targetURL)

        // Override-channel: when egressProxyURL is set, compute the
        // per-target same-origin allowlist and write it to a temp file.
        // The runner closure reads the path and advertises it to the
        // spawned node subprocess via SENKANI_EGRESS_POLICY_OVERRIDE.
        // Cleanup runs after the runner returns regardless of outcome.
        let overridePath = writeEgressOverridePolicyIfNeeded(request: request)
        defer {
            if let path = overridePath {
                try? FileManager.default.removeItem(atPath: path)
            }
        }

        let result: PlaywrightResult
        switch request.dispatch {
        case .subprocess:
            result = runRunner(runner, plan: plan, request: request, egressPolicyOverridePath: overridePath)
        case .headless:
            // U.2b-1b-6 — wire the off-screen WKWebView runner. The
            // headlessRunner slot is nil-by-default to preserve source
            // compatibility with callers that haven't wired it (the CLI
            // when SenkaniApp's factory isn't registered, or tests that
            // dispatch without a headless stub). When nil, fall back to
            // the structured refusal callers were wired against under
            // U.2b-1a. When non-nil, invoke through the same runRunner
            // helper so error translation + audit row shapes match the
            // subprocess arm byte-for-byte.
            if let headlessRunner {
                result = runRunner(headlessRunner, plan: plan, request: request, egressPolicyOverridePath: overridePath)
            } else {
                result = PlaywrightResult(
                    resultStatus: "fail",
                    axesRun: [],
                    assertionsPassed: 0,
                    assertionsFailed: 0,
                    screenshotPath: nil,
                    advisory: "headless_not_yet_implemented — register a BrowserDispatchRegistry.headlessRunnerFactory at app startup, or use dispatch:'subprocess'"
                )
            }
        case .pane:
            // U.2b-2 (headless seam) — wire the VISIBLE-pane runner. The
            // paneRunner slot is nil-by-default to preserve source
            // compatibility with callers that haven't wired it. SECURITY-
            // CRITICAL fail-closed contract: the ONLY way `.pane` produces
            // a non-refusal Response is via an explicitly-injected,
            // non-nil paneRunner. When non-nil, invoke through the SAME
            // runRunner helper the `.headless` and `.subprocess` arms use,
            // so error translation + audit row shapes match byte-for-byte
            // (the audit already encodes runner=wkwebview-pane via
            // dispatchMode.auditChainRunnerValue). When nil, fall back to a
            // structured `validation_browser_pane_no_runner` refusal — a
            // correctly-shaped fail Response + a validation.dispatch audit
            // row carrying runner=wkwebview-pane. NEVER a fabricated pass:
            // a missing pane runner (GUI not running / pane unavailable)
            // can only refuse, never silently approve. The `paneId`
            // selector is carried on the Request; the registered pane
            // factory resolves it against the BrowserPane registry (the
            // GUI/Cowork half).
            if let paneRunner {
                result = runRunner(paneRunner, plan: plan, request: request, egressPolicyOverridePath: overridePath)
            } else {
                result = PlaywrightResult(
                    resultStatus: "fail",
                    axesRun: [],
                    assertionsPassed: 0,
                    assertionsFailed: 0,
                    screenshotPath: nil,
                    advisory: "validation_browser_pane_no_runner — no visible pane runner registered (GUI not running / pane unavailable); register a BrowserDispatchRegistry.paneRunnerFactory, or use dispatch:'subprocess' or 'headless'"
                )
            }
        }

        let advisory = formatAdvisory(
            resultStatus: result.resultStatus,
            assertionsFailed: result.assertionsFailed,
            axesRun: result.axesRun,
            allowFailed: request.allowFailed,
            runnerAdvisory: result.advisory
        )

        let endNs = Self.nowUnixNs()
        let spanStatusCode: Int = result.resultStatus == "pass" ? 1 : 2
        let attributesJson = Self.encodeSpanAttributes(
            axesRun: result.axesRun,
            resultStatus: result.resultStatus,
            assertionsPassed: result.assertionsPassed,
            assertionsFailed: result.assertionsFailed
        )
        spanSink(DispatchSpan(
            validationRunId: validationRunId,
            sessionId: request.sessionId,
            toolCallId: request.toolCallId,
            traceId: traceId,
            spanId: spanId,
            name: "validation.dispatch",
            startUnixNs: startNs,
            endUnixNs: endNs,
            statusCode: spanStatusCode,
            attributesJson: attributesJson
        ))

        let row = BrowserValidationRow(
            sessionId: request.sessionId,
            targetURL: request.targetURL,
            axes: request.axes.map(\.rawValue),
            planSteps: plan,
            resultStatus: result.resultStatus,
            assertionsPassed: result.assertionsPassed,
            assertionsFailed: result.assertionsFailed,
            advisory: advisory,
            screenshotPath: result.screenshotPath,
            validationRunId: validationRunId,
            toolCallId: request.toolCallId
        )
        resultSink(row)

        let dispatchCmd = encodeAuditCommand(targetURL: request.targetURL, axes: request.axes,
                                              result: result, allowFailed: request.allowFailed,
                                              dispatchMode: request.dispatch)
        tokenEventSink(TokenEventInput(
            sessionId: request.sessionId,
            projectRoot: request.projectRoot,
            feature: "validation.dispatch",
            command: dispatchCmd
        ))

        if result.resultStatus == "fail" && request.allowFailed {
            let overrideCmd = encodeOverrideCommand(
                targetURL: request.targetURL,
                axes: request.axes,
                failingAxes: failingAxes(advisory: result.advisory, axesRun: result.axesRun),
                dispatchMode: request.dispatch
            )
            tokenEventSink(TokenEventInput(
                sessionId: request.sessionId,
                projectRoot: request.projectRoot,
                feature: "validation.fail.allow",
                command: overrideCmd
            ))
        }

        return Response(
            resultStatus: result.resultStatus,
            axesRun: result.axesRun,
            assertionsPassed: result.assertionsPassed,
            assertionsFailed: result.assertionsFailed,
            screenshotPath: result.screenshotPath,
            advisory: advisory,
            targetUrl: request.targetURL,
            allowFailed: request.allowFailed
        )
    }

    /// Encode the response to byte-stable JSON. MCP + CLI both call
    /// this so their stdout/result bytes are identical.
    public static func encode(_ response: Response) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(response)
    }

    // MARK: - Private

    private static func buildPlan(diff: DiffRequest?, axes: [ValidationAxes], targetURL: String) -> [ValidationStep] {
        if let diff, !diff.perFileDiff.isEmpty {
            return ValidationPlanner.plan(diff: diff, axes: axes)
        }
        // No diff supplied — emit one step per axis keyed on the target URL
        // itself so the runner still has a single "(target, axis)" pair to
        // execute against. Selector left nil (whole-page targeting); expected
        // nil (per-axis defaults from perf.swift / completeness.swift apply).
        return axes.map { axis in
            ValidationStep(
                axis: axis,
                assertionId: "\(axis.rawValue).default",
                targetPath: targetURL,
                selector: nil,
                expected: nil
            )
        }
    }

    /// Write the per-dispatch `EgressPolicy.sameOriginAllowlist(targetURL:)`
    /// to a temp JSON file in the wire format
    /// `EgressPolicy.load(from:)` reads. Returns the temp path on
    /// success, nil when `Request.egressProxyURL` is unset, the target
    /// URL is malformed, or the URL is hostless (`file://`). The caller
    /// is responsible for cleanup via `defer`.
    ///
    /// Exposed as `internal` for unit tests; production traffic goes
    /// through `dispatch(...)`.
    static func writeEgressOverridePolicyIfNeeded(request: Request) -> String? {
        guard let proxy = request.egressProxyURL, !proxy.isEmpty,
              let url = URL(string: request.targetURL),
              let policy = EgressPolicy.sameOriginAllowlist(targetURL: url) else {
            return nil
        }
        do {
            let data = try policy.encodeWireJSON()
            let dir = NSTemporaryDirectory()
            let filename = "senkani-egress-override-\(UUID().uuidString).json"
            let path = (dir as NSString).appendingPathComponent(filename)
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
            return path
        } catch {
            return nil
        }
    }

    private static func runRunner(
        _ runner: Runner,
        plan: [ValidationStep],
        request: Request,
        egressPolicyOverridePath: String?
    ) -> PlaywrightResult {
        do {
            return try runner(plan, request.targetURL, request.screenshot, egressPolicyOverridePath)
        } catch let error as PlaywrightRunnerError {
            switch error {
            case .validationBrowserMissing(let hint):
                return PlaywrightResult(
                    resultStatus: "fail",
                    axesRun: [],
                    assertionsPassed: 0,
                    assertionsFailed: 0,
                    screenshotPath: nil,
                    advisory: "validation_browser_missing — \(hint)"
                )
            case .subprocessFailed(let code, let stderr):
                return PlaywrightResult(
                    resultStatus: "fail",
                    axesRun: [],
                    assertionsPassed: 0,
                    assertionsFailed: 0,
                    screenshotPath: nil,
                    advisory: "subprocess_failed exit=\(code): \(stderr.prefix(200))"
                )
            case .decodingFailed(let detail):
                return PlaywrightResult(
                    resultStatus: "fail",
                    axesRun: [],
                    assertionsPassed: 0,
                    assertionsFailed: 0,
                    screenshotPath: nil,
                    advisory: "decoding_failed: \(detail.prefix(200))"
                )
            }
        } catch {
            return PlaywrightResult(
                resultStatus: "fail",
                axesRun: [],
                assertionsPassed: 0,
                assertionsFailed: 0,
                screenshotPath: nil,
                advisory: "runner_error: \(error)"
            )
        }
    }

    /// Build the advisory text shown to the agent. Schneier side-channel
    /// guard: this text NEVER carries the failed assertion's payload —
    /// only the axis name(s), counts, and operator hint.
    private static func formatAdvisory(
        resultStatus: String,
        assertionsFailed: Int,
        axesRun: [String],
        allowFailed: Bool,
        runnerAdvisory: String?
    ) -> String {
        if resultStatus == "pass" {
            return "browser_validation_passed: axes=\(axesRun.sorted().joined(separator: ","))"
        }
        if resultStatus == "partial" {
            let advisory = runnerAdvisory.map { ": \($0.prefix(200))" } ?? ""
            return "browser_validation_partial: failed=\(assertionsFailed) axes=\(axesRun.sorted().joined(separator: ","))\(advisory)"
        }
        // fail
        var advisory = "browser_validation_failed: failed=\(assertionsFailed) axes=\(axesRun.sorted().joined(separator: ","))"
        if let runner = runnerAdvisory, !runner.isEmpty {
            advisory += " — \(runner.prefix(200))"
        }
        advisory += allowFailed
            ? " (allow_failed override active — validation.fail.allow chained row written)"
            : " (override_hint: pass allow_failed:true to bypass)"
        return advisory
    }

    private static func encodeAuditCommand(
        targetURL: String,
        axes: [ValidationAxes],
        result: PlaywrightResult,
        allowFailed: Bool,
        dispatchMode: BrowserDispatchMode
    ) -> String {
        let axesStr = axes.map(\.rawValue).sorted().joined(separator: ",")
        return "validate_browser url=\(targetURL) axes=\(axesStr) status=\(result.resultStatus) passed=\(result.assertionsPassed) failed=\(result.assertionsFailed) allow_failed=\(allowFailed) runner=\(dispatchMode.auditChainRunnerValue)"
    }

    private static func encodeOverrideCommand(
        targetURL: String,
        axes: [ValidationAxes],
        failingAxes: [String],
        dispatchMode: BrowserDispatchMode
    ) -> String {
        let axesStr = axes.map(\.rawValue).sorted().joined(separator: ",")
        let failing = failingAxes.sorted().joined(separator: ",")
        return "validate_browser_override url=\(targetURL) axes=\(axesStr) failing_axes=\(failing) runner=\(dispatchMode.auditChainRunnerValue)"
    }

    /// V.18a-5 — current Unix-epoch nanoseconds. Bridges `Date`'s
    /// double-precision seconds onto the integer Ns precision the
    /// runtime_telemetry_span schema stores. Sufficient for sub-ms
    /// span ordering on the dispatch surface.
    private static func nowUnixNs() -> Int64 {
        return Int64(Date().timeIntervalSince1970 * 1_000_000_000)
    }

    /// V.18a-5 — 32-char hex trace id (16-byte OTLP). Random — no
    /// caller-controllable input.
    private static func randomTraceId() -> String {
        var out = ""
        out.reserveCapacity(32)
        for _ in 0..<16 {
            out += String(format: "%02x", UInt8.random(in: 0...255))
        }
        return out
    }

    /// V.18a-5 — 16-char hex span id (8-byte OTLP). Random.
    private static func randomSpanId() -> String {
        var out = ""
        out.reserveCapacity(16)
        for _ in 0..<8 {
            out += String(format: "%02x", UInt8.random(in: 0...255))
        }
        return out
    }

    /// V.18a-5 — byte-stable attributes JSON for the dispatch span.
    /// Schneier guard: NO assertion payloads, only metadata
    /// (axes list, result status, counts). `[.sortedKeys]` so two
    /// dispatches with the same axes set encode byte-identically.
    private static func encodeSpanAttributes(
        axesRun: [String],
        resultStatus: String,
        assertionsPassed: Int,
        assertionsFailed: Int
    ) -> String {
        struct Attrs: Encodable {
            let axes_run: [String]
            let result_status: String
            let assertions_passed: Int
            let assertions_failed: Int
        }
        let attrs = Attrs(
            axes_run: axesRun.sorted(),
            result_status: resultStatus,
            assertions_passed: assertionsPassed,
            assertions_failed: assertionsFailed
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(attrs),
              let str = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return str
    }

    private static func failingAxes(advisory: String?, axesRun: [String]) -> [String] {
        // Best-effort: when the runner's advisory mentions specific axes, use
        // those; otherwise fall back to the full axesRun set. The audit row's
        // job is observability — exact extraction matters less than the
        // record existing.
        guard let advisory else { return axesRun }
        var hits: [String] = []
        for axis in axesRun where advisory.lowercased().contains(axis.lowercased()) {
            hits.append(axis)
        }
        return hits.isEmpty ? axesRun : hits
    }
}
