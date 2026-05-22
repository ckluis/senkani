import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// V.18a-3 — local OTLP/HTTP receiver. Binds 127.0.0.1, accepts
/// `POST /v1/traces` and `POST /v1/logs` with OTLP/protobuf or
/// OTLP/JSON bodies, persists rows via `RuntimeTelemetryStore`.
///
/// Threading: BSD socket + dispatch accept source on a dedicated
/// `receiver-accept` queue. Each accepted connection is handled
/// on `receiver-conn` (concurrent). The receiver class is
/// `@unchecked Sendable`; all mutable state is guarded by `lock`.
///
/// Trust boundary: the loopback bind is **performative not
/// protective**. Any local user / local process can bind a
/// competing receiver on a different loopback port and accept
/// OTLP traffic without our consent. See
/// `spec/architecture.md#runtime-telemetry-receiver-trust-boundary`
/// for the full discussion.
public final class RuntimeTelemetryReceiver: @unchecked Sendable {

    /// MIME types this receiver accepts on /v1/traces and /v1/logs.
    public enum MimeType: String, Sendable {
        case otlpProtobuf = "application/x-protobuf"
        case otlpJSON = "application/json"

        static func from(headerValue: String) -> MimeType? {
            // Strip params after `;` (e.g. "application/json; charset=utf-8")
            let trimmed = headerValue
                .split(separator: ";", maxSplits: 1).first
                .map(String.init)?
                .trimmingCharacters(in: .whitespaces)
                .lowercased() ?? ""
            return MimeType(rawValue: trimmed)
        }
    }

    public struct Config: Sendable {
        /// Port to bind. 0 = kernel-assigned (read back via getsockname).
        public var port: Int
        /// Per-source span rate cap (spans/s).
        public var perSourceSpansPerSecond: Int
        /// Maximum request body bytes the receiver buffers before
        /// returning 413. OTLP-HTTP-spec mentions no explicit ceiling;
        /// 4 MB is enough for the largest realistic batch.
        public var maxBodyBytes: Int
        /// Optional override of the persistence path used by the
        /// drop-counter snapshot. Tests stub this to a temp file.
        public var configPath: String?
        /// V.18a-4 — per-source opt-in capture-mode map. Keyed by the
        /// `X-Senkani-Source` header value (typically the producing
        /// skill's `HandManifest.name`). Sources not present in the
        /// map default to `.metadata`, the safest mode.
        public var captureModesBySource: [String: HandRuntimeTelemetry.CaptureMode]

        public init(
            port: Int = 0,
            perSourceSpansPerSecond: Int = 1000,
            maxBodyBytes: Int = 4 * 1024 * 1024,
            configPath: String? = nil,
            captureModesBySource: [String: HandRuntimeTelemetry.CaptureMode] = [:]
        ) {
            self.port = port
            self.perSourceSpansPerSecond = perSourceSpansPerSecond
            self.maxBodyBytes = maxBodyBytes
            self.configPath = configPath
            self.captureModesBySource = captureModesBySource
        }
    }

    public enum BindError: Error, Equatable {
        case createFailed(Int32)
        case bindFailed(Int32)
        case listenFailed(Int32)
        case getsocknameFailed(Int32)
    }

    /// Per-source token bucket. Each call to `consume(_:)` returns the
    /// number of dropped spans (clamped by available capacity).
    final class SourceBucket {
        private let capPerSecond: Int
        private var tokens: Double
        private var lastRefillNs: UInt64
        private let lock = NSLock()

        init(capPerSecond: Int) {
            self.capPerSecond = max(1, capPerSecond)
            self.tokens = Double(self.capPerSecond)
            self.lastRefillNs = DispatchTime.now().uptimeNanoseconds
        }

        /// Returns (accepted, dropped) for `spans` arriving now.
        func consume(spans: Int) -> (accepted: Int, dropped: Int) {
            lock.lock(); defer { lock.unlock() }
            // Refill: tokens per nanosecond = cap / 1e9
            let nowNs = DispatchTime.now().uptimeNanoseconds
            let elapsedNs = nowNs &- lastRefillNs
            let refill = Double(elapsedNs) * Double(capPerSecond) / 1_000_000_000.0
            tokens = min(Double(capPerSecond), tokens + refill)
            lastRefillNs = nowNs
            let want = Double(spans)
            if tokens >= want {
                tokens -= want
                return (spans, 0)
            }
            let accepted = Int(tokens)
            tokens = 0
            return (accepted, spans - accepted)
        }
    }

    public let store: RuntimeTelemetryStore
    public let datasetId: Int64
    private let config: Config
    private let acceptQueue = DispatchQueue(label: "com.senkani.telemetry-receiver-accept", qos: .userInitiated)
    private let connQueue = DispatchQueue(label: "com.senkani.telemetry-receiver-conn", qos: .userInitiated, attributes: .concurrent)
    private let lock = NSLock()
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var boundPort: Int = 0
    private var running = false
    private var buckets: [String: SourceBucket] = [:]
    private var totalDrops: Int = 0
    private static let readTimeoutSeconds: Int = 5

    public init(
        store: RuntimeTelemetryStore,
        datasetId: Int64,
        config: Config = Config()
    ) {
        self.store = store
        self.datasetId = datasetId
        self.config = config
    }

    public var port: Int {
        lock.lock(); defer { lock.unlock() }
        return boundPort
    }

    public var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return running
    }

    /// Cumulative drops across the receiver's lifetime.
    public var currentDrops: Int {
        lock.lock(); defer { lock.unlock() }
        return totalDrops
    }

    /// Bind, listen, install the accept source. Persists the bound
    /// port to the config file if `Config.configPath` (or the env
    /// override) resolves to a writable location.
    public func start() throws {
        lock.lock()
        if running { lock.unlock(); return }
        lock.unlock()

        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw BindError.createFailed(errno) }

        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(config.port).bigEndian
        addr.sin_addr.s_addr = UInt32(0x7F00_0001).bigEndian
        #if canImport(Darwin)
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif

        let bindResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            let e = errno
            close(fd)
            throw BindError.bindFailed(e)
        }

        guard listen(fd, 32) == 0 else {
            let e = errno
            close(fd)
            throw BindError.listenFailed(e)
        }

        var bound = sockaddr_in()
        var boundLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &bound) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                getsockname(fd, sa, &boundLen)
            }
        }
        guard nameResult == 0 else {
            let e = errno
            close(fd)
            throw BindError.getsocknameFailed(e)
        }
        let port = Int(UInt16(bigEndian: bound.sin_port))

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: acceptQueue)
        source.setEventHandler { [weak self] in
            self?.acceptOne()
        }
        source.setCancelHandler { close(fd) }

        lock.lock()
        listenFD = fd
        acceptSource = source
        boundPort = port
        running = true
        lock.unlock()

        persistConfigSnapshot()
        source.resume()
    }

    public func stop() {
        lock.lock()
        guard running else { lock.unlock(); return }
        running = false
        let source = acceptSource
        acceptSource = nil
        boundPort = 0
        listenFD = -1
        lock.unlock()

        source?.cancel()
        // Snapshot drops on shutdown so doctor's read sees the
        // last-known total.
        persistConfigSnapshot()
    }

    // MARK: - Connection acceptance

    private func acceptOne() {
        lock.lock()
        let fd = listenFD
        lock.unlock()
        guard fd >= 0 else { return }

        var clientAddr = sockaddr_in()
        var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        let clientFD = withUnsafeMutablePointer(to: &clientAddr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                accept(fd, sa, &addrLen)
            }
        }
        guard clientFD >= 0 else { return }
        let peerIP = UInt32(bigEndian: clientAddr.sin_addr.s_addr)
        guard peerIP == 0x7F00_0001 else {
            close(clientFD)
            return
        }
        connQueue.async { [weak self] in
            self?.handleConnection(clientFD: clientFD)
        }
    }

    // MARK: - Connection handling

    private func handleConnection(clientFD: Int32) {
        defer { close(clientFD) }
        applyReadTimeout(fd: clientFD, seconds: Self.readTimeoutSeconds)

        guard let (head, residue) = readHead(fd: clientFD) else {
            sendStatus(fd: clientFD, code: 400, message: "Bad Request")
            return
        }
        guard let req = parseRequestHead(head) else {
            sendStatus(fd: clientFD, code: 400, message: "Bad Request")
            return
        }

        // Route by method + path. Only POST /v1/traces and POST /v1/logs.
        let path = req.path
        if req.method != "POST" || (path != "/v1/traces" && path != "/v1/logs") {
            sendStatus(fd: clientFD, code: 404, message: "Not Found")
            return
        }

        // 415 — unknown content-type.
        guard let mime = MimeType.from(headerValue: req.headers["content-type"] ?? "") else {
            sendStatus(fd: clientFD, code: 415, message: "Unsupported Media Type")
            return
        }

        // 413 — body too large.
        let contentLength = Int(req.headers["content-length"] ?? "0") ?? 0
        if contentLength > config.maxBodyBytes {
            sendStatus(fd: clientFD, code: 413, message: "Payload Too Large")
            return
        }

        // Read remaining body bytes.
        var body = residue
        while body.count < contentLength {
            let want = contentLength - body.count
            let chunkCap = min(want, 64 * 1024)
            var buf = [UInt8](repeating: 0, count: chunkCap)
            let n = buf.withUnsafeMutableBufferPointer { ptr -> Int in
                read(clientFD, ptr.baseAddress, ptr.count)
            }
            if n <= 0 { break }
            body.append(contentsOf: buf[0..<n])
            if body.count > config.maxBodyBytes {
                sendStatus(fd: clientFD, code: 413, message: "Payload Too Large")
                return
            }
        }

        let source = req.headers["x-senkani-source"] ?? "default"
        let processed = processBody(path: path, mime: mime, body: body, source: source)
        switch processed {
        case .ok:
            sendStatus(fd: clientFD, code: 200, message: "OK")
        case .badRequest:
            sendStatus(fd: clientFD, code: 400, message: "Bad Request")
        }
    }

    private enum ProcessResult { case ok, badRequest }

    private func processBody(path: String, mime: MimeType, body: Data, source: String) -> ProcessResult {
        // V.18a-4 — per-source capture-mode lookup. Unknown sources
        // default to the safest mode (`.metadata`); operators widen
        // explicitly via `HandManifest.runtime_telemetry.capture`.
        let mode = config.captureModesBySource[source] ?? .metadata
        let filter: OTLPDecoder.AttributesFilter = { attrs in
            OTLPPrivacyFilter.filter(attributes: attrs, mode: mode)
        }
        if path == "/v1/traces" {
            let spans: [RuntimeTelemetryStore.SpanRow]
            do {
                switch mime {
                case .otlpProtobuf:
                    spans = try OTLPDecoder.decodeTracesProtobuf(body, attributesFilter: filter)
                case .otlpJSON:
                    spans = try OTLPDecoder.decodeTracesJSON(body, attributesFilter: filter)
                }
            } catch {
                return .badRequest
            }
            guard !spans.isEmpty else { return .ok }
            let (accepted, dropped) = bucket(source: source).consume(spans: spans.count)
            if dropped > 0 { addDrops(dropped) }
            for span in spans.prefix(accepted) {
                _ = store.insertSpan(datasetId: datasetId, span: span)
            }
            return .ok
        } else {
            // /v1/logs
            let logs: [RuntimeTelemetryStore.LogRow]
            do {
                switch mime {
                case .otlpProtobuf:
                    logs = try OTLPDecoder.decodeLogsProtobuf(body, attributesFilter: filter)
                case .otlpJSON:
                    logs = try OTLPDecoder.decodeLogsJSON(body, attributesFilter: filter)
                }
            } catch {
                return .badRequest
            }
            guard !logs.isEmpty else { return .ok }
            // Rate-cap is keyed off the span-axis bullet, but apply
            // the same per-source cap to logs to prevent runaway log
            // emitters from overflowing the table cap. Logs share the
            // bucket with spans on the same source key.
            let (accepted, dropped) = bucket(source: source).consume(spans: logs.count)
            if dropped > 0 { addDrops(dropped) }
            for log in logs.prefix(accepted) {
                _ = store.insertLog(datasetId: datasetId, log: log)
            }
            return .ok
        }
    }

    private func bucket(source: String) -> SourceBucket {
        lock.lock(); defer { lock.unlock() }
        if let b = buckets[source] { return b }
        let b = SourceBucket(capPerSecond: config.perSourceSpansPerSecond)
        buckets[source] = b
        return b
    }

    private func addDrops(_ n: Int) {
        lock.lock(); defer { lock.unlock() }
        totalDrops += n
    }

    // MARK: - HTTP framing

    private struct RequestHead {
        let method: String
        let path: String
        let headers: [String: String]
    }

    private static let maxHeadBytes = 16 * 1024

    /// Returns the head bytes (up to and including `\r\n\r\n`) plus
    /// any body residue read into the same syscall.
    private func readHead(fd: Int32) -> (head: Data, residue: Data)? {
        var buf = Data()
        let term = Data([0x0d, 0x0a, 0x0d, 0x0a])
        var temp = [UInt8](repeating: 0, count: 1024)
        while buf.count < Self.maxHeadBytes {
            let n = temp.withUnsafeMutableBufferPointer { ptr -> Int in
                read(fd, ptr.baseAddress, ptr.count)
            }
            if n <= 0 { return nil }
            buf.append(contentsOf: temp[0..<n])
            if let r = buf.range(of: term) {
                let head = buf.subdata(in: 0..<r.upperBound)
                let residue = r.upperBound < buf.count
                    ? buf.subdata(in: r.upperBound..<buf.count)
                    : Data()
                return (head, residue)
            }
        }
        return nil
    }

    private func parseRequestHead(_ head: Data) -> RequestHead? {
        guard let text = String(data: head, encoding: .utf8) else { return nil }
        let lines = text.split(separator: "\r\n", omittingEmptySubsequences: false)
        guard let firstLine = lines.first else { return nil }
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        let method = String(parts[0]).uppercased()
        let path = String(parts[1])
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            if line.isEmpty { continue }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces).lowercased()
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }
        return RequestHead(method: method, path: path, headers: headers)
    }

    private func sendStatus(fd: Int32, code: Int, message: String) {
        let line = "HTTP/1.1 \(code) \(message)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        let data = Data(line.utf8)
        var written = 0
        while written < data.count {
            let n = data.withUnsafeBytes { (rb: UnsafeRawBufferPointer) -> Int in
                guard let base = rb.baseAddress else { return -1 }
                return write(fd, base.advanced(by: written), data.count - written)
            }
            if n <= 0 { return }
            written += n
        }
    }

    private func applyReadTimeout(fd: Int32, seconds: Int) {
        var tv = timeval(tv_sec: seconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    // MARK: - Config snapshot

    private func persistConfigSnapshot() {
        lock.lock()
        let snapshot = RuntimeTelemetryReceiverConfig(
            port: boundPort,
            totalDrops: totalDrops,
            perSourceSpansPerSecond: config.perSourceSpansPerSecond
        )
        lock.unlock()
        let path = config.configPath ?? RuntimeTelemetryReceiverConfigPath.canonical()
        try? RuntimeTelemetryReceiverConfigStore.save(snapshot, path: path)
    }
}
