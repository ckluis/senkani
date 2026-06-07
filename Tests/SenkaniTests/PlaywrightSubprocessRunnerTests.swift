import Testing
import Foundation
@testable import Core

/// U.2a-1 contract tests for `PlaywrightSubprocessRunner`. The refusal
/// path is the load-bearing surface this round ships — production
/// dispatch flows through it before any node spawn, so callers receive
/// a structured `validation_browser_missing` error with the install
/// hint pointing at `senkani doctor --install-validation-browser`.
///
/// The subprocess-spawn path is exercised by U.2a-2's MCP/CLI dispatch
/// round (which can mock or skip when playwright isn't installed in
/// CI). This round only tests the refusal path + the JSON framing
/// contract.
@Suite("PlaywrightSubprocessRunner — U.2a-1 refusal path + JSON framing")
struct PlaywrightSubprocessRunnerTests {

    @Test("run refuses with validation_browser_missing when chromium cache is absent")
    func refusalPathWhenCacheAbsent() {
        // Point at a path guaranteed not to exist; the runner's chromium
        // probe is a single fileExists check.
        let missingCache = "/tmp/senkani-pwr-cache-missing-\(UUID().uuidString)"
        let runner = PlaywrightSubprocessRunner(chromiumCachePath: missingCache)

        #expect(runner.chromiumCacheInstalled() == false)

        do {
            _ = try runner.run(plan: [], targetURL: "https://example.com", screenshot: false)
            Issue.record("expected validationBrowserMissing; runner returned without throwing")
        } catch let error as PlaywrightRunnerError {
            #expect(error == .validationBrowserMissing(installHint: "senkani doctor --install-validation-browser"),
                    "refusal hint must point at the doctor command")
        } catch {
            Issue.record("expected PlaywrightRunnerError.validationBrowserMissing; got \(error)")
        }
    }

    @Test("encodeRequest produces stable JSON for the {plan, target_url} stdin frame")
    func requestEncodingIsStable() throws {
        let plan: [ValidationStep] = [
            ValidationStep(
                axis: .perf,
                assertionId: "perf.inp",
                targetPath: "src/index.html",
                selector: nil,
                expected: nil
            )
        ]
        let data = try PlaywrightSubprocessRunner.encodeRequest(
            plan: plan, targetUrl: "https://example.com"
        )
        let json = String(data: data, encoding: .utf8) ?? ""

        // Swift's default JSONEncoder omits nil-optional properties; the
        // TS driver treats absent keys as null, so this is the canonical
        // stdin frame.
        let expected = """
            {"plan":[{"assertion_id":"perf.inp","axis":"perf","target_path":"src/index.html"}],"target_url":"https://example.com"}
            """
        #expect(json == expected,
                "stdin frame must use sortedKeys + withoutEscapingSlashes + snake_case CodingKeys; got: \(json)")
    }
}
