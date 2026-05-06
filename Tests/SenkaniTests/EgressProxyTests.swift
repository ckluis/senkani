import Testing
import Foundation
import SQLite3
@testable import Core

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
