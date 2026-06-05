import Foundation
import Security

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Per-connection logic for the EgressProxy listener (T.1a.2).
///
/// Lifecycle on a freshly-accepted client fd:
///   1. Read the request head (first line + headers up to `\r\n\r\n`,
///      bounded by `maxHeadBytes`).
///   2. Parse the request line via `HTTPRequestLine`.
///   3. Evaluate the host via `EgressRuleEngine`.
///   4. If denied — write `403 Forbidden\r\n\r\n`, log a deny row,
///      close.
///   5. If allowed and method is `CONNECT` — reply `200 Connection
///      Established`, peek the client's first ClientHello bytes,
///      validate SNI matches the CONNECT host, then either tunnel
///      bytes both ways to the upstream or tear down with a
///      `sni_mismatch` deny row.
///   6. If allowed and method is anything else — open the upstream
///      connection, rewrite the absolute-URL form to origin form,
///      write rewritten head, then pipe both directions.
final class EgressConnectionHandler: @unchecked Sendable {

    private let policy: EgressPolicy
    private let judge: JudgeAdapter?
    private let database: SessionDatabase
    private let clientFD: Int32
    private let startTime: DispatchTime
    /// Upstream-connect seam (V.13b-4d-ii). Defaults to the production
    /// `DefaultEgressUpstreamConnector` adopter so existing callers
    /// compile and behave unchanged. Tests inject `LoopbackStubConnector`
    /// to redirect ALLOW-arm CONNECTs at a fixture loopback port.
    private let upstreamConnector: EgressUpstreamConnecting
    /// T.1d-2b-i default-OFF MITM-termination gate. When false (default +
    /// today's only value) `handleConnect` runs the opaque tunnel unchanged.
    /// Child (ii) attaches the server-TLS termination seam to the ON branch.
    private let mitmTerminationEnabled: Bool
    /// T.1d-2b-ii — synchronous "give me the t1d-1 leaf PKCS#12 for this
    /// host" callback used ONLY on the flag-ON termination branch. Nil
    /// means "no leaf provider wired" — the handler falls back to the
    /// opaque tunnel even when the flag is ON, which preserves the
    /// child-(i) parity invariant in environments where the operator
    /// has not yet generated a CA (e.g. fresh install). Returning nil
    /// from the closure (per-host failure) is treated as fail-CLOSED.
    private let mitmLeafProvider: ((String) -> Data?)?
    /// T.1d-2b-iii — optional trust evaluator. Nil means production
    /// `MITMUpstreamVerify.defaultEvaluate` (System anchors). Tests
    /// inject a TEST-CA-anchored evaluator to drive the connect+
    /// handshake plumbing without touching System trust.
    private let mitmTrustEvaluator: MITMUpstreamVerify.TrustEvaluator?
    /// Resolved during request-head parsing (PaneMode.default if no
    /// `X-Senkani-Pane-Mode` header is present). Used by the decision
    /// recorder so audit rows carry the framing for the dispatched
    /// decision.
    private var resolvedPaneMode: PaneMode = .default

    /// Maximum request-head bytes the proxy will buffer before parsing.
    /// HTTP allows large header sets, but for proxy traffic 16 KB is
    /// well above what real-world clients emit. Anything beyond this
    /// is treated as a parse failure and rejected.
    private static let maxHeadBytes = 16 * 1024

    /// Maximum bytes peeked for the SNI extraction (TLS ClientHello).
    /// 4 KB always covers a real ClientHello.
    private static let maxSNIPeekBytes = 4 * 1024

    /// Read timeout (seconds) on the initial request head + ClientHello.
    /// Once a connection is in steady-state pipe, we use blocking reads
    /// without timeout — the EOF on either side terminates the pipe.
    private static let readTimeoutSeconds: Int = 5

    init(
        policy: EgressPolicy,
        judge: JudgeAdapter? = nil,
        database: SessionDatabase,
        clientFD: Int32,
        upstreamConnector: EgressUpstreamConnecting = DefaultEgressUpstreamConnector(),
        mitmTerminationEnabled: Bool = false,
        mitmLeafProvider: ((String) -> Data?)? = nil,
        mitmTrustEvaluator: MITMUpstreamVerify.TrustEvaluator? = nil
    ) {
        self.policy = policy
        self.judge = judge
        self.database = database
        self.clientFD = clientFD
        self.startTime = DispatchTime.now()
        self.upstreamConnector = upstreamConnector
        self.mitmTerminationEnabled = mitmTerminationEnabled
        self.mitmLeafProvider = mitmLeafProvider
        self.mitmTrustEvaluator = mitmTrustEvaluator
    }

    /// Back-compat init that wraps a flat rule engine in an EgressPolicy
    /// covering every PaneMode. T.1a callers (listener tests, fixture
    /// drivers) keep working without ceremony.
    convenience init(rules: EgressRuleEngine, database: SessionDatabase, clientFD: Int32) {
        var engines: [PaneMode: EgressRuleEngine] = [:]
        for mode in PaneMode.allCases { engines[mode] = rules }
        let policy = EgressPolicy(engines: engines)
        self.init(policy: policy, judge: nil, database: database, clientFD: clientFD)
    }

    func run() {
        defer { close(clientFD) }
        applyReadTimeout(fd: clientFD, seconds: Self.readTimeoutSeconds)

        guard let head = readRequestHead() else {
            recordDecision(host: "", method: "", decision: .deny, ruleId: "parse-failure")
            sendStatus(403, message: "Bad Request")
            return
        }

        // Split first line from the rest.
        guard let crlfRange = head.range(of: Data([0x0d, 0x0a])) else {
            recordDecision(host: "", method: "", decision: .deny, ruleId: "parse-failure")
            sendStatus(400, message: "Bad Request")
            return
        }
        let firstLineData = head.subdata(in: 0..<crlfRange.lowerBound)
        let restOfHead = head.subdata(in: crlfRange.upperBound..<head.count)

        guard let firstLine = String(data: firstLineData, encoding: .utf8) else {
            recordDecision(host: "", method: "", decision: .deny, ruleId: "parse-failure")
            sendStatus(400, message: "Bad Request")
            return
        }

        let parsed: HTTPRequestLine.ParsedRequest
        do {
            parsed = try HTTPRequestLine.parse(firstLine)
        } catch {
            recordDecision(host: "", method: "", decision: .deny, ruleId: "parse-failure")
            sendStatus(400, message: "Bad Request")
            return
        }

        // T.1b: parse `X-Senkani-Pane-Mode` from the rest-of-head bytes
        // BEFORE rule evaluation so the per-mode rule engine + audit
        // row both reflect the framing. Default = .general when absent.
        resolvedPaneMode = Self.parsePaneModeHeader(restOfHead)

        let engine = policy.engine(for: resolvedPaneMode)
        var evaluation = engine.evaluate(host: parsed.host)
        let normalizedHost = EgressHostNormalizer.normalize(parsed.host)
        var judgeRationale: String? = nil

        // T.1d-4: extract a request-body excerpt from the buffered head
        // bytes — body bytes (if any) follow the `\r\n\r\n` terminator
        // within `restOfHead`. For requests whose body overflowed the
        // 16 KB head buffer, the remainder streams through the pipe and
        // is not captured here. The excerpt is truncate-then-redacted
        // by `EgressDecisionStore.prepareBodyExcerpt` before it lands
        // in the audit row OR the judge prompt (Schneier P1).
        let bodyExcerptRaw: Data? = Self.bodyBytes(restOfHead: restOfHead)

        // T.1b: judge fallback on static-miss. Conditions:
        //   1. Static engine returned `defaultDeny` (no explicit rule).
        //   2. The pane mode allows judge dispatch (NOT .redteam).
        //   3. A judge adapter is wired in.
        // Otherwise the static `defaultDeny` stands.
        if evaluation.ruleId == "default-deny",
           resolvedPaneMode.allowsJudge,
           let judge {
            // T.1d-4: hand the judge a truncate-then-redact body excerpt
            // so it can promote a deny on payload content. The bytes are
            // already scrubbed of secrets by `prepareBodyExcerpt`.
            let preparedExcerpt = bodyExcerptRaw.map { EgressDecisionStore.prepareBodyExcerpt($0) }
            let verdict = judge.evaluate(JudgeRequest(
                host: normalizedHost,
                method: parsed.method,
                paneMode: resolvedPaneMode,
                bodyExcerpt: preparedExcerpt
            ))
            judgeRationale = verdict.rationale
            evaluation = EgressEvaluation(decision: verdict.decision, ruleId: "judge-\(verdict.decision.rawValue)")
        }

        if evaluation.decision == .deny {
            recordDecision(
                host: normalizedHost, method: parsed.method,
                decision: .deny, ruleId: evaluation.ruleId,
                paneMode: resolvedPaneMode, judgeRationale: judgeRationale,
                bodyExcerpt: bodyExcerptRaw
            )
            sendStatus(403, message: "Forbidden")
            return
        }

        if parsed.method == "CONNECT" {
            handleConnect(
                parsed: parsed,
                ruleId: evaluation.ruleId,
                normalizedHost: normalizedHost,
                judgeRationale: judgeRationale,
                engine: engine
            )
        } else {
            handlePlainHTTP(
                parsed: parsed,
                ruleId: evaluation.ruleId,
                normalizedHost: normalizedHost,
                restOfHead: Self.stripPaneModeHeader(restOfHead),
                judgeRationale: judgeRationale
            )
        }
    }

    // MARK: - Pane-mode header

    /// Parse `X-Senkani-Pane-Mode: <mode>` from the request-head bytes
    /// after the first line. Header name is case-insensitive per HTTP.
    /// Returns `.default` (.general) if header is absent, malformed,
    /// or carries an unrecognized mode token.
    static func parsePaneModeHeader(_ headBytes: Data) -> PaneMode {
        guard let s = String(data: headBytes, encoding: .utf8) else { return .default }
        let lines = s.split(separator: "\r\n", omittingEmptySubsequences: true)
        let headerLower = PaneMode.proxyHeader.lowercased()
        for line in lines {
            guard let colonIdx = line.firstIndex(of: ":") else { continue }
            let name = line[..<colonIdx].lowercased()
            if name.trimmingCharacters(in: .whitespaces) == headerLower {
                let value = line[line.index(after: colonIdx)...]
                return PaneMode.parseHeaderValue(String(value))
            }
        }
        return .default
    }

    /// Remove the `X-Senkani-Pane-Mode` header before forwarding the
    /// request upstream — the header is internal-only (Schneier
    /// 2026-05-19: never leak the framing taxonomy to the destination).
    static func stripPaneModeHeader(_ headBytes: Data) -> Data {
        guard let s = String(data: headBytes, encoding: .utf8) else { return headBytes }
        let headerLower = PaneMode.proxyHeader.lowercased()
        var out = ""
        // The header carries CRLF line terminators. Split on CRLF, drop
        // matching lines, rejoin so the upstream byte stream is intact.
        let parts = s.components(separatedBy: "\r\n")
        for part in parts {
            if let colonIdx = part.firstIndex(of: ":") {
                let name = part[..<colonIdx].lowercased().trimmingCharacters(in: .whitespaces)
                if name == headerLower { continue }
            }
            if !out.isEmpty { out += "\r\n" }
            out += part
        }
        return Data(out.utf8)
    }

    // MARK: - Plain HTTP

    private func handlePlainHTTP(
        parsed: HTTPRequestLine.ParsedRequest,
        ruleId: String,
        normalizedHost: String,
        restOfHead: Data,
        judgeRationale: String?
    ) {
        // Rewrite the absolute-URL request line to origin form.
        // `GET http://host:port/path HTTP/1.1` → `GET /path HTTP/1.1`.
        let path = parsed.path ?? "/"
        let rewrittenLine = "\(parsed.method) \(path) \(parsed.httpVersion)\r\n"
        guard let upstreamFD = upstreamConnector.connect(host: parsed.host, port: parsed.port) else {
            recordDecision(host: normalizedHost, method: parsed.method, decision: .deny, ruleId: "upstream_unreachable", paneMode: resolvedPaneMode, judgeRationale: judgeRationale)
            sendStatus(502, message: "Bad Gateway")
            return
        }
        defer { close(upstreamFD) }

        // Allow row written before piping so chain integrity holds even
        // if the upstream resets mid-flight.
        recordDecision(host: normalizedHost, method: parsed.method, decision: .allow, ruleId: ruleId, paneMode: resolvedPaneMode, judgeRationale: judgeRationale)

        // Write rewritten head: rewritten-first-line + rest-of-head bytes.
        var combined = Data(rewrittenLine.utf8)
        combined.append(restOfHead)
        guard writeAll(fd: upstreamFD, data: combined) else { return }

        // Bidirectional pipe until EOF on either side. Use a separate
        // dispatch queue for one direction and let the current thread
        // drive the other; whichever returns first cancels the other.
        pipeBidirectional(clientFD: clientFD, upstreamFD: upstreamFD)
    }

    // MARK: - CONNECT (HTTPS_PROXY)

    private func handleConnect(
        parsed: HTTPRequestLine.ParsedRequest,
        ruleId: String,
        normalizedHost: String,
        judgeRationale: String?,
        engine: EgressRuleEngine
    ) {
        // Send 200 Connection Established to client. Per RFC 7231, no
        // body, no headers required.
        guard sendStatus(200, message: "Connection Established") else { return }

        // Peek client bytes. We expect a TLS ClientHello as the first
        // record. Read up to maxSNIPeekBytes. We can't use MSG_PEEK
        // safely with a small buffer (would short-read silently), so
        // we read into a buffer and replay it upstream after validation.
        var peek = Data()
        let r = readUpTo(fd: clientFD, maxBytes: Self.maxSNIPeekBytes, into: &peek)
        guard r > 0, !peek.isEmpty else {
            recordDecision(host: normalizedHost, method: parsed.method, decision: .deny, ruleId: "sni_unparseable", paneMode: resolvedPaneMode, judgeRationale: judgeRationale)
            return
        }

        let sni: String
        do {
            sni = try TLSClientHelloSNI.extract(peek)
        } catch {
            recordDecision(host: normalizedHost, method: parsed.method, decision: .deny, ruleId: "sni_unparseable", paneMode: resolvedPaneMode, judgeRationale: judgeRationale)
            return
        }

        let normalizedSNI = EgressHostNormalizer.normalize(sni)
        if normalizedSNI != normalizedHost {
            recordDecision(host: normalizedHost, method: parsed.method, decision: .deny, ruleId: "sni_mismatch", paneMode: resolvedPaneMode, judgeRationale: judgeRationale)
            return
        }

        // T.1d-2b-i/ii: default-OFF MITM-termination gate.
        //
        //  - Flag OFF (default + today's only shipped value): fall through
        //    to the opaque-tunnel path below, byte-for-byte unchanged.
        //    This is the parity invariant child (i) shipped.
        //  - Flag ON + a leaf-provider wired: terminate the client TLS
        //    session with the t1d-1 minted leaf via the
        //    `MITMTermination` seam. On success, write a sentinel
        //    plaintext line (child (iii) replaces this with a verified
        //    upstream pipe) and close. On ANY failure, the connection
        //    is closed and an audit row is recorded — we DELIBERATELY
        //    do NOT silently fall back to the opaque tunnel here, since
        //    that would be a fail-OPEN bypass of the security control
        //    the flag turns ON (Schneier 2026-06-04).
        //  - Flag ON + NO leaf provider: fall through to the opaque
        //    tunnel. This handles the "operator flipped the flag but
        //    has not wired a provider" environmental case. The env-
        //    safety surface for that operator state is observability,
        //    not refusal: `EgressListener.start()` writes a stderr
        //    WARNING at bind time, and `senkani doctor` emits a
        //    matching .fail check (see
        //    `DoctorCommand.checkMITMTerminationReadiness` / r85 fix
        //    for the Schneier + Allspaw env-safety panel finding). An
        //    earlier comment here falsely claimed the listener
        //    constructor refuses to wire a provider when the on-disk
        //    CA is missing — that refusal logic never existed; the
        //    observability-via-stderr-warn-and-doctor surface is the
        //    actual behavior.
        if mitmTerminationEnabled, let provider = mitmLeafProvider {
            guard let leafPKCS12 = provider(normalizedHost) else {
                recordDecision(host: normalizedHost, method: parsed.method,
                               decision: .deny, ruleId: "mitm_leaf_unavailable",
                               paneMode: resolvedPaneMode, judgeRationale: judgeRationale)
                return
            }
            // T.1d-2b-iii — production path: server-side TLS termination
            // wired to a re-originated, VERIFIED upstream TLS leg via
            // MITMUpstreamVerify. On ANY trust-eval rejection we
            // FAIL-CLOSED: close the connection, write a structured
            // deny audit row, and (load-bearing) NEVER pipe plaintext
            // to the cert-rejected upstream. The opaque-tunnel
            // fallback is DELIBERATELY not taken here — that would
            // be a fail-OPEN bypass.
            let upstreamHost = parsed.host
            let upstreamPort = parsed.port
            let connector = self.upstreamConnector
            let evaluator = self.mitmTrustEvaluator ?? MITMUpstreamVerify.defaultEvaluate
            // t1d-5 follow-ups Round A — capture the decrypted post-Host-
            // rebind body bytes from the CONNECT path so operator body-deny
            // matchers fire on CONNECT-tunneled targets. Capture-strategy:
            // HEAD-BUFFER-BOUNDED (≤16 KB, mirrors the non-CONNECT
            // `bodyBytes(restOfHead:)` semantics). The closure stores raw
            // bytes here; `recordEgressDecision` calls into
            // `EgressDecisionStore.prepareBodyExcerpt` which performs the
            // Schneier truncate-then-redact-before-hash invariant before
            // the bytes hit SQLite or the chain canonical-map.
            //
            // The store is single-threaded: `pipeBidirectional` invokes
            // the callback at most ONCE, synchronously, on the same thread
            // as this handler's `run()` (no Dispatch queue hop in the
            // termination driver — it's the caller thread). No atomic
            // wrapper needed.
            var capturedInnerBody: Data? = nil
            let outcome = MITMTermination.runTerminationWithUpstream(
                fd: clientFD,
                peek: peek,
                leafPKCS12: leafPKCS12
            ) { clientSSL, clientCtx in
                // After client-side handshake completes, re-originate
                // to the real upstream with full chain + hostname
                // verification against System anchors.
                let connect = MITMUpstreamVerify.connectAndVerify(
                    host: upstreamHost,
                    port: upstreamPort,
                    connector: connector,
                    evaluator: evaluator
                )
                switch connect {
                case .failed(let failureOutcome):
                    return failureOutcome
                case .succeeded(let handle):
                    defer {
                        // r86 Schneier P2: send TLS close_notify alert to
                        // the upstream BEFORE closing the fd. ARC would
                        // release the SSLContext without `SSLClose`, which
                        // is operationally indistinguishable from a TCP
                        // RST but worth catching if upstream resource-
                        // cleanliness becomes audit-visible. Idempotent
                        // for ANY exit path from the pipe.
                        _ = SSLClose(handle.ssl)
                        Darwin.close(handle.fd)
                    }
                    return withExtendedLifetime(handle.ctx) { () -> MITMTermination.UpstreamOutcome in
                        // r94 t1d-5 r52 Allspaw P1 — LIVE in-path body
                        // denial. Wrap the per-pane engine in the
                        // default body-deny evaluator so the rebind
                        // peek's body slice flows into rule evaluation
                        // BEFORE any head-replay write to upstream.
                        let bodyDenyEvaluator: InnerBodyDenyEvaluating =
                            DefaultInnerBodyDenyEvaluator(engine: engine)
                        return MITMUpstreamVerify.pipeBidirectional(
                            clientSSL: clientSSL,
                            clientFD: clientCtx.fd,
                            upstreamSSL: handle.ssl,
                            upstreamFD: handle.fd,
                            validatedHost: normalizedHost,
                            bodyDenyEvaluator: bodyDenyEvaluator,
                            onInnerBodyExcerpt: { body in
                                capturedInnerBody = body
                            }
                        )
                    }
                }
            }
            // r93 Karpathy P3 — Outcome split into ServerOutcome +
            // UpstreamOutcome. The switch is now phase-scoped: server-
            // side setup/handshake failures vs upstream/inner-Host/pipe
            // failures. The audit-row ruleId mapping is unchanged —
            // every (case → ruleId) edge below is byte-identical to the
            // pre-split flat switch.
            switch outcome {
            case .server(let serverOutcome):
                switch serverOutcome {
                case .terminated:
                    // Sentinel-mode terminated reaches the allow row in
                    // production via the tagged-union wrap. (The
                    // server-side handshake completed and the sentinel
                    // write finished cleanly — same audit shape as
                    // upstreamCompleted in the pre-split flat switch.)
                    // t1d-5 follow-ups Round A — plumb the captured CONNECT-
                    // path inner body excerpt through to the allow audit row.
                    // Raw bytes flow into `recordEgressDecision`; the store's
                    // `prepareBodyExcerpt` runs truncate-then-redact BEFORE
                    // SQLite bind / chain hashing (Schneier P1 invariant).
                    recordDecision(host: normalizedHost, method: parsed.method,
                                   decision: .allow, ruleId: ruleId,
                                   paneMode: resolvedPaneMode, judgeRationale: judgeRationale,
                                   bodyExcerpt: capturedInnerBody)
                case .handshakeFailed:
                    recordDecision(host: normalizedHost, method: parsed.method,
                                   decision: .deny, ruleId: "mitm_handshake_failed",
                                   paneMode: resolvedPaneMode, judgeRationale: judgeRationale)
                case .ioError:
                    recordDecision(host: normalizedHost, method: parsed.method,
                                   decision: .deny, ruleId: "mitm_io_error",
                                   paneMode: resolvedPaneMode, judgeRationale: judgeRationale)
                case .wouldBlockBudgetExhausted:
                    recordDecision(host: normalizedHost, method: parsed.method,
                                   decision: .deny, ruleId: "mitm_would_block_budget",
                                   paneMode: resolvedPaneMode, judgeRationale: judgeRationale)
                case .sentinelWriteBudgetExhausted:
                    recordDecision(host: normalizedHost, method: parsed.method,
                                   decision: .deny, ruleId: "mitm_sentinel_write_budget",
                                   paneMode: resolvedPaneMode, judgeRationale: judgeRationale)
                case .contextCreateFailed, .identityLoadFailed, .identitySetFailed:
                    recordDecision(host: normalizedHost, method: parsed.method,
                                   decision: .deny, ruleId: "mitm_setup_failed",
                                   paneMode: resolvedPaneMode, judgeRationale: judgeRationale)
                }
            case .upstream(let upstreamOutcome):
                switch upstreamOutcome {
                case .upstreamCompleted:
                    // t1d-5 follow-ups Round A — plumb the captured CONNECT-
                    // path inner body excerpt through to the allow audit row.
                    // Raw bytes flow into `recordEgressDecision`; the store's
                    // `prepareBodyExcerpt` runs truncate-then-redact BEFORE
                    // SQLite bind / chain hashing (Schneier P1 invariant).
                    recordDecision(host: normalizedHost, method: parsed.method,
                                   decision: .allow, ruleId: ruleId,
                                   paneMode: resolvedPaneMode, judgeRationale: judgeRationale,
                                   bodyExcerpt: capturedInnerBody)
                case .upstreamUnreachable:
                    recordDecision(host: normalizedHost, method: parsed.method,
                                   decision: .deny, ruleId: "mitm_upstream_unreachable",
                                   paneMode: resolvedPaneMode, judgeRationale: judgeRationale)
                case .upstreamHandshakeFailed:
                    recordDecision(host: normalizedHost, method: parsed.method,
                                   decision: .deny, ruleId: "mitm_upstream_handshake_failed",
                                   paneMode: resolvedPaneMode, judgeRationale: judgeRationale)
                case .upstreamCertRejected:
                    // Load-bearing: bad upstream cert → deny + close. The
                    // sanitized reason on the .upstreamCertRejected case
                    // is intentionally not surfaced as the audit ruleId
                    // (so distinct reasons don't fragment the deny-row
                    // grouping); the ruleId is the stable enum string.
                    recordDecision(host: normalizedHost, method: parsed.method,
                                   decision: .deny, ruleId: "mitm_upstream_cert_rejected",
                                   paneMode: resolvedPaneMode, judgeRationale: judgeRationale)
                case .upstreamIOError:
                    recordDecision(host: normalizedHost, method: parsed.method,
                                   decision: .deny, ruleId: "mitm_upstream_io_error",
                                   paneMode: resolvedPaneMode, judgeRationale: judgeRationale)
                case .upstreamWouldBlockBudgetExhausted:
                    recordDecision(host: normalizedHost, method: parsed.method,
                                   decision: .deny, ruleId: "mitm_upstream_would_block_budget",
                                   paneMode: resolvedPaneMode, judgeRationale: judgeRationale)
                case .upstreamWriteBudgetExhausted:
                    recordDecision(host: normalizedHost, method: parsed.method,
                                   decision: .deny, ruleId: "mitm_upstream_write_budget",
                                   paneMode: resolvedPaneMode, judgeRationale: judgeRationale)
                case .upstreamContextCreateFailed:
                    // r93 Karpathy P3 — upstream client SSLContext
                    // creation failed. Pre-split this case lived under
                    // the server-phase `.contextCreateFailed` arm
                    // alongside identityLoadFailed / identitySetFailed
                    // and all three mapped to `mitm_setup_failed`. The
                    // ruleId is preserved byte-identical here.
                    recordDecision(host: normalizedHost, method: parsed.method,
                                   decision: .deny, ruleId: "mitm_setup_failed",
                                   paneMode: resolvedPaneMode, judgeRationale: judgeRationale)
                case .innerHostMismatch:
                    // T.1d-2b-iv — inner HTTP Host header did not match the
                    // SNI/CONNECT-validated host. Closes the HTTP/1.1
                    // connection-reuse / domain-fronting smuggling bypass.
                    // The mismatched raw Host value is INTENTIONALLY not
                    // surfaced in the audit row (Schneier 2026-06-04
                    // info-leak guard).
                    recordDecision(host: normalizedHost, method: parsed.method,
                                   decision: .deny, ruleId: "mitm_inner_host_mismatch",
                                   paneMode: resolvedPaneMode, judgeRationale: judgeRationale)
                case .innerNoHost:
                    // Karpathy r92 P2 — split out from `.innerHostMismatch`
                    // so missing-Host smuggling has its own auditable
                    // ruleId. Different attack shape, different forensics.
                    recordDecision(host: normalizedHost, method: parsed.method,
                                   decision: .deny, ruleId: "mitm_inner_no_host",
                                   paneMode: resolvedPaneMode, judgeRationale: judgeRationale)
                case .innerHeadTooLarge:
                    recordDecision(host: normalizedHost, method: parsed.method,
                                   decision: .deny, ruleId: "mitm_inner_head_too_large",
                                   paneMode: resolvedPaneMode, judgeRationale: judgeRationale)
                case .innerUnknownProtocol:
                    recordDecision(host: normalizedHost, method: parsed.method,
                                   decision: .deny, ruleId: "mitm_inner_unknown_protocol",
                                   paneMode: resolvedPaneMode, judgeRationale: judgeRationale)
                case .innerReadError:
                    recordDecision(host: normalizedHost, method: parsed.method,
                                   decision: .deny, ruleId: "mitm_inner_read_error",
                                   paneMode: resolvedPaneMode, judgeRationale: judgeRationale)
                case .upstreamPipeError:
                    // r86 Karpathy P2 — mid-stream TLS abort distinct from
                    // clean pipe completion. Sanitized reason on the case
                    // is intentionally not surfaced as the audit ruleId.
                    recordDecision(host: normalizedHost, method: parsed.method,
                                   decision: .deny, ruleId: "mitm_upstream_pipe_error",
                                   paneMode: resolvedPaneMode, judgeRationale: judgeRationale)
                case .bodyDeny(let ruleId):
                    // r94 t1d-5 r52 Allspaw P1 — LIVE in-path deny against
                    // the decrypted CONNECT-tunneled inner request body.
                    // The matched `ruleId` is the operator's EgressRule
                    // id; record it verbatim so audit-grep aggregates by
                    // the operator's own rule labels (NOT a stable
                    // `mitm_inner_body_deny` string). The audit row also
                    // carries the captured raw body excerpt — the store's
                    // `prepareBodyExcerpt` runs truncate-then-redact
                    // BEFORE SQLite bind / chain hashing (Schneier P1
                    // invariant). Upstream got ZERO bytes; the operator
                    // can see exactly what triggered the deny.
                    recordDecision(host: normalizedHost, method: parsed.method,
                                   decision: .deny, ruleId: ruleId,
                                   paneMode: resolvedPaneMode, judgeRationale: judgeRationale,
                                   bodyExcerpt: capturedInnerBody)
                }
            }
            return
        }

        // SNI matches CONNECT line. Open upstream and tunnel.
        guard let upstreamFD = upstreamConnector.connect(host: parsed.host, port: parsed.port) else {
            recordDecision(host: normalizedHost, method: parsed.method, decision: .deny, ruleId: "upstream_unreachable", paneMode: resolvedPaneMode, judgeRationale: judgeRationale)
            return
        }
        defer { close(upstreamFD) }

        recordDecision(host: normalizedHost, method: parsed.method, decision: .allow, ruleId: ruleId, paneMode: resolvedPaneMode, judgeRationale: judgeRationale)

        // Replay the peeked ClientHello bytes upstream first.
        guard writeAll(fd: upstreamFD, data: peek) else { return }

        pipeBidirectional(clientFD: clientFD, upstreamFD: upstreamFD)
    }

    // MARK: - Pipe

    /// Splice bytes both directions until either side closes.
    /// Implementation note: one direction runs on a dedicated queue, the
    /// other on the current thread. The first side to see EOF / error
    /// closes its half; the other unwinds when its read returns 0/-1.
    private func pipeBidirectional(clientFD: Int32, upstreamFD: Int32) {
        // Clear the read timeout on both fds — steady-state pipe is
        // EOF-bounded, not time-bounded.
        clearReadTimeout(fd: clientFD)
        clearReadTimeout(fd: upstreamFD)

        let group = DispatchGroup()
        let pipeQueue = DispatchQueue(label: "com.senkani.egress-pipe", qos: .userInitiated, attributes: .concurrent)

        // upstream → client
        pipeQueue.async(group: group) {
            Self.copyLoop(from: upstreamFD, to: clientFD)
            // Half-close: signal to the other direction we're done.
            shutdown(clientFD, Int32(SHUT_WR))
        }

        // client → upstream (this thread)
        Self.copyLoop(from: clientFD, to: upstreamFD)
        shutdown(upstreamFD, Int32(SHUT_WR))

        // Wait for the reverse direction to finish so we don't close
        // upstream before its reader unwinds.
        group.wait()
    }

    private static func copyLoop(from src: Int32, to dst: Int32) {
        let bufSize = 16 * 1024
        var buf = [UInt8](repeating: 0, count: bufSize)
        while true {
            let n = buf.withUnsafeMutableBufferPointer { ptr -> Int in
                read(src, ptr.baseAddress, ptr.count)
            }
            if n <= 0 { return }
            var written = 0
            while written < n {
                let w = buf.withUnsafeBufferPointer { ptr -> Int in
                    write(dst, ptr.baseAddress!.advanced(by: written), n - written)
                }
                if w <= 0 { return }
                written += w
            }
        }
    }

    // MARK: - Read helpers

    /// Read until `\r\n\r\n` (request head terminator) or `maxHeadBytes`.
    /// Returns the bytes read INCLUDING the terminator, or nil on
    /// timeout / read error / overflow.
    private func readRequestHead() -> Data? {
        var head = Data()
        let terminator = Data([0x0d, 0x0a, 0x0d, 0x0a])
        var buf = [UInt8](repeating: 0, count: 1024)
        while head.count < Self.maxHeadBytes {
            let n = buf.withUnsafeMutableBufferPointer { ptr -> Int in
                read(clientFD, ptr.baseAddress, ptr.count)
            }
            if n <= 0 { return nil }
            head.append(contentsOf: buf[0..<n])
            if let r = head.range(of: terminator) {
                // Truncate to head — body bytes that came along stay buffered
                // in the kernel for the upstream pipe, since we read into our
                // own buffer. To handle that, we'd need to plumb residue into
                // the pipe. For now, the rewritten-head path appends the bytes
                // AFTER the terminator into the upstream write (see
                // handlePlainHTTP, where the caller splits and forwards
                // everything in `head` after the first line). So we return
                // the FULL buffer (head + any tail bytes the client sent).
                _ = r
                return head
            }
        }
        return nil
    }

    /// Read up to `maxBytes` into `out`. Returns total bytes read,
    /// zero on EOF, -1 on error. Single read of whatever the kernel
    /// gives us; CGI / TLS clients normally hand us the whole
    /// ClientHello in one syscall.
    private func readUpTo(fd: Int32, maxBytes: Int, into out: inout Data) -> Int {
        var buf = [UInt8](repeating: 0, count: maxBytes)
        let n = buf.withUnsafeMutableBufferPointer { ptr -> Int in
            read(fd, ptr.baseAddress, ptr.count)
        }
        if n <= 0 { return n }
        out.append(contentsOf: buf[0..<n])
        return n
    }

    private func writeAll(fd: Int32, data: Data) -> Bool {
        var written = 0
        let total = data.count
        while written < total {
            let n = data.withUnsafeBytes { (rawPtr: UnsafeRawBufferPointer) -> Int in
                guard let base = rawPtr.baseAddress else { return -1 }
                return write(fd, base.advanced(by: written), total - written)
            }
            if n <= 0 { return false }
            written += n
        }
        return true
    }

    @discardableResult
    private func sendStatus(_ code: Int, message: String) -> Bool {
        let line = "HTTP/1.1 \(code) \(message)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        return writeAll(fd: clientFD, data: Data(line.utf8))
    }

    private func applyReadTimeout(fd: Int32, seconds: Int) {
        var tv = timeval(tv_sec: seconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    private func clearReadTimeout(fd: Int32) {
        var tv = timeval(tv_sec: 0, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    private func recordDecision(
        host: String,
        method: String,
        decision: EgressRule.Decision,
        ruleId: String,
        paneMode: PaneMode? = nil,
        judgeRationale: String? = nil,
        bodyExcerpt: Data? = nil
    ) {
        let elapsed = DispatchTime.now().uptimeNanoseconds &- startTime.uptimeNanoseconds
        let latencyUs = Int64(elapsed / 1_000)
        database.recordEgressDecision(
            host: host,
            method: method,
            decision: decision,
            ruleId: ruleId,
            latencyUs: max(latencyUs, 1),  // always > 0 per acceptance
            paneMode: paneMode,
            judgeRationale: judgeRationale,
            bodyExcerpt: bodyExcerpt
        )
    }

    /// T.1d-4 — extract the request-body bytes from the buffered head.
    /// The head buffer holds bytes through the `\r\n\r\n` terminator and
    /// any tail bytes that came along in the same kernel read. Body
    /// bytes (if any) start AFTER the terminator. Returns nil when:
    ///   - the terminator is absent (caller's parse path normally rejects
    ///     earlier, but defensive),
    ///   - no tail bytes follow the terminator (HEAD/GET with no body).
    /// The returned bytes are RAW — the caller is responsible for
    /// `EgressDecisionStore.prepareBodyExcerpt` (truncate-then-redact)
    /// before they enter the canonical-map or judge prompt.
    static func bodyBytes(restOfHead: Data) -> Data? {
        let terminator = Data([0x0d, 0x0a, 0x0d, 0x0a])
        guard let r = restOfHead.range(of: terminator) else { return nil }
        let after = restOfHead.subdata(in: r.upperBound..<restOfHead.count)
        return after.isEmpty ? nil : after
    }
}
