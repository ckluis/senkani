import Testing
import Foundation
import SQLite3
@testable import Core

#if canImport(Darwin)
import Darwin
#endif

/// T.1a — EgressProxy daemon scaffold tests. Covers:
///   - host normalization (case, default port, trailing dot, slash)
///   - rule engine (exact / prefix / suffix / glob, deny-wins,
///     deny-on-miss default)
///   - HTTP request line parser (absolute URL form + CONNECT form)
///   - TLS ClientHello SNI extractor
///   - chained egress_decisions writes + verification
///   - migration v19 idempotency
@Suite("EgressProxy — host normalizer")
struct EgressHostNormalizerTests {

    @Test("Normalizes case + default port + trailing dot")
    func normalizesCanonicalForms() {
        #expect(EgressHostNormalizer.normalize("Example.COM:80") == "example.com")
        #expect(EgressHostNormalizer.normalize("example.com.") == "example.com")
        #expect(EgressHostNormalizer.normalize("EXAMPLE.com:443/") == "example.com")
        #expect(EgressHostNormalizer.normalize("api.example.com") == "api.example.com")
    }

    @Test("Non-default ports are preserved")
    func preservesNonDefaultPorts() {
        #expect(EgressHostNormalizer.normalize("example.com:8443") == "example.com:8443")
        #expect(EgressHostNormalizer.normalize("EXAMPLE.com:8080") == "example.com:8080")
    }

    @Test("splitHostPort parses host:port and rejects malformed input")
    func splitHostPortParses() {
        let ok = EgressHostNormalizer.splitHostPort("example.com:443")
        #expect(ok?.host == "example.com")
        #expect(ok?.port == 443)
        #expect(EgressHostNormalizer.splitHostPort("noport") == nil)
        #expect(EgressHostNormalizer.splitHostPort("host:notaport") == nil)
        #expect(EgressHostNormalizer.splitHostPort("host:99999") == nil)
    }
}

@Suite("EgressProxy — rule engine")
struct EgressRuleEngineTests {

    @Test("Exact rule matches only the exact host")
    func exactMatchesExact() {
        let r = EgressRule(id: "r1", pattern: "example.com", mode: .exact, decision: .allow)
        #expect(r.matches(host: "example.com"))
        #expect(!r.matches(host: "api.example.com"))
        #expect(!r.matches(host: "notexample.com"))
    }

    @Test("Suffix rule honors label-boundary anchor")
    func suffixHonorsLabelBoundary() {
        let r = EgressRule(id: "r1", pattern: "example.com", mode: .suffix, decision: .allow)
        #expect(r.matches(host: "example.com"))
        #expect(r.matches(host: "api.example.com"))
        #expect(r.matches(host: "deep.api.example.com"))
        #expect(!r.matches(host: "notexample.com"))
        #expect(!r.matches(host: "exampleXcom"))
    }

    @Test("Glob rule matches single * wildcard")
    func globMatches() {
        let r = EgressRule(id: "r1", pattern: "*.example.com", mode: .glob, decision: .allow)
        #expect(r.matches(host: "api.example.com"))
        #expect(r.matches(host: "deep.api.example.com"))
        #expect(!r.matches(host: "example.com")) // empty middle disallowed when both sides non-empty
        #expect(!r.matches(host: "notexample.com"))
    }

    @Test("Deny wins over allow when both match")
    func denyWinsOverAllow() {
        let allow = EgressRule(id: "a", pattern: "example.com", mode: .suffix, decision: .allow)
        let deny  = EgressRule(id: "d", pattern: "evil.example.com", mode: .exact, decision: .deny)
        let engine = EgressRuleEngine(rules: [allow, deny])
        let result = engine.evaluate(host: "evil.example.com")
        #expect(result.decision == .deny)
        #expect(result.ruleId == "d")
    }

    @Test("Default deny on miss")
    func defaultDenyOnMiss() {
        let engine = EgressRuleEngine(rules: [
            EgressRule(id: "a", pattern: "example.com", mode: .exact, decision: .allow)
        ])
        let result = engine.evaluate(host: "unknown.host")
        #expect(result.decision == .deny)
        #expect(result.ruleId == "default-deny")
    }

    @Test("Engine normalizes the host before matching")
    func engineNormalizesHost() {
        let engine = EgressRuleEngine(rules: [
            EgressRule(id: "a", pattern: "example.com", mode: .exact, decision: .allow)
        ])
        let result = engine.evaluate(host: "Example.COM:80.")
        #expect(result.decision == .allow)
        #expect(result.ruleId == "a")
    }

    @Test("Static rule deny p95 under 1ms across 100 hosts")
    func denyLatencyP95UnderOneMs() {
        // P95 deny budget = 1 ms. We measure 100 misses against a
        // 100-rule fixture and assert each call returned in <1 ms.
        var rules: [EgressRule] = []
        for i in 0..<100 {
            rules.append(EgressRule(id: "r\(i)", pattern: "host\(i).example.com", mode: .exact, decision: .allow))
        }
        let engine = EgressRuleEngine(rules: rules)

        var latenciesUs: [Int64] = []
        for i in 0..<100 {
            let start = DispatchTime.now()
            _ = engine.evaluate(host: "miss\(i).unknown")
            let end = DispatchTime.now()
            latenciesUs.append(Int64(end.uptimeNanoseconds - start.uptimeNanoseconds) / 1000)
        }
        latenciesUs.sort()
        let p95 = latenciesUs[Int(Double(latenciesUs.count) * 0.95)]
        // 1 ms == 1000 us; we assert p95 well under that — 100 string
        // compares is microseconds even on a slow CI runner.
        #expect(p95 < 1000, "p95 deny latency too high: \(p95)us")
    }
}

@Suite("EgressProxy — HTTP request line parser")
struct HTTPRequestLineTests {

    @Test("Parses absolute-URL HTTP_PROXY GET request line")
    func parsesAbsoluteHTTPGet() throws {
        let parsed = try HTTPRequestLine.parse("GET http://example.com/path?q=1 HTTP/1.1")
        #expect(parsed.method == "GET")
        #expect(parsed.host == "example.com")
        #expect(parsed.port == 80)
        #expect(parsed.path == "/path?q=1")
        #expect(parsed.httpVersion == "HTTP/1.1")
    }

    @Test("Parses CONNECT request line for HTTPS_PROXY")
    func parsesConnect() throws {
        let parsed = try HTTPRequestLine.parse("CONNECT example.com:443 HTTP/1.1")
        #expect(parsed.method == "CONNECT")
        #expect(parsed.host == "example.com")
        #expect(parsed.port == 443)
        #expect(parsed.path == nil)
    }

    @Test("Origin-form (relative path) is rejected — proxy must see absolute URL")
    func originFormRejected() {
        #expect(throws: HTTPRequestLine.ParseError.missingHost) {
            try HTTPRequestLine.parse("GET / HTTP/1.1")
        }
    }

    @Test("Empty input throws empty error")
    func emptyInputThrowsEmpty() {
        #expect(throws: HTTPRequestLine.ParseError.empty) {
            try HTTPRequestLine.parse("   ")
        }
    }
}

@Suite("EgressProxy — TLS ClientHello SNI extractor")
struct TLSClientHelloSNITests {

    /// Build a minimal valid TLS 1.2 ClientHello carrying one server_name
    /// extension with the given hostname. This mirrors what curl/openssl
    /// produce on the wire — just enough to parse, not a full TLS impl.
    private static func clientHello(sni: String) -> Data {
        var ext = Data()
        // server_name extension data: list_len(2) + name_type(1) + name_len(2) + name
        let nameBytes = Data(sni.utf8)
        let listInner = Data([0x00]) + UInt16(nameBytes.count).bigEndianBytes + nameBytes
        let listFraming = UInt16(listInner.count).bigEndianBytes + listInner
        ext.append(UInt16(0x0000).bigEndianBytes) // ext type = server_name
        ext.append(UInt16(listFraming.count).bigEndianBytes)
        ext.append(listFraming)

        var hello = Data()
        hello.append(UInt16(0x0303).bigEndianBytes) // client_version
        hello.append(Data(repeating: 0, count: 32)) // random
        hello.append(0x00) // session_id len
        hello.append(UInt16(2).bigEndianBytes) // cipher_suites len
        hello.append(Data([0x00, 0x35]))       // one cipher
        hello.append(0x01) // compression methods len
        hello.append(0x00) // null compression
        hello.append(UInt16(ext.count).bigEndianBytes)
        hello.append(ext)

        var handshake = Data()
        handshake.append(0x01) // ClientHello
        let lenU24 = UInt32(hello.count)
        handshake.append(UInt8((lenU24 >> 16) & 0xff))
        handshake.append(UInt8((lenU24 >> 8) & 0xff))
        handshake.append(UInt8(lenU24 & 0xff))
        handshake.append(hello)

        var record = Data()
        record.append(0x16) // handshake
        record.append(UInt16(0x0301).bigEndianBytes) // legacy version
        record.append(UInt16(handshake.count).bigEndianBytes)
        record.append(handshake)
        return record
    }

    @Test("Extracts SNI from a synthesized ClientHello")
    func extractsSNI() throws {
        let bytes = Self.clientHello(sni: "example.com")
        let host = try TLSClientHelloSNI.extract(bytes)
        #expect(host == "example.com")
    }

    @Test("Truncated bytes raise truncated error")
    func truncatedRaises() {
        let bytes = Self.clientHello(sni: "example.com")
        let trunc = bytes.prefix(20)
        #expect(throws: TLSClientHelloSNI.ParseError.self) {
            _ = try TLSClientHelloSNI.extract(trunc)
        }
    }

    @Test("Non-handshake content type raises notHandshake")
    func nonHandshakeRaises() {
        var bytes = Self.clientHello(sni: "example.com")
        bytes[0] = 0x17 // application_data — not a handshake
        #expect(throws: TLSClientHelloSNI.ParseError.notHandshake) {
            _ = try TLSClientHelloSNI.extract(bytes)
        }
    }
}

@Suite("EgressProxy — chained decision store + chain verifier")
struct EgressDecisionStoreTests {

    private static func tempDB() -> SessionDatabase {
        let dir = NSTemporaryDirectory() + "senkani-egress-tests-\(UUID().uuidString)/"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = dir + "senkani.db"
        return SessionDatabase(path: path)
    }

    @Test("Records a decision row and reads it back")
    func recordsAndReads() {
        let db = Self.tempDB()
        let ok = db.recordEgressDecision(
            host: "example.com", method: "GET",
            decision: .allow, ruleId: "test-rule",
            latencyUs: 42
        )
        #expect(ok)
        let rows = db.recentEgressDecisions(limit: 10)
        #expect(rows.count == 1)
        #expect(rows[0].host == "example.com")
        #expect(rows[0].method == "GET")
        #expect(rows[0].decision == .allow)
        #expect(rows[0].ruleId == "test-rule")
        #expect(rows[0].latencyUs == 42)
    }

    @Test("Successive writes form a chain that verifies")
    func chainVerifies() {
        let db = Self.tempDB()
        for i in 0..<5 {
            db.recordEgressDecision(
                host: "host\(i).example.com",
                method: "CONNECT",
                decision: i % 2 == 0 ? .allow : .deny,
                ruleId: "rule-\(i)",
                latencyUs: Int64(i * 10)
            )
        }
        let result = ChainVerifier.verifyEgressDecisions(db)
        switch result {
        case .ok:
            // success
            break
        default:
            Issue.record("expected .ok, got \(result)")
        }
    }

    @Test("Tampering with a decision row breaks verification at that row")
    func tamperBreaksChain() {
        let db = Self.tempDB()
        for i in 0..<3 {
            db.recordEgressDecision(
                host: "h\(i).example.com", method: "GET",
                decision: .allow, ruleId: "r\(i)",
                latencyUs: 0
            )
        }
        // Tamper: rewrite the host of row 2 directly via SQLite, leaving
        // entry_hash untouched. Verifier should detect the divergence.
        db.queue.sync {
            guard let raw = db.db else { return }
            let sql = "UPDATE egress_decisions SET host = 'attacker.example.com' WHERE id = 2;"
            sqlite3_exec(raw, sql, nil, nil, nil)
        }
        let result = ChainVerifier.verifyEgressDecisions(db)
        switch result {
        case .brokenAt(let table, _, _, _):
            #expect(table == "egress_decisions")
        default:
            Issue.record("expected .brokenAt, got \(result)")
        }
    }

    @Test("egressDecisionCount tracks total rows")
    func countTracksRows() {
        let db = Self.tempDB()
        #expect(db.egressDecisionCount() == 0)
        db.recordEgressDecision(host: "a.com", method: "GET", decision: .allow, ruleId: "r", latencyUs: 0)
        db.recordEgressDecision(host: "b.com", method: "GET", decision: .deny, ruleId: "r", latencyUs: 0)
        #expect(db.egressDecisionCount() == 2)
    }

    @Test("Migration v19 creates egress_decisions table")
    func migrationCreatesTable() {
        let db = Self.tempDB()
        db.queue.sync {
            guard let raw = db.db else { return }
            var stmt: OpaquePointer?
            let sql = "SELECT name FROM sqlite_master WHERE type='table' AND name='egress_decisions';"
            sqlite3_prepare_v2(raw, sql, -1, &stmt, nil)
            defer { sqlite3_finalize(stmt) }
            #expect(sqlite3_step(stmt) == SQLITE_ROW)
        }
    }
}

// MARK: - Test helpers

private extension UInt16 {
    var bigEndianBytes: Data {
        Data([UInt8((self >> 8) & 0xff), UInt8(self & 0xff)])
    }
}

/// Build a minimal valid TLS 1.2 ClientHello carrying one server_name
/// extension with the given hostname. File-level so multiple suites
/// can share it.
private func makeClientHello(sni: String) -> Data {
    var ext = Data()
    let nameBytes = Data(sni.utf8)
    let listInner = Data([0x00]) + UInt16(nameBytes.count).bigEndianBytes + nameBytes
    let listFraming = UInt16(listInner.count).bigEndianBytes + listInner
    ext.append(UInt16(0x0000).bigEndianBytes)
    ext.append(UInt16(listFraming.count).bigEndianBytes)
    ext.append(listFraming)

    var hello = Data()
    hello.append(UInt16(0x0303).bigEndianBytes)
    hello.append(Data(repeating: 0, count: 32))
    hello.append(0x00)
    hello.append(UInt16(2).bigEndianBytes)
    hello.append(Data([0x00, 0x35]))
    hello.append(0x01)
    hello.append(0x00)
    hello.append(UInt16(ext.count).bigEndianBytes)
    hello.append(ext)

    var handshake = Data()
    handshake.append(0x01)
    let lenU24 = UInt32(hello.count)
    handshake.append(UInt8((lenU24 >> 16) & 0xff))
    handshake.append(UInt8((lenU24 >> 8) & 0xff))
    handshake.append(UInt8(lenU24 & 0xff))
    handshake.append(hello)

    var record = Data()
    record.append(0x16)
    record.append(UInt16(0x0301).bigEndianBytes)
    record.append(UInt16(handshake.count).bigEndianBytes)
    record.append(handshake)
    return record
}

#if canImport(Darwin)
/// Minimal raw-TCP fixture server: binds 127.0.0.1:0, accepts a single
/// connection, runs the supplied handler with the connected fd, then
/// closes the fd and the listener.
final class FixtureTCPServer: @unchecked Sendable {
    private var listenFD: Int32 = -1
    private(set) var port: Int = 0
    private let queue = DispatchQueue(label: "fixture-tcp", qos: .userInitiated)
    private var ready: DispatchSemaphore?

    enum FixtureError: Error { case bindFailed, listenFailed, getsocknameFailed }

    init() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = UInt32(0x7F00_0001).bigEndian
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        let br = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if br != 0 { close(fd); throw FixtureError.bindFailed }
        if listen(fd, 8) != 0 { close(fd); throw FixtureError.listenFailed }
        var bound = sockaddr_in()
        var blen = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nr = withUnsafeMutablePointer(to: &bound) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                getsockname(fd, sa, &blen)
            }
        }
        if nr != 0 { close(fd); throw FixtureError.getsocknameFailed }
        self.port = Int(UInt16(bigEndian: bound.sin_port))
        self.listenFD = fd
    }

    /// Accept one connection asynchronously and run handler with the fd.
    /// Closes the fd after handler returns.
    func acceptOnce(handler: @Sendable @escaping (Int32) -> Void) {
        let fd = listenFD
        queue.async {
            var cli = sockaddr_in()
            var clen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let cfd = withUnsafeMutablePointer(to: &cli) { ptr -> Int32 in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    accept(fd, sa, &clen)
                }
            }
            guard cfd >= 0 else { return }
            handler(cfd)
            close(cfd)
        }
    }

    func shutdown() {
        if listenFD >= 0 { close(listenFD); listenFD = -1 }
    }

    deinit { shutdown() }
}

/// Connect to 127.0.0.1:port and return the fd, or nil on failure.
func connectToLocalhost(port: Int) -> Int32? {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = UInt16(port).bigEndian
    addr.sin_addr.s_addr = UInt32(0x7F00_0001).bigEndian
    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    var tv = timeval(tv_sec: 5, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    let cr = withUnsafePointer(to: &addr) { ptr -> Int32 in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
            Darwin.connect(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    if cr != 0 { close(fd); return nil }
    return fd
}

func writeAllToFD(_ fd: Int32, _ data: Data) -> Bool {
    var written = 0
    let total = data.count
    while written < total {
        let n = data.withUnsafeBytes { (rb: UnsafeRawBufferPointer) -> Int in
            guard let base = rb.baseAddress else { return -1 }
            return Darwin.write(fd, base.advanced(by: written), total - written)
        }
        if n <= 0 { return false }
        written += n
    }
    return true
}

func readAllUntilEOF(_ fd: Int32, max: Int = 64 * 1024) -> Data {
    var out = Data()
    var buf = [UInt8](repeating: 0, count: 4096)
    while out.count < max {
        let n = buf.withUnsafeMutableBufferPointer { ptr -> Int in
            Darwin.read(fd, ptr.baseAddress, ptr.count)
        }
        if n <= 0 { break }
        out.append(contentsOf: buf[0..<n])
    }
    return out
}

func readBytes(_ fd: Int32, count: Int) -> Data {
    var out = Data()
    var buf = [UInt8](repeating: 0, count: count)
    while out.count < count {
        let want = count - out.count
        let n = buf.withUnsafeMutableBufferPointer { ptr -> Int in
            Darwin.read(fd, ptr.baseAddress, want)
        }
        if n <= 0 { break }
        out.append(contentsOf: buf[0..<n])
    }
    return out
}

/// Read until the HTTP head terminator `\r\n\r\n` or EOF. Returns the
/// full bytes read INCLUDING the terminator.
func readHTTPHead(_ fd: Int32, max: Int = 16 * 1024) -> Data {
    var out = Data()
    var buf = [UInt8](repeating: 0, count: 1024)
    let term = Data([0x0d, 0x0a, 0x0d, 0x0a])
    while out.count < max {
        let n = buf.withUnsafeMutableBufferPointer { ptr -> Int in
            Darwin.read(fd, ptr.baseAddress, ptr.count)
        }
        if n <= 0 { break }
        out.append(contentsOf: buf[0..<n])
        if out.range(of: term) != nil { break }
    }
    return out
}

private func tempDB() -> SessionDatabase {
    let dir = NSTemporaryDirectory() + "senkani-egress-listener-tests-\(UUID().uuidString)/"
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    return SessionDatabase(path: dir + "senkani.db")
}

private func waitForRow(db: SessionDatabase, timeoutSeconds: Double = 3.0) -> EgressDecisionStore.Row? {
    let deadline = Date().addingTimeInterval(timeoutSeconds)
    while Date() < deadline {
        let rows = db.recentEgressDecisions(limit: 1)
        if let row = rows.first { return row }
        usleep(20_000)
    }
    return nil
}

@Suite("EgressProxy — live listener (T.1a.2)")
struct EgressListenerLiveTests {

    @Test("Listener binds, writes port file, status reports running")
    func listenerWritesPortFile() throws {
        let db = tempDB()
        let portPath = NSTemporaryDirectory() + "egress-port-\(UUID().uuidString).txt"
        defer { unlink(portPath) }
        let listener = EgressListener(
            rules: EgressRuleEngine(rules: []),
            database: db,
            config: .init(port: 0, writePortFile: true, portFilePath: portPath)
        )
        try listener.start()
        defer { listener.stop() }

        #expect(listener.port > 0)
        #expect(listener.isRunning)

        // Port file should be readable and contain the same port.
        let raw = try String(contentsOfFile: portPath, encoding: .utf8)
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(Int(trimmed) == listener.port)
    }

    @Test("Plain HTTP allow: rewrites + pipes upstream and writes one allow row")
    func plainHTTPAllowPipes() throws {
        let db = tempDB()
        let fixture = try FixtureTCPServer()
        defer { fixture.shutdown() }

        // Fixture echoes a canned 200 response after reading the request head.
        let body = "hello-world"
        fixture.acceptOnce { fd in
            // Drain request head until \r\n\r\n.
            var head = Data()
            var buf = [UInt8](repeating: 0, count: 1024)
            while head.range(of: Data([0x0d, 0x0a, 0x0d, 0x0a])) == nil {
                let n = buf.withUnsafeMutableBufferPointer { ptr -> Int in
                    Darwin.read(fd, ptr.baseAddress, ptr.count)
                }
                if n <= 0 { return }
                head.append(contentsOf: buf[0..<n])
            }
            let resp = "HTTP/1.1 200 OK\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n\(body)"
            _ = writeAllToFD(fd, Data(resp.utf8))
        }

        let listener = EgressListener(
            rules: EgressRuleEngine(rules: [
                EgressRule(id: "test-allow", pattern: "127.0.0.1", mode: .exact, decision: .allow)
            ]),
            database: db,
            config: .init(port: 0, writePortFile: false, portFilePath: "")
        )
        try listener.start()
        defer { listener.stop() }

        let cfd = connectToLocalhost(port: listener.port)
        try #require(cfd != nil)
        let cli = cfd!
        defer { close(cli) }

        let req = "GET http://127.0.0.1:\(fixture.port)/ HTTP/1.1\r\nHost: 127.0.0.1:\(fixture.port)\r\nConnection: close\r\n\r\n"
        #expect(writeAllToFD(cli, Data(req.utf8)))

        let resp = readAllUntilEOF(cli)
        let respStr = String(data: resp, encoding: .utf8) ?? ""
        #expect(respStr.contains("200 OK"))
        #expect(respStr.contains(body))

        let row = waitForRow(db: db)
        try #require(row != nil)
        #expect(row!.decision == .allow)
        #expect(row!.host == "127.0.0.1")
        #expect(row!.method == "GET")
        #expect(row!.ruleId == "test-allow")
        #expect(row!.latencyUs > 0)
    }

    @Test("Plain HTTP deny: returns 403 and writes deny row")
    func plainHTTPDenyReturns403() throws {
        let db = tempDB()
        let listener = EgressListener(
            rules: EgressRuleEngine(rules: [
                EgressRule(id: "blockit", pattern: "blocked.example.com", mode: .exact, decision: .deny)
            ]),
            database: db,
            config: .init(port: 0, writePortFile: false, portFilePath: "")
        )
        try listener.start()
        defer { listener.stop() }

        let cfd = connectToLocalhost(port: listener.port)
        try #require(cfd != nil)
        let cli = cfd!
        defer { close(cli) }

        let req = "GET http://blocked.example.com/ HTTP/1.1\r\nHost: blocked.example.com\r\nConnection: close\r\n\r\n"
        #expect(writeAllToFD(cli, Data(req.utf8)))

        let resp = readAllUntilEOF(cli)
        let respStr = String(data: resp, encoding: .utf8) ?? ""
        #expect(respStr.contains("403 Forbidden"))

        let row = waitForRow(db: db)
        try #require(row != nil)
        #expect(row!.decision == .deny)
        #expect(row!.host == "blocked.example.com")
        #expect(row!.ruleId == "blockit")
    }

    @Test("CONNECT denied host: 403 + deny row, no upstream connect")
    func connectDeniedHost() throws {
        let db = tempDB()
        let listener = EgressListener(
            rules: EgressRuleEngine(rules: []),  // empty → default-deny
            database: db,
            config: .init(port: 0, writePortFile: false, portFilePath: "")
        )
        try listener.start()
        defer { listener.stop() }

        let cfd = connectToLocalhost(port: listener.port)
        try #require(cfd != nil)
        let cli = cfd!
        defer { close(cli) }

        let req = "CONNECT denied.example.com:443 HTTP/1.1\r\nHost: denied.example.com:443\r\n\r\n"
        #expect(writeAllToFD(cli, Data(req.utf8)))

        let resp = readAllUntilEOF(cli)
        let respStr = String(data: resp, encoding: .utf8) ?? ""
        #expect(respStr.contains("403 Forbidden"))

        let row = waitForRow(db: db)
        try #require(row != nil)
        #expect(row!.decision == .deny)
        #expect(row!.method == "CONNECT")
        #expect(row!.ruleId == "default-deny")
    }

    @Test("CONNECT SNI mismatch: writes sni_mismatch deny and tears down")
    func connectSNIMismatchTearsDown() throws {
        let db = tempDB()
        let listener = EgressListener(
            rules: EgressRuleEngine(rules: [
                EgressRule(id: "allow-loopback", pattern: "127.0.0.1", mode: .exact, decision: .allow)
            ]),
            database: db,
            config: .init(port: 0, writePortFile: false, portFilePath: "")
        )
        try listener.start()
        defer { listener.stop() }

        let cfd = connectToLocalhost(port: listener.port)
        try #require(cfd != nil)
        let cli = cfd!
        defer { close(cli) }

        // Use a port where no fixture is listening; SNI mismatch means
        // the proxy never connects upstream, so the port is irrelevant.
        let req = "CONNECT 127.0.0.1:9 HTTP/1.1\r\nHost: 127.0.0.1:9\r\n\r\n"
        #expect(writeAllToFD(cli, Data(req.utf8)))

        // Drain the 200 reply head fully so leftover bytes don't leak
        // into the post-handshake read.
        let okResp = readHTTPHead(cli)
        let okStr = String(data: okResp, encoding: .utf8) ?? ""
        #expect(okStr.contains("200 Connection Established"))

        // Now send a ClientHello with a MISMATCHING SNI.
        let hello = makeClientHello(sni: "evil.example.com")
        #expect(writeAllToFD(cli, hello))

        // Read until EOF — proxy tears down without piping.
        let tail = readAllUntilEOF(cli)
        // Tail should be empty (no upstream bytes piped back).
        #expect(tail.isEmpty)

        let row = waitForRow(db: db)
        try #require(row != nil)
        #expect(row!.decision == .deny)
        #expect(row!.ruleId == "sni_mismatch")
        #expect(row!.method == "CONNECT")
        // Host as recorded is the post-normalization parsed host
        // (port stored separately in the parsed struct, not concatenated
        // into the audit row).
        #expect(row!.host == "127.0.0.1")
    }

    @Test("CONNECT allow + matching SNI: pipes bytes both directions to upstream")
    func connectMatchingSNIPipes() throws {
        let db = tempDB()
        let fixture = try FixtureTCPServer()
        defer { fixture.shutdown() }

        // Fixture echoes whatever bytes it receives, then closes.
        fixture.acceptOnce { fd in
            var buf = [UInt8](repeating: 0, count: 4096)
            while true {
                let n = buf.withUnsafeMutableBufferPointer { ptr -> Int in
                    Darwin.read(fd, ptr.baseAddress, ptr.count)
                }
                if n <= 0 { return }
                _ = buf.withUnsafeBufferPointer { ptr -> Int in
                    Darwin.write(fd, ptr.baseAddress, n)
                }
            }
        }

        let listener = EgressListener(
            rules: EgressRuleEngine(rules: [
                EgressRule(id: "allow-loopback", pattern: "127.0.0.1", mode: .exact, decision: .allow)
            ]),
            database: db,
            config: .init(port: 0, writePortFile: false, portFilePath: "")
        )
        try listener.start()
        defer { listener.stop() }

        let cfd = connectToLocalhost(port: listener.port)
        try #require(cfd != nil)
        let cli = cfd!
        defer { close(cli) }

        let req = "CONNECT 127.0.0.1:\(fixture.port) HTTP/1.1\r\nHost: 127.0.0.1:\(fixture.port)\r\n\r\n"
        #expect(writeAllToFD(cli, Data(req.utf8)))

        // Drain the 200 reply head before sending the ClientHello, so
        // leftover header bytes don't pollute the echo read below.
        let okResp = readHTTPHead(cli)
        let okStr = String(data: okResp, encoding: .utf8) ?? ""
        #expect(okStr.contains("200 Connection Established"))

        // Send a ClientHello with matching SNI. Fixture will echo it.
        // The CONNECT host is "127.0.0.1" (port stripped during normalization).
        let hello = makeClientHello(sni: "127.0.0.1")
        let helloChecksum = sha256Prefix(hello)
        #expect(writeAllToFD(cli, hello))

        // Read echo back.
        let echoed = readBytes(cli, count: hello.count)
        #expect(echoed.count == hello.count)
        #expect(sha256Prefix(echoed) == helloChecksum)

        let row = waitForRow(db: db)
        try #require(row != nil)
        #expect(row!.decision == .allow)
        #expect(row!.method == "CONNECT")
    }

    @Test("Stop unlinks the port file and clears the bound port")
    func stopClearsPortFile() throws {
        let db = tempDB()
        let portPath = NSTemporaryDirectory() + "egress-stop-\(UUID().uuidString).txt"
        let listener = EgressListener(
            rules: EgressRuleEngine(rules: []),
            database: db,
            config: .init(port: 0, writePortFile: true, portFilePath: portPath)
        )
        try listener.start()
        let port = listener.port
        #expect(port > 0)
        #expect(FileManager.default.fileExists(atPath: portPath))

        listener.stop()

        #expect(listener.port == 0)
        #expect(!listener.isRunning)
        #expect(!FileManager.default.fileExists(atPath: portPath))
    }

    @Test("Chain integrity holds across 1k decision write-storm")
    func chainIntegrityAfter1kWrites() throws {
        let db = tempDB()
        for i in 0..<1_000 {
            let ok = db.recordEgressDecision(
                host: "host\(i % 32).example.com",
                method: i % 2 == 0 ? "GET" : "CONNECT",
                decision: i % 5 == 0 ? .deny : .allow,
                ruleId: i % 5 == 0 ? "deny-rule" : "allow-rule",
                latencyUs: Int64(i)
            )
            #expect(ok)
        }
        #expect(db.egressDecisionCount() == 1_000)

        let result = ChainVerifier.verifyEgressDecisions(db)
        switch result {
        case .ok:
            break
        default:
            Issue.record("expected .ok across 1k writes, got \(result)")
        }
    }
}
#endif

/// 64-bit FNV-1a — cheap fingerprint used to compare two Data blobs
/// for equality without having to import CryptoKit in the test target.
private func sha256Prefix(_ d: Data) -> UInt64 {
    var hash: UInt64 = 0xcbf29ce484222325
    for byte in d {
        hash ^= UInt64(byte)
        hash &*= 0x100000001b3
    }
    return hash
}
