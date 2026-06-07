import Testing
import Foundation
@testable import Core

/// U.2b-1b-2 — runner.ts measureDesign output + best-effort npm-audit
/// skip-path JSON byte-shape lock-in.
///
/// Mirrors the byte-stable contract pattern PlaywrightRunnerSecurity
/// MeasurementTests applies to the security axis: a captured expected
/// JSON fixture decodes through the Swift Codable surface
/// (`DesignMeasurement` for the design axis, `PlaywrightResult` for
/// the npm-audit envelope), re-encodes byte-identically under
/// `[.sortedKeys, .withoutEscapingSlashes]`, and any drift in the
/// Codable shape (key rename, type change, new field appearing) trips
/// the test before runner.ts output diverges from the Swift consumer.
@Suite("PlaywrightRunner design measurement + npm-audit envelope — U.2b-1b-2")
struct PlaywrightRunnerDesignMeasurementTests {

    /// Walk up from CWD looking for the Resources/playwright-runner/
    /// fixtures directory. Mirrors PlaywrightRunnerSecurityMeasurement
    /// Tests's resolver so the test skips gracefully outside repo
    /// checkouts.
    private static func fixturesDir() -> URL? {
        var cur = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        for _ in 0..<8 {
            let candidate = cur.appendingPathComponent("Resources/playwright-runner/fixtures", isDirectory: true)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            let parent = cur.deletingLastPathComponent()
            if parent.path == cur.path { break }
            cur = parent
        }
        return nil
    }

    @Test("design-roundtrip fixture JSON decodes through Swift DesignMeasurement Codable cleanly and re-encodes byte-stable")
    func designRoundTrip() throws {
        guard let dir = Self.fixturesDir() else { return }
        let url = dir.appendingPathComponent("design-roundtrip.expected.json")
        let original = try Data(contentsOf: url)
        let originalStr = String(data: original, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        let m = try JSONDecoder().decode(DesignMeasurement.self, from: original)

        #expect(m.interactiveTargets.count == 3, "three interactive targets in fixture")
        let ids = m.interactiveTargets.map(\.identifier)
        #expect(ids == ["a#start", "button#submit", "div#custom"],
                "stable-id ordering preserved across DOM walk")
        for t in m.interactiveTargets {
            #expect(t.widthPx == 100)
            #expect(t.heightPx == 40)
            #expect(t.defaultContrastRatio == 4.5)
            #expect(t.focusContrastRatio == 4.5)
            #expect(t.hoverContrastRatio == nil,
                    "headless run with no synthetic pointer events leaves :hover state unmeasurable; null per acceptance")
        }

        #expect(m.domFocusOrder == ["a#start", "button#submit", "div#custom"])
        #expect(m.tabFocusOrder == m.domFocusOrder,
                "Tab walk matches DOM focus order on the canonical fixture")

        // Re-encode pass — any drift in the DesignMeasurement Codable
        // surface (key rename, new field, ordering change) trips this
        // before it ships.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let reencoded = try encoder.encode(m)
        let reencodedStr = String(data: reencoded, encoding: .utf8) ?? ""
        #expect(reencodedStr == originalStr,
                "re-encode mismatch — drift in DesignMeasurement Codable shape vs fixture; got: \(reencodedStr)")
    }

    @Test("npm-audit-skip fixture: non-localhost target leaves vulnerable_dependencies empty; PlaywrightResult Codable round-trip byte-stable")
    func npmAuditSkipPath() throws {
        guard let dir = Self.fixturesDir() else { return }
        let url = dir.appendingPathComponent("npm-audit-skip.expected.json")
        let original = try Data(contentsOf: url)
        let originalStr = String(data: original, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        let r = try JSONDecoder().decode(PlaywrightResult.self, from: original)

        #expect(r.resultStatus == "pass")
        #expect(r.axesRun.isEmpty)
        #expect(r.assertionsPassed == 0)
        #expect(r.assertionsFailed == 0)
        #expect(r.vulnerableDependencies == [],
                "non-localhost target skips npm-audit; field is present-and-empty, not nil")
        #expect(r.designMeasurement == nil)
        #expect(r.securityMeasurement == nil)

        // Byte-stable re-encode under sortedKeys + withoutEscapingSlashes
        // — locks in the contract runner.ts emits and the Swift
        // dispatcher consumes.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let reencoded = try encoder.encode(r)
        let reencodedStr = String(data: reencoded, encoding: .utf8) ?? ""
        #expect(reencodedStr == originalStr,
                "re-encode mismatch — drift in PlaywrightResult Codable shape vs fixture; got: \(reencodedStr)")
    }
}
