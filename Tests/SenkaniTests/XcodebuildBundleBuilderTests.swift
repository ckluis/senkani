import Testing
import Foundation
@testable import CLI

/// `process-gap-no-xcodebuild-aware-app-bundler-2026-07-05`.
///
/// Covers the pure, headlessly-testable surfaces of the xcodebuild-aware
/// bundler: the two product-location probes (build-log parse + DerivedData
/// glob) and the `.app` wrap assembly. The actual xcodebuild invocation and
/// the `open`-launch crash-loop check are exercised by the build round on a
/// real machine (they need Xcode + the Metal Toolchain); these tests pin the
/// deterministic logic around them.
@Suite("XcodebuildBundleBuilder — product location + wrap assembly")
struct XcodebuildBundleBuilderTests {

    // MARK: - Probe (a): build-log parse

    @Test("productDirFromBuildLog extracts the Debug dir from the Ld line")
    func logParse_extractsProductDir() {
        let log = """
        Some earlier line
        Ld /Users/x/Library/Developer/Xcode/DerivedData/senkani-abc123/Build/Products/Debug/SenkaniApp normal (in target 'SenkaniApp' from project 'senkani')
        ** BUILD SUCCEEDED **
        """
        let dir = XcodebuildBundleBuilder.productDirFromBuildLog(log)
        #expect(dir == "/Users/x/Library/Developer/Xcode/DerivedData/senkani-abc123/Build/Products/Debug")
    }

    @Test("productDirFromBuildLog does NOT match resource-bundle copy lines")
    func logParse_ignoresResourceBundleLines() {
        // `senkani_SenkaniApp` ends in `_SenkaniApp`, not `/SenkaniApp` — must
        // not be mistaken for the product executable.
        let log = """
        CpResource /Users/x/DerivedData/senkani-abc/Build/Products/Debug/senkani_SenkaniApp.bundle/Contents/Resources/Foo
        ProcessInfoPlistFile /Users/x/DerivedData/senkani-abc/Build/Products/Debug/senkani_SenkaniApp
        """
        #expect(XcodebuildBundleBuilder.productDirFromBuildLog(log) == nil)
    }

    @Test("productDirFromBuildLog returns nil on a build with no Ld line")
    func logParse_nilWhenNoProduct() {
        #expect(XcodebuildBundleBuilder.productDirFromBuildLog("") == nil)
        #expect(XcodebuildBundleBuilder.productDirFromBuildLog("** BUILD FAILED **") == nil)
    }

    @Test("productDirFromBuildLog prefers the last Ld line (incremental relink)")
    func logParse_prefersLastMatch() {
        let log = """
        Ld /Users/x/DerivedData/stale-old/Build/Products/Debug/SenkaniApp normal
        Ld /Users/x/DerivedData/fresh-new/Build/Products/Debug/SenkaniApp normal
        """
        #expect(
            XcodebuildBundleBuilder.productDirFromBuildLog(log)
                == "/Users/x/DerivedData/fresh-new/Build/Products/Debug"
        )
    }

    // MARK: - Probe (c): DerivedData glob

    @Test("productDirFromDerivedData returns the newest dir containing the exe")
    func glob_picksNewestWithExe() throws {
        let fm = FileManager.default
        let root = NSTemporaryDirectory() + "dd-\(UUID().uuidString)"
        defer { try? fm.removeItem(atPath: root) }

        func makeCandidate(_ name: String, exeDate: Date?) throws {
            let productDir = (root as NSString)
                .appendingPathComponent("\(name)/Build/Products/Debug")
            try fm.createDirectory(atPath: productDir, withIntermediateDirectories: true)
            if let d = exeDate {
                let exe = (productDir as NSString).appendingPathComponent("SenkaniApp")
                try Data([0x7F]).write(to: URL(fileURLWithPath: exe))
                try fm.setAttributes([.modificationDate: d], ofItemAtPath: exe)
            }
        }
        // Matching prefix, older exe.
        try makeCandidate("senkani-oldhash", exeDate: Date(timeIntervalSince1970: 1_000_000))
        // Matching prefix, newer exe — should win.
        try makeCandidate("senkani-newhash", exeDate: Date(timeIntervalSince1970: 2_000_000))
        // Matching prefix but NO exe — must be skipped, never wrapped.
        try makeCandidate("senkani-noexe", exeDate: nil)
        // Non-matching prefix — ignored.
        try makeCandidate("otherproj-xyz", exeDate: Date(timeIntervalSince1970: 3_000_000))

        let dir = XcodebuildBundleBuilder.productDirFromDerivedData(
            derivedDataRoot: root, projectName: "senkani"
        )
        #expect(dir == (root as NSString).appendingPathComponent("senkani-newhash/Build/Products/Debug"))
    }

    @Test("productDirFromDerivedData returns nil when no candidate has the exe")
    func glob_nilWhenNoExe() throws {
        let fm = FileManager.default
        let root = NSTemporaryDirectory() + "dd-\(UUID().uuidString)"
        defer { try? fm.removeItem(atPath: root) }
        let productDir = (root as NSString)
            .appendingPathComponent("senkani-abc/Build/Products/Debug")
        try fm.createDirectory(atPath: productDir, withIntermediateDirectories: true)
        #expect(
            XcodebuildBundleBuilder.productDirFromDerivedData(
                derivedDataRoot: root, projectName: "senkani"
            ) == nil
        )
    }

    // MARK: - Wrap assembly

    /// Build a fake xcodebuild product directory: an executable, N `.bundle`
    /// directories, a `.swiftmodule` directory (must be excluded), plus a
    /// fake Info.plist source next to it.
    private static func makeFixtureProduct(
        bundleCount: Int
    ) throws -> (productDir: String, infoPlist: String, cleanup: String) {
        let fm = FileManager.default
        let base = NSTemporaryDirectory() + "wrapfix-\(UUID().uuidString)"
        let productDir = (base as NSString).appendingPathComponent("Products/Debug")
        try fm.createDirectory(atPath: productDir, withIntermediateDirectories: true)

        // executable
        let exe = (productDir as NSString).appendingPathComponent("SenkaniApp")
        try Data([0x7F, 0x45, 0x4C, 0x46]).write(to: URL(fileURLWithPath: exe))

        // N resource bundles (each a dir with a marker file)
        for i in 0..<bundleCount {
            let b = (productDir as NSString).appendingPathComponent("dep\(i)_Mod.bundle")
            try fm.createDirectory(atPath: b, withIntermediateDirectories: true)
            try Data("x".utf8).write(
                to: URL(fileURLWithPath: (b as NSString).appendingPathComponent("Info.plist"))
            )
        }
        // a .swiftmodule dir that must NOT be copied
        let sm = (productDir as NSString).appendingPathComponent("SenkaniApp.swiftmodule")
        try fm.createDirectory(atPath: sm, withIntermediateDirectories: true)

        // fake Info.plist source
        let plist = (base as NSString).appendingPathComponent("Info.plist")
        try Data("<plist/>".utf8).write(to: URL(fileURLWithPath: plist))

        return (productDir, plist, base)
    }

    @Test("wrap assembles the .app layout and copies only .bundle dirs")
    func wrap_assemblesLayout() throws {
        let fm = FileManager.default
        let (productDir, plist, base) = try Self.makeFixtureProduct(bundleCount: 3)
        defer { try? fm.removeItem(atPath: base) }
        let bundlePath = base + "-out/SenkaniApp.app"
        defer { try? fm.removeItem(atPath: (base + "-out")) }

        let result = try XcodebuildBundleBuilder.wrap(
            productDir: productDir,
            exeName: "SenkaniApp",
            infoPlistPath: plist,
            bundlePath: bundlePath
        )

        #expect(fm.fileExists(atPath: bundlePath + "/Contents/MacOS/SenkaniApp"))
        #expect(fm.fileExists(atPath: bundlePath + "/Contents/Info.plist"))
        // exactly the 3 .bundle dirs, sorted, .swiftmodule excluded
        #expect(result.resourceBundles == ["dep0_Mod.bundle", "dep1_Mod.bundle", "dep2_Mod.bundle"])
        #expect(!fm.fileExists(atPath: bundlePath + "/Contents/Resources/SenkaniApp.swiftmodule"))
        // executable bit set
        let attrs = try fm.attributesOfItem(atPath: bundlePath + "/Contents/MacOS/SenkaniApp")
        let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
        #expect(perms & 0o111 != 0)
    }

    @Test("wrap is re-run safe over an existing bundle and discovers a new count")
    func wrap_rerunSafeDynamicCount() throws {
        let fm = FileManager.default
        let bundlePath = NSTemporaryDirectory() + "rerun-\(UUID().uuidString)/SenkaniApp.app"
        defer { try? fm.removeItem(atPath: (bundlePath as NSString).deletingLastPathComponent) }

        // first run: 7 bundles
        let (dir7, plist7, base7) = try Self.makeFixtureProduct(bundleCount: 7)
        defer { try? fm.removeItem(atPath: base7) }
        let r1 = try XcodebuildBundleBuilder.wrap(
            productDir: dir7, exeName: "SenkaniApp", infoPlistPath: plist7, bundlePath: bundlePath
        )
        #expect(r1.resourceBundles.count == 7)

        // second run over the SAME bundle with a DIFFERENT count (5) — the
        // count is discovered dynamically; stale bundles from run 1 must not
        // linger.
        let (dir5, plist5, base5) = try Self.makeFixtureProduct(bundleCount: 5)
        defer { try? fm.removeItem(atPath: base5) }
        let r2 = try XcodebuildBundleBuilder.wrap(
            productDir: dir5, exeName: "SenkaniApp", infoPlistPath: plist5, bundlePath: bundlePath
        )
        #expect(r2.resourceBundles.count == 5)
        let landed = try fm.contentsOfDirectory(atPath: bundlePath + "/Contents/Resources")
            .filter { $0.hasSuffix(".bundle") }
        #expect(landed.count == 5)  // no stale dep5/dep6 left behind
    }

    @Test("wrap refuses to wrap a missing product executable")
    func wrap_missingExeThrows() throws {
        let fm = FileManager.default
        let base = NSTemporaryDirectory() + "noexe-\(UUID().uuidString)"
        let productDir = (base as NSString).appendingPathComponent("Products/Debug")
        try fm.createDirectory(atPath: productDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: base) }
        let plist = (base as NSString).appendingPathComponent("Info.plist")
        try Data("<plist/>".utf8).write(to: URL(fileURLWithPath: plist))

        #expect(throws: XcodebuildBundleBuilder.BuildError.self) {
            try XcodebuildBundleBuilder.wrap(
                productDir: productDir, exeName: "SenkaniApp",
                infoPlistPath: plist, bundlePath: base + "/out.app"
            )
        }
    }

    @Test("wrap refuses when the Info.plist source is missing")
    func wrap_missingPlistThrows() throws {
        let fm = FileManager.default
        let (productDir, _, base) = try Self.makeFixtureProduct(bundleCount: 1)
        defer { try? fm.removeItem(atPath: base) }
        #expect(throws: XcodebuildBundleBuilder.BuildError.self) {
            try XcodebuildBundleBuilder.wrap(
                productDir: productDir, exeName: "SenkaniApp",
                infoPlistPath: base + "/does-not-exist.plist",
                bundlePath: base + "/out.app"
            )
        }
    }
}
