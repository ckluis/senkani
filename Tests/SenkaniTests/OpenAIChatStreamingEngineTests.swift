import Testing
import Foundation
@testable import Core

/// V.13 real-chat (sub-item 2) — stub-stream coverage for the
/// `StreamingChatEngine` seam. Feeds a deterministic
/// `AsyncThrowingStream<TokenDelta, Error>` into
/// `OpenAIChatHandler.renderStreamingEvents` and asserts the rendered SSE
/// byte sequence matches the v13b stream shape (role chunk + content
/// chunks + terminal `finish_reason: "stop"`). No MLX runtime required —
/// the test runs in CI without any model download.
///
/// Two additional shape tests verify the `Plan(streamingEvents:)` driver
/// path through `OpenAIChatStream.run`: the byte sequence delivered to the
/// sink matches the pre-baked `events` path on the same input, and a
/// peer disconnect mid-stream surfaces as a `clientCancel` terminal status.
@Suite("V.13 real-chat sub-item 2 — StreamingChatEngine seam + SSE rendering")
struct OpenAIChatStreamingEngineTests {

    private static let id = "chatcmpl-streaming-test-0001"
    private static let createdEpoch = 1_700_000_000
    private static let model = "gemma4-e2b"

    /// Decode an SSE event payload's `choices[0].delta` dict.
    private static func deltaDict(_ data: Data) -> [String: Any]? {
        let s = String(decoding: data, as: UTF8.self)
        let json = s
            .replacingOccurrences(of: "data: ", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let obj = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let choices = obj["choices"] as? [[String: Any]],
              let delta = choices.first?["delta"] as? [String: Any] else { return nil }
        return delta
    }

    /// Decode an SSE event payload's `choices[0].finish_reason`.
    private static func finishReason(_ data: Data) -> String? {
        let s = String(decoding: data, as: UTF8.self)
        let json = s
            .replacingOccurrences(of: "data: ", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let obj = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let choices = obj["choices"] as? [[String: Any]],
              let fr = choices.first?["finish_reason"] as? String else { return nil }
        return fr
    }

    /// Build a deterministic `AsyncThrowingStream<TokenDelta, Error>` from
    /// an array of content slices. Used to feed `renderStreamingEvents`
    /// without an engine.
    private static func stubSource(_ slices: [String]) -> AsyncThrowingStream<OpenAIChatHandler.TokenDelta, Error> {
        AsyncThrowingStream { continuation in
            Task {
                for slice in slices {
                    continuation.yield(OpenAIChatHandler.TokenDelta(content: slice))
                }
                continuation.finish()
            }
        }
    }

    /// Collect all rendered Data events from an async stream into an array.
    private static func collectEvents(_ stream: AsyncThrowingStream<Data, Error>) async throws -> [Data] {
        var out: [Data] = []
        for try await ev in stream {
            out.append(ev)
        }
        return out
    }

    // MARK: - 1. SSE shape from stub source matches v13b output

    @Test("rendered SSE events match the v13b shape: role chunk + content chunks + terminal stop")
    func testSseShapeFromStubSource() async throws {
        let slices = ["Hello", " from", " the", " stream"]
        let source = Self.stubSource(slices)
        let stream = OpenAIChatHandler.renderStreamingEvents(
            id: Self.id, created: Self.createdEpoch, model: Self.model, source: source
        )
        let events = try await Self.collectEvents(stream)

        // role chunk + 4 content chunks + terminal = 6 events.
        #expect(events.count == 6)

        // Every event is `data: {…}\n\n`.
        for ev in events {
            let s = String(decoding: ev, as: UTF8.self)
            #expect(s.hasPrefix("data: "))
            #expect(s.hasSuffix("\n\n"))
        }

        // First chunk carries the assistant role + null finish_reason.
        let first = Self.deltaDict(events[0])
        #expect(first?["role"] as? String == "assistant")
        #expect(Self.finishReason(events[0]) == nil)

        // Content chunks 1..4 carry one slice each, finish_reason null.
        for (i, slice) in slices.enumerated() {
            let delta = Self.deltaDict(events[i + 1])
            #expect(delta?["content"] as? String == slice)
            #expect(Self.finishReason(events[i + 1]) == nil)
        }

        // Final chunk: empty delta + finish_reason "stop".
        let last = Self.deltaDict(events[5])
        #expect(last?.isEmpty == true)
        #expect(Self.finishReason(events[5]) == "stop")
    }

    // MARK: - 2. Empty content stream — role + terminal only

    @Test("an empty TokenDelta source still emits role chunk + terminal stop")
    func testEmptyStreamEmitsRoleAndTerminal() async throws {
        let source = Self.stubSource([])
        let stream = OpenAIChatHandler.renderStreamingEvents(
            id: Self.id, created: Self.createdEpoch, model: Self.model, source: source
        )
        let events = try await Self.collectEvents(stream)

        #expect(events.count == 2)
        #expect(Self.deltaDict(events[0])?["role"] as? String == "assistant")
        #expect(Self.deltaDict(events[1])?.isEmpty == true)
        #expect(Self.finishReason(events[1]) == "stop")
    }

    // MARK: - 3. Empty-content TokenDeltas skipped, not emitted as empty chunks

    @Test("a TokenDelta with empty content is skipped, not rendered as an empty chunk")
    func testEmptyContentDeltaSkipped() async throws {
        let slices = ["", "real", "", "content", ""]
        let source = Self.stubSource(slices)
        let stream = OpenAIChatHandler.renderStreamingEvents(
            id: Self.id, created: Self.createdEpoch, model: Self.model, source: source
        )
        let events = try await Self.collectEvents(stream)

        // role + 2 non-empty content + terminal = 4 events.
        #expect(events.count == 4)
        #expect(Self.deltaDict(events[1])?["content"] as? String == "real")
        #expect(Self.deltaDict(events[2])?["content"] as? String == "content")
    }

    // MARK: - 4. Plan(streamingEvents:) drive matches pre-baked events drive

    @Test("Plan(streamingEvents:) sink byte stream matches Plan(events:) on identical content")
    func testStreamingPlanMatchesPreBakedPlan() async throws {
        let content = "Hello world from the stream"

        // Pre-baked v13b plan.
        let preBaked = OpenAIChatStream.events(
            id: Self.id, created: Self.createdEpoch, model: Self.model, content: content
        )
        var preBakedBytes = Data()
        preBakedBytes.append(OpenAIChatStream.head())
        for ev in preBaked { preBakedBytes.append(ev) }
        preBakedBytes.append(OpenAIChatStream.doneSentinel())

        // Streaming plan: feed `splitForStreaming(content)` slices through
        // the stub source so the produced content slices match v13b's
        // splitter exactly.
        let slices = OpenAIChatStream.splitForStreaming(content)
        let sourceProvider: @Sendable () -> AsyncThrowingStream<Data, Error> = {
            let source = Self.stubSource(slices)
            return OpenAIChatHandler.renderStreamingEvents(
                id: Self.id, created: Self.createdEpoch, model: Self.model, source: source
            )
        }

        // Collect drive() output bytes into a buffer via a synchronous sink.
        final class Buffer: @unchecked Sendable {
            private let lock = NSLock()
            private var bytes = Data()
            func append(_ d: Data) { lock.lock(); bytes.append(d); lock.unlock() }
            func snapshot() -> Data { lock.lock(); defer { lock.unlock() }; return bytes }
        }
        let buffer = Buffer()
        let sink = OpenAIChatStream.Sink(
            write: { data in buffer.append(data) },
            isCancelled: { false },
            close: {}
        )
        final class FinishCapture: @unchecked Sendable {
            private let lock = NSLock()
            private var status: OpenAIChatStream.FinishStatus?
            func set(_ s: OpenAIChatStream.FinishStatus) { lock.lock(); status = s; lock.unlock() }
            func get() -> OpenAIChatStream.FinishStatus? { lock.lock(); defer { lock.unlock() }; return status }
        }
        let finish = FinishCapture()
        let plan = OpenAIChatStream.Plan(
            head: OpenAIChatStream.head(),
            streamingEvents: sourceProvider,
            done: OpenAIChatStream.doneSentinel(),
            onFinish: { status in finish.set(status) }
        )
        let status = OpenAIChatStream.run(plan: plan, sink: sink)

        #expect(status == .completed)
        #expect(finish.get() == .completed)
        #expect(buffer.snapshot() == preBakedBytes)
    }

    // MARK: - 5. Mid-stream cancellation surfaces as clientCancel

    @Test("a cancelled sink during the streaming drive returns clientCancel")
    func testStreamingDriveCancelsOnSinkCancel() async throws {
        let slices = ["one", "two", "three", "four"]
        let sourceProvider: @Sendable () -> AsyncThrowingStream<Data, Error> = {
            let source = Self.stubSource(slices)
            return OpenAIChatHandler.renderStreamingEvents(
                id: Self.id, created: Self.createdEpoch, model: Self.model, source: source
            )
        }

        // Sink that cancels after the first write succeeds.
        final class CancellingSink: @unchecked Sendable {
            private let lock = NSLock()
            private var writes = 0
            private var closed = false
            func recordWrite() { lock.lock(); writes += 1; lock.unlock() }
            func writeCount() -> Int { lock.lock(); defer { lock.unlock() }; return writes }
            var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return writes >= 1 }
            func setClosed() { lock.lock(); closed = true; lock.unlock() }
            func didClose() -> Bool { lock.lock(); defer { lock.unlock() }; return closed }
        }
        let state = CancellingSink()
        let sink = OpenAIChatStream.Sink(
            write: { _ in state.recordWrite() },
            isCancelled: { state.isCancelled },
            close: { state.setClosed() }
        )
        final class FinishCapture: @unchecked Sendable {
            private let lock = NSLock()
            private var status: OpenAIChatStream.FinishStatus?
            func set(_ s: OpenAIChatStream.FinishStatus) { lock.lock(); status = s; lock.unlock() }
            func get() -> OpenAIChatStream.FinishStatus? { lock.lock(); defer { lock.unlock() }; return status }
        }
        let finish = FinishCapture()
        let plan = OpenAIChatStream.Plan(
            head: OpenAIChatStream.head(),
            streamingEvents: sourceProvider,
            done: OpenAIChatStream.doneSentinel(),
            onFinish: { status in finish.set(status) }
        )
        let status = OpenAIChatStream.run(plan: plan, sink: sink)

        #expect(status == .clientCancel)
        #expect(finish.get() == .clientCancel)
        #expect(state.didClose())
        // First write was the head; cancellation kicks in before the next.
        #expect(state.writeCount() == 1)
    }
}
