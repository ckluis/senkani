import Foundation

/// Builds an `open`-launchable `SenkaniApp.app` that wraps the **xcodebuild**
/// product, NOT the `swift build` product.
///
/// ## Why this exists (the crash-loop trap)
///
/// `swift build` and `xcodebuild` emit **different SwiftPM resource-bundle
/// accessors**. A `.app` wrapping the `swift build` product crash-loops the
/// moment SwiftUI code touches `Bundle.module` under an `open`-launch — the
/// accessor baked into the swift-build binary resolves relative to
/// `.build/debug/`, which does not exist inside the wrapped bundle. The
/// xcodebuild product's accessor resolves against `Contents/Resources/`, so
/// the wrapped bundle launches cleanly. The existing
/// `senkani walk rebuild-bundle` → `BundleRebuilder.rebuild(...)` path and
/// Doctor's auto-rebuild path both wrap the fast `swift build` product and are
/// left UNTOUCHED — they serve the soak runner, which never exercises the
/// crashing `Bundle.module` access. This builder is the GUI-Cowork-walk path.
///
/// Originating gap:
/// `process-gap-no-xcodebuild-aware-app-bundler-2026-07-05` (surfaced by the
/// `t6-schedule-end-cli-to-app-bridge-2026-05-21` LEG-B GUI walk).
///
/// ## Product location
///
/// `xcodebuild -scheme SenkaniApp -showBuildSettings -json` returns **zero
/// entries** for this SwiftPM executable scheme (empirically verified
/// 2026-07-05; matches the t6 evidence), so probe (b) target/scheme-scoped
/// `-showBuildSettings` is dead for this package. The reliable mechanisms,
/// in order, are:
///   (a) parse the `xcodebuild build` log for the linker's `Ld <path>` line —
///       authoritative, points at the exact product the build just emitted;
///   (c) DerivedData glob (`~/Library/Developer/Xcode/DerivedData/senkani-*/
///       Build/Products/<Config>/`) — fallback, picks the most-recently-built
///       matching product directory.
/// Both are pure functions pinned by unit tests. A stale/missing/ambiguous
/// DerivedData state produces a clear `BuildError`, never a silent wrong-binary
/// wrap.
public enum XcodebuildBundleBuilder {

    /// A single failure point in the build → locate → wrap → sign → register
    /// pipeline, carrying enough context to distinguish "build failed" from
    /// "product location probe found nothing" from "wrap assembly failed".
    public struct BuildError: Error, CustomStringConvertible {
        public var step: String
        public var detail: String
        public init(step: String, detail: String) {
            self.step = step
            self.detail = detail
        }
        public var description: String { "\(step): \(detail)" }
    }

    /// What `wrap(...)` assembled — surfaced so the caller can log the
    /// resource-bundle count (dynamically discovered, never hardcoded) and
    /// tests can assert the layout.
    public struct WrapResult: Equatable {
        public var bundlePath: String
        public var executablePath: String
        public var infoPlistPath: String
        public var resourceBundles: [String]  // basenames, sorted
    }

    // MARK: - Product location (pure probes)

    /// Probe (a): parse an `xcodebuild build` log for the linker line that
    /// writes the product executable, and return its **directory**.
    ///
    /// The authoritative signal is the `Ld` task line:
    /// `Ld /…/Build/Products/Debug/SenkaniApp normal (in target 'SenkaniApp' …)`.
    /// We match a whitespace-led token that ends in `/<exeName>` and sits under
    /// a `/Build/Products/<something>/` path, then return everything up to the
    /// final path component. Returns `nil` if no such line is present (build
    /// failed, or emitted under an unexpected shape).
    public static func productDirFromBuildLog(
        _ log: String,
        exeName: String = "SenkaniApp"
    ) -> String? {
        // Look for the last matching occurrence so an incremental relink wins
        // over any earlier stale reference.
        var found: String? = nil
        for rawLine in log.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            // The Ld line is the canonical writer of the product exe.
            guard line.contains("/Build/Products/"),
                  line.contains("/\(exeName)")
            else { continue }
            // Extract whitespace-delimited tokens; pick the one that is an
            // absolute path ending in `/<exeName>` under `/Build/Products/`.
            for token in line.split(whereSeparator: { $0 == " " || $0 == "\t" }) {
                let t = String(token)
                guard t.hasPrefix("/"),
                      t.hasSuffix("/\(exeName)"),
                      t.contains("/Build/Products/")
                else { continue }
                found = (t as NSString).deletingLastPathComponent
            }
        }
        return found
    }

    /// Probe (c): DerivedData glob fallback. Scans
    /// `<derivedDataRoot>/senkani-*/Build/Products/<configuration>/` for a
    /// directory that actually contains an executable named `exeName`, and
    /// returns the newest such directory (by the executable's mtime).
    ///
    /// Returns `nil` if no candidate contains the executable — the caller then
    /// raises a clear `BuildError` rather than wrapping a wrong/absent binary.
    public static func productDirFromDerivedData(
        derivedDataRoot: String,
        projectName: String = "senkani",
        configuration: String = "Debug",
        exeName: String = "SenkaniApp",
        fileManager: FileManager = .default
    ) -> String? {
        let fm = fileManager
        guard let entries = try? fm.contentsOfDirectory(atPath: derivedDataRoot) else {
            return nil
        }
        var best: (dir: String, mtime: Date)? = nil
        for entry in entries {
            guard entry == projectName || entry.hasPrefix("\(projectName)-") else { continue }
            let productDir = (derivedDataRoot as NSString)
                .appendingPathComponent("\(entry)/Build/Products/\(configuration)")
            let exePath = (productDir as NSString).appendingPathComponent(exeName)
            guard fm.fileExists(atPath: exePath),
                  let attrs = try? fm.attributesOfItem(atPath: exePath),
                  let mtime = attrs[.modificationDate] as? Date
            else { continue }
            if best == nil || mtime > best!.mtime {
                best = (productDir, mtime)
            }
        }
        return best?.dir
    }

    /// Default DerivedData root for the current user.
    public static func defaultDerivedDataRoot() -> String {
        (NSHomeDirectory() as NSString)
            .appendingPathComponent("Library/Developer/Xcode/DerivedData")
    }

    // MARK: - Wrap (pure filesystem assembly)

    /// Assemble a `.app` around the xcodebuild product. Pure filesystem work —
    /// no subprocesses — so it is unit-testable with a fixture product dir.
    ///
    /// Steps:
    ///   1. Validate the product exe exists (else a clear error, never a silent
    ///      wrong-binary wrap) and the Info.plist source exists.
    ///   2. `rm -rf` any existing bundle (re-run safety — the operator may have
    ///      a prior `.app` present).
    ///   3. Create `Contents/MacOS` + `Contents/Resources`.
    ///   4. Copy exe → `Contents/MacOS/<exeName>` (0755).
    ///   5. Copy Info.plist → `Contents/Info.plist`.
    ///   6. **Dynamically discover** every `*.bundle` in the product dir and
    ///      copy each into `Contents/Resources/` — the count is discovered, not
    ///      hardcoded, so it survives dependency-graph changes.
    @discardableResult
    public static func wrap(
        productDir: String,
        exeName: String,
        infoPlistPath: String,
        bundlePath: String,
        fileManager: FileManager = .default
    ) throws -> WrapResult {
        let fm = fileManager

        let productExe = (productDir as NSString).appendingPathComponent(exeName)
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: productExe, isDirectory: &isDir), !isDir.boolValue else {
            throw BuildError(
                step: "locate-product",
                detail: "product executable not found at \(productExe) — the "
                    + "build likely failed or the product-location probe picked "
                    + "a stale/wrong directory. Refusing to wrap a wrong/absent binary."
            )
        }
        guard fm.fileExists(atPath: infoPlistPath) else {
            throw BuildError(
                step: "info-plist",
                detail: "Info.plist source not found at \(infoPlistPath)"
            )
        }

        // (2) re-run safety: remove any prior bundle wholesale.
        if fm.fileExists(atPath: bundlePath) {
            try fm.removeItem(atPath: bundlePath)
        }

        let contents = (bundlePath as NSString).appendingPathComponent("Contents")
        let macosDir = (contents as NSString).appendingPathComponent("MacOS")
        let resourcesDir = (contents as NSString).appendingPathComponent("Resources")
        try fm.createDirectory(atPath: macosDir, withIntermediateDirectories: true)
        try fm.createDirectory(atPath: resourcesDir, withIntermediateDirectories: true)

        // (4) executable.
        let dstExe = (macosDir as NSString).appendingPathComponent(exeName)
        try fm.copyItem(atPath: productExe, toPath: dstExe)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dstExe)

        // (5) Info.plist.
        let dstPlist = (contents as NSString).appendingPathComponent("Info.plist")
        try fm.copyItem(atPath: infoPlistPath, toPath: dstPlist)

        // (6) dynamically discovered resource bundles.
        var copied: [String] = []
        if let productEntries = try? fm.contentsOfDirectory(atPath: productDir) {
            for entry in productEntries.sorted() where entry.hasSuffix(".bundle") {
                let src = (productDir as NSString).appendingPathComponent(entry)
                let dst = (resourcesDir as NSString).appendingPathComponent(entry)
                if fm.fileExists(atPath: dst) {
                    try fm.removeItem(atPath: dst)
                }
                try fm.copyItem(atPath: src, toPath: dst)
                copied.append(entry)
            }
        }

        return WrapResult(
            bundlePath: bundlePath,
            executablePath: dstExe,
            infoPlistPath: dstPlist,
            resourceBundles: copied
        )
    }

    // MARK: - Full flow

    /// Build via xcodebuild, locate the product (probe a → c), wrap it, ad-hoc
    /// codesign, and re-register with LaunchServices. `log` receives one status
    /// line per step.
    public static func build(
        projectRoot: String,
        bundlePath: String,
        configuration: String = "Debug",
        scheme: String = "SenkaniApp",
        exeName: String = "SenkaniApp",
        log: (String) -> Void
    ) throws {
        let fm = FileManager.default

        // (1) xcodebuild — output redirected to a temp log file so the build's
        // large stdout can never deadlock a pipe buffer over a ~10-15 min run.
        let logPath = NSTemporaryDirectory()
            + "xcodebuild-\(scheme)-\(UUID().uuidString).log"
        fm.createFile(atPath: logPath, contents: nil)
        guard let logHandle = FileHandle(forWritingAtPath: logPath) else {
            throw BuildError(step: "xcodebuild", detail: "cannot open build log at \(logPath)")
        }
        defer { try? fm.removeItem(atPath: logPath) }

        log("xcodebuild: -scheme \(scheme) -destination 'platform=macOS' -configuration \(configuration) build")
        let build = Process()
        build.launchPath = "/usr/bin/env"
        build.arguments = [
            "xcodebuild",
            "-scheme", scheme,
            "-destination", "platform=macOS",
            "-configuration", configuration,
            "build",
        ]
        build.currentDirectoryPath = projectRoot
        build.standardOutput = logHandle
        build.standardError = logHandle
        do {
            try build.run()
        } catch {
            throw BuildError(step: "xcodebuild", detail: "failed to launch xcodebuild: \(error)")
        }
        build.waitUntilExit()
        try? logHandle.close()
        let buildLog = (try? String(contentsOfFile: logPath, encoding: .utf8)) ?? ""
        guard build.terminationStatus == 0 else {
            let tail = buildLog.split(separator: "\n").suffix(25).joined(separator: "\n")
            throw BuildError(
                step: "xcodebuild",
                detail: "exit \(build.terminationStatus). Last lines:\n\(tail)"
            )
        }

        // (2) locate product — probe (a) log parse, then (c) DerivedData glob.
        var productDir = productDirFromBuildLog(buildLog, exeName: exeName)
        var probe = "build-log"
        if productDir == nil {
            // DerivedData dirs are keyed on the workspace directory basename
            // (e.g. a worktree at `.worktrees/xcodebuild-bundler` yields
            // `xcodebuild-bundler-<hash>`), NOT the SwiftPM package name — so
            // derive the prefix from the project root, not a literal "senkani".
            productDir = productDirFromDerivedData(
                derivedDataRoot: defaultDerivedDataRoot(),
                projectName: (projectRoot as NSString).lastPathComponent,
                configuration: configuration,
                exeName: exeName
            )
            probe = "derived-data-glob"
        }
        guard let resolvedDir = productDir else {
            throw BuildError(
                step: "locate-product",
                detail: "could not locate the built \(exeName) product via build-log "
                    + "parse or DerivedData glob. Build reported success but no "
                    + "product directory was found — refusing to wrap. Check "
                    + "\(defaultDerivedDataRoot())."
            )
        }
        log("locate-product: \(resolvedDir) (via \(probe))")

        // (3) wrap.
        let infoPlist = (projectRoot as NSString).appendingPathComponent("SenkaniApp/Info.plist")
        let absoluteBundle = (bundlePath as NSString).isAbsolutePath
            ? bundlePath
            : (projectRoot as NSString).appendingPathComponent(bundlePath)
        let result = try wrap(
            productDir: resolvedDir,
            exeName: exeName,
            infoPlistPath: infoPlist,
            bundlePath: absoluteBundle
        )
        log("wrap: \(result.resourceBundles.count) resource bundle(s): \(result.resourceBundles.joined(separator: ", "))")

        // (4) ad-hoc codesign (idempotent under --force).
        log("codesign: --force --sign - \(absoluteBundle)")
        try runStep(
            step: "codesign",
            launchPath: "/usr/bin/codesign",
            arguments: ["--force", "--deep", "--sign", "-", absoluteBundle],
            workingDir: projectRoot
        )

        // (5) LaunchServices re-register (idempotent under -f).
        let lsregister = "/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"
        log("lsregister: -f \(absoluteBundle)")
        try runStep(
            step: "lsregister",
            launchPath: lsregister,
            arguments: ["-f", absoluteBundle],
            workingDir: projectRoot
        )
    }

    private static func runStep(
        step: String,
        launchPath: String,
        arguments: [String],
        workingDir: String
    ) throws {
        let proc = Process()
        proc.launchPath = launchPath
        proc.arguments = arguments
        proc.currentDirectoryPath = workingDir
        let errPipe = Pipe()
        proc.standardError = errPipe
        proc.standardOutput = Pipe()
        do {
            try proc.run()
        } catch {
            throw BuildError(step: step, detail: "failed to launch \(launchPath): \(error)")
        }
        proc.waitUntilExit()
        if proc.terminationStatus != 0 {
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let stderr = String(decoding: errData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw BuildError(step: step, detail: "exit \(proc.terminationStatus): \(stderr)")
        }
    }
}
