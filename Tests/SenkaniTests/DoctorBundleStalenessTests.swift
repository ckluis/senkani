import Testing
import Foundation
@testable import CLI

/// `onboarding-pass-stale-bundle-hazard-2026-05-14` — Doctor check #20.
///
/// The scanner is a pure mtime+ct comparison; tests synthesize bundle
/// fixtures under a unique temp directory rather than driving real
/// walks. The formatter under test produces the 3-line `.stale`
/// shape the onboarding-pass walk's recovery messaging depends on.
@Suite("Doctor — bundle staleness (check #20)")
struct DoctorBundleStalenessTests {

    private static func makeFakeBundle(
        binaryDate: Date,
        tag: String,
        file: StaticString = #file,
        line: UInt = #line
    ) throws -> String {
        let fm = FileManager.default
        let bundlePath = NSTemporaryDirectory()
            + "senkani-stale-\(tag)-\(UUID().uuidString).app"
        let macosDir = (bundlePath as NSString)
            .appendingPathComponent("Contents/MacOS")
        try fm.createDirectory(
            atPath: macosDir, withIntermediateDirectories: true
        )
        let binaryPath = (macosDir as NSString)
            .appendingPathComponent("SenkaniApp")
        try Data([0x7F, 0x45, 0x4C, 0x46]).write(to: URL(fileURLWithPath: binaryPath))
        try fm.setAttributes(
            [.modificationDate: binaryDate], ofItemAtPath: binaryPath
        )
        return bundlePath
    }

    // MARK: - Scanner

    @Test("scan_freshBundle_returnsFresh")
    func scan_freshBundle_returnsFresh() throws {
        let bundleDate = Date(timeIntervalSince1970: 1_715_000_000)
        let headDate = Date(timeIntervalSince1970: 1_714_999_000)  // 1000s older
        let bundlePath = try Self.makeFakeBundle(
            binaryDate: bundleDate, tag: "fresh"
        )
        defer { try? FileManager.default.removeItem(atPath: bundlePath) }

        let report = BundleStalenessScanner.scan(
            bundlePath: bundlePath,
            headCommitTime: headDate,
            headCommitSubject: "feat: something"
        )
        #expect(report.verdict == .fresh)
        #expect(report.binaryMtime == bundleDate)
        #expect(report.headCommitTime == headDate)
    }

    @Test("scan_staleBundle_returnsStale")
    func scan_staleBundle_returnsStale() throws {
        let bundleDate = Date(timeIntervalSince1970: 1_714_999_000)
        let headDate = Date(timeIntervalSince1970: 1_715_000_000)  // 1000s newer
        let bundlePath = try Self.makeFakeBundle(
            binaryDate: bundleDate, tag: "stale"
        )
        defer { try? FileManager.default.removeItem(atPath: bundlePath) }

        let report = BundleStalenessScanner.scan(
            bundlePath: bundlePath,
            headCommitTime: headDate,
            headCommitSubject: "feat: workstream-create discoverability fix"
        )
        #expect(report.verdict == .stale)
        #expect(report.binaryMtime == bundleDate)
        #expect(report.headCommitTime == headDate)
        #expect(report.headCommitSubject == "feat: workstream-create discoverability fix")
    }

    @Test("scan_missingBundle_returnsNotApplicable")
    func scan_missingBundle_returnsNotApplicable() {
        let bogusPath = NSTemporaryDirectory()
            + "senkani-stale-missing-\(UUID().uuidString).app"
        let report = BundleStalenessScanner.scan(
            bundlePath: bogusPath,
            headCommitTime: Date(timeIntervalSince1970: 1_715_000_000)
        )
        #expect(report.verdict == .notApplicable)
        #expect(report.notApplicableReason?.contains("does not exist") == true)
    }

    // MARK: - Formatter

    @Test("formatBundleStaleness_renders3LineReport")
    func formatBundleStaleness_renders3LineReport() {
        let bundleDate = Date(timeIntervalSince1970: 1_715_595_180)  // 2026-05-13 15:33 UTC-ish
        let headDate = Date(timeIntervalSince1970: 1_715_715_420)    // 2026-05-14 07:47 UTC-ish
        let report = BundleStalenessReport(
            verdict: .stale,
            bundlePath: "tools/soak/runner/_onboarding-pass-SenkaniApp.app",
            binaryMtime: bundleDate,
            headCommitTime: headDate,
            headCommitSubject: "feat: workstream-create discoverability fix"
        )
        let lines = Doctor.formatBundleStalenessLines(report, mergeTarget: "main")
        #expect(lines.count == 3, "expected 3 lines for .stale, got: \(lines)")
        for (status, _) in lines {
            guard case .fail = status else {
                Issue.record("expected all .fail, got non-fail in: \(lines)")
                return
            }
        }
        let header = lines[0].1
        #expect(header.contains("is older than main HEAD"),
                "header must call out merge target; got: \(header)")
        #expect(header.contains("_onboarding-pass-SenkaniApp.app"),
                "header must include the bundle path; got: \(header)")

        let detail = lines[1].1
        #expect(detail.contains("bundle:"), "detail line must label bundle mtime; got: \(detail)")
        #expect(detail.contains("HEAD:"), "detail line must label HEAD ct; got: \(detail)")
        #expect(detail.contains("workstream-create discoverability fix"),
                "detail line must include the commit subject; got: \(detail)")

        let recommend = lines[2].1
        #expect(recommend.contains("senkani walk rebuild-bundle"),
                "recommended line must point operator at the helper; got: \(recommend)")
        #expect(recommend.contains("_onboarding-pass-SenkaniApp.app"),
                "recommended line must include the bundle path; got: \(recommend)")
    }
}
