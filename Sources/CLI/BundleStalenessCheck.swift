import Foundation

/// Result of a `BundleStalenessScanner.scan(...)` comparison.
///
/// The doctor surface routes this report through
/// `Doctor.formatBundleStalenessLines(_:)`. Onboarding/release validation
/// walks wrap `swift build --product SenkaniApp` into a `.app` whose
/// `Contents/MacOS/SenkaniApp` binary mtime captures *when the operator
/// last refreshed the bundle.* On multi-day walks, the binary can fall
/// behind the merge-target HEAD without the operator noticing, silently
/// testing stale code (see onboarding-pass walk 2026-05-14 Finding #H).
///
/// `scan(...)` is pure: caller resolves the merge-target HEAD commit
/// time + subject (typically via `git log -1 <merge-target>`) and feeds
/// it in. Tests inject synthesized values directly; the production
/// doctor surface runs the git lookup before calling.
public struct BundleStalenessReport: Sendable, Equatable {

    /// Three-way verdict. `.notApplicable` covers every reason the
    /// scanner cannot or should not compare — missing bundle, missing
    /// HEAD timestamp, etc. — and keeps the doctor formatter's pass/
    /// skip routing simple.
    public enum Verdict: Sendable, Equatable {
        case fresh
        case stale
        case notApplicable
    }

    public var verdict: Verdict
    public var bundlePath: String
    public var binaryMtime: Date?
    public var headCommitTime: Date?
    public var headCommitSubject: String?
    public var notApplicableReason: String?

    public init(
        verdict: Verdict,
        bundlePath: String,
        binaryMtime: Date? = nil,
        headCommitTime: Date? = nil,
        headCommitSubject: String? = nil,
        notApplicableReason: String? = nil
    ) {
        self.verdict = verdict
        self.bundlePath = bundlePath
        self.binaryMtime = binaryMtime
        self.headCommitTime = headCommitTime
        self.headCommitSubject = headCommitSubject
        self.notApplicableReason = notApplicableReason
    }
}

/// Detects "the wrapped SenkaniApp bundle the walk runner is testing is
/// older than `main` HEAD" — the silent-stale-walk hazard surfaced by
/// the onboarding-pass walk 2026-05-14 (Finding #H). The recovery dance
/// (rebuild, swap binary, ad-hoc codesign, lsregister) is mechanical
/// and ~30s; the scanner is the detector and `BundleRebuilder` is the
/// shared action.
public enum BundleStalenessScanner {

    /// Bundle-discovery convention. Walks wrap the binary into one of
    /// two names under `tools/soak/runner/`:
    ///   - `_onboarding-pass-SenkaniApp.app` (onboarding-pass convention,
    ///     introduced 2026-05-11)
    ///   - `SenkaniApp.app` (older uninstall-pass convention)
    ///
    /// Returns the first existing path, or `nil` if neither is present
    /// (e.g. CI environment, fresh checkout). The doctor check skips
    /// (.notApplicable) in that case rather than failing.
    public static func discoverBundlePath(projectRoot: String) -> String? {
        let candidates = [
            "tools/soak/runner/_onboarding-pass-SenkaniApp.app",
            "tools/soak/runner/SenkaniApp.app",
        ]
        let fm = FileManager.default
        for candidate in candidates {
            let full = (projectRoot as NSString).appendingPathComponent(candidate)
            if fm.fileExists(atPath: full) {
                return full
            }
        }
        return nil
    }

    /// Reads the bundle's `Contents/MacOS/SenkaniApp` binary mtime via
    /// `FileManager.default.attributesOfItem(atPath:)`. Returns `nil`
    /// if the bundle exists but the binary inside it is missing —
    /// caller treats that as `.notApplicable`.
    public static func bundleBinaryMtime(bundlePath: String) -> Date? {
        let binaryPath = (bundlePath as NSString)
            .appendingPathComponent("Contents/MacOS/SenkaniApp")
        let fm = FileManager.default
        guard fm.fileExists(atPath: binaryPath),
              let attrs = try? fm.attributesOfItem(atPath: binaryPath),
              let mtime = attrs[.modificationDate] as? Date
        else {
            return nil
        }
        return mtime
    }

    /// Pure comparison. Verdict is `.stale` iff bundle binary mtime is
    /// strictly older than HEAD commit time. Ties (mtime == ct) are
    /// `.fresh` — the operator's refresh and the commit landed in the
    /// same second; not stale.
    ///
    /// Missing bundle path, missing binary, or missing HEAD timestamp
    /// all collapse to `.notApplicable` with the reason populated.
    public static func scan(
        bundlePath: String,
        headCommitTime: Date?,
        headCommitSubject: String? = nil
    ) -> BundleStalenessReport {
        let fm = FileManager.default
        guard fm.fileExists(atPath: bundlePath) else {
            return BundleStalenessReport(
                verdict: .notApplicable,
                bundlePath: bundlePath,
                notApplicableReason: "bundle path does not exist"
            )
        }
        guard let mtime = bundleBinaryMtime(bundlePath: bundlePath) else {
            return BundleStalenessReport(
                verdict: .notApplicable,
                bundlePath: bundlePath,
                notApplicableReason: "Contents/MacOS/SenkaniApp missing or unreadable"
            )
        }
        guard let headCt = headCommitTime else {
            return BundleStalenessReport(
                verdict: .notApplicable,
                bundlePath: bundlePath,
                binaryMtime: mtime,
                notApplicableReason: "HEAD commit time not available (no merge target / git lookup failed)"
            )
        }
        if mtime < headCt {
            return BundleStalenessReport(
                verdict: .stale,
                bundlePath: bundlePath,
                binaryMtime: mtime,
                headCommitTime: headCt,
                headCommitSubject: headCommitSubject
            )
        }
        return BundleStalenessReport(
            verdict: .fresh,
            bundlePath: bundlePath,
            binaryMtime: mtime,
            headCommitTime: headCt,
            headCommitSubject: headCommitSubject
        )
    }

    /// Resolves `merge_target` from `spec/autonomous-manifest.yaml`'s
    /// `close.merge_target` line, with fallbacks:
    ///   1. Manifest line (single-key lookup; no full YAML parse needed
    ///      — the line shape is fixed).
    ///   2. Upstream tracking branch via
    ///      `git rev-parse --abbrev-ref --symbolic-full-name @{u}`.
    ///   3. Literal `"main"`.
    public static func resolveMergeTarget(projectRoot: String) -> String {
        let manifestPath = (projectRoot as NSString)
            .appendingPathComponent("spec/autonomous-manifest.yaml")
        if let contents = try? String(contentsOfFile: manifestPath, encoding: .utf8) {
            var inCloseBlock = false
            for line in contents.split(separator: "\n", omittingEmptySubsequences: false) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("#") { continue }
                if line.hasPrefix("close:") {
                    inCloseBlock = true
                    continue
                }
                // Leave block on any new top-level key (non-indented
                // non-comment non-empty line).
                if inCloseBlock && !line.hasPrefix(" ") && !line.hasPrefix("\t") && !trimmed.isEmpty {
                    inCloseBlock = false
                }
                if inCloseBlock,
                   let range = trimmed.range(of: "merge_target:")
                {
                    let value = trimmed[range.upperBound...]
                        .trimmingCharacters(in: .whitespaces)
                        .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                    if !value.isEmpty { return value }
                }
            }
        }
        if let upstream = runGitForString(
            projectRoot: projectRoot,
            args: ["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"]
        ), !upstream.isEmpty {
            // Strip the remote prefix (e.g. "origin/main" → "main").
            if let slash = upstream.firstIndex(of: "/") {
                return String(upstream[upstream.index(after: slash)...])
            }
            return upstream
        }
        return "main"
    }

    /// `git log -1 <ref> --format=%ct` → commit time as Date (seconds
    /// since epoch). Returns `nil` if git invocation fails or the ref
    /// does not exist.
    public static func headCommitTime(
        projectRoot: String,
        ref: String
    ) -> Date? {
        guard let raw = runGitForString(
            projectRoot: projectRoot,
            args: ["log", "-1", ref, "--format=%ct"]
        ), let seconds = TimeInterval(raw) else {
            return nil
        }
        return Date(timeIntervalSince1970: seconds)
    }

    /// `git log -1 <ref> --format=%s` → commit subject line. `nil` on
    /// git failure.
    public static func headCommitSubject(
        projectRoot: String,
        ref: String
    ) -> String? {
        runGitForString(
            projectRoot: projectRoot,
            args: ["log", "-1", ref, "--format=%s"]
        )
    }

    /// Run `git <args>` in `projectRoot`, return trimmed stdout, or
    /// `nil` if the process fails / exits non-zero / produces no
    /// output. Pure subprocess helper — no logging.
    private static func runGitForString(
        projectRoot: String,
        args: [String]
    ) -> String? {
        let proc = Process()
        proc.launchPath = "/usr/bin/git"
        proc.currentDirectoryPath = projectRoot
        proc.arguments = args
        let outPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = Pipe()
        do {
            try proc.run()
        } catch {
            return nil
        }
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { return nil }
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        let raw = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.isEmpty ? nil : raw
    }
}

/// Shared rebuild dance — single callable form used by both the doctor
/// check and the `senkani walk rebuild-bundle` subcommand. Walk-runner
/// `.command` scripts migrate from inline `swift build` + `cp` +
/// `codesign` + `lsregister` to invoking the subcommand.
///
/// Steps (per onboarding-pass 2026-05-14 recovery dance):
///   1. `swift build --product SenkaniApp` in `projectRoot`.
///   2. Copy `.build/arm64-apple-macosx/debug/SenkaniApp` → bundle's
///      `Contents/MacOS/SenkaniApp`.
///   3. Ad-hoc re-codesign: `codesign --force --sign - <bundle>`.
///   4. Re-register with LaunchServices: `lsregister -f <bundle>`.
public enum BundleRebuilder {

    public struct RebuildError: Error, CustomStringConvertible {
        public var step: String
        public var exitCode: Int32
        public var stderr: String

        public var description: String {
            "\(step) failed (exit \(exitCode)): \(stderr)"
        }
    }

    /// Executes the four-step rebuild. `log` receives one-line status
    /// lines per step (so the doctor surface can stream terse output
    /// and the `senkani walk rebuild-bundle` subcommand can write
    /// directly to stdout). Verbose `swift build` output is captured
    /// into stderr-on-failure rather than streamed by default.
    public static func rebuild(
        bundlePath: String,
        projectRoot: String,
        log: (String) -> Void
    ) throws {
        log("rebuild: swift build --product SenkaniApp")
        try runStep(
            step: "swift build",
            launchPath: "/usr/bin/env",
            arguments: ["swift", "build", "--product", "SenkaniApp"],
            workingDir: projectRoot
        )

        let srcBinary = (projectRoot as NSString)
            .appendingPathComponent(".build/arm64-apple-macosx/debug/SenkaniApp")
        let dstBinary = (bundlePath as NSString)
            .appendingPathComponent("Contents/MacOS/SenkaniApp")
        log("rebuild: copy \(srcBinary) → \(dstBinary)")
        let fm = FileManager.default
        if fm.fileExists(atPath: dstBinary) {
            try fm.removeItem(atPath: dstBinary)
        }
        try fm.copyItem(atPath: srcBinary, toPath: dstBinary)

        log("rebuild: codesign --force --sign - \(bundlePath)")
        try runStep(
            step: "codesign",
            launchPath: "/usr/bin/codesign",
            arguments: ["--force", "--sign", "-", bundlePath],
            workingDir: projectRoot
        )

        let lsregisterPath = "/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"
        log("rebuild: lsregister -f \(bundlePath)")
        try runStep(
            step: "lsregister",
            launchPath: lsregisterPath,
            arguments: ["-f", bundlePath],
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
        try proc.run()
        proc.waitUntilExit()
        if proc.terminationStatus != 0 {
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let stderr = String(decoding: errData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw RebuildError(
                step: step,
                exitCode: proc.terminationStatus,
                stderr: stderr
            )
        }
    }
}
