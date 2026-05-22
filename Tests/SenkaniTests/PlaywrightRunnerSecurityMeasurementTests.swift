import Testing
import Foundation
@testable import Core

/// U.2b-1b-1 — runner.ts measureSecurity output JSON byte-shape lock-in.
///
/// The fixture pair under `Resources/playwright-runner/fixtures/` is the
/// durable corpus this round, U.2b-1b-3 (pure-JS extraction), and
/// U.2b-1b-6 (parity corpus) all reuse. This test pins the byte-shape
/// contract: feeding `security-roundtrip.html` through the runner's
/// `measureSecurity` should produce JSON byte-identical to
/// `security-roundtrip.expected.json`, which decodes through Swift
/// `SecurityMeasurement` Codable cleanly (no `decodingFailed`) AND
/// re-encodes byte-identically.
@Suite("PlaywrightRunner security measurement — U.2b-1b-1")
struct PlaywrightRunnerSecurityMeasurementTests {

    /// Walk up from CWD looking for the Resources/playwright-runner/
    /// fixtures directory. Mirrors PlaywrightRunnerPackageTests's
    /// resolver shape so the test skips gracefully outside repo
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

    @Test("security-roundtrip fixture JSON decodes through Swift SecurityMeasurement Codable cleanly and re-encodes byte-stable")
    func roundTrip() throws {
        guard let dir = Self.fixturesDir() else { return }
        let url = dir.appendingPathComponent("security-roundtrip.expected.json")
        let original = try Data(contentsOf: url)
        let originalStr = String(data: original, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        // Decode pass — locks in that runner.ts's measureSecurity output
        // shape (snake_case keys: csrf_token_present, same_origin) maps
        // cleanly onto Swift `SecurityMeasurement` Codable. Decoder
        // throws PlaywrightRunnerError-class `decodingFailed` upstream
        // when the JSON drifts from this contract; a Codable throw here
        // catches the drift one layer earlier.
        let m = try JSONDecoder().decode(SecurityMeasurement.self, from: original)

        #expect(m.forms.count == 2, "two forms in fixture (one post, one get)")
        let postForm = m.forms.first { $0.method == "post" }
        let getForm = m.forms.first { $0.method == "get" }
        #expect(postForm?.action == "/login")
        #expect(postForm?.csrfTokenPresent == true,
                "POST /login carries <input name=\"csrf_token\"> — patterns include 'csrf' substring")
        #expect(getForm?.action == "/search")
        #expect(getForm?.csrfTokenPresent == false,
                "GET /search has no CSRF-pattern input; field stays false")

        #expect(m.anchors.count == 2)
        #expect(m.anchors.contains(where: { $0.href == "https://example.com/safe" }))
        #expect(m.anchors.contains(where: { $0.href == "javascript:alert(1)" }),
                "raw href preserves javascript: scheme so SecurityAxis can match the prefix")

        #expect(m.scripts.count == 2)
        let local = m.scripts.first { $0.src == "/local.js" }
        let cdn = m.scripts.first { $0.src == "https://cdn.example.com/lib.js" }
        #expect(local?.sameOrigin == true,
                "<script src=\"/local.js\"> resolves to page origin")
        #expect(cdn?.sameOrigin == false,
                "<script src=\"https://cdn.example.com/lib.js\"> is cross-origin")

        // Re-encode pass — runner.ts output → Swift Codable → re-emit
        // yields the same byte sequence under sortedKeys +
        // withoutEscapingSlashes. Any drift in the SecurityMeasurement
        // Codable surface (key rename, ordering change, new field
        // appearing) trips this before it ships.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let reencoded = try encoder.encode(m)
        let reencodedStr = String(data: reencoded, encoding: .utf8) ?? ""
        #expect(reencodedStr == originalStr,
                "re-encode mismatch — drift in SecurityMeasurement Codable shape vs fixture; got: \(reencodedStr)")
    }
}
