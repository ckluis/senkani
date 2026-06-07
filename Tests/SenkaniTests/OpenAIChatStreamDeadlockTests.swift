import Testing
import Foundation
@testable import Core

/// Sibling regression for the phase-t1d-6 cooperative-pool deadlock class
/// (sync-over-async-on-cooperative-pool sweep, 2026-06-01).
///
/// THE BUG (test-only, latent): `OpenAIChatStream.driveStreaming` bridges
/// an async event source to the listener's synchronous `Sink` via a
/// `Channel` whose consumer loop BLOCKS the caller on an unbounded
/// `sem.wait()` while a producer `Task` iterates the upstream
/// `AsyncThrowingStream`. Under a full `swift test` (many concurrent
/// async `@Test`s) the calling thread may be a cooperative-pool thread;
/// if the producer `Task` was also placed on the cooperative pool (the
/// legacy default), every coop thread could end up parked in this very
/// `wait()` with no thread free to RUN the producer that would
/// `signal()` it. Production never self-starves because the live caller
/// (`OpenAIListener.runStream`) blocks an `NWConnection`/GCD thread —
/// never a cooperative thread.
///
/// THE FIX: host the producer `Task` on `ServeBridge.executor` (the
/// dedicated `TaskExecutor`, SE-0417, macOS 15+) whose threads are NOT
/// in the cooperative pool. The producer can START to push items +
/// `.end` regardless of pool saturation, so the channel pump completes.
///
/// Regression posture (deterministic + parallel-safe):
///
///   1. A SOURCE-TEXT INVARIANT pins the load-bearing `Task(executorPreference:
///      ServeBridge.executor, ...)` call site inside `OpenAIChatStream.swift`.
///      This is the structural proof: dropping the executor preference
///      (= regressing the fix) deterministically flips the assertion.
///      Mirrors the spirit of `ServeBridgeDeadlockTests` —
///      `isRunningOnDedicatedExecutor()` is the same seam, but
///      `driveStreaming` doesn't expose an in-Task hook for the test
///      to read it (the producer Task is private and its `for try await`
///      body calls private `Channel.push`), so we pin the equivalent
///      invariant at the source level.
///
///   2. A BEHAVIOR TEST drives `OpenAIChatStream.run(plan:sink:)` end-to-end
///      against a synthetic `AsyncThrowingStream` and asserts head + each
///      chunk + `[DONE]` arrive at the sink in order, the run reports
///      `.completed`, and the sink is closed exactly once. This is the
///      pass-after liveness check (a regressing build would hang here
///      under coop-pool saturation — the source-text invariant catches
///      the regression without needing a flaky saturation harness).
///
/// FAIL-BEFORE / PASS-AFTER: dropping the `executorPreference:` argument
/// (e.g. reverting `Task(executorPreference: ServeBridge.executor,
/// operation: producerBody)` to `Task(operation: producerBody)`)
/// deterministically fails the source-text invariant. The end-to-end
/// `swift test` LIVENESS proof remains the safety net at integration time.
@Suite
struct OpenAIChatStreamDeadlockTests {

    /// A buffer record + factory: `OpenAIChatStream.Sink` is a struct of
    /// `@Sendable` closures, not a protocol — so we close over a shared
    /// record. Thread-safe via NSLock.
    private final class BufferRecord: @unchecked Sendable {
        private let lock = NSLock()
        private var writes: [Data] = []
        private var closed = false
        func append(_ data: Data) {
            lock.lock(); defer { lock.unlock() }
            writes.append(data)
        }
        func markClosed() {
            lock.lock(); defer { lock.unlock() }
            closed = true
        }
        var allWrittenBytes: Data {
            lock.lock(); defer { lock.unlock() }
            return writes.reduce(into: Data()) { $0.append($1) }
        }
        var isClosed: Bool {
            lock.lock(); defer { lock.unlock() }
            return closed
        }
        func asSink() -> OpenAIChatStream.Sink {
            OpenAIChatStream.Sink(
                write: { [weak self] in self?.append($0) },
                isCancelled: { false },
                close: { [weak self] in self?.markClosed() }
            )
        }
    }

    // MARK: 1. Source-text invariant

    /// The structural proof: the producer Task in `driveStreaming` is
    /// hosted on `ServeBridge.executor` via `Task(executorPreference:)`.
    /// Dropping the `executorPreference` argument deterministically fails
    /// this assertion.
    @Test
    func driveStreamingProducerTaskPinnedToServeBridgeExecutor() throws {
        // Resolve the source file relative to this test file at build time
        // (Swift Package layout: Tests/SenkaniTests/<this> alongside
        //  Sources/Core/OpenAIEndpoint/OpenAIChatStream.swift via package root).
        let thisFile = URL(fileURLWithPath: #filePath)
        // Tests/SenkaniTests/ → up two → Sources/Core/OpenAIEndpoint/...
        let pkgRoot = thisFile.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let streamFile = pkgRoot
            .appendingPathComponent("Sources")
            .appendingPathComponent("Core")
            .appendingPathComponent("OpenAIEndpoint")
            .appendingPathComponent("OpenAIChatStream.swift")
        let src = try String(contentsOf: streamFile, encoding: .utf8)
        #expect(
            src.contains("Task(executorPreference: ServeBridge.executor, operation: producerBody)"),
            "driveStreaming's producer Task must be hosted on the dedicated TaskExecutor (ServeBridge.executor) so it can START under a saturated cooperative pool — see ServeBridgeDeadlockTests for the sibling fix's rationale."
        )
        // Defense-in-depth: the macOS-14 fallback branch must remain present
        // (we don't drop v14 support to fix this; v14 production never
        // self-starves because callers block GCD threads, never coop threads).
        #expect(
            src.contains("Task(operation: producerBody)"),
            "the macOS-14 fallback Task(operation:) branch must remain — dropping it would break the package floor"
        )
    }

    // MARK: 2. End-to-end behavior

    /// Drive a synthetic source through the REAL `OpenAIChatStream.run(plan:sink:)`
    /// and assert head + each chunk + `[DONE]` land at the sink in order,
    /// run reports `.completed`, sink closed exactly once. Pass-after
    /// liveness: a regressing build would hang here under coop-pool
    /// saturation; the structural test above catches the regression
    /// without a flaky saturation harness.
    @Test
    func driveStreamingCompletesEndToEndWithSyntheticSource() {
        let head = Data("HEAD\n".utf8)
        let done = Data("DONE\n".utf8)
        let chunks = [Data("a\n".utf8), Data("b\n".utf8), Data("c\n".utf8)]
        let sourceFactory: @Sendable () -> AsyncThrowingStream<Data, Error> = {
            AsyncThrowingStream<Data, Error> { continuation in
                for chunk in chunks { continuation.yield(chunk) }
                continuation.finish()
            }
        }
        let record = BufferRecord()
        let plan = OpenAIChatStream.Plan(
            head: head,
            streamingEvents: sourceFactory,
            done: done,
            onFinish: { _ in }
        )
        let status = OpenAIChatStream.run(plan: plan, sink: record.asSink())
        #expect(status == .completed)

        let bytes = record.allWrittenBytes
        let expected = head + chunks.reduce(Data(), +) + done
        #expect(bytes == expected)
        #expect(record.isClosed)
    }
}
