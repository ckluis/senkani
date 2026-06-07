import Testing
import Foundation
@testable import Core

/// V.13 sub-item 4 — durable module-boundary invariant: `Sources/Core/`
/// must NOT carry any `import MLX*` directive. The real chat / embedding
/// engines live in `Sources/MCP/` and register themselves into Core via
/// the `ChatEngine` / `EmbeddingEngine` protocol seams + `ModelManager`
/// registration slots; Core declares the protocol but never links MLX.
///
/// Mirrors v13c's installed-size SLO test pattern (test, not just a
/// throwaway grep-script): the invariant is enforced in CI so a future
/// `import MLXLLM` slipped into a Core file (which would re-link MLX
/// into the CLI binary and re-breach the 50 MiB install-size SLO that
/// `phase-u8b-mlx-prose-subprocess-delegation` just bought back) fails
/// the test suite immediately rather than surfacing two rounds later.
///
/// Pattern follows `OnboardingMilestoneTests`' `#filePath` repo-root
/// walk — climbs ancestors until `Package.swift` is found.
@Suite("Core module boundary — no MLX imports in Sources/Core")
struct CoreModuleBoundaryTests {

    private static let repoRoot: String = {
        var url = URL(fileURLWithPath: #filePath)
        while url.pathComponents.count > 1 {
            url.deleteLastPathComponent()
            let pkg = url.appendingPathComponent("Package.swift")
            if FileManager.default.fileExists(atPath: pkg.path) {
                return url.path
            }
        }
        return FileManager.default.currentDirectoryPath
    }()

    /// Recursively enumerates every `.swift` file under `Sources/Core/`.
    private static func coreSwiftFiles() -> [String] {
        let coreRoot = (repoRoot as NSString).appendingPathComponent("Sources/Core")
        guard let enumerator = FileManager.default.enumerator(atPath: coreRoot) else {
            return []
        }
        var paths: [String] = []
        for case let rel as String in enumerator where rel.hasSuffix(".swift") {
            paths.append((coreRoot as NSString).appendingPathComponent(rel))
        }
        return paths
    }

    @Test("Sources/Core contains no MLX framework imports")
    func testCoreContainsNoMLXImports() throws {
        let files = Self.coreSwiftFiles()
        try #require(!files.isEmpty, "expected to enumerate Sources/Core/**/*.swift")

        var offenders: [String] = []
        for path in files {
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
                continue
            }
            // Walk lines so a comment like `// import MLX` never trips the
            // check — only a leading `import MLX...` directive at line start
            // (matching the durable grep `^import MLX`) counts.
            for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                let s = String(line)
                if s.hasPrefix("import MLX") {
                    let rel = (path as NSString).lastPathComponent
                    offenders.append("\(rel): \(s)")
                    break
                }
            }
        }

        #expect(
            offenders.isEmpty,
            """
            Sources/Core/ must not import any MLX module — MLX lives in \
            Sources/MCP/ and registers into Core via ChatEngine / \
            EmbeddingEngine protocol seams. An MLX import in Core re-links \
            MLX into the CLI binary and re-breaches the 50 MiB install-size \
            SLO that phase-u8b-mlx-prose-subprocess-delegation closed. \
            Offenders: \(offenders.joined(separator: "; "))
            """
        )
    }
}
