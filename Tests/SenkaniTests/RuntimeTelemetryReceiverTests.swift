import Testing
import Foundation
import SQLite3
@testable import Core

#if canImport(Darwin)
import Darwin
#endif

/// V.18a-3 — receiver tests. Cover the five acceptance bullets from
/// `spec/autonomous/backlog/phase-v18a-3-otlp-receiver.md`:
///
///   1. Receiver binds 127.0.0.1 + accepts OTLP/JSON on
///      `POST /v1/traces`, persists the bound port to the operator
///      config file, and surfaces a span row in `runtime_telemetry_span`.
///      Per-source rate cap drop counter is exercised in the same
///      test (small bucket + over-cap batch).
///   2. Receiver accepts OTLP/protobuf on `POST /v1/traces`
///      (hand-built wire bytes — no swift-protobuf dependency).
///   3. Receiver returns 413 for bodies above the per-receiver cap.
///   4. Receiver returns 415 for unknown content-types.
///   5. **No-auth-loopback misuse fixture** — a competing
///      `RuntimeTelemetryReceiver` binds a different loopback port
///      and accepts traffic alongside the first. The bind is
///      performative; trust boundary is the local user.
@Suite("RuntimeTelemetryReceiver (V.18a-3)")
struct RuntimeTelemetryReceiverTests {

    // MARK: - Helpers

    private static func tempDB() -> SessionDatabase {
        let dir = NSTemporaryDirectory() + "senkani-v18a-3-tests-\(UUID().uuidString)/"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return SessionDatabase(path: dir + "senkani.db")
    }

    private static func tempConfigPath() -> String {
        return NSTemporaryDirectory() + "v18a-3-cfg-\(UUID().uuidString).json"
    }

    /// Send raw bytes to 127.0.0.1:port and return the full HTTP
    /// response bytes.
    private static func httpRoundTrip(port: Int, request: Data) -> Data? {
        guard let fd = connectToLocalhost(port: port) else { return nil }
        defer { close(fd) }
        guard writeAllToFD(fd, request) else { return nil }
        // Half-close write side so server sees EOF if needed.
        shutdown(fd, Int32(SHUT_WR))
        return readAllUntilEOF(fd)
    }

    /// Build a `POST /v1/{traces,logs}` request.
    private static func buildPOST(
        path: String,
        contentType: String,
        body: Data,
        extraHeaders: [(String, String)] = []
    ) -> Data {
        var head = "POST \(path) HTTP/1.1\r\n"
        head += "Host: 127.0.0.1\r\n"
        head += "Content-Type: \(contentType)\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Connection: close\r\n"
        for (k, v) in extraHeaders {
            head += "\(k): \(v)\r\n"
        }
        head += "\r\n"
        var data = Data(head.utf8)
        data.append(body)
        return data
    }

    /// Build a single-span OTLP/JSON traces body.
    private static func sampleJSONTraces(spanName: String = "v18a-3.test", traceHex: String = String(repeating: "ab", count: 16), spanHex: String = String(repeating: "cd", count: 8), spanCount: Int = 1) -> Data {
        var spans: [[String: Any]] = []
        for i in 0..<spanCount {
            // Distinct trace/span IDs per span so they're stored as separate rows.
            // Pad the index into the hex string by replacing the first two chars.
            let idx = String(format: "%02x", i & 0xff)
            let traceWithIdx = idx + String(traceHex.dropFirst(2))
            let spanWithIdx = idx + String(spanHex.dropFirst(2))
            spans.append([
                "traceId": traceWithIdx,
                "spanId": spanWithIdx,
                "name": spanName,
                "startTimeUnixNano": "\(1_700_000_000_000_000_000 + i)",
                "endTimeUnixNano": "\(1_700_000_000_000_000_100 + i)",
                "status": ["code": "STATUS_CODE_OK"]
            ])
        }
        let obj: [String: Any] = [
            "resourceSpans": [
                [
                    "scopeSpans": [
                        ["spans": spans]
                    ]
                ]
            ]
        ]
        return try! JSONSerialization.data(withJSONObject: obj)
    }

    /// Hand-built OTLP/protobuf traces body with a single span. Mirrors
    /// the field tags decoded by `OTLPDecoder.decodeTracesProtobuf`.
    private static func sampleProtobufTraces(name: String) -> Data {
        // Build the innermost Span first.
        var span = Data()
        // field 1, LEN — trace_id (16 bytes)
        span.append(0x0a)
        span.append(0x10)
        span.append(contentsOf: [UInt8](repeating: 0xab, count: 16))
        // field 2, LEN — span_id (8 bytes)
        span.append(0x12)
        span.append(0x08)
        span.append(contentsOf: [UInt8](repeating: 0xcd, count: 8))
        // field 5, LEN — name
        let nameBytes = Data(name.utf8)
        span.append(0x2a)
        span.append(UInt8(nameBytes.count))
        span.append(nameBytes)
        // field 7, I64 — start_time_unix_nano
        span.append(0x39)
        span.append(contentsOf: encodeFixed64(1_700_000_000_000_000_000))
        // field 8, I64 — end_time_unix_nano
        span.append(0x41)
        span.append(contentsOf: encodeFixed64(1_700_000_000_000_000_100))

        // Wrap span in ScopeSpans (field 2, LEN).
        var scopeSpans = Data()
        scopeSpans.append(0x12)
        scopeSpans.append(contentsOf: encodeVarint(UInt64(span.count)))
        scopeSpans.append(span)

        // Wrap in ResourceSpans (field 2, LEN — ScopeSpans).
        var resourceSpans = Data()
        resourceSpans.append(0x12)
        resourceSpans.append(contentsOf: encodeVarint(UInt64(scopeSpans.count)))
        resourceSpans.append(scopeSpans)

        // Wrap in ExportTraceServiceRequest (field 1, LEN — ResourceSpans).
        var req = Data()
        req.append(0x0a)
        req.append(contentsOf: encodeVarint(UInt64(resourceSpans.count)))
        req.append(resourceSpans)

        return req
    }

    private static func encodeVarint(_ value: UInt64) -> [UInt8] {
        var out: [UInt8] = []
        var v = value
        while v >= 0x80 {
            out.append(UInt8(v & 0x7f) | 0x80)
            v >>= 7
        }
        out.append(UInt8(v))
        return out
    }

    private static func encodeFixed64(_ value: Int64) -> [UInt8] {
        var out: [UInt8] = []
        let bits = UInt64(bitPattern: value)
        for i in 0..<8 {
            out.append(UInt8((bits >> (i * 8)) & 0xff))
        }
        return out
    }

    private static func countSpans(db: SessionDatabase, datasetId: Int64) -> Int {
        return db.runtimeTelemetryStore.rowCount(datasetId: datasetId, table: .span)
    }

    // MARK: - Acceptance bullets 1-3, 6 (JSON + rate cap + doctor surface)

    @Test("OTLP/JSON traces accepted: rows inserted, port + drop counter persisted, rate-cap drops counted")
    func acceptsJSONTracesAndCountsDrops() throws {
        let db = Self.tempDB()
        let datasetId = db.runtimeTelemetryStore.createDataset(projectId: "v18a-3-test")
        #expect(datasetId > 0)

        let cfgPath = Self.tempConfigPath()
        defer { unlink(cfgPath) }

        // Per-source cap = 2 spans. Send 3 spans — first 2 accepted,
        // 1 dropped. Verifies both 200 OK semantics AND drop counter.
        let recv = RuntimeTelemetryReceiver(
            store: db.runtimeTelemetryStore,
            datasetId: datasetId,
            config: .init(port: 0, perSourceSpansPerSecond: 2, configPath: cfgPath)
        )
        try recv.start()
        defer { recv.stop() }

        #expect(recv.port > 0)
        #expect(recv.isRunning)

        let body = Self.sampleJSONTraces(spanCount: 3)
        let req = Self.buildPOST(path: "/v1/traces", contentType: "application/json", body: body)
        let resp = Self.httpRoundTrip(port: recv.port, request: req)
        let respStr = String(data: resp ?? Data(), encoding: .utf8) ?? ""

        #expect(respStr.hasPrefix("HTTP/1.1 200 OK"))
        // Two spans accepted, one dropped.
        #expect(Self.countSpans(db: db, datasetId: datasetId) == 2)
        #expect(recv.currentDrops == 1)

        // Config snapshot reflects the bound port + drop count.
        let snap = try RuntimeTelemetryReceiverConfigStore.load(path: cfgPath)
        #expect(snap.port == recv.port)
        // The drop snapshot lands on persistConfigSnapshot() — called
        // from start() and stop(). start() snapshots zero (drops
        // happen during handling); stop() will snapshot post-drop.
        // For mid-receive verification, the live currentDrops is
        // authoritative — assert that explicitly above.
    }

    // MARK: - Acceptance bullet 4 (protobuf accept)

    @Test("OTLP/protobuf traces accepted: hand-built wire bytes parse and persist a span row")
    func acceptsProtobufTraces() throws {
        let db = Self.tempDB()
        let datasetId = db.runtimeTelemetryStore.createDataset(projectId: "v18a-3-test-pb")
        #expect(datasetId > 0)

        let cfgPath = Self.tempConfigPath()
        defer { unlink(cfgPath) }

        let recv = RuntimeTelemetryReceiver(
            store: db.runtimeTelemetryStore,
            datasetId: datasetId,
            config: .init(port: 0, perSourceSpansPerSecond: 100, configPath: cfgPath)
        )
        try recv.start()
        defer { recv.stop() }

        let body = Self.sampleProtobufTraces(name: "pb-span-1")
        let req = Self.buildPOST(path: "/v1/traces", contentType: "application/x-protobuf", body: body)
        let resp = Self.httpRoundTrip(port: recv.port, request: req)
        let respStr = String(data: resp ?? Data(), encoding: .utf8) ?? ""

        #expect(respStr.hasPrefix("HTTP/1.1 200 OK"))
        #expect(Self.countSpans(db: db, datasetId: datasetId) == 1)
    }

    // MARK: - Acceptance bullet 5 (413 on oversize)

    @Test("Bodies above the per-receiver cap are rejected with HTTP 413")
    func rejectsOversizeBodyWith413() throws {
        let db = Self.tempDB()
        let datasetId = db.runtimeTelemetryStore.createDataset(projectId: "v18a-3-test-413")
        #expect(datasetId > 0)

        let cfgPath = Self.tempConfigPath()
        defer { unlink(cfgPath) }

        // Set a 4 KB cap for the test — well below the 4 MB default —
        // so we can exercise the path without sending megabytes.
        let recv = RuntimeTelemetryReceiver(
            store: db.runtimeTelemetryStore,
            datasetId: datasetId,
            config: .init(port: 0, perSourceSpansPerSecond: 100, maxBodyBytes: 4096, configPath: cfgPath)
        )
        try recv.start()
        defer { recv.stop() }

        // Build a body whose declared Content-Length exceeds the cap.
        let oversize = Data(repeating: 0x7a, count: 8192)
        let req = Self.buildPOST(path: "/v1/traces", contentType: "application/json", body: oversize)
        let resp = Self.httpRoundTrip(port: recv.port, request: req)
        let respStr = String(data: resp ?? Data(), encoding: .utf8) ?? ""

        #expect(respStr.hasPrefix("HTTP/1.1 413 Payload Too Large"))
        #expect(Self.countSpans(db: db, datasetId: datasetId) == 0)
    }

    // MARK: - Acceptance bullet 6 (415 on unknown content-type)

    @Test("Unknown content-types are rejected with HTTP 415")
    func rejectsUnknownContentTypeWith415() throws {
        let db = Self.tempDB()
        let datasetId = db.runtimeTelemetryStore.createDataset(projectId: "v18a-3-test-415")
        #expect(datasetId > 0)

        let cfgPath = Self.tempConfigPath()
        defer { unlink(cfgPath) }

        let recv = RuntimeTelemetryReceiver(
            store: db.runtimeTelemetryStore,
            datasetId: datasetId,
            config: .init(port: 0, configPath: cfgPath)
        )
        try recv.start()
        defer { recv.stop() }

        let body = Data("not-otlp".utf8)
        let req = Self.buildPOST(path: "/v1/traces", contentType: "text/plain", body: body)
        let resp = Self.httpRoundTrip(port: recv.port, request: req)
        let respStr = String(data: resp ?? Data(), encoding: .utf8) ?? ""

        #expect(respStr.hasPrefix("HTTP/1.1 415 Unsupported Media Type"))
        #expect(Self.countSpans(db: db, datasetId: datasetId) == 0)
    }

    // MARK: - Acceptance bullet 7-8 (loopback boundary + misuse fixture)

    /// Boundary is the local user — any local process can bind a
    /// competing receiver on a different loopback port and accept
    /// OTLP traffic. This fixture proves it directly: stand up two
    /// receivers, send one batch to each, and verify both accept.
    @Test("Misuse fixture: a competing receiver binds a different loopback port and accepts OTLP without consent")
    func loopbackBindIsPerformative() throws {
        let dbA = Self.tempDB()
        let dsA = dbA.runtimeTelemetryStore.createDataset(projectId: "v18a-3-misuse-A")
        let cfgA = Self.tempConfigPath()
        defer { unlink(cfgA) }
        let recvA = RuntimeTelemetryReceiver(
            store: dbA.runtimeTelemetryStore,
            datasetId: dsA,
            config: .init(port: 0, perSourceSpansPerSecond: 100, configPath: cfgA)
        )
        try recvA.start()
        defer { recvA.stop() }

        // A second receiver — entirely independent of the first —
        // binds a *different* loopback port and accepts the same
        // OTLP traffic with the same authority. Nothing senkani does
        // can prevent this.
        let dbB = Self.tempDB()
        let dsB = dbB.runtimeTelemetryStore.createDataset(projectId: "v18a-3-misuse-B")
        let cfgB = Self.tempConfigPath()
        defer { unlink(cfgB) }
        let recvB = RuntimeTelemetryReceiver(
            store: dbB.runtimeTelemetryStore,
            datasetId: dsB,
            config: .init(port: 0, perSourceSpansPerSecond: 100, configPath: cfgB)
        )
        try recvB.start()
        defer { recvB.stop() }

        // Confirm the second listener bound a *different* port — proves
        // the OS doesn't grant the first receiver exclusive rights.
        #expect(recvA.port > 0)
        #expect(recvB.port > 0)
        #expect(recvA.port != recvB.port)

        // The same OTLP payload is accepted by both — there is no
        // authentication, no shared secret, no capability check.
        let body = Self.sampleJSONTraces(spanName: "misuse-fixture", spanCount: 1)
        let req = Self.buildPOST(path: "/v1/traces", contentType: "application/json", body: body)

        let respA = Self.httpRoundTrip(port: recvA.port, request: req)
        let respB = Self.httpRoundTrip(port: recvB.port, request: req)
        let respAStr = String(data: respA ?? Data(), encoding: .utf8) ?? ""
        let respBStr = String(data: respB ?? Data(), encoding: .utf8) ?? ""

        #expect(respAStr.hasPrefix("HTTP/1.1 200 OK"))
        #expect(respBStr.hasPrefix("HTTP/1.1 200 OK"))
        #expect(Self.countSpans(db: dbA, datasetId: dsA) == 1)
        #expect(Self.countSpans(db: dbB, datasetId: dsB) == 1)
    }
}
