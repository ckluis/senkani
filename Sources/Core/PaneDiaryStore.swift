import Foundation

/// Pane diary I/O half of the `pane-diaries-cross-session-memory` feature.
///
/// Round 1 of 3: this file owns the disk contract. Round 2 lands the
/// `PaneDiaryGenerator` (composition from token_events), round 3 wires
/// generator + store into the pane-open MCP path.
///
/// Disk layout: `~/.senkani/diaries/<workspaceSlug>/<paneSlug>.md`.
/// Workspace + pane slugs are caller-supplied identifiers that outlive
/// pane-id recycles (pane-open generates ephemeral ids; the slug pair
/// is the stable cross-session key).
///
/// Safety invariants:
///   - Every `read`/`write`/`delete` short-circuits when the env gate
///     `SENKANI_PANE_DIARY=off` is set (case-insensitive).
///   - Every write passes content through `SecretDetector.scan`.
///   - Every read re-scans before returning — defense-in-depth for
///     diaries written by older versions or hand-edited on disk.
///   - Slugs are hard-rejected if they contain `..`, `/`, `\`, or are
///     empty after trim. Callers get a throw, not silent coercion —
///     path-traversal inputs are caller bugs that should surface loudly.
///   - Writes land at mode 0600 (owner-only read/write). Diaries are
///     user-local data on a potentially multi-user machine and the
///     redaction regex is not a complete defense.
///   - Writes go temp-file → rename so a crashed or permission-denied
///     write cannot corrupt an existing diary.
public enum PaneDiaryStore {

    // MARK: - Env gate

    /// Env var consulted by `isEnabled(env:)`. Default ON: the feature
    /// is disabled only when the variable is set to `"off"` (case
    /// insensitive).
    public static let envVarName = "SENKANI_PANE_DIARY"

    /// Returns false when `SENKANI_PANE_DIARY=off` (case-insensitive),
    /// true otherwise. An unset var keeps the feature enabled.
    public static func isEnabled(env: [String: String]? = nil) -> Bool {
        let value: String?
        if let env {
            value = env[envVarName]
        } else {
            value = ProcessInfo.processInfo.environment[envVarName]
        }
        guard let v = value?.lowercased() else { return true }
        return v != "off"
    }

    // MARK: - Errors

    public enum StoreError: Error, Equatable {
        /// Slug failed validation — empty, or contains `..`, `/`, `\`.
        case invalidSlug(field: String, value: String)
        /// Underlying write failed (disk full, permission denied, …).
        case writeFailed(path: String)
    }

    // MARK: - Public API

    /// Read + SecretDetector-scan the diary at the slug pair. Returns
    /// nil when the env gate is off, when no diary exists, or when the
    /// file cannot be read. Defense-in-depth: the on-disk content is
    /// re-scanned before being returned, so a hand-edited or
    /// older-version diary containing a fresh secret still redacts.
    public static func read(
        workspaceSlug: String,
        paneSlug: String,
        home: String? = nil,
        env: [String: String]? = nil
    ) throws -> String? {
        guard isEnabled(env: env) else { return nil }
        try validate(workspaceSlug, field: "workspaceSlug")
        try validate(paneSlug, field: "paneSlug")
        let path = diaryPath(
            workspaceSlug: workspaceSlug,
            paneSlug: paneSlug,
            home: home
        )
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let raw = String(data: data, encoding: .utf8) else {
            return nil
        }
        return SecretDetector.scan(raw).redacted
    }

    /// Scan, write atomically, chmod 0600. A no-op when the env gate
    /// is off. Parent directory is created on demand so first writes
    /// for a fresh workspace slug don't require bootstrap.
    public static func write(
        _ content: String,
        workspaceSlug: String,
        paneSlug: String,
        home: String? = nil,
        env: [String: String]? = nil
    ) throws {
        guard isEnabled(env: env) else { return }
        try validate(workspaceSlug, field: "workspaceSlug")
        try validate(paneSlug, field: "paneSlug")

        let redacted = SecretDetector.scan(content).redacted
        let path = diaryPath(
            workspaceSlug: workspaceSlug,
            paneSlug: paneSlug,
            home: home
        )
        let url = URL(fileURLWithPath: path)
        let dir = url.deletingLastPathComponent()

        try? FileManager.default.createDirectory(
            at: dir,
            withIntermediateDirectories: true
        )

        let tmp = dir.appendingPathComponent(
            ".\(url.lastPathComponent).tmp.\(ProcessInfo.processInfo.processIdentifier)"
        )
        do {
            try Data(redacted.utf8).write(to: tmp, options: .atomic)
        } catch {
            throw StoreError.writeFailed(path: path)
        }

        // Rename is atomic on a single filesystem (~/.senkani/ always is
        // in practice). `replaceItemAt` handles the pre-existing-file
        // case; `moveItem` is the first-write path.
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
            } else {
                try FileManager.default.moveItem(at: tmp, to: url)
            }
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            throw StoreError.writeFailed(path: path)
        }

        // Mode 0600 — owner-only read/write. Mirrors `SocketAuthToken`.
        _ = chmod(path, 0o600)
    }

    /// Remove the diary at the slug pair. No-op when env-gated off or
    /// when the file is already absent.
    public static func delete(
        workspaceSlug: String,
        paneSlug: String,
        home: String? = nil,
        env: [String: String]? = nil
    ) throws {
        guard isEnabled(env: env) else { return }
        try validate(workspaceSlug, field: "workspaceSlug")
        try validate(paneSlug, field: "paneSlug")
        let path = diaryPath(
            workspaceSlug: workspaceSlug,
            paneSlug: paneSlug,
            home: home
        )
        if FileManager.default.fileExists(atPath: path) {
            try? FileManager.default.removeItem(atPath: path)
        }
    }

    // MARK: - Path derivation

    /// `~/.senkani/diaries/<workspaceSlug>/<paneSlug>.md` — split out
    /// so tests can assert the layout directly.
    public static func diaryPath(
        workspaceSlug: String,
        paneSlug: String,
        home: String? = nil
    ) -> String {
        let base = home ?? NSHomeDirectory()
        return base + "/.senkani/diaries/\(workspaceSlug)/\(paneSlug).md"
    }

    // MARK: - Validation

    /// Hard-reject path-traversal and empty slugs. Trimming is done
    /// before the emptiness check so whitespace-only slugs fail.
    private static func validate(_ slug: String, field: String) throws {
        let trimmed = slug.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty
            || slug.contains("..")
            || slug.contains("/")
            || slug.contains("\\") {
            throw StoreError.invalidSlug(field: field, value: slug)
        }
    }
}
