import Foundation

/// V.9a — FilesystemArtifactProvider.
///
/// Walks `<home>/.senkani/artifacts/` and projects each file onto the
/// ArtifactRecord shape. Creates the directory on first access with
/// mode 0700 (owner-only).
///
/// Filename convention:
///   - Unversioned: `<base>.<ext>` → version 1, no predecessor.
///   - Versioned:   `<base>.v<N>.<ext>` → version N. Predecessor is
///                  `<base>.v<N-1>.<ext>` when present, else nil.
///   - Sidecar tags: `<base>.v<N>.tags` or `<base>.tags`. One tag
///                   per line. Empty set when absent.
///
/// Lineage: filename convention IS the lineage record. `versions(of:)`
/// returns the chain in chronological order (v1 → v2 → … → vN).
public struct FilesystemArtifactProvider: ArtifactSourceProvider {

    public let sourcePane: ArtifactSourcePane = .filesystem
    public let home: String?

    public init(home: String? = nil) {
        self.home = home
    }

    public var artifactsDirectory: String {
        let base = home ?? NSHomeDirectory()
        return "\(base)/.senkani/artifacts"
    }

    /// Idempotent. Mode 0700 on every call.
    @discardableResult
    public func ensureDirectory() -> Bool {
        let dir = artifactsDirectory
        let fm = FileManager.default
        if !fm.fileExists(atPath: dir) {
            do {
                try fm.createDirectory(
                    atPath: dir,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
            } catch {
                return false
            }
        }
        // Defense-in-depth: re-chmod on every ensureDirectory, in case
        // the directory was created with default perms by an older
        // version or hand-modified.
        _ = chmod(dir, 0o700)
        return true
    }

    public func list() -> [ArtifactRecord] {
        ensureDirectory()
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(
            at: URL(fileURLWithPath: artifactsDirectory),
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var out: [ArtifactRecord] = []
        for url in urls.sorted(by: { $0.path < $1.path })
            where url.pathExtension != "tags" {
            let filename = url.lastPathComponent
            let parsed = parseFilename(filename)
            let attrs = try? fm.attributesOfItem(atPath: url.path)
            let mtime = (attrs?[.modificationDate] as? Date) ?? Date(timeIntervalSince1970: 0)
            let id = ArtifactID(
                sourcePane: .filesystem,
                surfaceKey: parsed.base,
                rowOrPath: filename
            )
            let prev: ArtifactID? = {
                guard parsed.version > 1 else { return nil }
                let prevFilename = "\(parsed.base).v\(parsed.version - 1).\(parsed.ext)"
                let prevPath = "\(artifactsDirectory)/\(prevFilename)"
                guard fm.fileExists(atPath: prevPath) else { return nil }
                return ArtifactID(
                    sourcePane: .filesystem,
                    surfaceKey: parsed.base,
                    rowOrPath: prevFilename
                )
            }()
            let tags = readSidecarTags(filename: filename)
            let record = ArtifactRecord(
                id: id,
                sourcePane: .filesystem,
                tags: tags,
                version: parsed.version,
                createdAt: mtime,
                previousVersion: prev,
                redactionMarker: nil
            )
            out.append(record)
        }
        return out
    }

    public func read(_ id: ArtifactID) throws -> ArtifactBody {
        let filename = parseFilenameFromId(id)
        guard !filename.isEmpty else { throw ArtifactReadError.notFound(id: id) }
        let path = "\(artifactsDirectory)/\(filename)"
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            throw ArtifactReadError.notFound(id: id)
        }
        return ArtifactBody(bytes: data)
    }

    public func versions(of id: ArtifactID) -> [ArtifactRecord] {
        let filename = parseFilenameFromId(id)
        guard !filename.isEmpty else { return [] }
        let parsed = parseFilename(filename)
        // Walk all files in the same base group; return chain in
        // chronological order (v1 → vN).
        let all = list()
        let chain = all.filter { record in
            let f = parseFilenameFromId(record.id)
            let p = parseFilename(f)
            return p.base == parsed.base
        }
        return chain.sorted { $0.version < $1.version }
    }

    // MARK: - Filename parsing

    private struct ParsedFilename {
        let base: String
        let version: Int
        let ext: String
    }

    /// Parses `<base>.v<N>.<ext>` or `<base>.<ext>`.
    /// Returns version 1 + extracted base for the unversioned form.
    private func parseFilename(_ filename: String) -> ParsedFilename {
        // Strip trailing `.ext` segment first.
        let dotComponents = filename.split(separator: ".", omittingEmptySubsequences: false)
        guard dotComponents.count >= 2 else {
            return ParsedFilename(base: filename, version: 1, ext: "")
        }
        let ext = String(dotComponents.last ?? "")
        let withoutExt = dotComponents.dropLast().joined(separator: ".")
        // Detect `…v<N>` trailing segment.
        let pieces = withoutExt.split(separator: ".", omittingEmptySubsequences: false)
        if let last = pieces.last,
           last.hasPrefix("v"),
           let v = Int(last.dropFirst()),
           v >= 1 {
            let base = pieces.dropLast().joined(separator: ".")
            if !base.isEmpty {
                return ParsedFilename(base: base, version: v, ext: ext)
            }
        }
        return ParsedFilename(base: withoutExt, version: 1, ext: ext)
    }

    private func parseFilenameFromId(_ id: ArtifactID) -> String {
        // ID shape: "filesystem:<base>:<filename>"
        let parts = id.raw.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count >= 3, parts[0] == "filesystem" else { return "" }
        return parts[2...].joined(separator: ":")
    }

    private func readSidecarTags(filename: String) -> Set<String> {
        // Sidecar pattern: replace ext with "tags".
        // For unversioned `notes.md`           → `notes.tags`.
        // For versioned   `notes.v2.md`        → `notes.v2.tags`.
        // For explicit-v1 `notes.v1.md`        → tries both `notes.v1.tags` THEN `notes.tags`.
        let parsed = parseFilename(filename)
        let candidates: [String] = {
            var out = ["\(parsed.base).v\(parsed.version).tags"]
            if parsed.version == 1 { out.append("\(parsed.base).tags") }
            return out
        }()
        for sidecarName in candidates {
            let path = "\(artifactsDirectory)/\(sidecarName)"
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                  let raw = String(data: data, encoding: .utf8) else {
                continue
            }
            let lines = raw.split(whereSeparator: { $0.isNewline })
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            return Set(lines)
        }
        return []
    }
}
