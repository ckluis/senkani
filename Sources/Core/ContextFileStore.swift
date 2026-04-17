import Foundation

// MARK: - ContextFileStore
//
// Phase H+2b — disk backing for applied `LearnedContextDoc`s.
// `.senkani/context/<title>.md` is where priming documents land once
// the operator applies them. Operators may hand-edit these files; the
// next session's brief injection reads them as-is (minus a secret
// re-scan at read time, belt + suspenders).
//
// Why a separate directory from `.senkani/knowledge/`:
//   - Evans: different aggregate root. KB entities are extracted from
//     source code; context docs are extracted from behavioral telemetry.
//     Keeping them separate preserves the bounded context.
//   - Operators can `git add .senkani/context/` selectively without
//     committing the KB's SQLite-derived markdown copies.
//   - F+1 (Layer-1-as-source-of-truth) applies only to KB entities
//     (Round 4); context docs get it for free now (Layer 2 is just
//     the JSON file; disk .md is the only canonical form).

public enum ContextFileStore {

    /// Directory under project root where applied context docs live.
    public static let dirName: String = ".senkani/context"

    public static func directory(for projectRoot: String) -> String {
        projectRoot + "/" + dirName
    }

    public static func pathFor(projectRoot: String, doc: LearnedContextDoc) -> String {
        directory(for: projectRoot) + "/" + doc.title + ".md"
    }

    /// Write an applied doc to disk. Sanitizes body again at write time
    /// (SecretDetector runs on every public entry point — init, decode,
    /// disk write — so a hand-fabricated doc can't smuggle secrets
    /// past the on-disk rescan). Atomic write via temp + rename.
    public static func write(
        doc: LearnedContextDoc,
        projectRoot: String,
        now: Date = Date()
    ) throws {
        let dir = directory(for: projectRoot)
        try FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true)

        let path = pathFor(projectRoot: projectRoot, doc: doc)
        let sanitizedBody = LearnedContextDoc.sanitizeBody(doc.body)

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        let header = "<!-- senkani context doc · id=\(doc.id) · applied=\(iso.string(from: now)) -->\n\n"
        let content = header + sanitizedBody
        try content.write(
            toFile: path, atomically: true, encoding: .utf8)
    }

    /// Read an applied doc's current on-disk markdown. Runs a secret
    /// scan at read time too — a file hand-edited to include a secret
    /// doesn't leak through. Returns nil when the file doesn't exist.
    public static func read(
        projectRoot: String,
        title: String
    ) -> String? {
        let path = directory(for: projectRoot) + "/" + LearnedContextDoc.sanitizeTitle(title) + ".md"
        guard let raw = try? String(contentsOfFile: path, encoding: .utf8) else {
            return nil
        }
        return LearnedContextDoc.sanitizeBody(raw)
    }

    /// Remove the on-disk file (e.g., on rejection of a previously-applied doc).
    public static func remove(projectRoot: String, title: String) {
        let safeTitle = LearnedContextDoc.sanitizeTitle(title)
        let path = directory(for: projectRoot) + "/" + safeTitle + ".md"
        try? FileManager.default.removeItem(atPath: path)
    }
}
