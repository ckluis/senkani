import Foundation

/// U.9b-3 — the consumer-pull-loop spine for the SessionWorkQueue
/// migration. Owns the four long-lived `session_event_stream` consumer
/// loops (`validation`, `agent_timeline`, `notifications`,
/// `compound_learning_analytics`) under the default-OFF
/// `WorkBusConfig.dualWrite` flag.
///
/// ## Contract
///
/// Each registered consumer is an `id` + a synchronous `handler` closure.
/// One drain of a consumer is the pure, deterministic three-step contract:
///
///   1. `pullSince(consumerId:limit:)`  — read up to `limit` events AFTER
///      the consumer's persisted offset (non-mutating).
///   2. invoke the handler for the batch (records lag / advances real work).
///   3. `commitOffset(consumerId:upTo: <max id in batch>)` — advance the
///      offset cursor past the batch.
///
/// `drainOnce(consumerId:)` runs exactly that contract once and is the
/// SYNCHRONOUS test seam: tests drive pull→process→commit deterministically
/// without any wall-clock loop timing.
///
/// ## Flake invariant (NON-NEGOTIABLE — parent acceptance line 66, R7/R8)
///
/// The original U.9b 5s flake came from `Task.detached(priority: .utility)`
/// starving on the cooperative pool under full-suite parallel load. This
/// dispatcher deliberately does NOT use `Task.detached(.utility)` and does
/// NOT introduce a second cooperative-pool hop. The long-lived loops use a
/// structured `Task { ... }` with `Task.sleep`/cancellation (the
/// `OpenAIServedRequestsPoller` precedent), and — critically — the
/// underlying pull/commit work runs on `SessionEventStreamStore`'s OWN
/// serial dispatch queue (NOT the cooperative pool). Tests never assert
/// "the loop fired within N ms"; they drive the synchronous `drainOnce`
/// contract directly.
///
/// ## Default-safe (Allspaw fail-safe)
///
/// `start()` consults the injected `dualWriteEnabled` flag loader ONCE. When
/// the flag is OFF (the default) the dispatcher stays idle — zero pulls,
/// zero commits, zero behavior change. Only when an operator opts in
/// (`WorkBusConfig.dualWrite == true`) do the loops run. `drainOnce` is the
/// test seam and is flag-independent (tests gate the flag explicitly).
public final class EventStreamDispatcher: @unchecked Sendable {

    /// The four U.9a-seeded consumer ids.
    public enum ConsumerId {
        public static let validation = "validation"
        public static let agentTimeline = "agent_timeline"
        public static let notifications = "notifications"
        public static let compoundLearningAnalytics = "compound_learning_analytics"

        /// Registration order for the four standard consumers.
        public static let all: [String] = [
            validation, agentTimeline, notifications, compoundLearningAnalytics,
        ]
    }

    /// A consumer's batch handler. Pure-synchronous, runs inline on the
    /// store's serial queue context — NO second cooperative-pool hop. It is
    /// handed the batch the loop just pulled (already after the offset) and
    /// returns nothing; the dispatcher commits the offset past the batch
    /// AFTER the handler returns. A handler that throws is NOT a delivery —
    /// the offset is still advanced (at-most-once for the handler side;
    /// re-derivation comes from the canonical row, not a re-pull).
    public typealias Handler = (_ batch: [SessionEventStreamStore.Event]) -> Void

    private struct Consumer {
        let id: String
        let handler: Handler
    }

    private let store: SessionEventStreamStore
    private let pullLimit: Int
    private let pollInterval: Duration
    /// Read once at `start()`. A missing/false flag keeps the dispatcher
    /// idle (Allspaw fail-safe). Injectable for hermetic tests.
    private let dualWriteEnabled: () -> Bool

    /// Serializes mutation of `consumers` / `tasks` across `register` /
    /// `start` / `stop`. NOT on the cooperative pool — a plain lock.
    private let lock = NSLock()
    private var consumers: [String: Consumer] = [:]
    private var consumerOrder: [String] = []
    private var tasks: [String: Task<Void, Never>] = [:]

    public init(
        store: SessionEventStreamStore,
        pullLimit: Int = 100,
        pollInterval: Duration = .milliseconds(500),
        dualWriteEnabled: @escaping () -> Bool = {
            ((try? WorkBusConfigStore.load()) ?? WorkBusConfig()).dualWrite
        }
    ) {
        self.store = store
        self.pullLimit = max(1, pullLimit)
        self.pollInterval = pollInterval
        self.dualWriteEnabled = dualWriteEnabled
    }

    /// Convenience factory wiring the four standard consumers.
    /// `validation` runs its REAL work (U.9b-3b leg 1:
    /// `ValidationStreamConsumer` — drains `validation_results` events and
    /// drives the `auto_validate.delivered` path, commitOffset-driven,
    /// idempotent-claim exactly-once). `compound_learning_analytics` runs
    /// its REAL work (U.9b-3b leg 2:
    /// `CompoundLearningAnalyticsStreamConsumer` — rolls drained
    /// `token_events` / `agent_trace_event` events into
    /// `compound_learning.analytics.*` counters, commitOffset-driven,
    /// applied-watermark-claim exactly-once). `agent_timeline` runs its
    /// REAL work (U.9b-3b leg 3: `AgentTimelineStreamConsumer` — turns
    /// drained `token_events` / `agent_trace_event` events into the
    /// timeline's `agent_timeline.feed.*` freshness counters /
    /// `feedVersion` change-detection seam, commitOffset-driven,
    /// applied-watermark-claim exactly-once under its OWN cursor).
    /// `notifications` is the no-op-recording stub (T.6c owns its real
    /// body).
    public static func standard(
        db: SessionDatabase,
        pullLimit: Int = 100,
        pollInterval: Duration = .milliseconds(500),
        dualWriteEnabled: @escaping () -> Bool = {
            ((try? WorkBusConfigStore.load()) ?? WorkBusConfig()).dualWrite
        }
    ) -> EventStreamDispatcher? {
        guard let stream = db.sessionEventStreamStore else { return nil }
        let dispatcher = EventStreamDispatcher(
            store: stream,
            pullLimit: pullLimit,
            pollInterval: pollInterval,
            dualWriteEnabled: dualWriteEnabled
        )
        // validation: REAL work (U.9b-3b leg 1) — a drop-in via the
        // register seam; the spine's drain contract is unchanged.
        dispatcher.register(
            consumerId: ConsumerId.validation,
            handler: ValidationStreamConsumer.makeHandler(db: db)
        )
        // agent_timeline: REAL work (U.9b-3b leg 3) — a drop-in via the
        // register seam; the spine's drain contract is unchanged.
        dispatcher.register(
            consumerId: ConsumerId.agentTimeline,
            handler: AgentTimelineStreamConsumer.makeHandler(db: db)
        )
        // notifications: explicit no-op stub. Recorded distinctly so the
        // intent is legible — it advances offset + lag ONLY, never any side
        // effect (T.6c PushoverSink owns the real body).
        dispatcher.register(consumerId: ConsumerId.notifications, handler: { _ in })
        // compound_learning_analytics: REAL work (U.9b-3b leg 2) — a
        // drop-in via the register seam; the spine's drain contract is
        // unchanged.
        dispatcher.register(
            consumerId: ConsumerId.compoundLearningAnalytics,
            handler: CompoundLearningAnalyticsStreamConsumer.makeHandler(db: db)
        )
        return dispatcher
    }

    /// Register (or replace) a consumer's handler. Idempotent on id.
    public func register(consumerId: String, handler: @escaping Handler) {
        lock.lock(); defer { lock.unlock() }
        if consumers[consumerId] == nil {
            consumerOrder.append(consumerId)
        }
        consumers[consumerId] = Consumer(id: consumerId, handler: handler)
    }

    /// The registered consumer ids in registration order.
    public func registeredConsumerIds() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return consumerOrder
    }

    /// Whether any loop task is currently running.
    public var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return !tasks.isEmpty
    }

    /// Current lag (rows behind head) for a consumer — convenience for
    /// diagnostics callers / tests.
    public func lag(consumerId: String) -> Int {
        store.lag(consumerId: consumerId)
    }

    /// One synchronous drain of a single consumer: pull → process → commit.
    /// This is the deterministic test seam AND the loop body. Returns the
    /// number of events processed in this drain (0 when caught up or the
    /// consumer is unregistered).
    ///
    /// Flake-safe: fully synchronous, no `Task`, no wall-clock dependence.
    /// The pull + commit run on the store's serial queue; the handler runs
    /// inline on the caller's thread between them.
    @discardableResult
    public func drainOnce(consumerId: String) -> Int {
        lock.lock()
        let consumer = consumers[consumerId]
        lock.unlock()
        guard let consumer else { return 0 }

        let batch = store.pullSince(consumerId: consumerId, limit: pullLimit)
        guard !batch.isEmpty else { return 0 }
        consumer.handler(batch)
        // Advance past the max id in the batch. `pullSince` returns ASC by
        // id, so the last element is the high-water mark.
        if let maxId = batch.last?.id {
            store.commitOffset(consumerId: consumerId, upTo: maxId)
        }
        return batch.count
    }

    /// Drain a consumer to its current head: repeated `drainOnce` until a
    /// drain returns 0. Bounded by `maxDrains` so a producer racing the
    /// drain cannot spin forever. Returns total events processed.
    @discardableResult
    public func drainToHead(consumerId: String, maxDrains: Int = 1_000) -> Int {
        var total = 0
        var drains = 0
        while drains < maxDrains {
            let n = drainOnce(consumerId: consumerId)
            if n == 0 { break }
            total += n
            drains += 1
        }
        return total
    }

    /// Start the long-lived consumer loops — ONE structured `Task` per
    /// registered consumer. No-op (dispatcher stays idle) when the
    /// `dualWrite` flag is OFF: that is the Allspaw fail-safe / zero-behavior
    /// -change default. Idempotent: a second `start()` while running first
    /// `stop()`s, so no loop is ever doubled.
    ///
    /// FLAKE INVARIANT: each loop is a structured `Task { ... }` (NOT
    /// `Task.detached(.utility)`); the body calls the synchronous
    /// `drainOnce` then `Task.sleep`s on the clock until cancelled. The
    /// drain runs on the store's serial queue — no second cooperative-pool
    /// hop is introduced for the actual pull/process/commit work.
    public func start<C: Clock>(clock: C) where C.Duration == Duration {
        guard dualWriteEnabled() else {
            // Default-OFF: idle. Pin by leaving `tasks` empty.
            return
        }
        stop()
        lock.lock()
        let ids = consumerOrder
        let interval = pollInterval
        for id in ids {
            let t = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self else { break }
                    // Synchronous drain — runs on the store's serial queue,
                    // not the cooperative pool. No second hop.
                    self.drainToHead(consumerId: id)
                    do {
                        try await clock.sleep(
                            until: clock.now.advanced(by: interval),
                            tolerance: nil
                        )
                    } catch {
                        // Cancellation (stop()) unwinds the in-flight sleep.
                        break
                    }
                }
            }
            tasks[id] = t
        }
        lock.unlock()
    }

    /// Production entry point — real wall-clock cadence.
    public func start() {
        start(clock: ContinuousClock())
    }

    /// Cancel every loop task and drop the handles. Cancellation throws out
    /// of the in-flight `sleep` so each loop unwinds cleanly rather than
    /// leaking a parked task.
    public func stop() {
        lock.lock()
        let running = tasks
        tasks.removeAll()
        lock.unlock()
        for (_, t) in running { t.cancel() }
    }
}
