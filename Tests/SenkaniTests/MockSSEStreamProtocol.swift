import Foundation

/// V.13b-sse-a — Chunked-streaming URLProtocol for testing the engine-side
/// SSE seam. Unlike `MockURLProtocol` (single shot, full body),
/// `MockSSEStreamProtocol` lets a test register an ORDERED sequence of
/// `Data` chunks with controllable inter-chunk delays plus an optional
/// terminal error. The protocol pushes each chunk to the
/// URLProtocol client via `urlProtocol(_:didLoad:)` so the consumer
/// (`URLSession.bytes(for:)`) observes a TRUE streaming response —
/// AsyncBytes yields bytes as chunks arrive, not in one go.
///
/// Cancellation observability (Karpathy r10 P1): `stopLoading()` flips
/// `observedStopLoading = true`, so the cancel-propagation probe can
/// assert that consumer-task cancellation reaches the URLProtocol within
/// the SLA window.
final class MockSSEStreamProtocol: URLProtocol, @unchecked Sendable {

    struct Stream: Sendable {
        let status: Int
        let chunks: [Data]
        let delayBetweenMs: Int
        let terminalError: URLError?
        let headers: [String: String]
    }

    nonisolated(unsafe) static var streams: [String: Stream] = [:]
    nonisolated(unsafe) static var lastRequest: URLRequest?
    /// Flipped to `true` by `stopLoading()` — the cancel-propagation probe
    /// asserts on this within ≤100ms of consumer-task cancellation.
    nonisolated(unsafe) static var observedStopLoading: Bool = false

    static func key(for url: URL) -> String {
        let host = url.host ?? ""
        let path = url.path
        let q = url.query.map { "?\($0)" } ?? ""
        return "\(host)\(path)\(q)"
    }

    static func register(
        url: URL,
        status: Int = 200,
        chunks: [Data],
        delayBetweenMs: Int = 0,
        terminalError: URLError? = nil,
        headers: [String: String] = ["Content-Type": "text/event-stream"]
    ) {
        streams[key(for: url)] = Stream(
            status: status,
            chunks: chunks,
            delayBetweenMs: delayBetweenMs,
            terminalError: terminalError,
            headers: headers
        )
    }

    static func reset() {
        streams = [:]
        lastRequest = nil
        observedStopLoading = false
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    /// Internal cancellation latch: set true on stopLoading() and polled
    /// on the chunk loop. Lets the test observe early termination.
    nonisolated(unsafe) private var cancelled: Bool = false

    override func startLoading() {
        Self.lastRequest = request
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let k = Self.key(for: url)
        guard let stream = Self.streams[k] else {
            let response = HTTPURLResponse(
                url: url, statusCode: 404,
                httpVersion: "HTTP/1.1", headerFields: [:])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("mock-sse stub not registered: \(k)".utf8))
            client?.urlProtocolDidFinishLoading(self)
            return
        }

        let response = HTTPURLResponse(
            url: url, statusCode: stream.status,
            httpVersion: "HTTP/1.1", headerFields: stream.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)

        // Push chunks with optional inter-chunk delay. Each chunk is
        // emitted on a background queue, and inter-chunk delays are
        // scheduled via `DispatchQueue.asyncAfter(...)` so we never park
        // a global-QoS thread on `Thread.sleep` (Karpathy r19 P3 — sse-E
        // mock-slow-emit async delay). The cancel latch is polled at the
        // head of each scheduled hop, so `stopLoading()` observation
        // remains prompt.
        let chunks = stream.chunks
        let delayMs = stream.delayBetweenMs
        let terminal = stream.terminalError

        let queue = DispatchQueue.global(qos: .userInitiated)
        weak var weakSelf = self

        func emit(_ i: Int) {
            guard let s = weakSelf else { return }
            if s.cancelled { return }
            if i >= chunks.count {
                if let err = terminal {
                    s.client?.urlProtocol(s, didFailWithError: err)
                } else {
                    s.client?.urlProtocolDidFinishLoading(s)
                }
                return
            }
            s.client?.urlProtocol(s, didLoad: chunks[i])
            let isLast = (i == chunks.count - 1)
            if !isLast && delayMs > 0 {
                let deadline: DispatchTime = .now() + .milliseconds(delayMs)
                queue.asyncAfter(deadline: deadline) { emit(i + 1) }
            } else {
                queue.async { emit(i + 1) }
            }
        }
        queue.async { emit(0) }
    }

    override func stopLoading() {
        cancelled = true
        Self.observedStopLoading = true
    }
}
