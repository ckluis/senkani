import Testing
import Foundation
@testable import Core

/// U.2a-2a contract tests for the `Resources/playwright-runner/` package
/// shape + the Swift-side encodeRequest byte-stability regression guard.
/// These two assertions guard the TS-runner extension landed by U.2a-2a:
/// (1) the dependency declaration parses and points at a `playwright`
///     version range the operator can install via `npm install` in this
///     directory; (2) the Swift-side framing stays byte-identical to the
///     U.2a-1 contract even when the plan contains the two new axes the
///     TS dispatcher now handles.
@Suite("Playwright runner package — U.2a-2a")
struct PlaywrightRunnerPackageTests {

    /// Walk up from CWD looking for the Resources/playwright-runner/
    /// directory. Mirrors PlaywrightSubprocessRunner.defaultRunnerPath's
    /// resolution shape.
    private static func runnerDir() -> URL? {
        var cur = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        for _ in 0..<8 {
            let candidate = cur.appendingPathComponent("Resources/playwright-runner", isDirectory: true)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            let parent = cur.deletingLastPathComponent()
            if parent.path == cur.path { break }
            cur = parent
        }
        return nil
    }

    @Test("package.json declares playwright dep and .gitignore excludes node_modules")
    func packageShape() throws {
        guard let dir = Self.runnerDir() else {
            // Skip gracefully when run from outside a repo checkout (e.g.
            // certain sandbox configurations). The PlaywrightSubprocessRunner
            // refusal-path tests already validate the absence behavior.
            return
        }

        let packageJsonURL = dir.appendingPathComponent("package.json")
        let data = try Data(contentsOf: packageJsonURL)

        struct PackageManifest: Decodable {
            let name: String
            let dependencies: [String: String]
        }
        let manifest = try JSONDecoder().decode(PackageManifest.self, from: data)
        #expect(manifest.name == "senkani-playwright-runner",
                "package name must stay senkani-playwright-runner so future tooling can detect this directory by manifest name")
        let pw = manifest.dependencies["playwright"]
        #expect(pw != nil, "package.json must declare a `playwright` dependency")
        #expect(pw?.hasPrefix("^1.") == true || pw?.hasPrefix("1.") == true,
                "playwright dep must pin to the 1.x major (current Chromium API surface); got \(pw ?? "nil")")

        let gitignoreURL = dir.appendingPathComponent(".gitignore")
        let gitignore = try String(contentsOf: gitignoreURL, encoding: .utf8)
        let lines = gitignore.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        #expect(lines.contains("node_modules/"),
                ".gitignore colocated with package.json must exclude node_modules/ so the heavy install tree never tracks in git")
    }

    @Test("encodeRequest byte-stable frame holds with perf + completeness steps in plan")
    func encodeRequestStableAcrossAxes() throws {
        let plan: [ValidationStep] = [
            ValidationStep(
                axis: .completeness,
                assertionId: "completeness.title_meta",
                targetPath: "src/index.html",
                selector: nil,
                expected: nil
            ),
            ValidationStep(
                axis: .perf,
                assertionId: "perf.inp",
                targetPath: "src/index.html",
                selector: nil,
                expected: "{\"inp_ms\":300}"
            ),
        ]
        let data = try PlaywrightSubprocessRunner.encodeRequest(
            plan: plan, targetUrl: "https://example.com"
        )
        let json = String(data: data, encoding: .utf8) ?? ""

        // The U.2a-1 contract:
        //   - sortedKeys at the outer + per-step level
        //   - withoutEscapingSlashes
        //   - snake_case CodingKeys (assertion_id / target_path / target_url)
        //   - omits nil-optional properties (no `selector: null`)
        // U.2a-2a's TS-side dispatcher reads the same JSON shape — this
        // round must NOT regress that framing even though the dispatcher
        // now branches on axis.
        let expected = """
            {"plan":[{"assertion_id":"completeness.title_meta","axis":"completeness","target_path":"src/index.html"},{"assertion_id":"perf.inp","axis":"perf","expected":"{\\"inp_ms\\":300}","target_path":"src/index.html"}],"target_url":"https://example.com"}
            """
        #expect(json == expected,
                "U.2a-1 stdin frame contract: sortedKeys + withoutEscapingSlashes + snake_case + nil-omission. Got: \(json)")
    }
}
