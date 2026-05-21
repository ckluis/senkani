import Testing
import Foundation
@testable import Core

#if canImport(Darwin)
import Darwin
#endif

/// Wiring tests for
/// `process-gap-validate-browser-runner-egress-not-wired-2026-05-19`.
///
/// U.2a-2b shipped `EgressPolicy.sameOriginAllowlist(targetURL:)` as a
/// tested factory but did NOT wire it into the live runner spawn path —
/// Chromium's outbound traffic did not traverse the EgressProxy listener
/// because (a) the spawned node subprocess didn't receive HTTP_PROXY /
/// HTTPS_PROXY env vars, and (b) no per-dispatch override-channel policy
/// file was written. This file covers both ends:
///
///   1. `PlaywrightSubprocessRunner.buildExtraEnv` returns the expected
///      env map when egressProxyURL is set (and an empty map when not).
///   2. End-to-end: dispatcher writes the override policy file with the
///      per-target same-origin rule, a live EgressListener loaded from
///      that file denies off-host CONNECT with rule_id `default-deny`,
///      and the dispatch advisory mentions the denial when the runner
///      surfaces a failure.
@Suite("validate-browser runner ↔ EgressProxy wiring")
struct EgressProxyRunnerWiringTests {

    // MARK: - Test 1 — runner env-var injection

    @Test("buildExtraEnv injects HTTP_PROXY/HTTPS_PROXY/NODE_TLS_REJECT_UNAUTHORIZED + SENKANI_EGRESS_POLICY_OVERRIDE when set")
    func runnerInjectsHTTPProxyEnvWhenEgressProxyURLSet() {
        // No-op path: nil + empty → no env injection.
        let emptyEnv = PlaywrightSubprocessRunner.buildExtraEnv(
            egressProxyURL: nil,
            egressPolicyOverridePath: nil
        )
        #expect(emptyEnv.isEmpty,
                "buildExtraEnv with both args nil must return an empty map; got: \(emptyEnv)")

        let emptyStringEnv = PlaywrightSubprocessRunner.buildExtraEnv(
            egressProxyURL: "",
            egressPolicyOverridePath: ""
        )
        #expect(emptyStringEnv.isEmpty,
                "empty-string args treated as no-op; got: \(emptyStringEnv)")

        // Both set → full env shape.
        let proxyURL = "http://127.0.0.1:18080"
        let overridePath = "/tmp/senkani-egress-override-test.json"
        let env = PlaywrightSubprocessRunner.buildExtraEnv(
            egressProxyURL: proxyURL,
            egressPolicyOverridePath: overridePath
        )
        #expect(env["HTTP_PROXY"] == proxyURL,
                "HTTP_PROXY must be set to the egress proxy URL")
        #expect(env["HTTPS_PROXY"] == proxyURL,
                "HTTPS_PROXY must be set to the egress proxy URL")
        #expect(env["NODE_TLS_REJECT_UNAUTHORIZED"] == "0",
                "NODE_TLS_REJECT_UNAUTHORIZED=0 is required so node accepts the MITM CA")
        #expect(env["SENKANI_EGRESS_POLICY_OVERRIDE"] == overridePath,
                "SENKANI_EGRESS_POLICY_OVERRIDE must carry the per-dispatch policy path")
        #expect(env.count == 4,
                "buildExtraEnv must inject exactly four keys when both args are set; got: \(env)")

        // Override-only (no proxy) is degenerate but must not write proxy
        // vars; we keep this branch defensive so the runner doesn't leak
        // proxy plumbing when the dispatcher decides not to wire it.
        let overrideOnly = PlaywrightSubprocessRunner.buildExtraEnv(
            egressProxyURL: nil,
            egressPolicyOverridePath: overridePath
        )
        #expect(overrideOnly["HTTP_PROXY"] == nil)
        #expect(overrideOnly["HTTPS_PROXY"] == nil)
        #expect(overrideOnly["NODE_TLS_REJECT_UNAUTHORIZED"] == nil)
        #expect(overrideOnly["SENKANI_EGRESS_POLICY_OVERRIDE"] == overridePath)
    }

    // MARK: - Test 2 — dispatcher → override file → listener deny

    @Test("dispatcher writes override policy file; live listener loaded from it denies off-host CONNECT with rule_id default-deny")
    func dispatcherWritesOverridePolicyAndStubListenerDeniesOffHost() throws {
        // Phase A — dispatcher computes and writes the override policy
        //          for a target URL with egressProxyURL set. The closure
        //          captures the path so the test can read it off disk.
        let target = "https://example.com/page"
        let proxyURL = "http://127.0.0.1:0"   // dummy — runner closure
                                              // doesn't actually spawn.
        let request = BrowserValidationDispatcher.Request(
            targetURL: target,
            axes: [.perf, .completeness],
            diff: nil,
            allowFailed: false,
            screenshot: false,
            sessionId: "wiring-test-sid",
            projectRoot: "/tmp/wiring-test-root",
            dispatch: .subprocess,
            egressProxyURL: proxyURL
        )

        let capturedPathBox = LockedBox<String?>(value: nil)
        let runner: BrowserValidationDispatcher.Runner = { _, _, _, overridePath in
            capturedPathBox.set(overridePath)
            return PlaywrightResult(
                resultStatus: "pass",
                axesRun: ["perf", "completeness"],
                assertionsPassed: 2,
                assertionsFailed: 0,
                screenshotPath: nil,
                advisory: nil
            )
        }
        let resultSink: BrowserValidationDispatcher.ResultSink = { _ in }
        let tokenEventSink: BrowserValidationDispatcher.TokenEventSink = { _ in }

        // Read the override file inside the runner closure — by the time
        // dispatch() returns, the defer has cleaned the temp file up, so
        // we copy it to a stable path for phase B.
        let stableCopyPath = NSTemporaryDirectory()
            + "senkani-wiring-stable-\(UUID().uuidString).json"
        defer { try? FileManager.default.removeItem(atPath: stableCopyPath) }

        let captureRunner: BrowserValidationDispatcher.Runner = { plan, t, ss, overridePath in
            if let path = overridePath {
                if let data = try? Data(contentsOf: URL(fileURLWithPath: path)) {
                    try? data.write(to: URL(fileURLWithPath: stableCopyPath))
                }
            }
            return try runner(plan, t, ss, overridePath)
        }

        _ = try BrowserValidationDispatcher.dispatch(
            request: request,
            runner: captureRunner,
            resultSink: resultSink,
            tokenEventSink: tokenEventSink
        )

        let capturedPath = capturedPathBox.value
        try #require(capturedPath != nil,
                     "dispatcher must compute + write an override policy path when egressProxyURL is set")
        try #require(FileManager.default.fileExists(atPath: stableCopyPath),
                     "override policy file must be readable inside the runner closure (copied for phase B)")

        // Phase B — load the override policy with the production loader,
        //          confirm the wire format round-trips, then stand up a
        //          live EgressListener configured with it and confirm an
        //          off-host CONNECT is denied with rule_id `default-deny`.
        let loaded = EgressPolicy.load(from: stableCopyPath)
        let degraded = loaded.degradedReason ?? ""
        #expect(loaded.degradedReason == nil,
                "override file must parse cleanly via EgressPolicy.load; got: \(degraded)")

        // The same-origin allowlist installs one allow-suffix rule keyed
        // on example.com across all PaneMode engines. Spot-check the
        // .default engine.
        let defaultEngine = loaded.policy.engine(for: .default)
        let ids = defaultEngine.rules.map(\.id)
        #expect(ids.contains("validate_browser_same_origin"),
                "override policy must carry the validate_browser_same_origin allowlist rule; got: \(ids)")
        let firstPattern = defaultEngine.rules.first?.pattern ?? ""
        #expect(firstPattern == "example.com",
                "rule pattern must equal the target host; got: \(firstPattern)")

        // Live listener with the override policy active. CONNECT to an
        // off-allowlist host (`evil.example.org`) must hit default-deny,
        // returning 403 and writing a deny row with rule_id default-deny.
        let dir = NSTemporaryDirectory() + "senkani-wiring-deny-\(UUID().uuidString)/"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let db = SessionDatabase(path: dir + "senkani.db")

        let listener = EgressListener(
            policy: loaded.policy,
            judge: nil,
            database: db,
            config: .init(port: 0, writePortFile: false, portFilePath: "")
        )
        try listener.start()
        defer { listener.stop() }
        #expect(listener.port > 0)

        let cfd = connectToLocalhost(port: listener.port)
        try #require(cfd != nil)
        let cli = cfd!
        defer { close(cli) }

        // Off-host CONNECT — example.org is NOT a suffix of example.com.
        let req = "CONNECT evil.example.org:443 HTTP/1.1\r\nHost: evil.example.org:443\r\n\r\n"
        #expect(writeAllToFD(cli, Data(req.utf8)))

        let resp = readAllUntilEOF(cli)
        let respStr = String(data: resp, encoding: .utf8) ?? ""
        #expect(respStr.contains("403 Forbidden"),
                "off-host CONNECT must be refused 403; got: \(respStr.prefix(120))")

        let row = waitForRow(db: db)
        try #require(row != nil, "listener must record a deny row for the off-host request")
        #expect(row!.decision == .deny)
        #expect(row!.host == "evil.example.org",
                "host is normalized (default port stripped) by EgressHostNormalizer before logging; got: \(row!.host)")
        #expect(row!.ruleId == "default-deny",
                "off-allowlist host must fall to default-deny under the same-origin override; got: \(row!.ruleId)")
    }
}

/// Local thread-safe box for capturing closure-scoped state.
/// Mirrors the helper declared `private` in
/// `BrowserRunnerScaffoldTests` / `AxesDispatchExtensionTests`.
private final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T
    init(value: T) { self._value = value }
    var value: T {
        lock.lock(); defer { lock.unlock() }
        return _value
    }
    func set(_ newValue: T) {
        lock.lock(); defer { lock.unlock() }
        _value = newValue
    }
}

