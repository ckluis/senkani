import ArgumentParser
import Foundation

/// `senkani walk` — operator-side walk helpers (release-validation
/// runners under `tools/soak/runner/`). Today the surface is single-
/// subcommand: `rebuild-bundle`. Other walk helpers can land here as
/// the walks evolve, but each gets its own subcommand for clarity.
///
/// Originating finding: `onboarding-pass-stale-bundle-hazard-2026-05-14`.
/// The walk runner's old inline `swift build` + `cp` + `codesign` +
/// `lsregister` dance now lives in `BundleRebuilder.rebuild(...)`;
/// runner scripts call this subcommand instead of duplicating the
/// logic.
struct Walk: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "walk",
        abstract: "Helpers for release-validation walk runners.",
        subcommands: [RebuildBundle.self]
    )

    struct RebuildBundle: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "rebuild-bundle",
            abstract: "Rebuild SenkaniApp from current HEAD and refresh the wrapped .app bundle."
        )

        @Argument(help: "Path to the .app bundle to refresh (e.g. tools/soak/runner/_onboarding-pass-SenkaniApp.app).")
        var bundlePath: String

        func run() throws {
            let projectRoot = FileManager.default.currentDirectoryPath
            let absoluteBundle = (bundlePath as NSString).isAbsolutePath
                ? bundlePath
                : (projectRoot as NSString).appendingPathComponent(bundlePath)

            guard FileManager.default.fileExists(atPath: absoluteBundle) else {
                FileHandle.standardError.write(Data(
                    "error: bundle does not exist: \(absoluteBundle)\n".utf8
                ))
                throw ExitCode.failure
            }

            do {
                try BundleRebuilder.rebuild(
                    bundlePath: absoluteBundle,
                    projectRoot: projectRoot
                ) { print($0) }
                print("rebuild: ok")
            } catch let error as BundleRebuilder.RebuildError {
                FileHandle.standardError.write(Data(
                    "error: \(error.description)\n".utf8
                ))
                throw ExitCode.failure
            }
        }
    }
}
