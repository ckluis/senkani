import Testing
import Foundation
@testable import CLI

/// `build-env-swiftpm-checkout-corruption-icloud-eviction-2026-05-09`
/// Phase A — doctor extension that detects iCloud-Drive / FileProvider
/// eviction symptoms.
///
/// The pure formatter `Doctor.formatFileProviderEvictionLines(_:)` is
/// the operator-facing surface; the integration tests below cover the
/// scanner against synthesized tree fixtures (the privileged
/// `SF_DATALESS` flag is FileProvider-only and untestable from user
/// space, so dataless-path coverage runs through the formatter via
/// report-injection).
@Suite("Doctor — FileProvider eviction detection (Phase A)")
struct DoctorFileProviderEvictionTests {

    // MARK: - Pattern matcher (pure, deterministic)

    @Test("matchesStar2Pattern accepts canonical Finder shadows")
    func matchesStar2Pattern_accepts() {
        // With single extension.
        #expect(FileProviderEvictionScanner.matchesStar2Pattern("Foo 2.swift"))
        #expect(FileProviderEvictionScanner.matchesStar2Pattern("DoctorAuditChainSurfaceTests 2.swift"))
        #expect(FileProviderEvictionScanner.matchesStar2Pattern("senkani-models 2.html"))
        // Without extension (directory or extensionless file).
        #expect(FileProviderEvictionScanner.matchesStar2Pattern("swift-sdk 2"))
        #expect(FileProviderEvictionScanner.matchesStar2Pattern("mlx-swift-lm 2"))
    }

    @Test("matchesStar2Pattern rejects non-shadow names")
    func matchesStar2Pattern_rejects() {
        #expect(!FileProviderEvictionScanner.matchesStar2Pattern("Foo2.swift"))
        #expect(!FileProviderEvictionScanner.matchesStar2Pattern("version-2.swift"))
        #expect(!FileProviderEvictionScanner.matchesStar2Pattern("Foo 23.swift"))
        #expect(!FileProviderEvictionScanner.matchesStar2Pattern("Foo.swift"))
        #expect(!FileProviderEvictionScanner.matchesStar2Pattern(" 2"))
        #expect(!FileProviderEvictionScanner.matchesStar2Pattern("Foo 2.bak.swift"))
    }

    // MARK: - Formatter (pure, report-injectable)

    @Test("Clean report emits a single .pass line")
    func formatLines_clean_passes() {
        let report = FileProviderEvictionReport(scannedRoot: "/tmp/clean")
        let lines = Doctor.formatFileProviderEvictionLines(report)
        #expect(lines.count == 1)
        guard case .pass = lines.first?.0 else {
            Issue.record("expected .pass, got: \(lines)")
            return
        }
        #expect(lines.first?.1.contains("no iCloud-Drive eviction symptoms") == true)
    }

    @Test("Path-under-FileProvider emits a .fail line citing CONTRIBUTING.md")
    func formatLines_underFileProvider_fails() {
        let report = FileProviderEvictionReport(
            scannedRoot: "/Users/x/Desktop/projects/senkani",
            pathUnderFileProvider: true
        )
        let lines = Doctor.formatFileProviderEvictionLines(report)
        #expect(lines.count == 1)
        guard case .fail = lines.first?.0 else {
            Issue.record("expected .fail, got: \(lines)")
            return
        }
        let message = lines.first?.1 ?? ""
        #expect(message.contains("/Users/x/Desktop/projects/senkani"),
                "warning must name the offending path; got: \(message)")
        #expect(message.contains("CONTRIBUTING.md"),
                "warning must point operator at CONTRIBUTING.md remediation; got: \(message)")
    }

    @Test("Dataless paths emit a .fail line with count + sample + remediation")
    func formatLines_dataless_fails() {
        let report = FileProviderEvictionReport(
            scannedRoot: "/Users/x/Desktop/projects/senkani",
            datalessPaths: [
                ".build/checkouts/swift-sdk/Package.swift",
                ".build/checkouts/swift-sdk/README.md",
                ".build/checkouts/swift-collections/Package.swift",
                ".build/checkouts/swift-jinja/Package.swift",
            ]
        )
        let lines = Doctor.formatFileProviderEvictionLines(report)
        #expect(lines.count == 1)
        guard case .fail = lines.first?.0 else {
            Issue.record("expected .fail, got: \(lines)")
            return
        }
        let message = lines.first?.1 ?? ""
        #expect(message.contains("4 dataless-flagged"),
                "warning must include the count; got: \(message)")
        #expect(message.contains("swift-sdk/Package.swift"),
                "warning must sample the offending paths; got: \(message)")
        #expect(message.contains("rm -rf .build"),
                "warning must include the recovery command; got: \(message)")
    }

    @Test("Star-2 siblings emit a .fail line with count + sample + cmp guidance")
    func formatLines_star2_fails() {
        let report = FileProviderEvictionReport(
            scannedRoot: "/Users/x/Desktop/projects/senkani",
            star2Siblings: [
                "Tests/SenkaniTests/Foo 2.swift",
                ".build/checkouts/swift-sdk 2",
            ]
        )
        let lines = Doctor.formatFileProviderEvictionLines(report)
        #expect(lines.count == 1)
        guard case .fail = lines.first?.0 else {
            Issue.record("expected .fail, got: \(lines)")
            return
        }
        let message = lines.first?.1 ?? ""
        #expect(message.contains("2 `* 2` Finder-shadow"),
                "warning must include the count; got: \(message)")
        #expect(message.contains("Foo 2.swift"),
                "warning must sample the offending names; got: \(message)")
        #expect(message.contains("cmp"),
                "warning must mention the byte-identity verification step; got: \(message)")
    }

    @Test("All three findings emit three discrete .fail lines")
    func formatLines_combinedFindings_emitsThreeLines() {
        let report = FileProviderEvictionReport(
            scannedRoot: "/Users/x/Desktop/projects/senkani",
            pathUnderFileProvider: true,
            datalessPaths: [".build/checkouts/swift-sdk/Package.swift"],
            star2Siblings: ["Tests/Foo 2.swift"]
        )
        let lines = Doctor.formatFileProviderEvictionLines(report)
        #expect(lines.count == 3)
        for (status, _) in lines {
            guard case .fail = status else {
                Issue.record("expected all .fail, got non-fail in: \(lines)")
                return
            }
        }
    }

    // MARK: - Scanner integration (synthesized fixtures, no syscalls
    //         that require FileProvider privileges)

    @Test("Scanner finds synthesized * 2 siblings under Tests/")
    func scanner_findsStar2InSyntheticTree() throws {
        let fm = FileManager.default
        let tmpRoot = NSTemporaryDirectory()
            + "senkani-fpevict-\(UUID().uuidString)"
        let testsDir = (tmpRoot as NSString).appendingPathComponent("Tests")
        try fm.createDirectory(atPath: testsDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: tmpRoot) }

        // Synthesize a non-shadow + a shadow + a benign-named non-match.
        let originalPath = (testsDir as NSString).appendingPathComponent("Foo.swift")
        let shadowPath = (testsDir as NSString).appendingPathComponent("Foo 2.swift")
        let benignPath = (testsDir as NSString).appendingPathComponent("Foo23.swift")
        try "// original".write(toFile: originalPath, atomically: true, encoding: .utf8)
        try "// shadow".write(toFile: shadowPath, atomically: true, encoding: .utf8)
        try "// benign".write(toFile: benignPath, atomically: true, encoding: .utf8)

        let report = FileProviderEvictionScanner.scan(root: tmpRoot)
        #expect(report.star2Siblings.contains("Tests/Foo 2.swift"),
                "scanner should flag Foo 2.swift under Tests/; got: \(report.star2Siblings)")
        #expect(!report.star2Siblings.contains(where: { $0.contains("Foo23.swift") }),
                "scanner should NOT flag Foo23.swift; got: \(report.star2Siblings)")
        #expect(!report.star2Siblings.contains(where: { $0.hasSuffix("Foo.swift") }),
                "scanner should NOT flag the original Foo.swift; got: \(report.star2Siblings)")
    }

    @Test("Scanner returns clean report on a tmp tree with no shadows")
    func scanner_silentOnCleanTree() throws {
        let fm = FileManager.default
        let tmpRoot = NSTemporaryDirectory()
            + "senkani-fpevict-clean-\(UUID().uuidString)"
        try fm.createDirectory(atPath: tmpRoot, withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: tmpRoot) }

        let report = FileProviderEvictionScanner.scan(root: tmpRoot)
        // /tmp on macOS is not under FileProvider; star2 + dataless empty.
        #expect(!report.pathUnderFileProvider,
                "/tmp should not be FileProvider-managed; got: \(report)")
        #expect(report.datalessPaths.isEmpty)
        #expect(report.star2Siblings.isEmpty)
        #expect(!report.hasFinding)
    }
}
