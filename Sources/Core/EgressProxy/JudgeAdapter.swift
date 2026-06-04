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
///
/// T.1d-4 (body-aware judge): `bodyExcerpt` carries the truncate-then-
/// redact request-body excerpt (≤4 KB, post-SecretDetector) for HTTP
/// methods that may carry one (POST/PUT/PATCH on the MITM-terminate
/// path). nil for paths that don't capture a body (GET/HEAD, the opaque
/// tunnel path, or pre-MITM denies). The judge prompt builder includes
/// the excerpt as a separate framed section so a body containing
/// "ALLOW" / "DENY" tokens can't smuggle a verdict (the prompt's last
/// line still pins the LLM to a fresh decision over the structured
/// inputs).
public struct JudgeRequest: Sendable, Equatable {
    public let host: String
    public let method: String
    public let paneMode: PaneMode
    public let bodyExcerpt: Data?

    public init(host: String, method: String, paneMode: PaneMode, bodyExcerpt: Data? = nil) {
        self.host = host
        self.method = method
        self.paneMode = paneMode
        self.bodyExcerpt = bodyExcerpt
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

/// r93 Carmack P3 — file-private lock-protected box used by
/// `GemmaJudgeAdapter.evaluate` to hand the inference result across the
/// DispatchSemaphore-bounded async → sync boundary. Hoisted out of the
/// function body so type-metadata setup happens ONCE at module load
/// rather than on every `evaluate(...)` call (micro-optimization for
/// the per-request hot path). The box is INTERNAL to this file —
/// `private` keeps it invisible to other Core sources, preserving the
/// public API surface unchanged.
///
/// Semantics: written once by the worker queue, read once by the
/// caller after `sem.wait()` returns. The lock makes the
/// happens-before explicit so Sendable-warning analysis is structurally
/// satisfied without the call-site closure capturing a `var`.
private final class JudgeResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: (decision: EgressRule.Decision, rationale: String)?
    func set(_ v: (decision: EgressRule.Decision, rationale: String)?) {
        lock.lock(); _value = v; lock.unlock()
    }
    func get() -> (decision: EgressRule.Decision, rationale: String)? {
        lock.lock(); defer { lock.unlock() }
        return _value
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

    /// r89 P3 (Lauret) — stable code-constant for the body-excerpt
    /// framing prefix. The prompt template above embeds this string
    /// verbatim; pinning it here lets the snapshot test assert the
    /// EXACT framing without the test having to mirror the literal.
    /// A future framing tweak that changes wording (e.g.
    /// `"Body excerpt:"`) must update this constant + the template +
    /// the snapshot test in lockstep — making the change PR-visible.
    public static let bodyExcerptFramingPrefix: String =
        "Request body excerpt (≤4 KB, post-redaction):"

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
        // r89 P3 (Karpathy) — pre-existing Sendable concurrency cleanup
        // (LSP previously reported `sendable-closure-captures` on the
        // captured `var result`). The cross-thread handoff is a tiny
        // lock-protected box so the Sendable warning is structurally
        // satisfied; semantics are unchanged. The caller path is sync
        // (DispatchSemaphore-bounded async) so the box is written once
        // on the worker, then read once on the calling thread after
        // `sem.wait` — the lock makes the happens-before explicit.
        //
        // r93 Carmack P3 — `JudgeResultBox` is now file-private (defined
        // at module scope above) rather than re-declared inside this
        // function each call. Avoids per-call type-metadata setup; the
        // public API surface is unchanged.
        let box = JudgeResultBox()
        DispatchQueue.global(qos: .userInitiated).async { [inference] in
            box.set(inference(prompt))
            sem.signal()
        }
        if sem.wait(timeout: deadline) == .timedOut {
            return JudgeVerdict(decision: .deny, rationale: "judge timeout (≥\(Int(Self.timeout * 1_000))ms)")
        }
        guard let result = box.get() else {
            return JudgeVerdict(decision: .deny, rationale: "judge unavailable")
        }

        let capped = String(result.rationale.prefix(Self.rationaleByteCap))
        return JudgeVerdict(decision: result.decision, rationale: capped)
    }

    /// Stable code-constant prompt template. Bumping requires a code
    /// change AND new test fixtures so regressions are visible in
    /// PR review (Karpathy P0).
    ///
    /// T.1d-4 (body-aware): when `bodyExcerpt` is present, the prompt
    /// includes a separate framed section so the LLM can promote a deny
    /// on payload content (Schneier P1: the bytes were ALREADY truncate-
    /// then-redacted by `EgressDecisionStore.prepareBodyExcerpt` before
    /// being placed on JudgeRequest, so the LLM never sees raw secrets).
    public static func buildPrompt(_ request: JudgeRequest) -> String {
        var prompt = """
        You are evaluating a network egress request from a developer tool.
        Reply with one line: ALLOW or DENY, followed by a brief rationale.

        Pane mode: \(request.paneMode.rawValue)
        Method: \(request.method)
        Host: \(request.host)
        """
        if let body = request.bodyExcerpt,
           !body.isEmpty,
           let bodyStr = String(data: body, encoding: .utf8) {
            prompt += "\n\n\(bodyExcerptFramingPrefix)\n\(bodyStr)"
        }
        prompt += """


        ALLOW if the host is a well-known software-development service
        (package registry, source forge, official documentation) AND
        the method is HEAD/GET/CONNECT.
        DENY otherwise. When in doubt, DENY.
        """
        return prompt
    }
}
