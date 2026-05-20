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
        /// closure as before; `.headless` short-circuits to a structured
        /// `headless_not_yet_implemented` refusal until U.2b-1b lands the
        /// off-screen WKWebView runner.
        public let dispatch: BrowserDispatchMode

        public init(
            targetURL: String,
            axes: [ValidationAxes],
            diff: DiffRequest?,
            allowFailed: Bool,
            screenshot: Bool,
            sessionId: String,
            projectRoot: String?,
            dispatch: BrowserDispatchMode = .subprocess
        ) {
            self.targetURL = targetURL
            self.axes = axes
            self.diff = diff
            self.allowFailed = allowFailed
            self.screenshot = screenshot
            self.sessionId = sessionId
            self.projectRoot = projectRoot
            self.dispatch = dispatch
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
    public typealias Runner = @Sendable ([ValidationStep], String, Bool) throws -> PlaywrightResult

    /// Sink for `validation_results` rows. Production wires
    /// `SessionDatabase.shared.insertBrowserValidationResult`; tests
    /// capture into an array.
    public typealias ResultSink = @Sendable (BrowserValidationRow) -> Void

    /// Sink for chained `token_events` rows (`validation.dispatch` and
    /// `validation.fail.allow`). Production wires
    /// `SessionDatabase.shared.recordTokenEvent`; tests capture into
    /// an array.
    public typealias TokenEventSink = @Sendable (TokenEventInput) -> Void

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
    @discardableResult
    public static func dispatch(
        request: Request,
        runner: Runner,
        resultSink: ResultSink,
        tokenEventSink: TokenEventSink
    ) throws -> Response {
        guard !request.axes.isEmpty else {
            throw DispatchError.noAxesRequested
        }
        guard URL(string: request.targetURL) != nil else {
            throw DispatchError.invalidTargetURL(request.targetURL)
        }

        let plan = buildPlan(diff: request.diff, axes: request.axes, targetURL: request.targetURL)
        let result: PlaywrightResult
        switch request.dispatch {
        case .subprocess:
            result = runRunner(runner, plan: plan, request: request)
        case .headless:
            // U.2b-1a scaffold — no off-screen WKWebView yet. Skip the
            // runner closure entirely and synthesize a structured
            // refusal. U.2b-1b replaces this branch with the real
            // headless runner.
            result = PlaywrightResult(
                resultStatus: "fail",
                axesRun: [],
                assertionsPassed: 0,
                assertionsFailed: 0,
                screenshotPath: nil,
                advisory: "headless_not_yet_implemented — landing in U.2b-1b; use dispatch:'subprocess' for now"
            )
        }

        let advisory = formatAdvisory(
            resultStatus: result.resultStatus,
            assertionsFailed: result.assertionsFailed,
            axesRun: result.axesRun,
            allowFailed: request.allowFailed,
            runnerAdvisory: result.advisory
        )

        let row = BrowserValidationRow(
            sessionId: request.sessionId,
            targetURL: request.targetURL,
            axes: request.axes.map(\.rawValue),
            planSteps: plan,
            resultStatus: result.resultStatus,
            assertionsPassed: result.assertionsPassed,
            assertionsFailed: result.assertionsFailed,
            advisory: advisory,
            screenshotPath: result.screenshotPath
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

    private static func runRunner(_ runner: Runner, plan: [ValidationStep], request: Request) -> PlaywrightResult {
        do {
            return try runner(plan, request.targetURL, request.screenshot)
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
