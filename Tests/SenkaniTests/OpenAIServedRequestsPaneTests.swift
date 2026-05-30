import Testing
import Foundation
@testable import Core

/// V.13 GUI a-1 — served-requests pane core.
///
/// The SwiftUI view (`SenkaniApp/Views/OpenAIServedRequestsPane.swift`)
/// lives in the `SenkaniApp` executable target, which is NOT importable
/// into this test target (mirrors every other SenkaniTests suite —
/// `ScheduleCommandListRenderTests` is the precedent). So behavior is
/// asserted against the importable `OpenAIServedRequestsPresenter` (Core),
/// and the view shell is covered by a `#filePath` source guard.
@Suite("OpenAI served-requests pane — a-1 rendering")
struct OpenAIServedRequestsPaneTests {

    // MARK: - (1) row shape — all fields render from a populated row

    @Test("Row shape: all fields map to non-empty display strings")
    func rowShapeAllFields() {
        let row = OpenAIRequestLogStore.Row(
            id: 7,
            ts: Date(timeIntervalSince1970: 1_000_000),
            surface: "chat",
            status: 200,
            keyLabel: "default",
            modelLogged: "gemma-3-4b",
            resolvedTier: "local",
            inputTokens: 128,
            outputTokens: 64
        )
        let now = Date(timeIntervalSince1970: 1_000_030) // 30s later
        let f = OpenAIServedRequestsPresenter.fields(for: row, now: now)

        #expect(f.id == 7)
        #expect(f.age == "30s")
        #expect(f.surface == "chat")
        #expect(f.model == "gemma-3-4b")
        #expect(f.tier == "local")
        #expect(f.tokens == "128/64")
        #expect(f.keyLabel == "default")
        #expect(f.status == 200)
        #expect(f.statusCategory == .ok)
    }

    // MARK: - (2) empty-state surface (view source declares it)

    @Test("Empty-state surface is declared in the view with serve guidance")
    func emptyStateDeclared() {
        let src = paneViewSource()
        #expect(src.contains("No served requests yet"),
                "view must declare the empty-state title")
        #expect(src.contains("senkani serve --openai"),
                "empty-state must point the operator at the serve command")
        #expect(src.contains("senkani vault add"),
                "empty-state must point the operator at key provisioning")
    }

    // MARK: - (3) malformed model_logged renders raw as the literal token

    @Test("Malformed model_logged passes through raw as <malformed>")
    func malformedModelRaw() {
        #expect(OpenAIServedRequestsPresenter.modelDisplay("<malformed>") == "<malformed>")
        // No special-casing: an arbitrary (already-sanitized) value is verbatim.
        #expect(OpenAIServedRequestsPresenter.modelDisplay("weird.name_1") == "weird.name_1")
    }

    // MARK: - (4) refusal rows — semantic color + NULL tolerance

    @Test("Refusal rows render with semantic color and tolerate NULLs")
    func refusalRowsNullTolerant() {
        // 401 / 403 → error bucket; 429 → its own warn bucket.
        #expect(OpenAIServedRequestsPresenter.statusCategory(401) == .error)
        #expect(OpenAIServedRequestsPresenter.statusCategory(403) == .error)
        #expect(OpenAIServedRequestsPresenter.statusCategory(429) == .warn)
        #expect(OpenAIServedRequestsPresenter.statusCategory(200) == .ok)
        #expect(OpenAIServedRequestsPresenter.statusCategory(500) == .error)

        let refusal = OpenAIRequestLogStore.Row(
            id: 9,
            ts: Date(timeIntervalSince1970: 2_000_000),
            surface: "other",
            status: 429,
            keyLabel: nil,
            modelLogged: "<refused>",
            resolvedTier: nil,
            inputTokens: nil,
            outputTokens: nil
        )
        let f = OpenAIServedRequestsPresenter.fields(for: refusal, now: Date(timeIntervalSince1970: 2_000_000))
        #expect(f.statusCategory == .warn)
        #expect(f.model == "<refused>")
        #expect(f.tier == OpenAIServedRequestsPresenter.nullPlaceholder)
        #expect(f.keyLabel == OpenAIServedRequestsPresenter.nullPlaceholder)
        #expect(f.tokens == "—/—")
        #expect(f.age == "0s")
    }

    // MARK: - (5) smoke render of a multi-row snapshot

    @Test("Smoke: a multi-row snapshot maps every row without loss")
    func multiRowSnapshot() {
        let base = Date(timeIntervalSince1970: 3_000_000)
        let rows = (0..<5).map { i in
            OpenAIRequestLogStore.Row(
                id: Int64(i),
                ts: base,
                surface: ["chat", "chat_stream", "embeddings", "tool_use", "other"][i],
                status: [200, 200, 429, 401, 503][i],
                keyLabel: i == 4 ? nil : "k\(i)",
                modelLogged: i == 3 ? "<refused>" : "m\(i)",
                resolvedTier: i == 3 ? nil : "local",
                inputTokens: i == 3 ? nil : i * 10,
                outputTokens: i == 3 ? nil : i * 5
            )
        }
        let fields = rows.map { OpenAIServedRequestsPresenter.fields(for: $0, now: base) }
        #expect(fields.count == 5)
        #expect(fields.map(\.statusCategory) == [.ok, .ok, .warn, .error, .error])
        #expect(fields[0].surface == "chat")
        #expect(fields[4].surface == "other")
        #expect(fields[4].keyLabel == OpenAIServedRequestsPresenter.nullPlaceholder)
        // ids preserved 1:1, no drops
        #expect(fields.map(\.id) == [0, 1, 2, 3, 4])
    }

    // MARK: - relative-age boundaries (presenter parity with AgentTimelinePane)

    @Test("Relative age: seconds, minutes, absolute boundaries")
    func relativeAgeBoundaries() {
        let t = Date(timeIntervalSince1970: 10_000_000)
        #expect(OpenAIServedRequestsPresenter.relativeAge(t, now: t.addingTimeInterval(5)) == "5s")
        #expect(OpenAIServedRequestsPresenter.relativeAge(t, now: t.addingTimeInterval(120)) == "2m")
        // ≥ 1h → absolute HH:mm:ss (just assert it is not the relative form)
        let abs = OpenAIServedRequestsPresenter.relativeAge(t, now: t.addingTimeInterval(7200))
        #expect(!abs.hasSuffix("s") && !abs.hasSuffix("m"))
        #expect(abs.contains(":"))
    }

    // MARK: - Source-level guard for the SwiftUI view shell

    @Test("View source declares the row + status-color mapping + poll lifecycle wiring")
    func viewSourceGuard() {
        let src = paneViewSource()
        #expect(src.contains("struct OpenAIServedRequestsPane: View"),
                "the pane view must be declared")
        #expect(src.contains("OpenAIServedRequestsPresenter.fields(for:"),
                "the pane must route rendering through the Core presenter")
        #expect(src.contains("case .warn:") && src.contains(".orange"),
                "the pane must map the warn (429) bucket to orange")
        #expect(src.contains("case .error:") && src.contains(".red"),
                "the pane must map the error bucket to red")
        // a-2: the store read + poll loop moved into
        // Core.OpenAIServedRequestsPoller (the view is a thin shell that
        // owns + drives it via onAppear/onDisappear). The view no longer
        // reads the store directly; it binds the poller's rows.
        #expect(src.contains("OpenAIServedRequestsPoller(store: SessionDatabase.shared"),
                "the pane must own a Core poller seeded with the shared DB")
        #expect(src.contains("poller.start()") && src.contains(".onAppear"),
                "the pane must start the 500ms poll loop onAppear")
        #expect(src.contains("poller.stop()") && src.contains(".onDisappear"),
                "the pane must stop the poll loop onDisappear (no leak)")
    }

    // MARK: - (a-2) 500ms poll lifecycle — driven by an advance-time clock

    @Test("Poll lifecycle: a new persisted row appears after one 500ms interval")
    @MainActor
    func pollPicksUpNewRowAfterOneInterval() async {
        let store = MockOpenAIRequestsStore()
        let clock = ManualClock()
        let poller = OpenAIServedRequestsPoller(store: store, limit: 100, pollInterval: .milliseconds(500))

        let handle = poller.start(clock: clock)
        await clock.untilSleeping()              // first poll done (store empty), loop parked
        #expect(poller.rows.isEmpty, "no rows polled before any are persisted")

        // A request is served between polls.
        store.scripted = [Self.makeRow(id: 1, status: 200)]
        clock.advance(by: .milliseconds(500))    // exactly one poll interval elapses
        await clock.untilSleeping()              // second poll done, loop re-parked

        #expect(poller.rows.count == 1, "the 500ms poll must surface the new row")
        #expect(poller.rows.first?.id == 1)

        poller.stop()
        await handle.value                       // loop unwinds — no parked task left
    }

    @Test("onDisappear cancels the poll task with no leak")
    @MainActor
    func stopCancelsPollTaskNoLeak() async {
        let store = MockOpenAIRequestsStore()
        let clock = ManualClock()
        let poller = OpenAIServedRequestsPoller(store: store, pollInterval: .milliseconds(500))

        let handle = poller.start(clock: clock)
        await clock.untilSleeping()
        #expect(poller.isPolling, "the loop must be running after start()")

        poller.stop()                            // onDisappear
        #expect(!poller.isPolling, "stop() must drop the task handle")

        // The decisive no-leak check: a parked poll task that ignored
        // cancellation would hang this await forever. It returns promptly
        // because cancellation throws out of the in-flight sleep.
        await handle.value
        #expect(handle.isCancelled, "the poll task must observe cancellation")
        #expect(clock.sleeperCount == 0, "no sleeper continuation left parked")
    }

    @Test("100-row burst renders without dropping a single row")
    @MainActor
    func hundredRowBurstNoDrop() async {
        let store = MockOpenAIRequestsStore()
        let clock = ManualClock()
        let poller = OpenAIServedRequestsPoller(store: store, limit: 100, pollInterval: .milliseconds(500))

        // The v13e-5 burst pattern: 100 requests across mixed surfaces.
        let burst = (1...100).map { i in
            Self.makeRow(id: Int64(i),
                         status: [200, 200, 429, 401, 503][i % 5],
                         surface: ["chat", "chat_stream", "embeddings", "tool_use", "other"][i % 5])
        }
        store.scripted = burst

        let handle = poller.start(clock: clock)
        await clock.untilSleeping()              // one wholesale poll reads the full burst

        #expect(poller.rows.count == 100, "every persisted row must render — a poll skip would drop rows")
        #expect(Set(poller.rows.map(\.id)) == Set(burst.map(\.id)),
                "no id may be dropped — recent(limit:) is the truth source, rendered 1:1")

        poller.stop()
        await handle.value
    }

    // MARK: - (a-3) pane catalog registration

    @Test("a-3: the served-requests pane is registered in the Add-Pane catalog")
    func paneRegisteredInCatalog() {
        // The Add-Pane sheet renders `PaneGalleryBuilder.allEntries()` (the
        // catalog truth source; the SwiftUI sheet is a thin presentation
        // layer over it). A registered entry here is what makes the pane
        // operator-addable without a rebuild. The command palette derives
        // from the same source (CommandPaletteTests pins gallery↔palette
        // parity), so one registration reaches both surfaces.
        let entries = PaneGalleryBuilder.allEntries()
        let served = entries.first { $0.id == "openAIServedRequests" }
        #expect(served != nil,
                "served-requests pane must appear in the Add-Pane catalog")
        #expect(served?.category == "Data & Insights",
                "served-requests is a measurement surface — Data & Insights")
        #expect(served?.name == "Served Requests")
        #expect((served?.description.count ?? 99) <= 80,
                "catalog description must fit the two-line card budget")
        // No regression: the catalog still renders without duplicate IDs and
        // keeps every category within the ≤6-cell skimmability budget.
        let ids = entries.map(\.id)
        #expect(Set(ids).count == ids.count, "catalog IDs must stay unique")
        for group in PaneGalleryBuilder.categorized() {
            #expect(group.entries.count <= 6,
                    "category '\(group.category)' exceeded the 6-cell cap")
        }
    }

    // MARK: - (a-3) per-column accessibility labels

    @Test("a-3: every served-request row column carries an accessibility label")
    func rowColumnsHaveAccessibilityLabels() {
        // The row view lives in the non-importable SenkaniApp target, so the
        // a11y wiring is asserted via a `#filePath` source guard (the same
        // pattern as `viewSourceGuard`). Each of the seven columns must carry
        // an `.accessibilityLabel(...)` naming its semantic field, so
        // VoiceOver reads "Surface chat" rather than a truncated monospace
        // token.
        let src = paneViewSource()
        let expectedLabels = [
            "Age \\(fields.age)",
            "Surface \\(fields.surface)",
            "Model \\(fields.model)",
            "Resolved tier \\(fields.tier)",
            "Tokens \\(fields.tokens)",
            "Key \\(fields.keyLabel)",
            "Status \\(fields.status)",
        ]
        for label in expectedLabels {
            #expect(src.contains(".accessibilityLabel(Text(\"\(label)\"))"),
                    "row must label its column: \(label)")
        }
        // Exactly one label per rendered column — no column left unlabeled.
        let labelCount = src.components(separatedBy: ".accessibilityLabel(").count - 1
        #expect(labelCount >= expectedLabels.count,
                "every row column must carry an accessibility label (found \(labelCount))")
    }

    // MARK: - (a-2) test fixtures

    /// Build a populated row; only the fields a poll test cares about are
    /// parameterized.
    static func makeRow(
        id: Int64,
        status: Int,
        surface: String = "chat"
    ) -> OpenAIRequestLogStore.Row {
        OpenAIRequestLogStore.Row(
            id: id,
            ts: Date(timeIntervalSince1970: 1_000_000 + Double(id)),
            surface: surface,
            status: status,
            keyLabel: "default",
            modelLogged: "gemma-3-4b",
            resolvedTier: "local",
            inputTokens: 16,
            outputTokens: 8
        )
    }

    // MARK: - helper

    private func paneViewSource() -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tests/SenkaniTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // <repo root>
            .appendingPathComponent("SenkaniApp/Views/OpenAIServedRequestsPane.swift")
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }
}

// MARK: - Test fixtures (a-2 poll lifecycle)

/// In-memory `OpenAIServedRequestsReading` double. `scripted` is the row
/// set the next poll will read; mutate it between `advance` calls to model
/// requests arriving while the pane is visible. Lock-guarded so the
/// MainActor poll loop and the test can touch it without a data race.
final class MockOpenAIRequestsStore: OpenAIServedRequestsReading, @unchecked Sendable {
    private let lock = NSLock()
    private var _scripted: [OpenAIRequestLogStore.Row] = []

    var scripted: [OpenAIRequestLogStore.Row] {
        get { lock.lock(); defer { lock.unlock() }; return _scripted }
        set { lock.lock(); defer { lock.unlock() }; _scripted = newValue }
    }

    func recentOpenAIRequests(limit: Int) -> [OpenAIRequestLogStore.Row] {
        lock.lock(); defer { lock.unlock() }
        return Array(_scripted.prefix(limit))   // id-desc truth source, capped at limit
    }
}

/// A manually-advanced `Clock` for deterministic poll-cadence tests — no
/// real wall-clock wait. `advance(by:)` moves time forward and resumes any
/// sleeper whose deadline has passed; `untilSleeping()` yields until the
/// poll loop has run a refresh and re-parked, giving the test a precise
/// synchronization barrier. Cancellation throws `CancellationError` out of
/// an in-flight `sleep` so the poll loop unwinds on `stop()` (the no-leak
/// assertion).
final class ManualClock: Clock, @unchecked Sendable {
    struct Instant: InstantProtocol {
        let offset: Duration
        func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }
        func duration(to other: Instant) -> Duration { other.offset - offset }
        static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
    }

    private let lock = NSLock()
    private var _now = Instant(offset: .zero)
    private var sleepers: [(id: UUID, deadline: Instant, cont: CheckedContinuation<Void, Error>)] = []

    var now: Instant { lock.lock(); defer { lock.unlock() }; return _now }
    let minimumResolution: Duration = .nanoseconds(1)

    var sleeperCount: Int { lock.lock(); defer { lock.unlock() }; return sleepers.count }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        try Task.checkCancellation()
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                lock.lock()
                if _now >= deadline {
                    lock.unlock()
                    cont.resume()
                } else {
                    sleepers.append((id, deadline, cont))
                    lock.unlock()
                }
            }
        } onCancel: {
            lock.lock()
            let removed = sleepers.firstIndex { $0.id == id }.map { sleepers.remove(at: $0) }
            lock.unlock()
            removed?.cont.resume(throwing: CancellationError())
        }
    }

    /// Advance time and resume every sleeper whose deadline is now due.
    func advance(by duration: Duration) {
        lock.lock()
        _now = _now.advanced(by: duration)
        let due = sleepers.filter { $0.deadline <= _now }
        sleepers.removeAll { $0.deadline <= _now }
        lock.unlock()
        for s in due { s.cont.resume() }
    }

    /// Cooperatively yield until at least `count` sleepers are parked. On
    /// the MainActor executor this lets the poll loop run its refresh and
    /// re-enter `sleep`, so the test asserts against a settled state. The
    /// cap is a runaway guard — a healthy loop parks within a few yields.
    func untilSleeping(_ count: Int = 1) async {
        var spins = 0
        while sleeperCount < count {
            await Task.yield()
            spins += 1
            if spins > 1_000_000 { break }
        }
    }
}
