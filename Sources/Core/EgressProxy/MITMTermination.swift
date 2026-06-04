import Foundation
import Security

#if canImport(Darwin)
import Darwin
#endif

/// T.1d-2b-ii — server-side MITM TLS termination seam used from
/// `EgressConnectionHandler.handleConnect` when the default-OFF
/// `mitmTlsTermination` feature flag is ON.
///
/// This module proves and lands the TWO hazards the t1d-2b panel flagged
/// as one-round blockers:
///
///   1. **Buffered-ClientHello replay.** `handleConnect` destructively
///      `read(2)`s the ClientHello into a peek buffer so it can extract
///      the SNI. Feeding those already-consumed bytes into a server-side
///      SecureTransport state machine requires a custom prepend-buffer
///      `SSLReadFunc` that drains the peek buffer BEFORE reading the fd.
///      `MITMTerminationContext` carries the snapshot + cursor; the
///      `sslReadCallback` below drains it first, then falls through to a
///      non-blocking `read(2)` from the fd.
///
///   2. **Non-blocking IO path.** The t1d-2a spike uses `socketpair(2)`
///      with always-ready blocking fds. Production fds are real network
///      sockets with `errSSLWouldBlock` / partial-read / `EINTR`
///      semantics. The fd is flipped to `O_NONBLOCK` before the
///      handshake, the read/write callbacks correctly map `EAGAIN` →
///      `errSSLWouldBlock`, and the handshake driver uses a bounded
///      `select(2)` wait when the state machine would block.
///
/// ### Failure mode (load-bearing)
///
/// On ANY non-`errSSLWouldBlock` non-`errSecSuccess` outcome the
/// connection is closed and a structured decision row is logged. The
/// code path NEVER silently falls back to the opaque tunnel — that would
/// be a fail-OPEN bypass of the very security control the flag turns ON.
///
/// ### Boundary
///
/// This file handles ONE side of the MITM: the SERVER-side handshake
/// (we are the server presenting a t1d-1 minted leaf to the client). The
/// upstream-verified leg (we as a client to the real origin) is
/// phase-t1d-2b-iii. For now, once the client-side handshake completes,
/// we write a sentinel plaintext line over the terminated TLS session so
/// a test can prove "plaintext exposed", then close cleanly. Child (iii)
/// replaces the sentinel with a real upstream pipe.
///
/// ### macOS-14 floor
///
/// `SSLContext` / `SecureTransport` is available on every supported
/// macOS version. No `@available(macOS 15.0, *)` symbols are referenced
/// here. The PKCS#12 identity load goes through
/// `MITMCertificateAuthority.loadIdentity(from:)` whose `if #available`
/// already handles the floor.
enum MITMTermination {

    /// Outcome surfaced back to `handleConnect` so the audit decision
    /// row carries something more useful than "failed".
    enum Outcome: Equatable {
        /// Handshake completed; the sentinel plaintext was written and
        /// the session was closed cleanly. (Sentinel-mode for tests
        /// only — production goes through `runTerminationWithUpstream`
        /// and lands on `.upstreamCompleted`.)
        case terminated
        /// Handshake itself returned a non-zero OSStatus other than
        /// `errSSLWouldBlock`.
        case handshakeFailed(OSStatus)
        /// The non-blocking IO loop hit an unrecoverable error (a
        /// non-`EAGAIN`/non-`EINTR` errno).
        case ioError(Int32)
        /// We could not even build the `SSLContext` (catastrophic).
        case contextCreateFailed
        /// PKCS#12 → `SecIdentity` load failed.
        case identityLoadFailed
        /// `SSLSetCertificate` returned non-success.
        case identitySetFailed(OSStatus)
        /// Bounded retry budget for `errSSLWouldBlock` exhausted —
        /// treated as fail-CLOSED, not fail-OPEN.
        case wouldBlockBudgetExhausted
        /// r85 Allspaw P3 — sentinel-write would-block budget exhausted
        /// (the server-side TLS handshake succeeded but the
        /// post-handshake write stalled). Distinct from `.terminated`
        /// so the audit row reflects "we attempted termination but the
        /// post-handshake write stalled" rather than "cleanly terminated".
        case sentinelWriteBudgetExhausted

        // --- Child-(iii) upstream-verify outcomes (production path). ---

        /// Server-side TLS termination + upstream-verify leg completed;
        /// the bidirectional plaintext pipe ran to EOF on one side.
        case upstreamCompleted
        /// Upstream TCP connect failed (DNS / unreachable / timeout).
        case upstreamUnreachable
        /// Upstream TLS handshake state machine returned a non-success
        /// OSStatus.
        case upstreamHandshakeFailed(OSStatus)
        /// `SecTrustEvaluateWithError` rejected the upstream chain.
        /// Reason is a sanitized classification string (NEVER raw cert
        /// bytes or upstream-specific identifiers) — e.g.
        /// "chain validation failed".
        case upstreamCertRejected(reason: String)
        /// Upstream non-blocking IO unrecoverable error.
        case upstreamIOError(Int32)
        /// Upstream handshake / pipe would-block budget exhausted.
        case upstreamWouldBlockBudgetExhausted
        /// r85 Allspaw P3, mirrored on the upstream side — write budget
        /// exhausted while flushing buffered plaintext or piping. Distinct
        /// from `.upstreamCompleted` so a stalled write is auditably
        /// different from a clean pipe close.
        case upstreamWriteBudgetExhausted
    }

    /// Heap-boxed connection context referenced from the
    /// `@convention(c)` callbacks via `SSLSetConnection`. The lifetime
    /// is bound to the surrounding stack frame (`runTermination`) — we
    /// pass the box `Unmanaged.passUnretained` and rely on the
    /// `withExtendedLifetime` block to keep it alive for the entire
    /// SSLContext lifetime, so there is no use-after-free.
    final class Context {
        let fd: Int32
        /// Snapshot of the bytes the parent `handleConnect` already
        /// consumed from the client fd before TLS termination started.
        /// IMMUTABLE during the handshake — the cursor advances, the
        /// buffer itself never mutates.
        let prepend: [UInt8]
        /// Cursor into `prepend`. Once it reaches `prepend.count` the
        /// read callback falls through to `read(2)` from `fd`.
        var prependCursor: Int = 0

        init(fd: Int32, prepend: Data) {
            self.fd = fd
            self.prepend = Array(prepend)
        }

        /// Has the peek buffer been fully drained into SecureTransport?
        var prependDrained: Bool { prependCursor >= prepend.count }
    }

    /// Maximum number of `errSSLWouldBlock` retries the handshake
    /// driver will issue before giving up. With the `select(2)` wait
    /// between retries this corresponds to ~10s of wall time in the
    /// worst case — enough for a normal handshake, fail-CLOSED for a
    /// stuck/malicious peer.
    static let maxWouldBlockRetries: Int = 128

    /// `select(2)` timeout per `errSSLWouldBlock` retry, in seconds.
    static let selectTimeoutSeconds: Int = 1

    // MARK: - IO callbacks

    /// Read callback: drain the prepend buffer first, then fall through
    /// to a non-blocking `read(2)` from the fd. Maps `EAGAIN`/
    /// `EWOULDBLOCK` to `errSSLWouldBlock` (NOT a real error — the
    /// driver will retry). Retries `EINTR` internally. Any other errno
    /// returns `errSSLClosedAbort` so the handshake fails CLOSED.
    static let sslReadCallback: SSLReadFunc = { connection, data, dataLength in
        let ctx = Unmanaged<Context>.fromOpaque(connection).takeUnretainedValue()
        let want = dataLength.pointee
        let base = data.assumingMemoryBound(to: UInt8.self)
        var got = 0

        // 1. Drain the peek buffer first. Hazard #1: failing to do this
        //    is what would silently truncate the ClientHello and corrupt
        //    the handshake.
        if ctx.prependCursor < ctx.prepend.count {
            let avail = ctx.prepend.count - ctx.prependCursor
            let take = min(avail, want)
            ctx.prepend.withUnsafeBufferPointer { src in
                guard let srcBase = src.baseAddress else { return }
                memcpy(base, srcBase.advanced(by: ctx.prependCursor), take)
            }
            ctx.prependCursor += take
            got += take
            if got == want {
                dataLength.pointee = got
                return errSecSuccess
            }
        }

        // 2. Fall through to a non-blocking read(2) from the fd.
        while got < want {
            let n = Darwin.read(ctx.fd, base + got, want - got)
            if n > 0 {
                got += n
                continue
            }
            if n == 0 {
                // EOF / orderly shutdown.
                dataLength.pointee = got
                return errSSLClosedGraceful
            }
            // n < 0
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

    /// Write callback: non-blocking `write(2)` loop. Maps
    /// `EAGAIN`/`EWOULDBLOCK` to `errSSLWouldBlock`; any other errno is
    /// `errSSLClosedAbort` so the handshake fails CLOSED.
    static let sslWriteCallback: SSLWriteFunc = { connection, data, dataLength in
        let ctx = Unmanaged<Context>.fromOpaque(connection).takeUnretainedValue()
        let want = dataLength.pointee
        let base = data.assumingMemoryBound(to: UInt8.self)
        var sent = 0
        while sent < want {
            let n = Darwin.write(ctx.fd, base + sent, want - sent)
            if n > 0 {
                sent += n
                continue
            }
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

    // MARK: - fcntl helpers

    /// Flip the fd to `O_NONBLOCK`. Returns false if the fcntl call
    /// itself failed; callers treat that as ioError and fail CLOSED.
    static func setNonBlocking(_ fd: Int32) -> Bool {
        let flags = fcntl(fd, F_GETFL, 0)
        guard flags != -1 else { return false }
        let rc = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        return rc != -1
    }

    /// Outcome of a `select(2)` wait — r85 Carmack P3 fix surfaces
    /// errno + return code so callers can map EBADF / EINVAL to
    /// `.ioError` instead of waiting out the would-block budget.
    enum SelectOutcome {
        /// fd is readable (select returned > 0).
        case ready
        /// 0-return — timer elapsed with no readiness. Caller retries.
        case timeout
        /// select(2) failed with the given errno. Caller maps to
        /// `.ioError` and fails CLOSED. EINTR is retried internally so
        /// it never surfaces here.
        case error(Int32)
    }

    /// `select(2)` for read-ready, with timeout. Surfaces errno via
    /// `SelectOutcome` so EBADF / EINVAL are distinguishable from a
    /// clean timeout (r85 Carmack P3). EINTR retries internally with
    /// the timeout reset — at worst the caller waits ~2× the configured
    /// timeout before its own budget catches the stuck fd.
    static func waitReadable(fd: Int32, seconds: Int) -> SelectOutcome {
        while true {
            var rfds = fd_set()
            // Initialize fd_set to zero. Darwin's fd_set is a fixed-size
            // bitmap; zeroing all words via withUnsafeMutableBytes is
            // equivalent to FD_ZERO without needing the macro.
            withUnsafeMutableBytes(of: &rfds) { ptr in
                ptr.initializeMemory(as: UInt8.self, repeating: 0)
            }
            fdSet(fd, &rfds)
            var tv = timeval(tv_sec: seconds, tv_usec: 0)
            let rc = select(fd + 1, &rfds, nil, nil, &tv)
            if rc > 0 { return .ready }
            if rc == 0 { return .timeout }
            // rc < 0
            let err = errno
            if err == EINTR { continue }
            return .error(err)
        }
    }

    /// FD_SET equivalent. Darwin's `fd_set` is a 1024-bit array of
    /// `Int32`s (`fds_bits`). We toggle the bit for `fd` by hand.
    ///
    /// r85 Carmack P3 fix: `Int32(1 << bit)` traps when `bit == 31`
    /// because Swift computes `1 << 31` in `Int` as `2_147_483_648`,
    /// which does not fit in `Int32` (max `2^31 - 1`). The fix is to
    /// compute the mask in `UInt32` and bit-pattern-convert. For typical
    /// loopback proxy fds (< 32) the old code never tripped, but child
    /// (iii) opens upstream sockets in addition to client sockets, so
    /// the FD pressure goes up.
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

    // MARK: - Termination driver

    /// Stand up a server-side SecureTransport context bound to `fd`,
    /// drain the peek buffer through the custom SSLReadFunc, run the
    /// handshake to completion with bounded `errSSLWouldBlock` retries,
    /// write the sentinel plaintext line, and close cleanly.
    ///
    /// Returns the `Outcome` so the caller can record a structured
    /// audit row. On ANY non-`.terminated` outcome the fd is left
    /// open (the caller closes it in its `defer { close(clientFD) }`)
    /// — the SSLContext is torn down here so there is no fd-double-
    /// close hazard.
    ///
    /// `sentinelOverride` lets tests inject a smaller / specific
    /// payload to assert against; production passes nil and the
    /// default sentinel is used.
    static func runTermination(
        fd: Int32,
        peek: Data,
        leafPKCS12: Data,
        sentinelOverride: Data? = nil
    ) -> Outcome {

        // 1. Load the t1d-1 minted leaf as a SecIdentity. The whole
        //    point of the flag is that the server presents THIS leaf,
        //    not a fresh self-signed cert.
        let identity: SecIdentity
        do {
            identity = try MITMCertificateAuthority.loadIdentity(from: leafPKCS12)
        } catch {
            return .identityLoadFailed
        }

        // 2. Flip the fd to O_NONBLOCK so the SecureTransport callbacks
        //    can return errSSLWouldBlock instead of blocking the whole
        //    connection queue.
        guard setNonBlocking(fd) else { return .ioError(errno) }

        // 3. Build the server SSLContext.
        guard let ssl = SSLCreateContext(nil, .serverSide, .streamType) else {
            return .contextCreateFailed
        }

        // 4. Wire IO + connection context. The Context box must outlive
        //    the SSLContext — withExtendedLifetime below pins it for the
        //    whole handshake + sentinel write + close.
        let ctx = Context(fd: fd, prepend: peek)

        return withExtendedLifetime(ctx) { () -> Outcome in
            _ = SSLSetIOFuncs(ssl, sslReadCallback, sslWriteCallback)
            _ = SSLSetConnection(ssl, Unmanaged.passUnretained(ctx).toOpaque())
            let setStatus = SSLSetCertificate(ssl, [identity] as CFArray)
            if setStatus != errSecSuccess { return .identitySetFailed(setStatus) }
            _ = SSLSetProtocolVersionMin(ssl, .tlsProtocol12)
            _ = SSLSetClientSideAuthenticate(ssl, .neverAuthenticate)

            // 5. Handshake loop. The non-blocking IO callbacks WILL
            //    return errSSLWouldBlock; we wait on select(2) between
            //    retries so we are not a CPU-burning busy loop, and we
            //    bound the retry budget so a stuck peer cannot pin the
            //    connection thread forever.
            //
            //    Design trade-off: kqueue would be more elegant but
            //    requires a kqueue fd lifecycle. select(2) on a single
            //    fd with a 1s timeout is dead-simple, has the right
            //    fail-CLOSED bound (≤ maxWouldBlockRetries * 1s wall),
            //    and matches the t1d-2a spike's "small, auditable
            //    callback" posture. We document the trade-off here so
            //    a future round can swap select for kqueue without
            //    changing the seam contract.
            var blockBudget = maxWouldBlockRetries
            while true {
                let st = SSLHandshake(ssl)
                if st == errSecSuccess { break }
                if st == errSSLWouldBlock {
                    blockBudget -= 1
                    if blockBudget <= 0 {
                        return .wouldBlockBudgetExhausted
                    }
                    switch waitReadable(fd: ctx.fd, seconds: selectTimeoutSeconds) {
                    case .ready, .timeout:
                        continue
                    case .error(let e):
                        // r85 Carmack P3 fix: surface as ioError rather
                        // than waiting out the would-block budget.
                        return .ioError(e)
                    }
                }
                // ANY other return is fail-CLOSED. The opaque-tunnel
                // fallback is DELIBERATELY not taken here — that would
                // be a fail-OPEN bypass of the security control the
                // flag turns ON.
                return .handshakeFailed(st)
            }

            // 6. Sentinel plaintext write — proves to a test client
            //    that the server presented the t1d-1 leaf, that the
            //    handshake actually completed, and that we now have a
            //    plaintext channel. Child (iii) replaces this with a
            //    verified upstream pipe via runTerminationWithUpstream
            //    (this overload is now a test-only convenience).
            //
            //    r85 Allspaw P3 fix: budget exhaustion now returns
            //    .sentinelWriteBudgetExhausted, not .terminated. A
            //    nested function is used so we can `return` a distinct
            //    Outcome from inside withUnsafeBytes.
            let sentinel = sentinelOverride ?? Data("SENKANI-MITM-TERMINATED\n".utf8)
            let sentinelOutcome: Outcome = sentinel.withUnsafeBytes { (rb: UnsafeRawBufferPointer) -> Outcome in
                guard let base = rb.baseAddress else { return .terminated }
                var sent = 0
                var sentinelBudget = maxWouldBlockRetries
                while sent < sentinel.count {
                    var processed = 0
                    let st = SSLWrite(ssl, base.advanced(by: sent), sentinel.count - sent, &processed)
                    sent += processed
                    if st == errSecSuccess { continue }
                    if st == errSSLWouldBlock {
                        sentinelBudget -= 1
                        if sentinelBudget <= 0 {
                            return .sentinelWriteBudgetExhausted
                        }
                        switch waitReadable(fd: ctx.fd, seconds: selectTimeoutSeconds) {
                        case .ready, .timeout:
                            continue
                        case .error(let e):
                            return .ioError(e)
                        }
                    }
                    // Non-success non-wouldblock — surface as ioError
                    // rather than silently returning .terminated.
                    return .handshakeFailed(st)
                }
                return .terminated
            }

            // 7. Orderly shutdown of the TLS session. The fd is closed
            //    by the caller's defer { close(clientFD) }.
            _ = SSLClose(ssl)
            return sentinelOutcome
        }
    }

    /// T.1d-2b-iii — production termination + upstream-verify path.
    ///
    /// Runs the server-side TLS handshake (same prepend-buffer logic as
    /// `runTermination`) and, on success, invokes `pipeUpstream` with the
    /// live `SSLContextRef` so the caller can re-originate to the real
    /// upstream over a verified TLS leg and pipe plaintext both ways.
    ///
    /// The `pipeUpstream` closure receives the SSLContext + the
    /// post-handshake Context (which carries the client fd + any prepend
    /// residue) and returns the final `Outcome` (a `.upstream*` variant).
    /// `runTerminationWithUpstream` does NOT write the sentinel — the
    /// closure owns the plaintext side end-to-end.
    static func runTerminationWithUpstream(
        fd: Int32,
        peek: Data,
        leafPKCS12: Data,
        pipeUpstream: (SSLContext, Context) -> Outcome
    ) -> Outcome {
        let identity: SecIdentity
        do {
            identity = try MITMCertificateAuthority.loadIdentity(from: leafPKCS12)
        } catch {
            return .identityLoadFailed
        }
        guard setNonBlocking(fd) else { return .ioError(errno) }
        guard let ssl = SSLCreateContext(nil, .serverSide, .streamType) else {
            return .contextCreateFailed
        }
        let ctx = Context(fd: fd, prepend: peek)
        return withExtendedLifetime(ctx) { () -> Outcome in
            _ = SSLSetIOFuncs(ssl, sslReadCallback, sslWriteCallback)
            _ = SSLSetConnection(ssl, Unmanaged.passUnretained(ctx).toOpaque())
            let setStatus = SSLSetCertificate(ssl, [identity] as CFArray)
            if setStatus != errSecSuccess { return .identitySetFailed(setStatus) }
            _ = SSLSetProtocolVersionMin(ssl, .tlsProtocol12)
            _ = SSLSetClientSideAuthenticate(ssl, .neverAuthenticate)

            var blockBudget = maxWouldBlockRetries
            while true {
                let st = SSLHandshake(ssl)
                if st == errSecSuccess { break }
                if st == errSSLWouldBlock {
                    blockBudget -= 1
                    if blockBudget <= 0 {
                        return .wouldBlockBudgetExhausted
                    }
                    switch waitReadable(fd: ctx.fd, seconds: selectTimeoutSeconds) {
                    case .ready, .timeout: continue
                    case .error(let e): return .ioError(e)
                    }
                }
                return .handshakeFailed(st)
            }
            // Handshake succeeded — caller drives the upstream + pipe.
            let result = pipeUpstream(ssl, ctx)
            _ = SSLClose(ssl)
            return result
        }
    }
}
