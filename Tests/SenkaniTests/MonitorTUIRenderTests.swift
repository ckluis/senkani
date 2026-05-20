import Testing
import Foundation
@testable import Core
@testable import MonitorTUI

/// V.15a-1 render substrate — 5 unit / integration tests.
///
/// Acceptance coverage:
///   1. `RenderFrame.toANSI()` is deterministic (byte-identical on
///      identical input).
///   2. ANSI primitives emit canonical CSI escape sequences.
///   3. Source-discipline grep: `Sources/MonitorTUI/**/*.swift` does
///      not reference known write-method names from `SessionDatabase`.
///   4. Header bar region contains the literal `READ-ONLY` in every
///      frame.
///   5. CLI integration — `senkani monitor --tui` stdout contains
///      `ESC[2J` + `READ-ONLY` + at least one tile row.

// MARK: - Test stub

/// In-memory `MonitorReadOnlyAPI` stub for deterministic frame
/// assembly tests. Doesn't touch the database or filesystem.
struct MonitorAPIStub: MonitorReadOnlyAPI {
    let snapshot: PaneRefreshCoordinator.Snapshot
    let savings: [SessionDatabase.FeatureSavings]
    let rows: [MonitorProjectRow]

    func fetchPaneSnapshot() throws -> PaneRefreshCoordinator.Snapshot { snapshot }
    func fetchFeatureSavings() throws -> [SessionDatabase.FeatureSavings] { savings }
    func fetchProjectRows() throws -> [MonitorProjectRow] { rows }
}

private func makeStub() -> MonitorAPIStub {
    let snapshot = PaneRefreshCoordinator.Snapshot(
        budgetBurn: PaneRefreshState(cacheType: .duration, cacheDuration: 30, contentAvailable: true),
        validationQueue: PaneRefreshState(cacheType: .duration, cacheDuration: 5, contentAvailable: false),
        repoDirtyState: PaneRefreshState(cacheType: .duration, cacheDuration: 10, contentAvailable: true)
    )
    let savings = [
        SessionDatabase.FeatureSavings(feature: "filter", savedTokens: 1234, inputTokens: 100, outputTokens: 50, eventCount: 7),
        SessionDatabase.FeatureSavings(feature: "compress", savedTokens: 567, inputTokens: 80, outputTokens: 30, eventCount: 3),
    ]
    let rows = [
        MonitorProjectRow(
            name: "senkani",
            path: "/Users/op/Desktop/projects/senkani",
            todayCostSaved: 1.23,
            monthCostSaved: 12.34,
            savingsPercent: 41.5,
            topOptimization: "filter",
            savedTokensMonth: 12345
        )
    ]
    return MonitorAPIStub(snapshot: snapshot, savings: savings, rows: rows)
}

// MARK: - (1) toANSI determinism

@Suite("MonitorTUI — render determinism")
struct MonitorTUIDeterminismSuite {
    @Test func toANSIIsByteIdenticalOnIdenticalInput() throws {
        let stub = makeStub()
        let a = try DashboardRender.buildFrame(appVersion: "9.9.9", api: stub)
        let b = try DashboardRender.buildFrame(appVersion: "9.9.9", api: stub)
        let outA = a.toANSI()
        let outB = b.toANSI()
        #expect(outA == outB)
        #expect(!outA.isEmpty)
    }
}

// MARK: - (2) ANSI primitives

@Suite("MonitorTUI — ANSI primitives")
struct MonitorTUIANSIPrimitivesSuite {
    @Test func clearEmitsCSI2J() {
        #expect(ANSI.clear() == "\u{1B}[2J")
    }
    @Test func homeEmitsCSIH() {
        #expect(ANSI.home() == "\u{1B}[H")
    }
    @Test func boldEmitsCSI1m() {
        #expect(ANSI.bold() == "\u{1B}[1m")
    }
    @Test func resetEmitsCSI0m() {
        #expect(ANSI.reset() == "\u{1B}[0m")
    }
    @Test func colorEmitsCSIValuem() {
        #expect(ANSI.color(31) == "\u{1B}[31m")
        #expect(ANSI.color(42) == "\u{1B}[42m")
    }
    @Test func moveToEmitsCSIRowSemiColH() {
        #expect(ANSI.moveTo(row: 3, col: 7) == "\u{1B}[3;7H")
    }
}

// MARK: - (3) Source-discipline grep

@Suite("MonitorTUI — source discipline (no SessionDatabase writes)")
struct MonitorTUISourceDisciplineSuite {
    /// The MonitorTUI library must not call any SessionDatabase write
    /// methods directly. The audit surface is the
    /// `MonitorReadOnlyAdapter` (which lives in Core, not MonitorTUI).
    @Test func monitorTUISourcesDoNotReferenceWriteMethods() throws {
        let dir = try repoRoot().appendingPathComponent("Sources/MonitorTUI")
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: dir, includingPropertiesForKeys: nil) else {
            Issue.record("Cannot enumerate Sources/MonitorTUI directory")
            return
        }
        // Substrings that would indicate a write surface reaching into
        // MonitorTUI. `appendEvent` is excepted — it is the read-only
        // audit-stream append used by chain verification.
        let writeSubstrings = [
            "SessionDatabase.shared.record",
            ".recordTokenEvent",
            ".recordOutcome",
            "SessionDatabase.shared.write",
            ".insertRow",
            ".executeUpdate",
            "INSERT INTO",
            "UPDATE ",
            "DELETE FROM",
        ]
        var offending: [String] = []
        for case let url as URL in enumerator
            where url.pathExtension == "swift" {
            let content = (try? String(contentsOf: url)) ?? ""
            for needle in writeSubstrings where content.contains(needle) {
                offending.append("\(url.lastPathComponent): contains `\(needle)`")
            }
        }
        #expect(offending.isEmpty, "MonitorTUI source discipline broken: \(offending.joined(separator: " | "))")
    }

    private func repoRoot() throws -> URL {
        // Tests run from the package root; resolve relative to the
        // current source file's location at compile time via #filePath.
        let here = URL(fileURLWithPath: #filePath)
        // .../Tests/SenkaniTests/MonitorTUIRenderTests.swift → repo root is two parents up from Tests/
        return here
            .deletingLastPathComponent()   // SenkaniTests/
            .deletingLastPathComponent()   // Tests/
            .deletingLastPathComponent()   // <repo root>
    }
}

// MARK: - (4) Header contains READ-ONLY literal

@Suite("MonitorTUI — header read-only badge")
struct MonitorTUIHeaderReadOnlySuite {
    @Test func headerRegionContainsReadOnlyBadge() throws {
        let stub = makeStub()
        let frame = try DashboardRender.buildFrame(appVersion: "0.3.0", api: stub)
        let header = frame.regions.first { $0.id == DashboardRender.headerRegionId }
        #expect(header != nil)
        let joined = header?.lines.joined(separator: " ") ?? ""
        #expect(joined.contains("READ-ONLY"), "header region must contain literal READ-ONLY badge, got: \(joined)")
    }

    @Test func toANSIOutputContainsReadOnlyBadge() throws {
        let stub = makeStub()
        let frame = try DashboardRender.buildFrame(appVersion: "0.3.0", api: stub)
        #expect(frame.toANSI().contains("READ-ONLY"))
    }
}

// MARK: - (5) CLI integration — senkani monitor --tui

@Suite("MonitorTUI — CLI integration")
struct MonitorTUICLISuite {
    @Test func monitorTuiPrintsAnsiFrameWithReadOnly() throws {
        let binary = senkaniBinaryURL()
        guard FileManager.default.isExecutableFile(atPath: binary.path) else {
            // Binary not built (e.g., partial test invocation) — skip; the
            // full safe-suite build always produces it.
            return
        }
        let process = Process()
        process.executableURL = binary
        process.arguments = ["monitor", "--tui"]
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        try process.run()
        process.waitUntilExit()
        let stdoutData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let stdoutStr = String(data: stdoutData, encoding: .utf8) ?? ""
        #expect(stdoutStr.contains("\u{1B}[2J"), "expected ESC[2J in stdout, got: \(stdoutStr.prefix(120))")
        #expect(stdoutStr.contains("READ-ONLY"), "expected READ-ONLY in stdout")
        #expect(stdoutStr.contains("Projects ("), "expected panes-table row in stdout")
    }

    private func senkaniBinaryURL() -> URL {
        // The test target's executable lives next to the test bundle
        // in the swiftpm build dir. Resolve up to the build root and
        // pick the `senkani` executable.
        let bundleURL = Bundle(for: BundleMarker.self).bundleURL
        // bundleURL: .../debug/SenkaniTests.xctest (or .../release/...)
        var dir = bundleURL.deletingLastPathComponent()
        // Walk one extra level in case the bundle is nested (e.g. inside a Contents dir).
        if !FileManager.default.isExecutableFile(atPath: dir.appendingPathComponent("senkani").path) {
            dir = dir.deletingLastPathComponent()
        }
        return dir.appendingPathComponent("senkani")
    }
}

/// Marker class used to anchor `Bundle(for:)` to the test target.
private final class BundleMarker {}
