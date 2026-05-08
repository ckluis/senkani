import Foundation

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

    private let rules: EgressRuleEngine
    private let database: SessionDatabase
    private let clientFD: Int32
    private let startTime: DispatchTime

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

    init(rules: EgressRuleEngine, database: SessionDatabase, clientFD: Int32) {
        self.rules = rules
        self.database = database
        self.clientFD = clientFD
        self.startTime = DispatchTime.now()
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

        let evaluation = rules.evaluate(host: parsed.host)
        let normalizedHost = EgressHostNormalizer.normalize(parsed.host)
        if evaluation.decision == .deny {
            recordDecision(host: normalizedHost, method: parsed.method, decision: .deny, ruleId: evaluation.ruleId)
            sendStatus(403, message: "Forbidden")
            return
        }

        if parsed.method == "CONNECT" {
            handleConnect(parsed: parsed, ruleId: evaluation.ruleId, normalizedHost: normalizedHost)
        } else {
            handlePlainHTTP(
                parsed: parsed,
                ruleId: evaluation.ruleId,
                normalizedHost: normalizedHost,
                restOfHead: restOfHead
            )
        }
    }

    // MARK: - Plain HTTP

    private func handlePlainHTTP(
        parsed: HTTPRequestLine.ParsedRequest,
        ruleId: String,
        normalizedHost: String,
        restOfHead: Data
    ) {
        // Rewrite the absolute-URL request line to origin form.
        // `GET http://host:port/path HTTP/1.1` → `GET /path HTTP/1.1`.
        let path = parsed.path ?? "/"
        let rewrittenLine = "\(parsed.method) \(path) \(parsed.httpVersion)\r\n"
        guard let upstreamFD = EgressUpstreamConnector.connect(host: parsed.host, port: parsed.port) else {
            recordDecision(host: normalizedHost, method: parsed.method, decision: .deny, ruleId: "upstream_unreachable")
            sendStatus(502, message: "Bad Gateway")
            return
        }
        defer { close(upstreamFD) }

        // Allow row written before piping so chain integrity holds even
        // if the upstream resets mid-flight.
        recordDecision(host: normalizedHost, method: parsed.method, decision: .allow, ruleId: ruleId)

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
        normalizedHost: String
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
            recordDecision(host: normalizedHost, method: parsed.method, decision: .deny, ruleId: "sni_unparseable")
            return
        }

        let sni: String
        do {
            sni = try TLSClientHelloSNI.extract(peek)
        } catch {
            recordDecision(host: normalizedHost, method: parsed.method, decision: .deny, ruleId: "sni_unparseable")
            return
        }

        let normalizedSNI = EgressHostNormalizer.normalize(sni)
        if normalizedSNI != normalizedHost {
            recordDecision(host: normalizedHost, method: parsed.method, decision: .deny, ruleId: "sni_mismatch")
            return
        }

        // SNI matches CONNECT line. Open upstream and tunnel.
        guard let upstreamFD = EgressUpstreamConnector.connect(host: parsed.host, port: parsed.port) else {
            recordDecision(host: normalizedHost, method: parsed.method, decision: .deny, ruleId: "upstream_unreachable")
            return
        }
        defer { close(upstreamFD) }

        recordDecision(host: normalizedHost, method: parsed.method, decision: .allow, ruleId: ruleId)

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

    private func recordDecision(host: String, method: String, decision: EgressRule.Decision, ruleId: String) {
        let elapsed = DispatchTime.now().uptimeNanoseconds &- startTime.uptimeNanoseconds
        let latencyUs = Int64(elapsed / 1_000)
        database.recordEgressDecision(
            host: host,
            method: method,
            decision: decision,
            ruleId: ruleId,
            latencyUs: max(latencyUs, 1)  // always > 0 per acceptance
        )
    }
}
