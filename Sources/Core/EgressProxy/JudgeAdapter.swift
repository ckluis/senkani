import Foundation

/// Judge fallback verdict for an egress request that missed the static
/// allowlist (T.1b). Returned by `JudgeAdapter` implementations.
///
/// Schneier audit 2026-05-19: the rationale is INFORMATIONAL — it
/// flows into `egress_decisions.judge_rationale` for post-hoc audit
/// but does NOT participate in any future decision (no caching of
/// "the judge said yes for example.com last time"). Every static-miss
/// dispatches fresh.
public struct JudgeVerdict: Sendable, Equatable {
    public let decision: EgressRule.Decision
    public let rationale: String

    public init(decision: EgressRule.Decision, rationale: String) {
        self.decision = decision
        self.rationale = rationale
    }
}

/// Request shape handed to a `JudgeAdapter`. The struct is value-typed
/// so unit tests can construct one directly without spinning the
/// daemon.
public struct JudgeRequest: Sendable, Equatable {
    public let host: String
    public let method: String
    public let paneMode: PaneMode

    public init(host: String, method: String, paneMode: PaneMode) {
        self.host = host
        self.method = method
        self.paneMode = paneMode
    }
}

/// Abstraction over the on-device judge inference layer. Production
/// wires a `GemmaJudgeAdapter` that calls the local Gemma adapter
/// under `MLXInferenceLock`; tests inject a stub that returns a
/// scripted verdict and counts calls.
///
/// The dispatch returns synchronously from the connection handler's
/// perspective via `DispatchSemaphore` — the connection handler is a
/// POSIX-thread per-connection loop, NOT a Swift-concurrency task,
/// so a sync surface keeps the integration boring. Adapters that
/// internally use Swift concurrency may bridge over the actor
/// boundary inside their `evaluate` implementation.
public protocol JudgeAdapter: Sendable {
    /// Evaluate one request. Implementations MUST honor a hard 300 ms
    /// deadline and return `.deny` with a `timeout` rationale on
    /// expiry (Schneier P0: deny-on-timeout is the safe default for
    /// a model layer).
    func evaluate(_ request: JudgeRequest) -> JudgeVerdict

    /// Number of `evaluate` calls served since process start. Used by
    /// `redteam-no-judge` invariant tests — the assertion is that the
    /// counter does not advance on a redteam static-miss.
    var callCount: Int { get }
}

/// In-memory test adapter. Production code MUST NOT use this. Tests
/// inject it into the connection handler / dispatch path to assert
/// invariants without spinning up Gemma.
public final class MockJudgeAdapter: JudgeAdapter, @unchecked Sendable {
    private let verdict: JudgeVerdict
    private let lock = NSLock()
    private var _callCount = 0

    public var callCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _callCount
    }

    public init(verdict: JudgeVerdict) {
        self.verdict = verdict
    }

    public func evaluate(_ request: JudgeRequest) -> JudgeVerdict {
        lock.lock()
        _callCount += 1
        lock.unlock()
        return verdict
    }
}

/// Production `JudgeAdapter` backed by the local Gemma inference
/// adapter through `MLXInferenceLock`. The actual Gemma call lives in
/// `Sources/MCP/GemmaInferenceAdapter.swift` and is injected via the
/// `inferenceClosure` seam — Core does not import MCP. The egress
/// daemon's start path wires the closure to a real Gemma call.
///
/// Karpathy P0: the prompt is a stable code constant, not a file. A
/// future change to prompt framing requires a code change + new
/// tests, never a hot-swap on disk.
public final class GemmaJudgeAdapter: JudgeAdapter, @unchecked Sendable {
    /// Returns `(decision, rationale)` from a Gemma inference call.
    /// Wired by the daemon's start path. nil → daemon was started
    /// without Gemma available and the adapter should refuse.
    public typealias InferenceClosure = @Sendable (String) -> (decision: EgressRule.Decision, rationale: String)?

    public static let timeout: TimeInterval = 0.300
    public static let rationaleByteCap = 2_000  // ≤200 tokens conservatively

    private let inference: InferenceClosure
    private let lock = NSLock()
    private var _callCount = 0

    public var callCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _callCount
    }

    public init(inference: @escaping InferenceClosure) {
        self.inference = inference
    }

    public func evaluate(_ request: JudgeRequest) -> JudgeVerdict {
        lock.lock()
        _callCount += 1
        lock.unlock()

        let prompt = Self.buildPrompt(request)

        let deadline = DispatchTime.now() + .milliseconds(Int(Self.timeout * 1_000))
        let sem = DispatchSemaphore(value: 0)
        var result: (decision: EgressRule.Decision, rationale: String)?
        DispatchQueue.global(qos: .userInitiated).async { [inference] in
            result = inference(prompt)
            sem.signal()
        }
        if sem.wait(timeout: deadline) == .timedOut {
            return JudgeVerdict(decision: .deny, rationale: "judge timeout (≥\(Int(Self.timeout * 1_000))ms)")
        }
        guard let result else {
            return JudgeVerdict(decision: .deny, rationale: "judge unavailable")
        }

        let capped = String(result.rationale.prefix(Self.rationaleByteCap))
        return JudgeVerdict(decision: result.decision, rationale: capped)
    }

    /// Stable code-constant prompt template. Bumping requires a code
    /// change AND new test fixtures so regressions are visible in
    /// PR review (Karpathy P0).
    public static func buildPrompt(_ request: JudgeRequest) -> String {
        return """
        You are evaluating a network egress request from a developer tool.
        Reply with one line: ALLOW or DENY, followed by a brief rationale.

        Pane mode: \(request.paneMode.rawValue)
        Method: \(request.method)
        Host: \(request.host)

        ALLOW if the host is a well-known software-development service
        (package registry, source forge, official documentation) AND
        the method is HEAD/GET/CONNECT.
        DENY otherwise. When in doubt, DENY.
        """
    }
}
