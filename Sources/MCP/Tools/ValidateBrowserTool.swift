import Foundation
import MCP
import Core

/// `senkani_validate_browser` MCP tool handler (U.2a-2b).
///
/// Drives `BrowserValidationDispatcher.dispatch` over the live
/// `PlaywrightSubprocessRunner` (or the missing-Chromium refusal path
/// if the cache is absent). Output bytes are produced by
/// `BrowserValidationDispatcher.encode` so MCP and CLI surfaces are
/// byte-identical for the same input plan (parity test).
enum ValidateBrowserTool {
    static func handle(arguments: [String: Value]?, session: MCPSession) async -> CallTool.Result {
        guard let url = arguments?["target_url"]?.stringValue, !url.isEmpty else {
            return .init(
                content: [.text(text: "Error: 'target_url' is required", annotations: nil, _meta: nil)],
                isError: true
            )
        }
        let axes = parseAxes(arguments?["axes"])
        let allowFailed = arguments?["allow_failed"]?.boolValue ?? false
        let screenshot = arguments?["screenshot"]?.boolValue ?? true
        let diff: DiffRequest? = parseDiff(arguments?["diff_target"]?.stringValue, projectRoot: session.projectRoot)

        let dispatchMode: BrowserDispatchMode
        if let parsed = parseDispatch(arguments?["dispatch"]?.stringValue) {
            dispatchMode = parsed
        } else {
            return .init(
                content: [.text(text: "Error: dispatch must be 'subprocess' or 'headless'", annotations: nil, _meta: nil)],
                isError: true
            )
        }

        let egressProxyURL = arguments?["egress_proxy_url"]?.stringValue

        let request = BrowserValidationDispatcher.Request(
            targetURL: url,
            axes: axes,
            diff: diff,
            allowFailed: allowFailed,
            screenshot: screenshot,
            sessionId: session.sessionId ?? "mcp-validate-browser",
            projectRoot: session.projectRoot,
            dispatch: dispatchMode,
            egressProxyURL: egressProxyURL
        )

        let runner = PlaywrightSubprocessRunner(egressProxyURL: egressProxyURL)
        let runnerClosure: BrowserValidationDispatcher.Runner = { plan, target, screenshot, overridePath in
            try runner.run(plan: plan, targetURL: target, screenshot: screenshot,
                           egressPolicyOverridePath: overridePath)
        }
        // U.2b-1b-6 — look up the off-screen WKWebView runner factory the
        // host (SenkaniApp at startup) may have registered. When the MCP
        // server is hosted in SenkaniApp the factory is present and
        // `.headless` dispatches drive the real BrowserPaneRunner. When
        // hosted standalone (senkani-mcp binary) the factory is nil and
        // the dispatcher falls back to the structured refusal.
        let headlessClosure: BrowserValidationDispatcher.Runner? =
            BrowserDispatchRegistry.makeHeadlessRunnerClosure(egressProxyURL: egressProxyURL)
        let db = SessionDatabase.shared
        let resultSink: BrowserValidationDispatcher.ResultSink = { row in
            let planJSON = encodePlanSteps(row.planSteps)
            db.insertBrowserValidationResult(
                sessionId: row.sessionId,
                targetURL: row.targetURL,
                axes: row.axes,
                planStepsJSON: planJSON,
                resultStatus: row.resultStatus,
                assertionsPassed: row.assertionsPassed,
                assertionsFailed: row.assertionsFailed,
                advisory: row.advisory,
                screenshotPath: row.screenshotPath,
                validationRunId: row.validationRunId
            )
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

        let response: BrowserValidationDispatcher.Response
        do {
            response = try BrowserValidationDispatcher.dispatch(
                request: request,
                runner: runnerClosure,
                headlessRunner: headlessClosure,
                resultSink: resultSink,
                tokenEventSink: tokenEventSink
            )
        } catch {
            return .init(
                content: [.text(text: "Error: \(error)", annotations: nil, _meta: nil)],
                isError: true
            )
        }

        let bodyData = (try? BrowserValidationDispatcher.encode(response)) ?? Data()
        let body = String(data: bodyData, encoding: .utf8) ?? "{}"
        return .init(
            content: [.text(text: body, annotations: nil, _meta: nil)],
            isError: response.resultStatus == "fail" && !request.allowFailed
        )
    }

    /// Parse the `axes` argument. Accepts an array of strings, a single
    /// string ("perf,completeness"), or omitted (defaults to all four).
    private static func parseAxes(_ value: Value?) -> [ValidationAxes] {
        let all = ValidationAxes.allCases
        guard let value else { return all }
        switch value {
        case .array(let arr):
            let names = arr.compactMap { $0.stringValue }
            let parsed = names.compactMap { ValidationAxes(rawValue: $0) }
            return parsed.isEmpty ? all : parsed
        case .string(let s):
            let parts = s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            let parsed = parts.compactMap { ValidationAxes(rawValue: $0) }
            return parsed.isEmpty ? all : parsed
        default:
            return all
        }
    }

    /// Parse the `dispatch` argument. Omitted → `.subprocess`. Unknown
    /// values return nil; the handler turns nil into a structured
    /// `invalidArguments`-shaped Response.
    private static func parseDispatch(_ raw: String?) -> BrowserDispatchMode? {
        guard let raw, !raw.isEmpty else { return .subprocess }
        return BrowserDispatchMode(rawValue: raw)
    }

    /// Parse the `diff_target` argument. Empty or unrecognized values
    /// produce nil (the dispatcher then targets the URL itself with one
    /// step per axis).
    private static func parseDiff(_ raw: String?, projectRoot: String) -> DiffRequest? {
        guard let raw, !raw.isEmpty,
              let selector = DiffSelector(rawValue: raw) else { return nil }
        // For the build-round contract we don't shell out to `git diff`
        // here; an empty perFileDiff plus a real selector still produces
        // a one-step-per-axis plan via the dispatcher's fallback. U.3
        // (autorun) wires a real diff producer when per-task validation
        // gates land.
        return DiffRequest(selector: selector, perFileDiff: [:])
    }

    /// Encode a `[ValidationStep]` plan to a byte-stable JSON string for
    /// the `validation_results.plan_steps` column.
    private static func encodePlanSteps(_ steps: [ValidationStep]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(steps),
              let str = String(data: data, encoding: .utf8) else { return "[]" }
        return str
    }
}
