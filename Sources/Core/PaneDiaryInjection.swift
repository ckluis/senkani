import Foundation

/// Glue between `PaneDiaryStore` (I/O half) + `PaneDiaryGenerator`
/// (composition half) and the MCP subprocess — round 3 of 3 under the
/// `pane-diaries-cross-session-memory` umbrella.
///
/// MCPSession lives in the MCPServer target, which pulls heavy ML
/// dependencies and is hard to cover from SenkaniTests. So the
/// env-read + disk-read logic lives here in Core where it can be
/// fixture-driven (every entry point takes explicit `env:` + `home:`
/// overrides). MCPSession stays a thin caller.
///
/// Two entry points:
///   - ``instructionsSection(env:home:)``    — called on MCP server
///     start to inject the prior diary into the instructions payload
///   - ``persist(rows:env:home:lastError:)`` — called on MCP server
///     shutdown to regenerate + write the diary for next time
///
/// Both are no-ops when the env gate `SENKANI_PANE_DIARY=off` is set,
/// when the `SENKANI_WORKSPACE_SLUG` / `SENKANI_PANE_SLUG` env vars are
/// missing/empty, or when the underlying store throws (malformed slug,
/// write failure, …) — the pane-open path must not block on diary
/// issues per the round-3 acceptance.
public enum PaneDiaryInjection {

    /// Caller-supplied env var naming the workspace (project) the pane
    /// belongs to. Combined with `paneSlugEnvVar` to key the diary on
    /// disk. SenkaniApp sets this when it spawns the MCP subprocess.
    public static let workspaceSlugEnvVar = "SENKANI_WORKSPACE_SLUG"

    /// Caller-supplied env var naming the pane slot (stable across
    /// pane-id recycles). Typically `PaneType.rawValue` — reopens of
    /// the same pane type in the same workspace surface the same
    /// diary.
    public static let paneSlugEnvVar = "SENKANI_PANE_SLUG"

    /// Section header prepended to the diary body when it's injected
    /// into the MCP instructions payload. Kept short so the truncation
    /// marker in `MCPSession.instructionsPayload` has budget headroom.
    public static let sectionHeader = "Pane context:"

    // MARK: - Read side (pane-open)

    /// Load the prior diary for the slug pair in `env` and return it
    /// as a formatted instructions section. Returns `""` when:
    ///   - `SENKANI_PANE_DIARY=off` (case-insensitive)
    ///   - either slug env var is missing, empty, or invalid
    ///   - no diary exists on disk
    ///   - reading the diary throws (degrade to no brief — pane-open
    ///     must never hang on a bad diary, per round-3 acceptance)
    ///
    /// The returned string (when non-empty) starts with `\n\n` so the
    /// caller can concatenate it into the MCP instructions payload
    /// without needing a separator of its own.
    public static func instructionsSection(
        env: [String: String]? = nil,
        home: String? = nil
    ) -> String {
        guard PaneDiaryStore.isEnabled(env: env) else { return "" }
        let resolved = env ?? ProcessInfo.processInfo.environment
        guard let ws = slug(resolved[workspaceSlugEnvVar]),
              let pane = slug(resolved[paneSlugEnvVar]) else { return "" }

        let content: String?
        do {
            content = try PaneDiaryStore.read(
                workspaceSlug: ws, paneSlug: pane, home: home, env: env
            )
        } catch {
            return ""  // malformed slug / read failure — degrade silently
        }
        guard let body = content, !body.isEmpty else { return "" }
        return "\n\n\(sectionHeader)\n" + body
    }

    // MARK: - Write side (pane-close / session-end)

    /// Regenerate a diary for the slug pair in `env` from `rows` and
    /// persist it via `PaneDiaryStore.write`. No-op when:
    ///   - `SENKANI_PANE_DIARY=off`
    ///   - either slug env var is missing, empty, or invalid
    ///   - the generator returns an empty brief (no rows + no error)
    ///   - the underlying write throws (best-effort — pane-close
    ///     should never hang waiting on disk)
    ///
    /// Returns `true` if a diary was written, `false` otherwise. The
    /// return value is primarily for test assertions; callers can
    /// safely ignore it.
    @discardableResult
    public static func persist(
        rows: [SessionDatabase.TimelineEvent],
        env: [String: String]? = nil,
        home: String? = nil,
        lastError: String? = nil
    ) -> Bool {
        guard PaneDiaryStore.isEnabled(env: env) else { return false }
        let resolved = env ?? ProcessInfo.processInfo.environment
        guard let ws = slug(resolved[workspaceSlugEnvVar]),
              let pane = slug(resolved[paneSlugEnvVar]) else { return false }

        let brief = PaneDiaryGenerator.generate(
            rows: rows, paneSlug: pane, lastError: lastError
        )
        guard !brief.isEmpty else { return false }

        do {
            try PaneDiaryStore.write(
                brief, workspaceSlug: ws, paneSlug: pane, home: home, env: env
            )
            return true
        } catch {
            return false
        }
    }

    // MARK: - Helpers

    /// Normalize a slug env value: trim whitespace, reject empty. The
    /// `PaneDiaryStore` does its own hard validation against `..`,
    /// `/`, `\` — this pre-check just avoids the throw path for the
    /// very common "env var not set" case.
    private static func slug(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
