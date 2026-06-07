import Testing
import Foundation
@testable import Core

// V.13b-4c follow-up — `phase-v13b-4c-followup-dispatch-concurrency-cap`
//
// Concurrency-cap regression tests for the process-wide dispatch gate
// installed in `ClaudeAPIServeDispatch.dispatch(...)`. The gate caps the
// number of in-flight GCD-blocked dispatches against the Claude engine
// so a contended hung upstream cannot exhaust the GCD worker pool.
//
// Tests are `.serialized` so the per-suite `configureMaxInflight(...)`
// calls do not race a parallel test still parked on a previous semaphore
// generation, and `.urlProtocolGate` so the swizzled URLProtocol stack
// is isolated.

// MARK: - Slow / failing URL protocols (in-suite)

/// URLProtocol that sleeps for `delaySeconds` before replying 200 with a
/// minimal Anthropic message body. Used by the gate-permit-exhaustion
/// test to hold a permit for a known, bounded interval.
private final class SlowSuccessProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var delaySeconds: TimeInterval = 1.0

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let request = self.request
        let delay = Self.delaySeconds
        // Bounce off the cancellation-friendly DispatchQueue.global so the
        // sleep is interruptible via `stopLoading`. The 200 body is the
        // minimal Anthropic Messages shape the engine's decoder accepts.
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            guard let url = request.url else {
                self.client?.urlProtocol(self, didFailWithError: URLError(.badURL))
                return
            }
            let response = HTTPURLResponse(
                url: url, statusCode: 200,
                httpVersion: "HTTP/1.1", headerFields: [:]
            )!
            let body = #"{"id":"msg_x","type":"message","role":"assistant","content":[{"type":"text","text":"ok"}],"stop_reason":"end_turn","usage":{"input_tokens":1,"output_tokens":1}}"#
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: Data(body.utf8))
            self.client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}

/// URLProtocol that fails immediately with a configurable URLError. Used
/// by the gate-released-on-throw test to drive the engine into the
/// `.networkError` path so we can verify the gate's `defer` released the
/// permit even when the body threw before the engine returned a value.
private final class ImmediateFailureProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var failureCode: URLError.Code = .notConnectedToInternet

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        client?.urlProtocol(self, didFailWithError: URLError(Self.failureCode))
    }
    override func stopLoading() {}
}

// MARK: - Shared fixtures

private let anthropicURL = URL(string: "https://api.anthropic.com/v1/messages")!

private func makeEngine(
    protocolClass: AnyClass,
    retryPolicy: ClaudeAPIChatEngine.RetryPolicy = ClaudeAPIChatEngine.RetryPolicy(
        maxRetries: 0, maxTotalWait: .seconds(0), baseDelay: .seconds(0)
    )
) -> ClaudeAPIChatEngine {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [protocolClass]
    let session = URLSession(configuration: config)
    return ClaudeAPIChatEngine(
        apiKey: "ak-test", session: session,
        endpoint: anthropicURL,
        retryPolicy: retryPolicy,
        sleeper: { _ in }
    )
}

private func makeRouting() -> OpenAIChatHandler.Routing {
    OpenAIChatHandler.Routing(
        presetUsed: .auto,
        resolvedTier: .quick,
        actualModel: ModelTier.quick.claudeModelValue,
        modelLogged: "gpt-4o"
    )
}

private func makeRequest() -> ChatCompletionRequest {
    ChatCompletionRequest(
        model: "gpt-4o",
        messages: [.init(role: "user", content: "ping")]
    )
}

// MARK: - 1. Permit-exhaustion under burst

@Suite(
    "ClaudeAPIServeDispatch — concurrency-cap permit exhaustion",
    .serialized,
    .urlProtocolGate
)
struct ClaudeAPIServeDispatchPermitExhaustionTests {

    @Test func gateBoundsInflightDispatchesUnderBurst() async throws {
        // Configure a small cap and a slow upstream so each in-flight
        // dispatch holds its permit for a known interval (~1s).
        ClaudeAPIServeDispatch.configureMaxInflight(4)
        defer { ClaudeAPIServeDispatch.resetMaxInflightToDefault() }

        SlowSuccessProtocol.delaySeconds = 1.0
        let engine = makeEngine(protocolClass: SlowSuccessProtocol.self)
        let routing = makeRouting()
        let request = makeRequest()

        let callCount = 8
        let start = Date()

        // Fire 8 concurrent dispatches via a TaskGroup. Each dispatch
        // calls into `runBlocking` which parks the executing thread; the
        // group's executor (cooperative pool, or dedicated executor on
        // macOS-15+) hands out threads as the semaphore signals.
        await withTaskGroup(of: Int.self) { group in
            for _ in 0..<callCount {
                group.addTask {
                    let o = ClaudeAPIServeDispatch.dispatch(
                        engine: engine,
                        request: request,
                        routing: routing,
                        keyLabel: "work",
                        now: Date(),
                        id: "chatcmpl-burst-\(UUID().uuidString.prefix(6))"
                    )
                    return o.httpStatus
                }
            }
            var completed = 0
            for await status in group {
                #expect(status == 200)
                completed += 1
            }
            #expect(completed == callCount, "all 8 dispatches must complete")
        }

        let elapsed = Date().timeIntervalSince(start)

        // Peak in-flight observed during the burst must not exceed the cap.
        let peak = ClaudeAPIServeDispatch._testOnlyPeakInflight()
        #expect(peak <= 4, "gate must cap in-flight dispatches at 4, got peak \(peak)")
        #expect(peak >= 1, "test infrastructure sanity: peak should be at least 1, got \(peak)")

        // Total wall-clock must reflect serialization through the gate.
        // 8 calls × 1s / 4 permits = 2s lower bound; allow generous upper
        // bound for CI jitter (URLSession + producer scheduling).
        #expect(elapsed >= 1.8, "8 calls × 1s / 4 permits → ≥ 2s; got \(elapsed)s")
    }
}

// MARK: - 2. Gate released on throw + cancellation paths

@Suite(
    "ClaudeAPIServeDispatch — gate released on throw + cancel",
    .serialized,
    .urlProtocolGate
)
struct ClaudeAPIServeDispatchGateReleaseTests {

    /// Drive one dispatch through the immediate-failure protocol with a
    /// specific failure code; return the outcome's audit status so we can
    /// confirm it took the error path (audit token != "ok").
    private func driveOneFailure(failureCode: URLError.Code) -> String {
        ImmediateFailureProtocol.failureCode = failureCode
        let engine = makeEngine(protocolClass: ImmediateFailureProtocol.self)
        let outcome = ClaudeAPIServeDispatch.dispatch(
            engine: engine,
            request: makeRequest(),
            routing: makeRouting(),
            keyLabel: nil,
            now: Date(),
            id: "chatcmpl-fail-\(UUID().uuidString.prefix(6))"
        )
        return outcome.auditFields.status
    }

    @Test func permitReleasedAfterUpstreamNetworkFailure() async throws {
        // maxInflight=1 — if the first dispatch did NOT release its
        // permit, the second would block forever. We assert the second
        // dispatch completes promptly under both representative failure
        // modes (`.notConnectedToInternet` and `.timedOut`).
        ClaudeAPIServeDispatch.configureMaxInflight(1)
        defer { ClaudeAPIServeDispatch.resetMaxInflightToDefault() }

        // First failure: notConnectedToInternet → .networkError path.
        let firstStatus = driveOneFailure(failureCode: .notConnectedToInternet)
        #expect(firstStatus == "upstream_network_error",
                "first dispatch must take the error path, got \(firstStatus)")

        // After release, the cap is 1 again — observed peak across both
        // calls so far must be at most 1.
        let peakAfterFirst = ClaudeAPIServeDispatch._testOnlyPeakInflight()
        #expect(peakAfterFirst <= 1)

        // Second failure: timedOut → still releases. If the gate were
        // not released by the defer above, this call would block until
        // the test timeout. The wall-clock guard catches that.
        let start = Date()
        let secondStatus = driveOneFailure(failureCode: .timedOut)
        let elapsed = Date().timeIntervalSince(start)
        #expect(secondStatus == "upstream_network_error",
                "second dispatch must take the error path, got \(secondStatus)")
        #expect(elapsed < 5.0,
                "second dispatch must acquire promptly — gate released by defer; got \(elapsed)s")
    }

    @Test func permitReleasedAfterTaskCancellationCollapse() async throws {
        // Cancellation that propagates THROUGH the engine surfaces as a
        // `CancellationError` caught by the `Captured.cancellation` arm
        // inside `dispatch(...)`. The gate's `defer` must still fire on
        // that arm. We exercise this by cancelling the awaiting Task
        // mid-flight against the slow URLProtocol: the engine's
        // `URLSession.data(for:)` is cancellation-aware and throws
        // `CancellationError` when the wrapping Task is cancelled.
        ClaudeAPIServeDispatch.configureMaxInflight(1)
        defer { ClaudeAPIServeDispatch.resetMaxInflightToDefault() }

        SlowSuccessProtocol.delaySeconds = 5.0  // long enough that the
        // cancel arrives before the body returns

        let engine = makeEngine(protocolClass: SlowSuccessProtocol.self)
        let routing = makeRouting()
        let request = makeRequest()

        // Fire dispatch on a child task; cancel it shortly after.
        let task = Task<Int, Never> {
            let o = ClaudeAPIServeDispatch.dispatch(
                engine: engine,
                request: request,
                routing: routing,
                keyLabel: nil,
                now: Date(),
                id: "chatcmpl-cancel"
            )
            return o.httpStatus
        }
        // Give the dispatch a moment to enter `runBlocking`, then cancel.
        try? await Task.sleep(nanoseconds: 100_000_000)  // 100ms
        task.cancel()
        let cancelledStatus = await task.value
        // Either the cancel propagated as CancellationError (502 via
        // the `.cancellation` collapse) or the URL request completed
        // before the cancel signal — both are acceptable; the
        // load-bearing assertion is "the gate releases regardless."
        #expect(cancelledStatus == 200 || cancelledStatus == 502,
                "dispatch must terminate (200 success or 502 cancellation collapse), got \(cancelledStatus)")

        // Reset delay so the next dispatch returns quickly.
        SlowSuccessProtocol.delaySeconds = 0.0

        // If the gate failed to release on the cancellation path, this
        // dispatch would deadlock on the semaphore. Bounded by a wall
        // clock check.
        let start = Date()
        let outcome = ClaudeAPIServeDispatch.dispatch(
            engine: engine,
            request: request,
            routing: routing,
            keyLabel: nil,
            now: Date(),
            id: "chatcmpl-after-cancel"
        )
        let elapsed = Date().timeIntervalSince(start)
        #expect(elapsed < 5.0,
                "post-cancel dispatch must acquire promptly — gate released by defer; got \(elapsed)s")
        #expect(outcome.httpStatus == 200,
                "post-cancel dispatch must succeed against the fast upstream")
    }
}
