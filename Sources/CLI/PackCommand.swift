import ArgumentParser
import Core
import Foundation

/// `senkani pack` — install / uninstall / list SkillPacks.
///
/// Pack format v1 — see `spec/skill_packs.md`. V.11a ships directory
/// installs only; tarball ingestion lands in V.11b.
public struct Pack: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "pack",
        abstract: "Install, uninstall, and list SkillPacks.",
        subcommands: [Install.self, Uninstall.self, List.self])

    public init() {}

    public struct Install: ParsableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "install",
            abstract: "Install a SkillPack from a directory.")

        @Argument(help: "Path to a pack directory (containing pack.json).")
        public var path: String

        @Flag(name: .long, help: "Print the collision diff without mutating anything.")
        public var dryRun: Bool = false

        @Flag(name: .long, help: "Apply despite collisions; records a force_override audit row.")
        public var force: Bool = false

        public init() {}

        public func run() throws {
            let installer = PackInstaller.defaultProduction()
            let sourceDir = URL(fileURLWithPath: path).standardizedFileURL
            let plan: PackInstaller.Plan
            do {
                plan = try installer.plan(sourceDir: sourceDir)
            } catch {
                FileHandle.standardError.write(Data(
                    "error: \(installerErrorMessage(error))\n".utf8))
                throw ExitCode(1)
            }

            let diff = PackCollisionDiff.render(
                incomingPack: plan.manifest.name,
                collisions: plan.collisions)
            print(diff)

            if dryRun {
                return
            }

            if plan.hasCollisions && !force {
                FileHandle.standardError.write(Data(
                    "error: refusing to install due to collisions; pass --force to override.\n".utf8))
                throw ExitCode(1)
            }

            do {
                let installed = try installer.apply(plan: plan, force: force)
                print("installed: \(installed.manifest.name) \(installed.manifest.version) → \(installed.installDir.path)")
            } catch {
                FileHandle.standardError.write(Data(
                    "error: \(installerErrorMessage(error))\n".utf8))
                throw ExitCode(1)
            }
        }
    }

    public struct Uninstall: ParsableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "uninstall",
            abstract: "Uninstall a SkillPack by name.")

        @Argument(help: "Pack name (e.g. 'code-quality').")
        public var name: String

        public init() {}

        public func run() throws {
            let installer = PackInstaller.defaultProduction()
            do {
                let removed = try installer.uninstall(name: name)
                print("uninstalled: \(removed.manifest.name) \(removed.manifest.version)")
            } catch {
                FileHandle.standardError.write(Data(
                    "error: \(installerErrorMessage(error))\n".utf8))
                throw ExitCode(1)
            }
        }
    }

    public struct List: ParsableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "list",
            abstract: "List installed SkillPacks.")

        @Flag(name: .long, help: "Print as JSON.")
        public var json: Bool = false

        public init() {}

        public func run() throws {
            let installer = PackInstaller.defaultProduction()
            let installed = installer.list()
            if json {
                let payload = installed.map {
                    PackListEntry(
                        name: $0.manifest.name,
                        version: $0.manifest.version,
                        skills: $0.manifest.skills,
                        installDir: $0.installDir.path,
                        activation: "installed")
                }
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                if let data = try? encoder.encode(payload),
                   let s = String(data: data, encoding: .utf8) {
                    print(s)
                } else {
                    print("[]")
                }
                return
            }
            if installed.isEmpty {
                print("(no packs installed)")
                return
            }
            for pack in installed {
                let skillStr = pack.manifest.skills.joined(separator: ",")
                print("\(pack.manifest.name)\t\(pack.manifest.version)\tinstalled\tskills=\(skillStr)")
            }
        }
    }
}

private struct PackListEntry: Encodable {
    let name: String
    let version: String
    let skills: [String]
    let installDir: String
    let activation: String
}

private func installerErrorMessage(_ error: Error) -> String {
    guard let e = error as? PackInstaller.InstallError else { return "\(error)" }
    switch e {
    case .sourceNotFound(let p): return "source not found: \(p)"
    case .packJsonMissing(let p): return "pack.json missing: \(p)"
    case .manifestParse(let d): return "pack.json parse failed: \(d)"
    case .skillManifestMissing(let s, let p): return "skill manifest missing for '\(s)': \(p)"
    case .skillManifestInvalid(let s, let d): return "skill manifest invalid for '\(s)': \(d)"
    case .policyFragmentMissing(let p): return "policy fragment missing: \(p)"
    case .policyFragmentInvalid(let d): return "policy fragment invalid: \(d)"
    case .contextDocMissing(let p): return "context doc missing: \(p)"
    case .copyFailed(let d): return "copy failed: \(d)"
    case .removeFailed(let d): return "remove failed: \(d)"
    case .collisionsRefuseInstall: return "collisions present; pass --force to override"
    case .packNotInstalled(let n): return "pack not installed: \(n)"
    case .auditWriteFailed: return "audit chain write failed"
    }
}
