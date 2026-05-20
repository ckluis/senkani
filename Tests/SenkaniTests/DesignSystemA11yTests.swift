import Foundation
import Testing
@testable import Core

/// V.10b — runs `tools/website-checks/run-axe.js` against a fixture
/// HTML page styled with the generated design-system stylesheet,
/// asserts zero WCAG 2 AA violations.
///
/// Test gates on `which node` + `tools/website-checks/node_modules`
/// presence — skips with a clear message if either is missing. The
/// runner is the same Puppeteer + @axe-core/puppeteer harness used
/// by the site-wide a11y check (no test-only infra).
@Suite("DesignSystemA11y")
struct DesignSystemA11yTests {

    @Test("axe-core asserts zero WCAG 2 AA violations on styled fixture")
    func axeCoreFixtureHasZeroViolations() async throws {
        guard let nodePath = which("node") else {
            // Skip — Node not installed. Not a test failure.
            return
        }

        let cwd = FileManager.default.currentDirectoryPath
        let runner = (cwd as NSString).appendingPathComponent("tools/website-checks/run-axe.js")
        let nodeModules = (cwd as NSString).appendingPathComponent("tools/website-checks/node_modules")
        guard FileManager.default.fileExists(atPath: runner),
              FileManager.default.fileExists(atPath: nodeModules) else {
            // Skip — runner or its deps not present.
            return
        }

        // Build canonical CSS.
        let ruleSet = try DesignSystemPatternParser.parse(
            DesignSystemPatternsResource.canonicalMarkdown
        )
        let css = DesignSystemStylesheet.css(from: ruleSet)

        // Write the styled fixture HTML to a tmp dir.
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("v10b-axe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir,
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let fixtureURL = tmpDir.appendingPathComponent("fixture.html")
        let fixtureHTML = """
        <!DOCTYPE html>
        <html lang="en">
        <head>
          <meta charset="utf-8">
          <title>V.10b fixture</title>
          <style>
        \(css)
          </style>
        </head>
        <body>
          <main>
            <h1>V.10b design-system fixture</h1>
            <p>This is body copy used by the axe-core a11y assertion. It
            contains enough text to exercise contrast checks under the
            generated stylesheet.</p>
            <h2>Section heading</h2>
            <p>More body copy with a <a href="#anchor">labeled link</a>
            and a <code>code span</code>.</p>
            <h3>Sub heading</h3>
            <ul>
              <li>List item one</li>
              <li>List item two</li>
            </ul>
          </main>
        </body>
        </html>
        """
        try fixtureHTML.write(to: fixtureURL, atomically: true, encoding: .utf8)

        // run-axe.js expects --urls <file-of-urls> --out <json-out>.
        let urlsFile = tmpDir.appendingPathComponent("urls.txt")
        let fileURL = "file://" + fixtureURL.path
        try fileURL.write(to: urlsFile, atomically: true, encoding: .utf8)
        let outFile = tmpDir.appendingPathComponent("axe.json")

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: nodePath)
        proc.arguments = [runner, "--urls", urlsFile.path, "--out", outFile.path]
        proc.currentDirectoryURL = URL(fileURLWithPath: cwd)
        proc.environment = ProcessInfo.processInfo.environment

        let stderr = Pipe()
        proc.standardError = stderr
        try proc.run()
        proc.waitUntilExit()

        guard proc.terminationStatus == 0 else {
            let errData = stderr.fileHandleForReading.readDataToEndOfFile()
            let errStr = String(data: errData, encoding: .utf8) ?? "<no stderr>"
            // Don't hard-fail on runner crash — Puppeteer needs Chromium
            // available; some CI envs lack it. Skip with a recorded note.
            Issue.record(Comment(rawValue: "axe-core runner exited \(proc.terminationStatus): \(errStr)"))
            return
        }

        let raw = try Data(contentsOf: outFile)
        let json = try JSONSerialization.jsonObject(with: raw) as? [[String: Any]]
        #expect(json != nil, "run-axe.js must produce a JSON array")
        guard let pages = json, let first = pages.first else { return }

        let violations = first["violations"] as? [[String: Any]] ?? []
        #expect(violations.isEmpty,
                "fixture must have zero WCAG 2 AA violations; got \(violations.count) — first id: \((violations.first?["id"] as? String) ?? "<n/a>")")
    }

    /// `which <bin>` shim — returns the full path on PATH or nil.
    private func which(_ binary: String) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = ["which", binary]
        let stdout = Pipe()
        proc.standardOutput = stdout
        proc.standardError = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            return nil
        }
        guard proc.terminationStatus == 0 else { return nil }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        let path = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (path?.isEmpty ?? true) ? nil : path
    }
}
