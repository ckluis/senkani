import Testing
import Foundation
import MCP
@testable import Core
@testable import MCPServer

/// U.2b-1a — BrowserRunner protocol + BrowserDispatchMode enum +
/// audit-chain `runner=` field + MCP/CLI dispatch arg scaffold.
///
/// Five tests, one per acceptance bullet group. The headless dispatch
/// arm doesn't allocate an off-screen WKWebView — that lands in
/// U.2b-1b. This round verifies the contract + the structured
/// `headless_not_yet_implemented` refusal that callers wire against.
@Suite("U.2b-1a — BrowserRunner protocol scaffold")
struct BrowserRunnerScaffoldTests {

    // MARK: - Test 1: protocol conformance

    @Test("PlaywrightSubprocessRunner conforms to BrowserRunner; protocol signature compiles")
    func browserRunnerProtocolConformance() {
        // Compile-time check: PlaywrightSubprocessRunner is usable as
        // `any BrowserRunner`. Point its chromium cache at a path
        // guaranteed not to exist so calling `.run` would refuse with
        // `validationBrowserMissing` — but the conformance check itself
        // is purely about the type system.
        let missingCache = "/tmp/senkani-pwr-cache-missing-\(UUID().uuidString)"
        let concrete = PlaywrightSubprocessRunner(chromiumCachePath: missingCache)
        let asProtocol: any BrowserRunner = concrete
        #expect(asProtocol is PlaywrightSubprocessRunner,
                "PlaywrightSubprocessRunner must be passable as any BrowserRunner")

        // Calling the protocol method with the protocol-signature labels
        // (`targetURL:screenshot:`) must compile + dispatch to the
        // concrete refusal path.
        do {
            _ = try asProtocol.run(plan: [], targetURL: "https://example.com", screenshot: false)
            Issue.record("expected validationBrowserMissing; runner returned without throwing")
        } catch let error as PlaywrightRunnerError {
            #expect(error == .validationBrowserMissing(installHint: "senkani doctor --install-validation-browser"),
                    "protocol dispatch must reach the concrete refusal path")
        } catch {
            Issue.record("expected PlaywrightRunnerError.validationBrowserMissing; got \(error)")
        }
    }

    // MARK: - Test 2: BrowserDispatchMode round-trip

    @Test("BrowserDispatchMode round-trips as 'subprocess'/'headless'/'pane'; unknown values rejected; three audit-chain runner values")
    func browserDispatchModeRoundTrip() throws {
        // Raw-value round trip.
        #expect(BrowserDispatchMode.subprocess.rawValue == "subprocess")
        #expect(BrowserDispatchMode.headless.rawValue == "headless")
        #expect(BrowserDispatchMode.pane.rawValue == "pane")
        #expect(BrowserDispatchMode(rawValue: "subprocess") == .subprocess)
        #expect(BrowserDispatchMode(rawValue: "headless") == .headless)

        // U.2b-2 child (a) — `.pane` is now the third valid case (the
        // visible-pane runner selector). Until child (b) wires pane
        // execution, the dispatcher's `.pane` arm refuses with a
        // structured validation_browser_pane_not_yet_wired Response.
        #expect(BrowserDispatchMode(rawValue: "pane") == .pane,
                "pane is now accepted (U.2b-2 child (a)); the enum carries three cases")
        #expect(BrowserDispatchMode(rawValue: "unknown") == nil)
        #expect(BrowserDispatchMode(rawValue: "") == nil)
        // Case-sensitive parse — capitalized variants are rejected.
        #expect(BrowserDispatchMode(rawValue: "Pane") == nil)

        // CaseIterable now enumerates exactly the three closed values.
        #expect(BrowserDispatchMode.allCases == [.subprocess, .headless, .pane])

        // Audit-chain field values: subprocess/headless/pane each get a
        // distinct `runner=` value so observability rows distinguish the
        // node-subprocess path, the off-screen WKWebView path, and the
        // visible-pane path. These three are the closed set the
        // audit-chain `runner` field carries (no row schema change).
        #expect(BrowserDispatchMode.subprocess.auditChainRunnerValue == "subprocess")
        #expect(BrowserDispatchMode.headless.auditChainRunnerValue == "wkwebview-headless")
        #expect(BrowserDispatchMode.pane.auditChainRunnerValue == "wkwebview-pane")
        // All three are distinct — no collision in the runner column.
        let runnerValues = Set(BrowserDispatchMode.allCases.map(\.auditChainRunnerValue))
        #expect(runnerValues.count == 3, "the three runner values must be distinct")

        // Codable round trip — all three cases.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let subprocessData = try encoder.encode(BrowserDispatchMode.subprocess)
        let headlessData = try encoder.encode(BrowserDispatchMode.headless)
        let paneData = try encoder.encode(BrowserDispatchMode.pane)
        #expect(String(data: subprocessData, encoding: .utf8) == "\"subprocess\"")
        #expect(String(data: headlessData, encoding: .utf8) == "\"headless\"")
        #expect(String(data: paneData, encoding: .utf8) == "\"pane\"")

        let decoder = JSONDecoder()
        #expect(try decoder.decode(BrowserDispatchMode.self, from: subprocessData) == .subprocess)
        #expect(try decoder.decode(BrowserDispatchMode.self, from: headlessData) == .headless)
        #expect(try decoder.decode(BrowserDispatchMode.self, from: paneData) == .pane)
    }

    // MARK: - Test 3: audit-chain runner field (subprocess path)

    @Test("dispatch with subprocess runner writes validation.dispatch row whose command contains runner=subprocess")
    func auditChainRunnerFieldSubprocess() throws {
        let evSink = LockedArray<BrowserValidationDispatcher.TokenEventInput>()
        let resultSink: BrowserValidationDispatcher.ResultSink = { _ in }
        let runner: BrowserValidationDispatcher.Runner = { _, _, _, _ in
            PlaywrightResult(
                resultStatus: "pass",
                axesRun: ["perf", "completeness"],
                assertionsPassed: 4,
                assertionsFailed: 0,
                screenshotPath: "/tmp/audit-runner-field.png",
                advisory: nil
            )
        }
        let request = BrowserValidationDispatcher.Request(
            targetURL: "https://example.com/page",
            axes: [.perf, .completeness],
            diff: nil,
            allowFailed: false,
            screenshot: true,
            sessionId: "sid-u2b-1a-subprocess",
            projectRoot: "/tmp/u2b-1a-subprocess",
            dispatch: .subprocess
        )
        _ = try BrowserValidationDispatcher.dispatch(
            request: request,
            runner: runner,
            resultSink: resultSink,
            tokenEventSink: { evSink.append($0) }
        )

        let events = evSink.snapshot()
        #expect(events.count == 1, "subprocess pass should write exactly one validation.dispatch row; got \(events.count)")
        let dispatchRow = events.first!
        #expect(dispatchRow.feature == "validation.dispatch")
        #expect(dispatchRow.command.contains("runner=subprocess"),
                "audit command must include runner=subprocess; got: \(dispatchRow.command)")
        #expect(dispatchRow.command.contains("allow_failed=false"),
                "audit command must preserve allow_failed= prefix; got: \(dispatchRow.command)")
        // Field order: runner= appended after allow_failed=, preserving
        // prefix compatibility with the v22 ValidationStore command shape.
        if let allowIdx = dispatchRow.command.range(of: "allow_failed=")?.lowerBound,
           let runnerIdx = dispatchRow.command.range(of: "runner=")?.lowerBound {
            #expect(allowIdx < runnerIdx, "runner= must come after allow_failed= in the command string")
        } else {
            Issue.record("command missing allow_failed= or runner= field; got: \(dispatchRow.command)")
        }
    }

    // MARK: - Test 4: headless dispatch returns structured refusal + audit row
    // U.2b-1b-6 — refusal path is now gated on whether a headlessRunner is
    // wired. With no headlessRunner (the default), the dispatcher still
    // produces the structured headless_not_yet_implemented refusal so
    // standalone CLI invocations that never load SenkaniApp keep working.

    @Test("dispatch:.headless with no headlessRunner returns structured refusal; audit row carries runner=wkwebview-headless")
    func mcpDispatchHeadlessReturnsStructuredRefusal() throws {
        let evSink = LockedArray<BrowserValidationDispatcher.TokenEventInput>()
        let rowSink = LockedArray<BrowserValidationDispatcher.BrowserValidationRow>()
        let runnerCalled = LockedBox(value: false)
        let runner: BrowserValidationDispatcher.Runner = { _, _, _, _ in
            runnerCalled.set(true)
            Issue.record("headless path must NOT invoke the subprocess runner closure")
            return PlaywrightResult(
                resultStatus: "pass",
                axesRun: [],
                assertionsPassed: 0,
                assertionsFailed: 0,
                screenshotPath: nil,
                advisory: nil
            )
        }
        let request = BrowserValidationDispatcher.Request(
            targetURL: "https://example.com/headless",
            axes: [.perf, .completeness, .security, .design],
            diff: nil,
            allowFailed: false,
            screenshot: true,
            sessionId: "sid-u2b-1a-headless",
            projectRoot: "/tmp/u2b-1a-headless",
            dispatch: .headless
        )
        let response = try BrowserValidationDispatcher.dispatch(
            request: request,
            runner: runner,
            resultSink: { rowSink.append($0) },
            tokenEventSink: { evSink.append($0) }
        )

        #expect(runnerCalled.get() == false,
                "headless dispatch must short-circuit before invoking the subprocess runner closure")
        #expect(response.resultStatus == "fail",
                "headless arm with no headlessRunner falls back to result_status:fail")
        #expect(response.advisory.contains("headless_not_yet_implemented"),
                "response advisory must carry headless_not_yet_implemented; got: \(response.advisory)")
        #expect(response.advisory.contains("BrowserDispatchRegistry.headlessRunnerFactory") || response.advisory.contains("U.2b-1b"),
                "advisory must point operators at the registry (post U.2b-1b-6) or at U.2b-1b (pre); got: \(response.advisory)")
        #expect(response.screenshotPath == nil,
                "headless refusal writes no screenshot")

        let events = evSink.snapshot()
        #expect(events.count == 1,
                "headless dispatch (allow_failed:false) writes exactly one validation.dispatch row; got \(events.count)")
        let dispatchRow = events.first!
        #expect(dispatchRow.feature == "validation.dispatch")
        #expect(dispatchRow.command.contains("runner=wkwebview-headless"),
                "audit command must record runner=wkwebview-headless; got: \(dispatchRow.command)")
        #expect(dispatchRow.command.contains("status=fail"),
                "audit command must record status=fail for the refused dispatch; got: \(dispatchRow.command)")

        // validation_results row also recorded with status=fail.
        let rows = rowSink.snapshot()
        #expect(rows.count == 1)
        #expect(rows.first?.resultStatus == "fail")
    }

    // MARK: - Test 5: invalid dispatch value refused (MCP + CLI)

    @Test("MCP dispatch:'foo' returns structured invalidArguments refusal; BrowserDispatchMode rejects unknown raws (CLI parity)")
    func cliDispatchInvalidValueRefuses() async {
        // MCP path: invoke the tool handler with dispatch:'foo'. The
        // handler parses args BEFORE any subprocess or DB call, so the
        // refusal path returns early with isError=true and the canonical
        // error message.
        let session = MCPSession(
            projectRoot: "/tmp/u2b-1a-dispatch-invalid-\(UUID().uuidString)",
            filterEnabled: false, secretsEnabled: false, indexerEnabled: false,
            cacheEnabled: false, terseEnabled: false, injectionGuardEnabled: false,
            sessionId: nil, paneId: nil
        )
        let args: [String: Value] = [
            "target_url": .string("https://example.com"),
            "dispatch": .string("foo"),
        ]
        let result = await ValidateBrowserTool.handle(arguments: args, session: session)
        #expect(result.isError == true,
                "invalid dispatch must return isError=true")
        let text = result.content.compactMap { content -> String? in
            if case let .text(text: t, annotations: _, _meta: _) = content { return t } else { return nil }
        }.joined()
        #expect(text.contains("dispatch must be 'subprocess', 'headless', or 'pane'"),
                "refusal message must enumerate the three accepted values; got: \(text)")

        // CLI parity: the CLI's `--dispatch foo` parsing routes through
        // the same `BrowserDispatchMode(rawValue:)` initializer and
        // emits the same error message before invoking the dispatcher.
        // Validate the enum-level contract that backs both surfaces.
        #expect(BrowserDispatchMode(rawValue: "foo") == nil,
                "BrowserDispatchMode must reject 'foo' so both MCP and CLI refuse with the structured message")
        #expect(BrowserDispatchMode(rawValue: "Subprocess") == nil,
                "raw-value parse is case-sensitive — 'Subprocess' is not 'subprocess'")
        // U.2b-2 child (a) — 'pane' is now a VALID dispatch value (does
        // not trip the invalidArguments refusal). The MCP handler accepts
        // it and routes to the dispatcher's .pane refusal arm instead.
        #expect(BrowserDispatchMode(rawValue: "pane") == .pane,
                "'pane' must be accepted by the parser now (U.2b-2 child (a))")
    }
}

// MARK: - test helpers

private final class LockedArray<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [T] = []
    func append(_ item: T) { lock.lock(); defer { lock.unlock() }; items.append(item) }
    func snapshot() -> [T] { lock.lock(); defer { lock.unlock() }; return items }
}

private final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(value: T) { self.value = value }
    func set(_ v: T) { lock.lock(); defer { lock.unlock() }; value = v }
    func get() -> T { lock.lock(); defer { lock.unlock() }; return value }
}
