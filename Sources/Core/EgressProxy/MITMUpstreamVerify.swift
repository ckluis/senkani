import Foundation
import Security

#if canImport(Darwin)
import Darwin
#endif

/// T.1d-2b-iii — re-originated upstream TLS client with full
/// chain + hostname/SNI verification against System anchors,
/// reject-on-invalid.
///
/// After child (ii) terminates the client TLS, the proxy must
/// re-originate to the real upstream over a **verified** TLS leg.
/// `EgressUpstreamConnector` historically opened raw POSIX TCP with
/// ZERO upstream-TLS code; a MITM that skips upstream verification
/// becomes the attacker: the client sees a green padlock terminating
/// at the proxy with no real upstream trust.
///
/// ### Trust posture (inverse of t1d-2a spike)
///
/// The t1d-2a spike pins the TEST CA + `breakOnServerAuth` for a
/// hermetic seam proof. Production does the **inverse**:
///   - System anchors (`SecTrustSetAnchorCertificates(trust, nil)` +
///     `SecTrustSetAnchorCertificatesOnly(trust, false)` — explicit
///     for safety even though they're the defaults),
///   - `SSLSetPeerDomainName` pins the expected hostname into the
///     trust evaluation (chain + hostname/SNI),
///   - `SecTrustEvaluateWithError` evaluates,
///   - On failure → fail-CLOSED: close the upstream fd, write a
///     `mitm_upstream_cert_rejected` deny audit row, NEVER pipe
///     plaintext to a cert-rejected upstream.
///
/// ### Sanitization
///
/// `SecTrustEvaluateWithError`'s CFError carries raw cert metadata.
/// We sanitize the reason to a small classification string so the
/// audit row never leaks raw cert bytes or upstream-specific
/// identifiers (Schneier 2026-06-04). The full error is dropped on
/// the floor.
///
/// ### macOS-14 floor
///
/// `SSLContext` / SecureTransport / `SecTrustEvaluateWithError` are
/// available on every supported macOS. No `@available(macOS 15.0, *)`
/// symbols are referenced.

/// r94 t1d-5 r52 Allspaw P1 — connector seam for live in-path body
/// denial inside `pipeBidirectional`'s `.allow` arm. The evaluator
/// receives the validated host + parsed HEAD fragments + REDACTED body
/// excerpt and returns an `EgressEvaluation`. Production wiring threads
/// in a real `EgressRuleEngine` via `DefaultInnerBodyDenyEvaluator`;
/// tests inject a stub that returns canned `.allow` / `.deny` verdicts
/// without standing up a real engine.
///
/// Mirrors the `EgressUpstreamConnecting` connector-seam pattern from
/// becc8f2 — small protocol + struct adapter + injected default.
///
/// IMPORTANT: the `bodyExcerpt` handed to the evaluator is ALREADY
/// `EgressDecisionStore.prepareBodyExcerpt`-processed (truncate-then-
/// redact). Operator deny rules MUST therefore match against the
/// REDACTED text shape — operator-supplied `bodyContains:` substrings
/// that target redacted output (e.g. `[REDACTED:` from SecretDetector)
/// will fire; substrings that ONLY appear in raw secret-shaped tokens
/// (e.g. `sk-ant-`) will NOT fire because the redaction has already
/// scrubbed those bytes. This is the SAME shape operator rules must
/// use for the non-CONNECT path today since `prepareBodyExcerpt` runs
/// there too — preserving the Schneier P1 truncate-then-redact-before-
/// hash invariant end-to-end.
protocol InnerBodyDenyEvaluating: Sendable {
    func evaluate(
        host: String,
        method: String?,
        path: String?,
        headers: [(name: String, value: String)],
        bodyExcerpt: String?
    ) -> EgressEvaluation
}

/// Default production adapter — wraps an `EgressRuleEngine`.
struct DefaultInnerBodyDenyEvaluator: InnerBodyDenyEvaluating {
    let engine: EgressRuleEngine
    func evaluate(
        host: String,
        method: String?,
        path: String?,
        headers: [(name: String, value: String)],
        bodyExcerpt: String?
    ) -> EgressEvaluation {
        let req = EgressRequest(
            host: host,
            method: method,
            path: path,
            headers: headers,
            bodyExcerpt: bodyExcerpt
        )
        return engine.evaluate(request: req)
    }
}

enum MITMUpstreamVerify {

    /// Heap-boxed connection context for the upstream fd. Lifetime is
    /// pinned by the surrounding stack frame via `withExtendedLifetime`.
    final class Context {
        let fd: Int32
        init(fd: Int32) { self.fd = fd }
    }

    /// Bounded would-block retry budget. Same shape as the server side
    /// (see `MITMTermination.maxWouldBlockRetries`): worst-case wall
    /// time is `maxWouldBlockRetries * selectTimeoutSeconds`.
    static let maxWouldBlockRetries: Int = 128
    static let selectTimeoutSeconds: Int = 1

    /// Pipe-loop wall budget — a soft cap on how long the plaintext
    /// bidirectional pipe can stall on would-block before we tear it
    /// down. r85 Allspaw P3 mirrored on the upstream side: a stuck
    /// write surfaces as `.upstreamWriteBudgetExhausted` not a silent
    /// `.upstreamCompleted`.
    static let pipeWouldBlockBudget: Int = 256

    // MARK: - IO callbacks (client-side, mirror the server-side shape)

    static let sslReadCallback: SSLReadFunc = { connection, data, dataLength in
        let ctx = Unmanaged<Context>.fromOpaque(connection).takeUnretainedValue()
        let want = dataLength.pointee
        let base = data.assumingMemoryBound(to: UInt8.self)
        var got = 0
        while got < want {
            let n = Darwin.read(ctx.fd, base + got, want - got)
            if n > 0 { got += n; continue }
            if n == 0 {
                dataLength.pointee = got
                return errSSLClosedGraceful
            }
            if errno == EINTR { continue }
            if errno == EAGAIN || errno == EWOULDBLOCK {
                dataLength.pointee = got
                return errSSLWouldBlock
            }
            dataLength.pointee = got
            return errSSLClosedAbort
        }
        dataLength.pointee = got
        return errSecSuccess
    }

    static let sslWriteCallback: SSLWriteFunc = { connection, data, dataLength in
        let ctx = Unmanaged<Context>.fromOpaque(connection).takeUnretainedValue()
        let want = dataLength.pointee
        let base = data.assumingMemoryBound(to: UInt8.self)
        var sent = 0
        while sent < want {
            let n = Darwin.write(ctx.fd, base + sent, want - sent)
            if n > 0 { sent += n; continue }
            if n < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    dataLength.pointee = sent
                    return errSSLWouldBlock
                }
            }
            dataLength.pointee = sent
            return errSSLClosedAbort
        }
        dataLength.pointee = sent
        return errSecSuccess
    }

    // MARK: - Trust-eval seam (test-only injection point)

    /// Trust evaluation seam. Production calls `defaultEvaluate` which
    /// goes through `SecTrustEvaluateWithError` against System anchors.
    /// Tests can inject `pinnedTestCAEvaluate(_:)` so a self-signed cert
    /// + test CA can drive a positive path without polluting the
    /// System trust store. The seam exists ONLY for tests — the
    /// production wiring in `EgressConnectionHandler` always uses
    /// `defaultEvaluate`.
    typealias TrustEvaluator = (SecTrust) -> TrustResult

    enum TrustResult {
        case accepted
        case rejected(reason: String)
    }

    /// PRODUCTION trust evaluator: System anchors, full chain +
    /// hostname (the hostname leg comes from `SSLSetPeerDomainName`,
    /// which is wired separately on the SSLContext). Sanitizes the
    /// reason string — NO raw cert content reaches the audit row.
    static func defaultEvaluate(_ trust: SecTrust) -> TrustResult {
        // EXPLICIT System anchors. These are the defaults but we set
        // them anyway so a future caller cannot accidentally pre-pin
        // a test CA on the SecTrust and have us pass it through.
        _ = SecTrustSetAnchorCertificates(trust, nil)
        _ = SecTrustSetAnchorCertificatesOnly(trust, false)
        var cfErr: CFError?
        let ok = SecTrustEvaluateWithError(trust, &cfErr)
        if ok { return .accepted }
        return .rejected(reason: sanitizedTrustErrorReason(cfErr))
    }

    /// Map a `CFError` from `SecTrustEvaluateWithError` to a small
    /// classification string. We DELIBERATELY do not include the raw
    /// `localizedDescription` because it can carry cert subject CN /
    /// SAN bytes which are precisely the upstream identifier we don't
    /// want in audit rows.
    ///
    /// The classification is by error code (kSecTrust... domain) so
    /// the output is a stable enum-like string an operator can grep
    /// without learning to read SecureTransport internals.
    static func sanitizedTrustErrorReason(_ cfErr: CFError?) -> String {
        guard let cfErr else { return "chain validation failed" }
        let nsErr = cfErr as Error as NSError
        // Common SecTrust error codes (Security framework). We keep
        // the mapping tight: anything we don't recognize maps to the
        // generic "chain validation failed" rather than leaking the
        // localizedDescription.
        switch nsErr.code {
        case -67808, -67809, -67810: // hostname mismatch family
            return "hostname mismatch"
        case -67843, -67844, -67817: // expired / not yet valid family
            return "certificate expired or not yet valid"
        case -67856, -67857: // revoked
            return "certificate revoked"
        default:
            return "chain validation failed"
        }
    }

    // MARK: - Connect + verify + handshake

    /// Open a TLS-verified client leg to `host:port`. Returns the
    /// connected upstream fd + the configured SSLContext on success,
    /// OR an outcome describing the failure mode.
    ///
    /// On ANY failure mode the upstream fd (if opened) is closed
    /// before returning. The caller never sees a half-open
    /// cert-rejected upstream.
    static func connectAndVerify(
        host: String,
        port: Int,
        timeoutSeconds: Int = 5,
        connector: EgressUpstreamConnecting = DefaultEgressUpstreamConnector(),
        evaluator: TrustEvaluator = MITMUpstreamVerify.defaultEvaluate
    ) -> ConnectResult {
        // 1. Open a fresh TCP connection. The connector seam stays so
        //    tests can redirect to a loopback fixture if they ever need
        //    to assert the connector contract — production uses the
        //    default POSIX path.
        guard let fd = connector.connect(host: host, port: port, timeoutSeconds: timeoutSeconds) else {
            return .failed(.upstreamUnreachable)
        }
        // 2. Flip to non-blocking BEFORE the SSLContext sees the fd.
        guard MITMTermination.setNonBlocking(fd) else {
            let e = errno
            Darwin.close(fd)
            return .failed(.upstreamIOError(e))
        }
        // 3. Build the client SSLContext.
        guard let ssl = SSLCreateContext(nil, .clientSide, .streamType) else {
            Darwin.close(fd)
            return .failed(.upstreamContextCreateFailed)
        }
        let ctx = Context(fd: fd)
        let connectionPtr = Unmanaged.passUnretained(ctx).toOpaque()

        _ = SSLSetIOFuncs(ssl, sslReadCallback, sslWriteCallback)
        _ = SSLSetConnection(ssl, connectionPtr)
        _ = SSLSetProtocolVersionMin(ssl, .tlsProtocol12)
        // 4. SSLSetPeerDomainName — load-bearing. Pins SNI on the wire
        //    AND tells SecTrust the expected hostname for the cert
        //    chain evaluation. Without this, the SecTrust hostname
        //    check is vacuous.
        _ = SSLSetPeerDomainName(ssl, host, host.utf8.count)
        // 5. Opt IN to breakOnServerAuth so WE control trust eval
        //    against System anchors — never the default automatic
        //    pass.
        _ = SSLSetSessionOption(ssl, .breakOnServerAuth, true)

        // 6. Handshake loop. The breakOnServerAuth callback fires once
        //    the server cert is available; we evaluate trust and loop
        //    back into SSLHandshake. On reject, FAIL-CLOSED.
        var blockBudget = maxWouldBlockRetries
        var trustEvaluated = false
        // Pin the Context box for the handshake duration. We can't use
        // a single withExtendedLifetime around the entire return path
        // because the caller wants to keep the SSLContext + Context
        // alive for the post-handshake pipe; we move ownership into
        // the SuccessHandle below.
        while true {
            let st = SSLHandshake(ssl)
            if st == errSecSuccess { break }
            if st == errSSLWouldBlock {
                blockBudget -= 1
                if blockBudget <= 0 {
                    _ = SSLClose(ssl)
                    Darwin.close(fd)
                    return .failed(.upstreamWouldBlockBudgetExhausted)
                }
                switch MITMTermination.waitReadable(fd: fd, seconds: selectTimeoutSeconds) {
                case .ready, .timeout: continue
                case .error(let e):
                    _ = SSLClose(ssl)
                    Darwin.close(fd)
                    return .failed(.upstreamIOError(e))
                }
            }
            if st == errSSLPeerAuthCompleted {
                trustEvaluated = true
                var peerTrust: SecTrust?
                let copy = SSLCopyPeerTrust(ssl, &peerTrust)
                guard copy == errSecSuccess, let trust = peerTrust else {
                    _ = SSLClose(ssl)
                    Darwin.close(fd)
                    return .failed(.upstreamCertRejected(reason: "chain validation failed"))
                }
                switch evaluator(trust) {
                case .accepted:
                    // Loop back into SSLHandshake to progress past
                    // the break.
                    continue
                case .rejected(let reason):
                    _ = SSLClose(ssl)
                    Darwin.close(fd)
                    return .failed(.upstreamCertRejected(reason: reason))
                }
            }
            // Any other non-success status is fail-CLOSED.
            _ = SSLClose(ssl)
            Darwin.close(fd)
            return .failed(.upstreamHandshakeFailed(st))
        }

        // 7. Defensive: handshake succeeded WITHOUT us evaluating
        //    trust. This SHOULD be impossible with breakOnServerAuth
        //    opted in, but if it happens it means the System anchors
        //    auto-validated — which is the very fail-open we set
        //    breakOnServerAuth to prevent. Refuse to proceed.
        if !trustEvaluated {
            _ = SSLClose(ssl)
            Darwin.close(fd)
            return .failed(.upstreamCertRejected(reason: "trust evaluation skipped"))
        }

        return .succeeded(SuccessHandle(ssl: ssl, ctx: ctx, fd: fd))
    }

    /// Handshake-completed handle. Owns the SSLContext + upstream fd
    /// and (load-bearing) the Context box that SSLSetConnection points
    /// at — the caller must keep this handle alive for as long as it
    /// uses the SSLContext, otherwise the IO callbacks read a freed
    /// Context box.
    final class SuccessHandle {
        let ssl: SSLContext
        let ctx: Context
        let fd: Int32
        init(ssl: SSLContext, ctx: Context, fd: Int32) {
            self.ssl = ssl
            self.ctx = ctx
            self.fd = fd
        }
    }

    enum ConnectResult {
        case succeeded(SuccessHandle)
        /// Connect + verify failed. r93 Karpathy P3 — the inner
        /// associated value is `MITMTermination.UpstreamOutcome`
        /// (phase-scoped) since this path only ever produces upstream-
        /// phase failures (connect / handshake / cert-rejected /
        /// would-block budget / ioError). Previously this carried the
        /// flat `MITMTermination.Outcome` which forced call sites to
        /// list ~20 unreachable cases.
        case failed(MITMTermination.UpstreamOutcome)
    }

    // MARK: - Bidirectional plaintext pipe

    /// Drive the plaintext pipe between the server-side terminated TLS
    /// session and the verified upstream TLS leg. Both sides are
    /// non-blocking SecureTransport contexts; we shuttle bytes both
    /// directions using `SSLRead` / `SSLWrite` with a bounded
    /// would-block budget and an internal `select(2)` wait.
    ///
    /// Returns one of the `.upstream*` / `.inner*` outcomes.
    /// `.upstreamCompleted` means the pipe ran to EOF on one side (or
    /// both); a stuck write surfaces as `.upstreamWriteBudgetExhausted`
    /// (r85 Allspaw P3); a mid-stream TLS abort surfaces as
    /// `.upstreamPipeError(_)` (r86 Karpathy P2).
    ///
    /// ### Inner-Host rebind (T.1d-2b-iv)
    ///
    /// If `validatedHost` is non-nil, BEFORE any client→upstream byte
    /// flows, we peek the inner HTTP/1.x request head from the
    /// terminated client TLS, validate the `Host:` header against the
    /// validated SNI/CONNECT host, and FAIL-CLOSED on mismatch /
    /// non-HTTP-1.x / over-budget input. The successfully-peeked head
    /// bytes are replayed to the upstream as the first write so no
    /// bytes are lost or double-consumed.
    ///
    /// `validatedHost == nil` skips the rebind (preserved for the
    /// child-iii seam tests that bypass the inner-Host layer).
    ///
    /// ### t1d-5 follow-ups Round A — CONNECT-path body excerpt plumbing
    ///
    /// `onInnerBodyExcerpt`, when non-nil, is invoked EXACTLY ONCE on the
    /// `.allow` rebind branch, immediately after the inner Host header is
    /// validated and BEFORE any client→upstream byte forwarding. The Data
    /// payload is the post-`\r\n\r\n` slice of the head-buffered bytes the
    /// rebind peek already drained from the terminated TLS — i.e. the
    /// decrypted plaintext request body bytes that happened to be present
    /// in the same head buffer (capture-strategy: HEAD-BUFFER-BOUNDED, ≤16
    /// KB, mirrors the non-CONNECT `bodyBytes(restOfHead:)` semantics).
    /// r94 Round B promoted CONNECT-path operator body-deny matchers from
    /// audit-row-only to LIVE in-path denial via `bodyDenyEvaluator` below
    /// (engine.evaluate(request:) called pre-head-replay; deny aborts the
    /// upstream forward). Scope caveat: the plain-HTTP static path at
    /// `EgressConnectionHandler.run()` calls `engine.evaluate(host:)` only
    /// today; static `bodyContains` rules fire on plain-HTTP via the judge
    /// fallback (not the request-dimension engine). Full plain-HTTP
    /// request-dimension parity remains follow-up work — CONNECT path now
    /// has stronger live body-deny coverage than plain-HTTP, not "identical".
    /// nil/empty body → callback receives nil so the
    /// caller can pass it straight to `recordEgressDecision` without
    /// needing a "should I record an empty blob" decision.
    ///
    /// ### t1d-5 r52 Allspaw P2 — capture-state annotation (v47)
    ///
    /// The callback's SECOND argument is the `EgressBodyCaptureState` that
    /// explains the first argument: `.empty` (no body), `.overflowed` (a
    /// Content-Length-declared body exceeded the ≤16 KB peek window so the
    /// excerpt is a prefix), `.extractionFailed` (malformed head — defensively
    /// (near-)unreachable from `.allow`), or `.captured` (full body fit). The
    /// caller threads this into `recordEgressDecision(... bodyExcerptCaptureState:)`
    /// so doctor `--check-egress` can surface a per-state counter and an
    /// operator can spot an `.overflowed` spike (peek window undersized).
    ///
    /// r52 P3 guard (Schneier): an internal `bodyExcerptDelivered` flag
    /// pins the "EXACTLY ONCE" guarantee at the helper level so a
    /// future refactor (e.g. moving the rebind peek inside the read
    /// loop) cannot silently re-fire the callback per iteration — it
    /// becomes a no-op past the first invocation.
    ///
    /// r52 P3 note (Carmack `@escaping`): the `onInnerBodyExcerpt`
    /// parameter is `((Data?) -> Void)?` — Swift's optional closure
    /// types are ALREADY implicitly escaping (the optionality forces
    /// it). An explicit `@escaping` on an optional-closure-type
    /// parameter is a compile error ("closure is already escaping in
    /// optional type argument"), so the intent is pinned by the
    /// optionality itself; the r52 P3 spec bullet is satisfied as-is.
    ///
    /// The bytes handed to the callback are RAW — the caller is responsible
    /// for `EgressDecisionStore.prepareBodyExcerpt` (truncate-then-redact)
    /// before they enter the canonical-map / judge prompt. This preserves
    /// the Schneier truncate-then-redact-before-hash invariant end-to-end
    /// on the CONNECT path (the same invariant already enforced by
    /// `EgressDecisionStore.record(... bodyExcerpt:)` which calls
    /// `prepareBodyExcerpt` before SQLite bind).
    ///
    /// ### r94 t1d-5 r52 follow-ups Round B — LIVE in-path body denial
    ///
    /// `bodyDenyEvaluator`, when non-nil, is invoked on the `.allow`
    /// rebind branch IMMEDIATELY AFTER `onInnerBodyExcerpt` fires (so
    /// the audit-row callback ALWAYS sees the raw body, even on a deny
    /// outcome) and BEFORE the head is replayed upstream. The evaluator
    /// sees the parsed HEAD fragments (method/path/headers) + the
    /// `prepareBodyExcerpt`-REDACTED body excerpt (NOT the raw bytes —
    /// the Schneier P1 truncate-then-redact-before-hash invariant
    /// applies to the engine input too). On a `.deny` verdict, the
    /// function returns `.bodyDeny(ruleId:)` carrying the operator's
    /// stable rule id — upstream gets ZERO bytes, the client gets a
    /// clean TLS close on the way out.
    ///
    /// Fall-through cases (do NOT body-deny, head-replay proceeds):
    ///   - `bodyDenyEvaluator == nil` → behavior byte-identical to
    ///     pre-r94 (default-OFF invariant).
    ///   - Evaluator returns `.allow` → head-replay proceeds.
    ///   - Evaluator returns the `default-deny` sentinel (no rule
    ///     matched) → fall through to allow. Host-level was already
    ///     allowed up-arc (else this code wouldn't run), so a request-
    ///     dimension miss must NOT body-deny — that would be a second
    ///     deny-on-miss layer the operator never opted into.
    ///
    /// Fail-CLOSED case (DO body-deny):
    ///   - HEAD parse fails (`parseInnerHTTPHead` returns nil) → return
    ///     `.bodyDeny(ruleId: "mitm_inner_head_parse_failed")`. The
    ///     rebind peek already validated the Host header, so a parse
    ///     failure HERE means the bytes between Host validation and
    ///     full-head parse are malformed — fail-CLOSED rather than
    ///     forwarding ambiguous bytes upstream.
    static func pipeBidirectional(
        clientSSL: SSLContext,
        clientFD: Int32,
        upstreamSSL: SSLContext,
        upstreamFD: Int32,
        validatedHost: String? = nil,
        bodyDenyEvaluator: InnerBodyDenyEvaluating? = nil,
        onInnerBodyExcerpt: ((Data?, EgressBodyCaptureState) -> Void)? = nil
    ) -> MITMTermination.UpstreamOutcome {
        let bufSize = 16 * 1024
        var clientBuf = [UInt8](repeating: 0, count: bufSize)
        var upstreamBuf = [UInt8](repeating: 0, count: bufSize)

        var clientDone = false
        var upstreamDone = false
        var blockBudget = pipeWouldBlockBudget
        var writeBudget = pipeWouldBlockBudget

        // r52 P3 (Schneier) — pin the "callback fires EXACTLY ONCE on
        // the `.allow` branch" guarantee at the helper level. Today the
        // rebind peek lives OUTSIDE the read loop so a single invocation
        // is structurally guaranteed; this flag wraps the call site so a
        // future refactor (e.g. moving the rebind peek inside the read
        // loop) becomes a silent no-op on the second-and-later fire
        // rather than re-firing per iteration.
        var bodyExcerptDelivered = false

        // T.1d-2b-iv — inner-Host rebind peek. Drain the first request
        // head into a bounded buffer, validate Host matches the
        // validated SNI/CONNECT host, fail-CLOSED on mismatch. On
        // accept, replay the buffered head bytes to the upstream as
        // the first write so the pipe sees an intact request.
        if let validatedHost = validatedHost {
            let decision = MITMInnerHostRebind.peekAndDecide(
                ssl: clientSSL,
                waitFD: clientFD,
                validatedHost: validatedHost
            )
            switch decision {
            case .rejectMismatch:
                return .innerHostMismatch
            case .rejectMissingHost:
                return .innerNoHost
            case .rejectHeadTooLarge:
                return .innerHeadTooLarge
            case .rejectUnknownProtocol:
                return .innerUnknownProtocol
            case .rejectReadError(let st):
                return .innerReadError(st)
            case .allow(let headBytes):
                // t1d-5 follow-ups — CONNECT-path body excerpt plumbing.
                // The rebind peek drained the inner request HEAD (and any
                // body bytes that fit in the same 16 KB buffer) off the
                // terminated TLS. Extract the body slice (post
                // `\r\n\r\n`) with the SAME head-bounded semantics the
                // non-CONNECT path's `bodyBytes(restOfHead:)` uses, then
                // hand the raw bytes to the audit-row callback so the
                // operator can see exactly what crossed the tunnel — even
                // if the body matches a deny rule and we abort the
                // upstream forward below.
                //
                // r94 Round B promoted this from audit-row-only to LIVE
                // in-path denial: after the audit callback fires, if a
                // `bodyDenyEvaluator` is wired in, evaluate the parsed
                // HEAD + REDACTED body excerpt against the rule engine
                // and abort the upstream forward on a `.deny` verdict.
                // Scope: CONNECT path now invokes `engine.evaluate(request:)`
                // with the redacted body excerpt; plain-HTTP static path
                // still calls `evaluate(host:)` only, with static body
                // rules routing through the judge fallback. Full
                // request-dimension parity on the plain-HTTP path is
                // follow-up work (Schneier r94 P2-#1 carve-out).
                //
                // The Schneier P1 truncate-then-redact-before-hash
                // invariant IS preserved end-to-end:
                //   - `EgressDecisionStore.prepareBodyExcerpt` runs
                //     INSIDE `record(... bodyExcerpt:)` so the raw bytes
                //     never reach disk or the canonical-map hash.
                //   - The same `prepareBodyExcerpt` ALSO runs BEFORE the
                //     bytes are handed to the body-deny evaluator below
                //     — the engine never sees raw plaintext that wasn't
                //     truncate-then-redact-processed.
                let body = MITMUpstreamVerify.innerBodyBytes(fromHeadBuffer: headBytes)
                // v47 Allspaw P2 — classify WHY `body` came out the way it
                // did from the SAME headBytes payload (pure, no IO). Delivered
                // alongside the body so the audit row is non-ambiguous.
                let captureState = MITMUpstreamVerify.innerBodyCaptureState(fromHeadBuffer: headBytes)
                // r52 P3 (Schneier) guard — fire EXACTLY ONCE even under
                // a future refactor that could re-enter this arm.
                if let onInnerBodyExcerpt, !bodyExcerptDelivered {
                    bodyExcerptDelivered = true
                    onInnerBodyExcerpt(body, captureState)
                }
                // r94 t1d-5 r52 Allspaw P1 — LIVE in-path body denial.
                // BEFORE the head-replay write, evaluate the parsed HEAD
                // + redacted body excerpt against the rule engine.
                if let bodyDenyEvaluator {
                    guard let head = MITMUpstreamVerify.parseInnerHTTPHead(headBytes) else {
                        // Fail-CLOSED: rebind already validated the Host
                        // header, so a HEAD parse failure HERE means the
                        // bytes between Host validation and full-head
                        // parse are malformed. Refuse to forward
                        // ambiguous bytes upstream.
                        return .bodyDeny(ruleId: "mitm_inner_head_parse_failed")
                    }
                    // Redact-before-evaluate (Schneier P1 invariant).
                    // Non-UTF8 caveat: `prepareBodyExcerpt` passes through
                    // non-UTF8 bodies unchanged; the `String(data:encoding:.utf8)`
                    // round-trip then yields nil, so the evaluator sees
                    // `bodyExcerpt: nil` and operator `bodyContains:` rules
                    // silently fall through to allow. This is consistent with
                    // the existing plain-HTTP behavior (which also requires
                    // UTF-8-decodable bodies for substring matching). Operators
                    // with binary-body (gRPC over h2c, etc.) traffic should not
                    // rely on `bodyContains:` for those targets. Schneier
                    // r94 P2-#2.
                    let preparedExcerpt: String? = body.map { raw in
                        let prepared = EgressDecisionStore.prepareBodyExcerpt(raw)
                        return String(data: prepared, encoding: .utf8)
                    } ?? nil
                    // Evaluator host: prefer the validated SNI/CONNECT host
                    // so a parser-confused inner Host header cannot drive
                    // host-dimension matching past the boundary we already
                    // pinned via rebind.
                    let evaluation = bodyDenyEvaluator.evaluate(
                        host: validatedHost,
                        method: head.method,
                        path: head.path,
                        headers: head.headers,
                        bodyExcerpt: preparedExcerpt
                    )
                    if evaluation.decision == .deny
                        && evaluation.ruleId != "default-deny" {
                        // Operator rule fired — abort upstream forward.
                        // Upstream gets ZERO bytes; the connection-handler
                        // `defer` closes the upstream fd + sends client
                        // TLS close cleanly on the way out.
                        return .bodyDeny(ruleId: evaluation.ruleId)
                    }
                    // Either `.allow` OR the `default-deny` sentinel
                    // (no rule matched) — fall through to head-replay.
                    // Host-level was already allowed up-arc, so a request-
                    // dimension miss must NOT introduce a second deny-on-
                    // miss layer the operator never opted into.
                }
                // Replay buffered head bytes to upstream as the first
                // write. Use the same bounded sslWriteAll that the
                // pipe uses so write would-block waits + budget exhaustion
                // are uniformly handled.
                let writeResult = sslWriteAll(
                    ssl: upstreamSSL,
                    buf: headBytes,
                    count: headBytes.count,
                    writeBudget: &writeBudget,
                    waitFD: upstreamFD
                )
                switch writeResult {
                case .ok: break
                case .wouldBlockBudgetExhausted:
                    return .upstreamWriteBudgetExhausted
                case .ioError(let e):
                    return .upstreamIOError(e)
                case .terminalStatus:
                    return .upstreamPipeError(reason: "head replay failed")
                }
            }
        }

        // Outer drive loop. Each iteration: try to drain client → upstream,
        // then upstream → client. EOF on either side closes the pipe.
        while !clientDone || !upstreamDone {
            var madeProgress = false

            // --- client → upstream direction (plaintext from client TLS,
            //     re-encrypt over upstream TLS). ---
            if !clientDone {
                let outcome = copyOnce(
                    srcSSL: clientSSL,
                    dstSSL: upstreamSSL,
                    buf: &clientBuf,
                    writeBudget: &writeBudget,
                    waitFD: upstreamFD
                )
                switch outcome {
                case .progressed:
                    madeProgress = true
                case .wouldBlock:
                    break
                case .eof:
                    clientDone = true
                case .writeBudgetExhausted:
                    return .upstreamWriteBudgetExhausted
                case .ioError(let e):
                    return .upstreamIOError(e)
                case .terminalError:
                    // r86 Karpathy P2: a non-graceful, non-wouldblock
                    // TLS status mid-stream surfaces as a distinct
                    // `.upstreamPipeError` deny outcome rather than
                    // silently mapping to `.upstreamCompleted → allow`.
                    // The chain was already System-validated so this
                    // isn't a security bypass, but a mid-stream TLS
                    // abort being logged as ALLOW is operationally
                    // misleading.
                    return .upstreamPipeError(reason: "client-side mid-stream abort")
                }
            }

            // --- upstream → client direction (plaintext from upstream TLS,
            //     re-encrypt over client TLS so the original client sees
            //     a valid TLS response). ---
            if !upstreamDone {
                let outcome = copyOnce(
                    srcSSL: upstreamSSL,
                    dstSSL: clientSSL,
                    buf: &upstreamBuf,
                    writeBudget: &writeBudget,
                    waitFD: clientFD
                )
                switch outcome {
                case .progressed:
                    madeProgress = true
                case .wouldBlock:
                    break
                case .eof:
                    upstreamDone = true
                case .writeBudgetExhausted:
                    return .upstreamWriteBudgetExhausted
                case .ioError(let e):
                    return .upstreamIOError(e)
                case .terminalError:
                    return .upstreamPipeError(reason: "upstream-side mid-stream abort")
                }
            }

            if !madeProgress {
                // Both directions returned wouldBlock without progress.
                // Drain the would-block budget with a bounded wait so we
                // never busy-spin.
                blockBudget -= 1
                if blockBudget <= 0 {
                    return .upstreamWouldBlockBudgetExhausted
                }
                // Wait for ANY of the two fds to become readable. We use
                // a fresh fd_set spanning both (lifted from
                // MITMTermination.waitReadable but for two fds).
                let outcome = waitEitherReadable(fdA: clientFD, fdB: upstreamFD,
                                                 seconds: selectTimeoutSeconds)
                switch outcome {
                case .ready, .timeout: continue
                case .error(let e): return .upstreamIOError(e)
                }
            } else {
                // Reset the wall budget — we are making forward progress.
                blockBudget = pipeWouldBlockBudget
            }
        }
        return .upstreamCompleted
    }

    private enum CopyOnceResult {
        case progressed
        case wouldBlock
        case eof
        case writeBudgetExhausted
        case ioError(Int32)
        case terminalError
    }

    /// One non-blocking SSLRead → SSLWrite cycle. Returns whether we
    /// made progress and any terminal condition.
    private static func copyOnce(
        srcSSL: SSLContext,
        dstSSL: SSLContext,
        buf: inout [UInt8],
        writeBudget: inout Int,
        waitFD: Int32
    ) -> CopyOnceResult {
        var processed = 0
        let readStatus = buf.withUnsafeMutableBufferPointer { ptr -> OSStatus in
            guard let base = ptr.baseAddress else { return errSSLInternal }
            return SSLRead(srcSSL, base, ptr.count, &processed)
        }
        if processed > 0 {
            // Flush the chunk through SSLWrite — handle short writes /
            // would-block within the same call so we don't lose bytes.
            let writeResult = sslWriteAll(
                ssl: dstSSL,
                buf: buf,
                count: processed,
                writeBudget: &writeBudget,
                waitFD: waitFD
            )
            switch writeResult {
            case .ok: break
            case .wouldBlockBudgetExhausted:
                return .writeBudgetExhausted
            case .ioError(let e):
                return .ioError(e)
            case .terminalStatus:
                return .terminalError
            }
            return .progressed
        }
        if readStatus == errSSLWouldBlock { return .wouldBlock }
        if readStatus == errSSLClosedGraceful || readStatus == errSSLClosedNoNotify {
            return .eof
        }
        // r86 Carmack P2: tighten the 0-byte-success case. A successful
        // SSLRead with `processed == 0` does NOT indicate forward
        // progress (it's most commonly a TLS re-handshake / session-
        // resumption interstitial). Treat it as wouldBlock so the outer
        // loop's would-block budget catches a stall instead of being
        // silently reset.
        if readStatus == errSecSuccess { return .wouldBlock }
        return .terminalError
    }

    private enum WriteAllResult {
        case ok
        case wouldBlockBudgetExhausted
        case ioError(Int32)
        case terminalStatus
    }

    private static func sslWriteAll(
        ssl: SSLContext,
        buf: [UInt8],
        count: Int,
        writeBudget: inout Int,
        waitFD: Int32
    ) -> WriteAllResult {
        var sent = 0
        return buf.withUnsafeBufferPointer { ptr -> WriteAllResult in
            guard let base = ptr.baseAddress else { return .terminalStatus }
            while sent < count {
                var n = 0
                let st = SSLWrite(ssl, base.advanced(by: sent), count - sent, &n)
                sent += n
                if st == errSecSuccess { continue }
                if st == errSSLWouldBlock {
                    writeBudget -= 1
                    if writeBudget <= 0 {
                        return .wouldBlockBudgetExhausted
                    }
                    // r86 Carmack P2: SSLWrite would-block waits on
                    // write-readiness, not read-readiness. Previously
                    // we routed through `waitReadable` which is a
                    // mis-shaped wait (the bounded budget kept this
                    // fail-CLOSED but the typical recovery path was
                    // suboptimal).
                    switch MITMTermination.waitWritable(fd: waitFD, seconds: selectTimeoutSeconds) {
                    case .ready, .timeout: continue
                    case .error(let e): return .ioError(e)
                    }
                }
                return .terminalStatus
            }
            return .ok
        }
    }

    /// `select(2)` for read-readiness on either of two fds. Mirrors
    /// `MITMTermination.waitReadable` shape (returns SelectOutcome)
    /// but bits-in two fds so the pipe loop doesn't burn cycles
    /// polling each side independently.
    private static func waitEitherReadable(fdA: Int32, fdB: Int32, seconds: Int)
        -> MITMTermination.SelectOutcome
    {
        while true {
            var rfds = fd_set()
            withUnsafeMutableBytes(of: &rfds) { ptr in
                ptr.initializeMemory(as: UInt8.self, repeating: 0)
            }
            fdSet(fdA, &rfds)
            fdSet(fdB, &rfds)
            var tv = timeval(tv_sec: seconds, tv_usec: 0)
            let maxFD = max(fdA, fdB) + 1
            let rc = select(maxFD, &rfds, nil, nil, &tv)
            if rc > 0 { return .ready }
            if rc == 0 { return .timeout }
            let err = errno
            if err == EINTR { continue }
            return .error(err)
        }
    }

    /// t1d-5 follow-ups Round A — extract the inner request body bytes
    /// from the rebind peek's head-buffer payload.
    ///
    /// The rebind peek drained a bounded (≤16 KB) buffer off the
    /// terminated TLS containing the inner HTTP request HEAD and any body
    /// bytes that fit into the same read. The HEAD ends at the first
    /// `\r\n\r\n` terminator; body bytes (if present) are everything
    /// after that. Returns nil when no body bytes follow the terminator
    /// (HEAD/GET-style requests) and nil when the terminator is somehow
    /// absent (defensive — `peekAndDecide` only returns `.allow` once a
    /// terminator was found, so this branch should be unreachable in
    /// practice). Mirrors `EgressConnectionHandler.bodyBytes(restOfHead:)`
    /// semantics exactly so the CONNECT and plain-HTTP paths produce
    /// identical excerpt-shape inputs to `recordEgressDecision`.
    ///
    /// Pure — no IO. Lives here next to `pipeBidirectional` so the head
    /// buffer's body-byte extraction has a single owning module.
    static func innerBodyBytes(fromHeadBuffer headBytes: [UInt8]) -> Data? {
        // Locate `\r\n\r\n`. Same shape as
        // `MITMInnerHostRebind.headTerminatorIndex` but operates on raw
        // bytes (no allocations until we slice).
        guard headBytes.count >= 4 else { return nil }
        var terminatorEnd: Int? = nil
        for i in 0...(headBytes.count - 4) {
            if headBytes[i] == 0x0D && headBytes[i+1] == 0x0A
                && headBytes[i+2] == 0x0D && headBytes[i+3] == 0x0A {
                terminatorEnd = i + 4
                break
            }
        }
        guard let end = terminatorEnd, end < headBytes.count else { return nil }
        let body = headBytes[end..<headBytes.count]
        return body.isEmpty ? nil : Data(body)
    }

    /// r-followups t1d-5 r52 Allspaw P2 — classify WHY `innerBodyBytes`
    /// came out the way it did, so the audit row can record a non-ambiguous
    /// `EgressBodyCaptureState` instead of a bare nil.
    ///
    /// Pure — no IO. Operates on the SAME `headBytes` payload the rebind
    /// peek's `.allow` arm produced, applying the SAME `\r\n\r\n`-locating
    /// semantics as `innerBodyBytes`:
    ///   - `< 4` bytes or no `\r\n\r\n` terminator → `.extractionFailed`
    ///     (defensively (near-)unreachable from `.allow` — the rebind peek
    ///     guarantees a terminator before returning `.allow(headBytes:)` —
    ///     but the classifier is honest if a future caller feeds an
    ///     unvalidated buffer).
    ///   - terminator found, NO body bytes after it → `.empty` (GET/HEAD,
    ///     or an explicit Content-Length:0 POST).
    ///   - terminator found, body bytes present, AND a parseable
    ///     `Content-Length` header declares MORE bytes than were captured
    ///     after the terminator → `.overflowed` (the declared body exceeded
    ///     the 16 KB peek window, so the captured excerpt is a PREFIX).
    ///   - terminator found, body bytes present, declared length fits (or no
    ///     Content-Length to compare) → `.captured`.
    ///
    /// The `.overflowed` signal is best-effort: it fires ONLY when a
    /// parseable `Content-Length` proves the body was truncated. A chunked
    /// body (Transfer-Encoding: chunked, no Content-Length) whose frames
    /// overflowed the window is reported `.captured` (we have no length to
    /// compare) — a conservative classification that never FALSELY claims
    /// `.overflowed`. An operator monitoring the `.overflowed` counter is
    /// thus seeing a lower bound on real overflows, never a false alarm.
    static func innerBodyCaptureState(fromHeadBuffer headBytes: [UInt8]) -> EgressBodyCaptureState {
        guard headBytes.count >= 4 else { return .extractionFailed }
        var terminatorEnd: Int? = nil
        for i in 0...(headBytes.count - 4) {
            if headBytes[i] == 0x0D && headBytes[i+1] == 0x0A
                && headBytes[i+2] == 0x0D && headBytes[i+3] == 0x0A {
                terminatorEnd = i + 4
                break
            }
        }
        guard let end = terminatorEnd, end <= headBytes.count else {
            return .extractionFailed
        }
        let capturedBodyLen = headBytes.count - end
        if capturedBodyLen == 0 { return .empty }
        // Body bytes present — check whether a declared Content-Length proves
        // the captured slice is only a prefix (overflowed the peek window).
        if let declared = declaredContentLength(fromHeadBuffer: headBytes),
           declared > capturedBodyLen {
            return .overflowed
        }
        return .captured
    }

    /// Parse a `Content-Length` request-header value (the first one) out of
    /// the head buffer, if present and a non-negative integer. Returns nil
    /// when absent or unparseable. Case-insensitive header-name match per
    /// RFC 7230 §3.2. Pure — no IO.
    static func declaredContentLength(fromHeadBuffer headBytes: [UInt8]) -> Int? {
        guard let parsed = parseInnerHTTPHead(headBytes) else { return nil }
        for header in parsed.headers
        where header.name.trimmingCharacters(in: .whitespaces)
            .lowercased() == "content-length" {
            let v = header.value.trimmingCharacters(in: .whitespaces)
            if let n = Int(v), n >= 0 { return n }
            return nil  // present but malformed → don't guess
        }
        return nil
    }

    /// r94 t1d-5 r52 Allspaw P1 — parse the inner request HEAD out of
    /// the rebind peek's head-buffer payload into (method, path,
    /// headers). Returns nil on any malformed input (no `\r\n`
    /// terminating the request line, request line missing parts, no
    /// `\r\n\r\n` terminator).
    ///
    /// The rebind peek's `.allow(headBytes:)` payload contains the
    /// validated request HEAD plus any body bytes that fit in the same
    /// ≤16 KB buffer. The rebind already pulled `Host:` out and
    /// validated it; this parser walks the full HEAD so the body-deny
    /// evaluator can match against method / path / arbitrary headers.
    ///
    /// Pure — no IO. Bytes-level parser so a non-UTF8 header value
    /// degrades gracefully (we use Latin-1-style byte-wise decoding for
    /// header lines; the engine's own header normalizer handles case +
    /// OWS trimming).
    static func parseInnerHTTPHead(
        _ headBytes: [UInt8]
    ) -> (method: String, path: String, headers: [(name: String, value: String)])? {
        // Locate `\r\n\r\n` — same shape as `innerBodyBytes`.
        guard headBytes.count >= 4 else { return nil }
        var terminatorEnd: Int? = nil
        for i in 0...(headBytes.count - 4) {
            if headBytes[i] == 0x0D && headBytes[i+1] == 0x0A
                && headBytes[i+2] == 0x0D && headBytes[i+3] == 0x0A {
                terminatorEnd = i
                break
            }
        }
        guard let headEnd = terminatorEnd else { return nil }
        // Decode HEAD bytes up to (not including) the `\r\n\r\n` as a
        // String. Use UTF8 first, fall back to Latin-1 (via
        // ISOLatin1StringEncoding) so a stray non-UTF8 byte in a header
        // value doesn't poison the whole parse.
        let headSlice = Array(headBytes[0..<headEnd])
        let headText: String
        if let utf8 = String(bytes: headSlice, encoding: .utf8) {
            headText = utf8
        } else if let latin1 = String(bytes: headSlice, encoding: .isoLatin1) {
            headText = latin1
        } else {
            return nil
        }
        // Split into lines on `\r\n`. The first line is the request
        // line; the rest are headers.
        let lines = headText.components(separatedBy: "\r\n")
        guard let firstLine = lines.first, !firstLine.isEmpty else {
            return nil
        }
        // Request line: METHOD SP PATH SP HTTP-VERSION
        let parts = firstLine.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 3 else { return nil }
        let method = String(parts[0])
        let path = String(parts[1])
        // Parse headers — each line is `name: value`. A leading `\t` or
        // ` ` indicates a continuation of the previous header (obsolete
        // line-folding per RFC 7230 §3.2.4); we collapse by appending.
        var headers: [(name: String, value: String)] = []
        for raw in lines.dropFirst() {
            if raw.isEmpty { continue }
            if (raw.first == " " || raw.first == "\t") && !headers.isEmpty {
                // Obsolete line-folding: append to the previous value
                // with a single space (the engine OWS-trims at match
                // time so leading WS here is benign).
                let last = headers.removeLast()
                headers.append((name: last.name,
                                value: last.value + " " + raw.trimmingCharacters(in: .whitespaces)))
                continue
            }
            guard let colon = raw.firstIndex(of: ":") else { continue }
            let name = String(raw[..<colon])
            let valueStart = raw.index(after: colon)
            let value = String(raw[valueStart...])
            headers.append((name: name, value: value))
        }
        return (method: method, path: path, headers: headers)
    }

    /// FD_SET equivalent for the two-fd case — same r85 Carmack P3
    /// overflow-safe bit-pattern conversion as the server side.
    private static func fdSet(_ fd: Int32, _ set: UnsafeMutablePointer<fd_set>) {
        let bitsPerWord = MemoryLayout<Int32>.size * 8
        let word = Int(fd) / bitsPerWord
        let bit = Int(fd) % bitsPerWord
        withUnsafeMutableBytes(of: &set.pointee.fds_bits) { raw in
            let words = raw.bindMemory(to: Int32.self)
            if word < words.count {
                words[word] |= Int32(bitPattern: UInt32(1) << bit)
            }
        }
    }
}
