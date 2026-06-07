import Foundation
import Observation

/// Read seam for the served-requests poll loop. The persisted store
/// (`SessionDatabase`, via `recentOpenAIRequests(limit:)`) conforms in
/// production; tests inject a mock that returns a scripted row set so the
/// poll lifecycle is deterministic without a live database.
///
/// V.13 GUI a-2. Lives in Core — NOT the `SenkaniApp` executable target —
/// for the same reason `OpenAIServedRequestsPresenter` does: the SwiftUI
/// `View` cannot be `@testable import`-ed from `SenkaniTests`, so the poll
/// lifecycle (cadence, cancellation, no-drop wholesale read) is exercised
/// here against this seam + an advance-time clock.
public protocol OpenAIServedRequestsReading: Sendable {
    /// The N most recent request-log rows in id-desc order. This is the
    /// poll loop's single truth source: a wholesale re-read every tick, so
    /// no row is ever dropped (a-2's 100-req burst acceptance).
    func recentOpenAIRequests(limit: Int) -> [OpenAIRequestLogStore.Row]
}

/// `SessionDatabase.recentOpenAIRequests(limit:)` already has this exact
/// shape (V.13e-1), so the conformance is declaration-only.
extension SessionDatabase: OpenAIServedRequestsReading {}

/// Drives the served-requests pane's 500ms poll cadence
/// (`SenkaniApp/Views/OpenAIServedRequestsPane.swift`, V.13 GUI a-2).
///
/// Mirrors `AgentTimelinePane`'s poll pattern verbatim: an `onAppear`-
/// started `Task` loops `refresh` → `sleep(pollInterval)` until cancelled,
/// and `onDisappear` cancels it. There is deliberately NO reactive
/// SQLite-change-notification seam (operator decompose decision
/// 2026-05-30, Q3 — a 500ms poll is sufficient and adds no producer/write
/// path). The View is a thin `@Observable`-bound shell that reads `rows`.
///
/// The loop is generic over a `Clock` so tests can inject an advance-time
/// clock and assert "a new row appears after one poll interval" without a
/// real 500ms wall-clock wait. Production calls `start()` (a
/// `ContinuousClock`).
@MainActor
@Observable
public final class OpenAIServedRequestsPoller {

    /// The most recently polled rows. The View binds this directly; tests
    /// assert on it after advancing the injected clock.
    public private(set) var rows: [OpenAIRequestLogStore.Row] = []

    @ObservationIgnored private let store: any OpenAIServedRequestsReading
    @ObservationIgnored private let limit: Int
    @ObservationIgnored private let pollInterval: Duration
    @ObservationIgnored private var task: Task<Void, Never>?

    public init(
        store: any OpenAIServedRequestsReading,
        limit: Int = 100,
        pollInterval: Duration = .milliseconds(500)
    ) {
        self.store = store
        self.limit = limit
        self.pollInterval = pollInterval
    }

    /// Whether a poll loop is currently running. The `onDisappear`-cancel
    /// acceptance asserts this flips to `false` after `stop()`.
    public var isPolling: Bool { task != nil }

    /// One poll tick: re-read the truth source wholesale. `recent(limit:)`
    /// returns every persisted row up to `limit` in id-desc order, so a
    /// burst is rendered in full — no row is dropped. The diff suppresses a
    /// redundant `@Observable` mutation when nothing changed (matching
    /// `AgentTimelinePane.refreshEvents`).
    public func refresh() {
        let next = store.recentOpenAIRequests(limit: limit)
        if next != rows { rows = next }
    }

    /// Start the poll loop on the given clock. Idempotent: a running loop
    /// is cancelled first, so a re-`onAppear` never leaks a second task.
    /// Returns the loop's `Task` so tests can `await` its unwind after
    /// cancellation (the no-leak assertion).
    @discardableResult
    public func start<C: Clock>(clock: C) -> Task<Void, Never> where C.Duration == Duration {
        stop()
        let interval = pollInterval
        let t = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { break }
                self.refresh()
                do {
                    try await clock.sleep(until: clock.now.advanced(by: interval), tolerance: nil)
                } catch {
                    // Cancellation (onDisappear) unwinds the in-flight
                    // sleep: exit cleanly so the task terminates.
                    break
                }
            }
        }
        task = t
        return t
    }

    /// Production entry point — real wall-clock 500ms cadence.
    @discardableResult
    public func start() -> Task<Void, Never> {
        start(clock: ContinuousClock())
    }

    /// Cancel the poll loop and drop the task handle. Called from
    /// `onDisappear`; cancellation throws out of the in-flight `sleep` so
    /// the loop unwinds rather than leaking a parked task.
    public func stop() {
        task?.cancel()
        task = nil
    }
}
