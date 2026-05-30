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

    @Test("View source declares the row + status-color mapping + read API")
    func viewSourceGuard() {
        let src = paneViewSource()
        #expect(src.contains("struct OpenAIServedRequestsPane: View"),
                "the pane view must be declared")
        #expect(src.contains("recentOpenAIRequests(limit:"),
                "the pane must read via the persisted-store read API")
        #expect(src.contains("OpenAIServedRequestsPresenter.fields(for:"),
                "the pane must route rendering through the Core presenter")
        #expect(src.contains("case .warn:") && src.contains(".orange"),
                "the pane must map the warn (429) bucket to orange")
        #expect(src.contains("case .error:") && src.contains(".red"),
                "the pane must map the error bucket to red")
        // a-1 is snapshot-only: no poll task yet (that is a-2).
        #expect(!src.contains("Task.sleep"),
                "a-1 must NOT introduce a poll loop — that is a-2's scope")
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
