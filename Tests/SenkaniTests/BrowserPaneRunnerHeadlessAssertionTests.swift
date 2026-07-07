import Testing
import Foundation
@testable import Core
import BrowserPane

/// U.2b-1b-6 — headless-arm assertion-evaluation + cross-runner parity.
///
/// Regression guard for
/// `process-gap-u2b-1b-6-headless-arm-skips-assertion-evaluation-2026-07-07`.
///
/// The off-screen `BrowserPaneRunner.run(...)` used to run each axis's
/// measurement JS, `_ = try`-DISCARD the result, count 1 pass/axis when the
/// JS merely executed, and return `result_status: pass` on genuinely-failing
/// pages. It never called the per-axis evaluators. This suite drives the
/// extracted, pure aggregation (`aggregateAxisResults`) + measurement decode
/// (`decodeJSONMeasurement` / `CompletenessDOM`) the runtime `run(...)` now
/// routes through, proving:
///
///   1. A known-failing measurement (missing `<meta name="description">`) can
///      no longer false-pass — it yields the correct `fail`/`partial` +
///      assertion counts in the HEADLESS arm.
///   2. Byte-parity with the subprocess arm on the four parity fields for the
///      two walk fixtures (design → partial/3/2, security → partial/4/1).
///   3. The parity contract: security + design are measured-and-attached but
///      NOT folded into the counts (matching `runner.ts`, which has no
///      production `evaluateSecurity` / `evaluateDesign`).
///
/// Runtime WKWebView parity (LCP measurement in the off-screen window, real
/// HEAD probes, live NSWindow lifecycle) is verified by the operator's re-run
/// of the U.2b-1b-6 walk; CI + the host are the authority there. These tests
/// pin the assertion-evaluation contract in pure Swift.
@Suite("U.2b-1b-6 — headless assertion evaluation + parity")
struct BrowserPaneRunnerHeadlessAssertionTests {

    private let allFourAxes = ["completeness", "design", "perf", "security"]

    // MARK: - Parity with the subprocess arm on the two walk fixtures

    @Test("design-roundtrip.html → partial / 3 passed / 2 failed (byte-parity with subprocess)")
    func designFixtureAggregateMatchesSubprocess() {
        // perf: INP not measured (pass), LCP under budget (pass) = 2 passed.
        // completeness: title present but NO <meta name=description> (fail),
        // /start link 404s (fail), no images (img_alt pass) = 1 passed, 2 failed.
        let perf = PerfMeasurement(inpMs: nil, lcpMs: 1200)
        let completeness = CompletenessMeasurement(
            title: "U.2b-1b-2 design roundtrip fixture",
            metaDescription: nil,
            internalLinks: [.init(href: "http://127.0.0.1:8765/start", statusCode: 404)],
            images: []
        )
        let agg = BrowserPaneRunner.aggregateAxisResults(
            axesRun: allFourAxes,
            perf: perf,
            perfExpected: nil,
            completeness: completeness,
            security: SecurityMeasurement(),
            design: DesignMeasurement()
        )
        #expect(agg.resultStatus == "partial")
        #expect(agg.assertionsPassed == 3)
        #expect(agg.assertionsFailed == 2)
    }

    @Test("security-roundtrip.html → partial / 4 passed / 1 failed (byte-parity with subprocess)")
    func securityFixtureAggregateMatchesSubprocess() {
        // perf: 2 passed. completeness: title present, NO meta (fail), links
        // resolve (pass), no images (pass) = 2 passed, 1 failed.
        let perf = PerfMeasurement(inpMs: nil, lcpMs: 1200)
        let completeness = CompletenessMeasurement(
            title: "U.2b-1b-1 security roundtrip fixture",
            metaDescription: nil,
            internalLinks: [.init(href: "http://127.0.0.1:8765/", statusCode: 200)],
            images: []
        )
        let agg = BrowserPaneRunner.aggregateAxisResults(
            axesRun: allFourAxes,
            perf: perf,
            perfExpected: nil,
            completeness: completeness,
            security: SecurityMeasurement(),
            design: DesignMeasurement()
        )
        #expect(agg.resultStatus == "partial")
        #expect(agg.assertionsPassed == 4)
        #expect(agg.assertionsFailed == 1)
    }

    // MARK: - The core falsifier: a failing page can no longer false-pass

    @Test("missing <meta name=description> yields a FAIL row, never an unconditional pass")
    func missingMetaCannotFalsePass() {
        // The OLD smoke-test path returned pass here (completeness.js merely
        // executed → +1). The evaluator path MUST surface the missing-meta
        // failure.
        let completeness = CompletenessMeasurement(
            title: "Has a title but no meta description",
            metaDescription: nil,
            internalLinks: [],
            images: []
        )
        let agg = BrowserPaneRunner.aggregateAxisResults(
            axesRun: ["completeness"],
            perf: nil,
            perfExpected: nil,
            completeness: completeness,
            security: nil,
            design: nil
        )
        #expect(agg.resultStatus != "pass", "a missing meta description must not report pass")
        #expect(agg.assertionsFailed >= 1)
        #expect(agg.advisory?.contains("completeness.title_meta") == true)
    }

    @Test("all-clean completeness page passes (no false-fail regression)")
    func cleanCompletenessPasses() {
        let completeness = CompletenessMeasurement(
            title: "Complete page",
            metaDescription: "A real meta description.",
            internalLinks: [.init(href: "http://127.0.0.1/ok", statusCode: 200)],
            images: [.init(src: "http://127.0.0.1/a.png", alt: "described")]
        )
        let agg = BrowserPaneRunner.aggregateAxisResults(
            axesRun: ["completeness"],
            perf: nil,
            perfExpected: nil,
            completeness: completeness,
            security: nil,
            design: nil
        )
        #expect(agg.resultStatus == "pass")
        #expect(agg.assertionsPassed == 3)
        #expect(agg.assertionsFailed == 0)
    }

    // MARK: - Parity contract: security + design measured but NOT counted

    @Test("security + design measurements are captured but do NOT inflate the counts")
    func securityAndDesignMeasuredButNotCounted() {
        // perf + completeness are ALL-PASS (5 rows). The security + design
        // measurements carry genuine failures (CSRF-less POST form,
        // javascript: href, undersized target, focus-order mismatch) — if the
        // headless arm counted them (unlike the subprocess arm) the status
        // would be partial/fail. Parity requires pass / 5 / 0.
        let perf = PerfMeasurement(inpMs: 50, lcpMs: 1000)
        let completeness = CompletenessMeasurement(
            title: "T", metaDescription: "M", internalLinks: [], images: []
        )
        let security = SecurityMeasurement(
            forms: [.init(action: "/pay", method: "post", csrfTokenPresent: false)],
            anchors: [.init(href: "javascript:alert(1)")],
            scripts: []
        )
        let design = DesignMeasurement(
            interactiveTargets: [.init(identifier: "a#x", widthPx: 10, heightPx: 10)],
            domFocusOrder: ["a#x"],
            tabFocusOrder: []
        )
        let agg = BrowserPaneRunner.aggregateAxisResults(
            axesRun: allFourAxes,
            perf: perf,
            perfExpected: nil,
            completeness: completeness,
            security: security,
            design: design
        )
        #expect(agg.resultStatus == "pass")
        #expect(agg.assertionsPassed == 5)
        #expect(agg.assertionsFailed == 0)
        // ...but the measurements ARE genuinely captured (not discarded) and
        // attached to the result for the same-shape payload the subprocess arm
        // ships.
        #expect(agg.securityMeasurement == security)
        #expect(agg.designMeasurement == design)
    }

    @Test("a security/design-only plan passes 0/0 on both arms (parity-consistent)")
    func securityDesignOnlyPlanIsParityConsistentZeroZero() {
        // Neither arm evaluates security/design assertions in production, so a
        // plan with only those axes reports pass / 0 / 0 on BOTH — parity holds
        // (documented latent gap, out of scope for this fix).
        let agg = BrowserPaneRunner.aggregateAxisResults(
            axesRun: ["design", "security"],
            perf: nil,
            perfExpected: nil,
            completeness: nil,
            security: SecurityMeasurement(),
            design: DesignMeasurement()
        )
        #expect(agg.resultStatus == "pass")
        #expect(agg.assertionsPassed == 0)
        #expect(agg.assertionsFailed == 0)
    }

    // MARK: - perf threshold overrides route through the shared evaluator

    @Test("perf expected override is parsed and applied via PerfAxis")
    func perfExpectedOverrideApplied() {
        let step = ValidationStep(
            axis: .perf,
            assertionId: "perf.default",
            targetPath: "http://127.0.0.1/",
            selector: nil,
            expected: "{\"lcp_ms\": 1000}"
        )
        let expected = BrowserPaneRunner.parsePerfExpected(plan: [step])
        #expect(expected?.lcpMs == 1000)

        // With the tight 1000ms budget a 1200ms LCP now FAILS.
        let agg = BrowserPaneRunner.aggregateAxisResults(
            axesRun: ["perf"],
            perf: PerfMeasurement(inpMs: nil, lcpMs: 1200),
            perfExpected: expected,
            completeness: nil,
            security: nil,
            design: nil
        )
        #expect(agg.resultStatus == "partial")
        #expect(agg.assertionsFailed == 1)
        #expect(agg.assertionsPassed == 1) // INP-not-measured still passes
    }

    @Test("no perf step → parsePerfExpected returns nil (Web-Vitals defaults apply)")
    func perfExpectedNilWithoutPerfStep() {
        let step = ValidationStep(
            axis: .completeness,
            assertionId: "completeness.default",
            targetPath: "http://127.0.0.1/",
            selector: nil,
            expected: nil
        )
        #expect(BrowserPaneRunner.parsePerfExpected(plan: [step]) == nil)
    }

    // MARK: - Measurement decode from WKWebView-marshaled values

    @Test("SecurityMeasurement decodes from a marshaled JS dictionary")
    func decodeSecurityMeasurementFromMarshaledDict() {
        let dict: [String: Any] = [
            "forms": [["action": "/login", "method": "post", "csrf_token_present": true]],
            "anchors": [["href": "javascript:void(0)"]],
            "scripts": [["src": "https://cdn.example.com/x.js", "same_origin": false]],
        ]
        let m = BrowserPaneRunner.decodeJSONMeasurement(SecurityMeasurement.self, from: dict)
        #expect(m != nil)
        #expect(m?.forms.first?.action == "/login")
        #expect(m?.forms.first?.method == "post")
        #expect(m?.forms.first?.csrfTokenPresent == true)
        #expect(m?.anchors.first?.href == "javascript:void(0)")
        #expect(m?.scripts.first?.sameOrigin == false)
    }

    @Test("CompletenessDOM decodes from a marshaled dict with NSNull meta/alt")
    func decodeCompletenessDOMFromMarshaledDict() {
        let dict: [String: Any] = [
            "title": "Page title",
            "metaDescription": NSNull(),
            "sameOriginLinks": ["http://127.0.0.1:8765/start"],
            "images": [["src": "http://127.0.0.1:8765/a.png", "alt": NSNull()]],
        ]
        let dom = BrowserPaneRunner.decodeJSONMeasurement(BrowserPaneRunner.CompletenessDOM.self, from: dict)
        #expect(dom != nil)
        #expect(dom?.title == "Page title")
        #expect(dom?.metaDescription == nil)
        #expect(dom?.sameOriginLinks == ["http://127.0.0.1:8765/start"])
        #expect(dom?.images.first?.src == "http://127.0.0.1:8765/a.png")
        #expect(dom?.images.first?.alt == nil)
    }

    @Test("PerfMeasurement decodes null inp_ms from a marshaled dict")
    func decodePerfMeasurementNullInp() {
        let dict: [String: Any] = ["inp_ms": NSNull(), "lcp_ms": 1234]
        let m = BrowserPaneRunner.decodeJSONMeasurement(PerfMeasurement.self, from: dict)
        #expect(m != nil)
        #expect(m?.inpMs == nil)
        #expect(m?.lcpMs == 1234)
    }

    @Test("decodeJSONMeasurement returns nil for a non-JSON-object value")
    func decodeRejectsNonObject() {
        #expect(BrowserPaneRunner.decodeJSONMeasurement(PerfMeasurement.self, from: "not-an-object") == nil)
        #expect(BrowserPaneRunner.decodeJSONMeasurement(PerfMeasurement.self, from: nil) == nil)
    }
}
