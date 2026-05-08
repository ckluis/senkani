import Foundation

/// SkillPack installer for V.11a — file-system-driven install/uninstall
/// of pack directories under `~/.senkani/packs/<name>/`. Provenance is
/// chained through `pack_audits` (migration v20). Live HookRouter merge
/// is V.11b.
public final class PackInstaller {

    public struct Plan: Sendable, Equatable {
        public let manifest: PackManifest
        public let sourceDir: URL
        public let targetDir: URL
        public let collisions: [Collision]

        public var hasCollisions: Bool { !collisions.isEmpty }
    }

    public enum Collision: Sendable, Equatable {
        case skillName(String, conflictingPack: String)
        case policyScopeKey(String, conflictingPack: String)
        case contextFilename(String, conflictingPack: String)
    }

    public enum InstallError: Error, Equatable, Sendable {
        case sourceNotFound(path: String)
        case packJsonMissing(path: String)
        case manifestParse(detail: String)
        case skillManifestMissing(skill: String, expectedAt: String)
        case skillManifestInvalid(skill: String, detail: String)
        case policyFragmentMissing(path: String)
        case policyFragmentInvalid(detail: String)
        case contextDocMissing(path: String)
        case copyFailed(detail: String)
        case removeFailed(detail: String)
        case collisionsRefuseInstall([Collision])
        case packNotInstalled(name: String)
        case auditWriteFailed
    }

    public struct InstalledPack: Sendable, Equatable {
        public let manifest: PackManifest
        public let installDir: URL
    }

    private let installRoot: URL
    private let auditStore: PackAuditStore?

    /// Initialize with an explicit install root + audit store. Tests pass
    /// a temp directory + temp-DB-backed audit store; production callers
    /// use `defaultProduction()`.
    public init(installRoot: URL, auditStore: PackAuditStore?) {
        self.installRoot = installRoot
        self.auditStore = auditStore
    }

    /// Default install root: `~/.senkani/packs/`. Audit store comes from
    /// the live SessionDatabase. Both can fail in tests with no HOME —
    /// production callers handle the fallback by overriding both.
    public static func defaultProduction() -> PackInstaller {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let root = home.appendingPathComponent(".senkani/packs", isDirectory: true)
        return PackInstaller(
            installRoot: root,
            auditStore: SessionDatabase.shared.packAuditStore
        )
    }

    // MARK: - Plan

    /// Read the source directory, parse its pack.json + policy fragment,
    /// detect collisions against already-installed packs, and return a
    /// plan. Pure read — does not mutate the filesystem or DB.
    public func plan(sourceDir: URL) throws -> Plan {
        let fm = FileManager.default
        guard fm.fileExists(atPath: sourceDir.path) else {
            throw InstallError.sourceNotFound(path: sourceDir.path)
        }
        let packJson = sourceDir.appendingPathComponent("pack.json")
        guard fm.fileExists(atPath: packJson.path) else {
            throw InstallError.packJsonMissing(path: packJson.path)
        }

        let manifest: PackManifest
        do {
            manifest = try PackManifestParser.load(from: packJson)
        } catch {
            throw InstallError.manifestParse(detail: "\(error)")
        }

        for skill in manifest.skills {
            let skillManifest = sourceDir
                .appendingPathComponent("skills/\(skill)/manifest.json")
            guard fm.fileExists(atPath: skillManifest.path) else {
                throw InstallError.skillManifestMissing(
                    skill: skill, expectedAt: skillManifest.path)
            }
            let data: Data
            do {
                data = try Data(contentsOf: skillManifest)
            } catch {
                throw InstallError.skillManifestInvalid(skill: skill, detail: "\(error)")
            }
            let issues = HandManifestLinter.lintJSON(data)
            if HandManifestLinter.hasErrors(issues) {
                let firstErr = issues.first(where: { $0.severity == .error })
                let detail = firstErr.map { "\($0.path): \($0.message)" } ?? "lint errors"
                throw InstallError.skillManifestInvalid(skill: skill, detail: detail)
            }
        }

        var fragmentScope: String? = nil
        if let policy = manifest.policy {
            let policyURL = sourceDir.appendingPathComponent(policy)
            guard fm.fileExists(atPath: policyURL.path) else {
                throw InstallError.policyFragmentMissing(path: policyURL.path)
            }
            do {
                let fragment = try HookRouterFragmentParser.load(from: policyURL)
                fragmentScope = fragment.scopeKey
            } catch {
                throw InstallError.policyFragmentInvalid(detail: "\(error)")
            }
        }

        if let context = manifest.context {
            let ctx = sourceDir.appendingPathComponent(context)
            guard fm.fileExists(atPath: ctx.path) else {
                throw InstallError.contextDocMissing(path: ctx.path)
            }
        }

        let target = installRoot.appendingPathComponent(manifest.name, isDirectory: true)
        let collisions = detectCollisions(
            incoming: manifest,
            incomingScopeKey: fragmentScope,
            incomingContextFilename: manifest.context.map {
                ($0 as NSString).lastPathComponent
            }
        )

        return Plan(
            manifest: manifest,
            sourceDir: sourceDir,
            targetDir: target,
            collisions: collisions)
    }

    // MARK: - Install

    /// Apply a plan. With `force = false` and any collisions present,
    /// throws `collisionsRefuseInstall`. With `force = true`, applies and
    /// records a `force_override` audit row in addition to `install`.
    @discardableResult
    public func apply(plan: Plan, force: Bool = false) throws -> InstalledPack {
        if plan.hasCollisions && !force {
            throw InstallError.collisionsRefuseInstall(plan.collisions)
        }

        let fm = FileManager.default
        do {
            try fm.createDirectory(at: installRoot, withIntermediateDirectories: true)
        } catch {
            throw InstallError.copyFailed(detail: "create install root: \(error)")
        }

        // Idempotent re-install: clear the existing target before copy.
        if fm.fileExists(atPath: plan.targetDir.path) {
            do {
                try fm.removeItem(at: plan.targetDir)
            } catch {
                throw InstallError.copyFailed(detail: "remove existing: \(error)")
            }
        }

        do {
            try fm.copyItem(at: plan.sourceDir, to: plan.targetDir)
        } catch {
            throw InstallError.copyFailed(detail: "\(error)")
        }

        if force && plan.hasCollisions {
            guard auditStore?.record(
                packName: plan.manifest.name,
                packVersion: plan.manifest.version,
                event: "force_override",
                sourcePath: plan.sourceDir.path,
                sha256: plan.manifest.provenance.sha256,
                appliedSkills: plan.manifest.skills
            ) ?? false else {
                throw InstallError.auditWriteFailed
            }
        }

        guard auditStore?.record(
            packName: plan.manifest.name,
            packVersion: plan.manifest.version,
            event: "install",
            sourcePath: plan.sourceDir.path,
            sha256: plan.manifest.provenance.sha256,
            appliedSkills: plan.manifest.skills
        ) ?? false else {
            throw InstallError.auditWriteFailed
        }

        // V.11b — same-process live merge: tell the registry to re-
        // read so the next hook event sees the freshly installed
        // policy fragment without waiting for the mtime-based
        // staleness check inside HookRouter.handle().
        HookRouter.refreshInstalledPacks()

        return InstalledPack(manifest: plan.manifest, installDir: plan.targetDir)
    }

    /// Convenience: plan + apply.
    @discardableResult
    public func install(sourceDir: URL, force: Bool = false) throws -> InstalledPack {
        let p = try plan(sourceDir: sourceDir)
        return try apply(plan: p, force: force)
    }

    // MARK: - Uninstall

    public func uninstall(name: String) throws -> InstalledPack {
        let fm = FileManager.default
        let dir = installRoot.appendingPathComponent(name, isDirectory: true)
        guard fm.fileExists(atPath: dir.path) else {
            throw InstallError.packNotInstalled(name: name)
        }
        let manifest: PackManifest
        do {
            manifest = try PackManifestParser.load(
                from: dir.appendingPathComponent("pack.json"))
        } catch {
            // Even if pack.json is unreadable, allow uninstall — the
            // operator's intent is "remove this directory." Surface the
            // version as "unknown" in the audit row so the chain is
            // honest.
            let synthesized = PackManifest(
                name: name,
                description: "(pack.json unreadable at uninstall)",
                version: "unknown",
                author: "",
                senkaniMinVersion: "0.0.0",
                skills: [])
            do {
                try fm.removeItem(at: dir)
            } catch {
                throw InstallError.removeFailed(detail: "\(error)")
            }
            guard auditStore?.record(
                packName: name,
                packVersion: synthesized.version,
                event: "uninstall",
                sourcePath: dir.path,
                sha256: nil,
                appliedSkills: []
            ) ?? false else {
                throw InstallError.auditWriteFailed
            }
            HookRouter.refreshInstalledPacks()
            return InstalledPack(manifest: synthesized, installDir: dir)
        }

        do {
            try fm.removeItem(at: dir)
        } catch {
            throw InstallError.removeFailed(detail: "\(error)")
        }

        guard auditStore?.record(
            packName: manifest.name,
            packVersion: manifest.version,
            event: "uninstall",
            sourcePath: dir.path,
            sha256: manifest.provenance.sha256,
            appliedSkills: manifest.skills
        ) ?? false else {
            throw InstallError.auditWriteFailed
        }

        HookRouter.refreshInstalledPacks()

        return InstalledPack(manifest: manifest, installDir: dir)
    }

    // MARK: - List

    public func list() -> [InstalledPack] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: installRoot.path) else {
            return []
        }
        var out: [InstalledPack] = []
        for entry in entries.sorted() {
            let dir = installRoot.appendingPathComponent(entry, isDirectory: true)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else {
                continue
            }
            let packJson = dir.appendingPathComponent("pack.json")
            guard let manifest = try? PackManifestParser.load(from: packJson) else {
                continue
            }
            out.append(InstalledPack(manifest: manifest, installDir: dir))
        }
        return out
    }

    // MARK: - Collision detection

    private func detectCollisions(
        incoming: PackManifest,
        incomingScopeKey: String?,
        incomingContextFilename: String?
    ) -> [Collision] {
        var collisions: [Collision] = []
        let installed = list()

        for pack in installed where pack.manifest.name != incoming.name {
            for skill in incoming.skills where pack.manifest.skills.contains(skill) {
                collisions.append(.skillName(skill, conflictingPack: pack.manifest.name))
            }
            if let key = incomingScopeKey, let installedPolicy = pack.manifest.policy {
                let installedFragmentURL = pack.installDir
                    .appendingPathComponent(installedPolicy)
                if let fragment = try? HookRouterFragmentParser.load(from: installedFragmentURL),
                   fragment.scopeKey == key {
                    collisions.append(
                        .policyScopeKey(key, conflictingPack: pack.manifest.name))
                }
            }
            if let filename = incomingContextFilename,
               let installedContext = pack.manifest.context {
                let installedFilename = (installedContext as NSString).lastPathComponent
                if installedFilename == filename {
                    collisions.append(
                        .contextFilename(filename, conflictingPack: pack.manifest.name))
                }
            }
        }

        return collisions
    }
}
