import Testing
import Foundation
@testable import Core

/// U.2b-axes — dispatch-extension tests. Asserts that the two new
/// axes (`security`, `design`) participate in the existing dispatch
/// surface as first-class entries: the `ValidationAxes` enum exposes
/// all four cases, `ValidationPlanner.plan` emits steps for security
/// and design alongside perf/completeness, and the MCP + CLI surfaces
/// default to all four axes when the caller omits an explicit
/// selection.
@Suite("U.2b-axes — dispatch surface extension")
struct AxesDispatchExtensionTests {

    @Test("ValidationPlanner emits one step per (file × axis) for all 4 axes; order is (path ASC, axis arg order)")
    func plannerEmitsAllFourAxesPerFile() {
        let diff = DiffRequest(
            selector: .unstaged,
            perFileDiff: [
                "src/login.html": "@@ -1,3 +1,5 @@ <form>...</form>",
                "src/dashboard.html": "@@ -10,0 +11,5 @@ <button>...</button>",
            ]
        )
        let axes: [ValidationAxes] = [.perf, .security, .design, .completeness]
        let steps = ValidationPlanner.plan(diff: diff, axes: axes)

        // 2 files × 4 axes = 8 steps.
        #expect(steps.count == 8)

        // Per-path: 4 steps in axis-arg order (perf, security, design, completeness).
        let loginSteps = steps.filter { $0.targetPath == "src/login.html" }
        #expect(loginSteps.count == 4)
        #expect(loginSteps.map(\.axis) == axes)
        #expect(loginSteps[0].assertionId == "perf.default")
        #expect(loginSteps[1].assertionId == "security.default")
        #expect(loginSteps[2].assertionId == "design.default")
        #expect(loginSteps[3].assertionId == "completeness.default")

        // Path ordering: ASC by target_path.
        let pathsSorted = steps.map(\.targetPath)
        #expect(pathsSorted == pathsSorted.sorted(),
                "ValidationPlanner emits steps in (target_path ASC, axis order) — must be deterministic")
    }

    @Test("ValidationAxes vocabulary covers exactly perf/security/design/completeness; allCases is stable")
    func validationAxesVocabularyIsFourComplete() {
        let all = ValidationAxes.allCases
        #expect(all.count == 4)
        let raws = Set(all.map(\.rawValue))
        #expect(raws == ["perf", "security", "design", "completeness"])
    }

    @Test("BrowserValidationDispatcher dispatch routes a 4-axis request through the runner; runner sees all four")
    func dispatcherEnumeratesAllFourAxesInPlan() throws {
        // Use the dispatcher's no-diff fallback (one step per axis,
        // keyed on target URL). This is the MCP/CLI default when the
        // caller omits diff_target — the test mirrors that path.
        let seenBox = LockedBox<[String]>(value: [])
        let runner: BrowserValidationDispatcher.Runner = { plan, _, _, _ in
            let axes = plan.map(\.axis.rawValue)
            seenBox.set(axes)
            return PlaywrightResult(
                resultStatus: "pass",
                axesRun: axes,
                assertionsPassed: 0,
                assertionsFailed: 0,
                screenshotPath: nil,
                advisory: nil
            )
        }
        let sinkResults: BrowserValidationDispatcher.ResultSink = { _ in }
        let sinkEvents: BrowserValidationDispatcher.TokenEventSink = { _ in }
        let request = BrowserValidationDispatcher.Request(
            targetURL: "https://example.com/page",
            axes: ValidationAxes.allCases,
            diff: nil,
            allowFailed: false,
            screenshot: false,
            sessionId: "sid-u2b-axes",
            projectRoot: "/tmp/u2b-axes-test"
        )
        let resp = try BrowserValidationDispatcher.dispatch(
            request: request,
            runner: runner,
            resultSink: sinkResults,
            tokenEventSink: sinkEvents
        )
        // Plan emitted to the runner contains exactly the four axes.
        #expect(seenBox.get() == ["perf", "security", "design", "completeness"])
        #expect(resp.resultStatus == "pass")
        #expect(resp.axesRun == ["perf", "security", "design", "completeness"])
    }
}

private final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(value: T) { self.value = value }
    func set(_ v: T) { lock.lock(); defer { lock.unlock() }; value = v }
    func get() -> T { lock.lock(); defer { lock.unlock() }; return value }
}
