import Testing
import Foundation
@testable import Core

/// Pane diary generator — composition half (round 2 of 3).
///
/// Covers the acceptance matrix: empty rows → empty brief, small rows →
/// full brief with every section, hard 200-token cap under a flood of
/// rows, caller-supplied error surfaces in the brief, file-touched
/// dedupe (recency wins), and truncation never splits a section.
@Suite("PaneDiaryGenerator") struct PaneDiaryGeneratorTests {

    // MARK: - Fixtures

    private func row(
        id: Int64 = 1,
        offset: TimeInterval = 0,
        source: String = "mcp_tool",
        tool: String? = "read",
        feature: String? = nil,
        command: String? = nil,
        input: Int = 10,
        output: Int = 5,
        saved: Int = 0,
        cents: Int = 0
    ) -> SessionDatabase.TimelineEvent {
        SessionDatabase.TimelineEvent(
            id: id,
            timestamp: Date(timeIntervalSince1970: 1_700_000_000 + offset),
            source: source,
            toolName: tool,
            feature: feature,
            command: command,
            inputTokens: input,
            outputTokens: output,
            savedTokens: saved,
            costCents: cents
        )
    }

    // MARK: - Empty input

    @Test func emptyRowsAndNoErrorReturnsEmpty() {
        let out = PaneDiaryGenerator.generate(
            rows: [], paneSlug: "chat-main"
        )
        #expect(out == "")
    }

    // MARK: - Small brief — every section present

    @Test func smallBriefSurfacesHeaderLastFilesCostRecent() {
        let rows = [
            row(id: 1, offset: 30, tool: "read",
                command: "/proj/Sources/Core/HookRouter.swift",
                input: 120, output: 40),
            row(id: 2, offset: 20, tool: "edit",
                command: "/proj/Sources/Core/PaneDiaryStore.swift",
                input: 200, output: 80),
            row(id: 3, offset: 10, tool: "read",
                command: "/proj/README.md",
                input: 60, output: 10),
        ]
        let out = PaneDiaryGenerator.generate(
            rows: rows, paneSlug: "chat-main", maxTokens: 200
        )
        #expect(out.contains("Last time in 'chat-main':"))
        #expect(out.contains("Last: /proj/Sources/Core/HookRouter.swift"))
        // Top-3 files in recency order, basenames only.
        #expect(out.contains("Files: HookRouter.swift, PaneDiaryStore.swift, README.md"))
        // Total cost = 120+40 + 200+80 + 60+10 = 510.
        #expect(out.contains("Cost: 510t"))
        #expect(out.contains("Recent: "))
        // Size check — under the cap, for real.
        let tokens = ModelPricing.bytesToTokens(out.utf8.count)
        #expect(tokens <= 200)
    }

    // MARK: - Error surfaces in brief

    @Test func callerSuppliedErrorAppearsBelowHeader() {
        let rows = [
            row(id: 1, offset: 10, tool: "exec",
                command: "swift build", input: 50, output: 10),
        ]
        let out = PaneDiaryGenerator.generate(
            rows: rows,
            paneSlug: "chat-main",
            lastError: "build failed: missing module"
        )
        #expect(out.contains("Error: build failed: missing module"))
        // Error line comes after the header but before Last/Files/Cost.
        let lines = out.split(separator: "\n")
        #expect(lines.first == "Last time in 'chat-main':")
        #expect(lines.dropFirst().first == "Error: build failed: missing module")
    }

    @Test func errorWithNoRowsStillProducesHeaderAndError() {
        let out = PaneDiaryGenerator.generate(
            rows: [],
            paneSlug: "slot-a",
            lastError: "crashed on open"
        )
        #expect(out.contains("Last time in 'slot-a':"))
        #expect(out.contains("Error: crashed on open"))
    }

    // MARK: - Hard token cap under flood

    @Test func largeRowsetRespects200TokenCapExactly() {
        // Build 200 rows each with a long command so the Recent
        // section would blow the budget many times over.
        let rows: [SessionDatabase.TimelineEvent] = (0..<200).map { i in
            row(
                id: Int64(i),
                offset: TimeInterval(i),
                tool: "read",
                command: "/proj/very/deeply/nested/path/file-\(i)-with-verbose-name.swift",
                input: 100, output: 100
            )
        }
        let out = PaneDiaryGenerator.generate(
            rows: rows, paneSlug: "chat-main", maxTokens: 200
        )
        let tokens = ModelPricing.bytesToTokens(out.utf8.count)
        #expect(tokens <= 200)

        // Output must end on a section boundary (no mid-line truncation).
        #expect(!out.hasSuffix(","))
        #expect(!out.hasSuffix(":"))
        // Every line either is the header, or starts with a known label.
        let lines = out.split(separator: "\n", omittingEmptySubsequences: true)
        for line in lines {
            let s = String(line)
            let valid = s.hasPrefix("Last time in '")
                || s.hasPrefix("Last: ")
                || s.hasPrefix("Files: ")
                || s.hasPrefix("Cost: ")
                || s.hasPrefix("Recent: ")
                || s.hasPrefix("Error: ")
            #expect(valid, "unexpected section shape: \(s)")
        }
    }

    // MARK: - Tight budget drops tail sections whole

    @Test func tightBudgetDropsRecentBeforeCore() {
        let rows = [
            row(id: 1, offset: 10, tool: "read",
                command: "/proj/file-a.swift", input: 100, output: 50),
            row(id: 2, offset: 5, tool: "read",
                command: "/proj/file-b.swift", input: 100, output: 50),
        ]
        // 30 tokens ≈ 120 bytes — enough for the header + maybe one more,
        // not enough for the full brief. "Recent: …" is the bulkiest
        // section and should get dropped first.
        let out = PaneDiaryGenerator.generate(
            rows: rows, paneSlug: "p", maxTokens: 30
        )
        #expect(!out.isEmpty)
        #expect(out.hasPrefix("Last time in 'p':"))
        #expect(!out.contains("Recent: "))
        let tokens = ModelPricing.bytesToTokens(out.utf8.count)
        #expect(tokens <= 30)
    }

    // MARK: - Files dedupe keeps first (most-recent) occurrence

    @Test func fileDedupeKeepsMostRecentPositionOnly() {
        let rows = [
            row(id: 1, offset: 100, tool: "read",
                command: "/a/b/File.swift"),
            row(id: 2, offset: 90, tool: "edit",
                command: "/a/b/Other.swift"),
            row(id: 3, offset: 80, tool: "read",
                // Re-read of File.swift — should NOT add a second entry.
                command: "/a/b/File.swift"),
            row(id: 4, offset: 70, tool: "read",
                command: "/a/b/Third.swift"),
        ]
        let out = PaneDiaryGenerator.generate(
            rows: rows, paneSlug: "p"
        )
        // Top-3: File.swift (most recent), Other.swift, Third.swift.
        // File.swift must appear exactly once.
        let fileLine = out.split(separator: "\n")
            .first { $0.hasPrefix("Files: ") } ?? ""
        #expect(String(fileLine) == "Files: File.swift, Other.swift, Third.swift")
    }

    // MARK: - Non-file tools are excluded from the Files section

    @Test func nonFileToolsDoNotLeakIntoFiles() {
        let rows = [
            row(id: 1, offset: 10, tool: "exec",
                command: "swift build"),
            row(id: 2, offset: 5, tool: "grep",
                command: "TODO"),
        ]
        let out = PaneDiaryGenerator.generate(
            rows: rows, paneSlug: "p"
        )
        #expect(!out.contains("Files: "))
        // Last command + Recent section still carry the exec/grep rows.
        #expect(out.contains("Last: swift build"))
    }
}
