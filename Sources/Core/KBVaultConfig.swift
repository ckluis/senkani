import Foundation

// MARK: - KBVaultConfig
//
// V.7 — externalize KB markdown vault to a configurable path so the
// operator can keep their KB next to other Obsidian vaults instead of
// inside the project tree.
//
// Resolution order (cheapest first; nil at any layer falls through):
//
//   1. SENKANI_KB_VAULT_ROOT env var               (test override)
//   2. ~/.senkani/config.json   "kb_vault_path"    (operator opt-in)
//   3. <projectRoot>/.senkani/knowledge            (default — preserves
//                                                  existing behavior)
//
// When (1) or (2) yield a vault root, the resolved per-project dir is
// `<vault_root>/<project-slug>` so multiple projects don't collide on
// entity name. The slug is the projectRoot's last path component, with
// non-alphanum characters replaced by `-`.

public enum KBVaultConfig {

    // MARK: - Public API

    /// Resolved knowledge directory for a given project.
    /// Returns the per-project default when no global config exists,
    /// or `<vault_root>/<project-slug>` when one is set.
    /// `configPath` defaults to `~/.senkani/config.json`; tests pass an alt path.
    public static func resolvedVaultDir(
        projectRoot: String, configPath: String? = nil
    ) -> String {
        // getenv reads the current environment (ProcessInfo.environment is a snapshot
        // from process start, so tests using setenv would never see the override).
        if let raw = getenv("SENKANI_KB_VAULT_ROOT") {
            let envRoot = String(cString: raw)
            if !envRoot.isEmpty { return joined(envRoot, slug(projectRoot)) }
        }
        if let configRoot = readConfiguredVaultRoot(configPath: configPath) {
            return joined(configRoot, slug(projectRoot))
        }
        return projectRoot + "/.senkani/knowledge"
    }

    /// True when the resolved vault dir lives outside `<projectRoot>/.senkani/knowledge`.
    public static func isExternalized(
        projectRoot: String, configPath: String? = nil
    ) -> Bool {
        let resolved = resolvedVaultDir(projectRoot: projectRoot, configPath: configPath)
        let defaultDir = projectRoot + "/.senkani/knowledge"
        return resolved != defaultDir
    }

    /// Persist `kb_vault_path` to `~/.senkani/config.json`. Creates the file if missing,
    /// preserves any other top-level keys, and uses an atomic write.
    /// Pass `nil` to clear the setting.
    public static func writeConfiguredVaultRoot(_ path: String?) throws {
        let configPath = userConfigPath()
        try ensureDir(URL(fileURLWithPath: configPath).deletingLastPathComponent().path)

        var dict: [String: Any] = [:]
        if FileManager.default.fileExists(atPath: configPath),
           let data = try? Data(contentsOf: URL(fileURLWithPath: configPath)),
           let parsed = try? JSONSerialization.jsonObject(with: data),
           let obj = parsed as? [String: Any] {
            dict = obj
        }

        if let p = path, !p.isEmpty {
            dict["kb_vault_path"] = p
        } else {
            dict.removeValue(forKey: "kb_vault_path")
        }

        let json = try JSONSerialization.data(
            withJSONObject: dict, options: [.prettyPrinted, .sortedKeys])
        try atomicWrite(json, to: configPath)
    }

    /// Path to `~/.senkani/config.json`. Exposed for tests and CLI messages.
    public static func userConfigPath() -> String {
        let home = NSHomeDirectory()
        return home + "/.senkani/config.json"
    }

    /// Read the configured `kb_vault_path` from `~/.senkani/config.json`. Returns nil if
    /// the file is missing, malformed, or the field is absent / non-string.
    /// Tilde-prefixed paths are expanded to the operator's home dir.
    /// `configPath` defaults to `~/.senkani/config.json`; tests inject a tmp path.
    public static func readConfiguredVaultRoot(configPath: String? = nil) -> String? {
        let path = configPath ?? userConfigPath()
        guard FileManager.default.fileExists(atPath: path),
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let parsed = try? JSONSerialization.jsonObject(with: data),
              let obj = parsed as? [String: Any],
              let raw = obj["kb_vault_path"] as? String,
              !raw.isEmpty
        else { return nil }
        return expandTilde(raw)
    }

    // MARK: - Helpers (internal but exposed for tests)

    /// Sanitize a project root into a filesystem-safe slug. Strips leading slashes,
    /// keeps the last path component, and replaces every non `[A-Za-z0-9._-]` char
    /// with `-`. Empty input returns `unknown`.
    public static func slug(_ projectRoot: String) -> String {
        let trimmed = projectRoot.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !trimmed.isEmpty else { return "unknown" }
        let last = (trimmed as NSString).lastPathComponent
        let basis = last.isEmpty ? trimmed : last
        let safe = String(basis.unicodeScalars.map { sc -> Character in
            let s = String(sc)
            let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
            return allowed.isSuperset(of: CharacterSet(charactersIn: s)) ? Character(s) : "-"
        })
        return safe.isEmpty ? "unknown" : safe
    }

    // MARK: - Private

    private static func joined(_ root: String, _ leaf: String) -> String {
        let trimmed = root.hasSuffix("/") ? String(root.dropLast()) : root
        return trimmed + "/" + leaf
    }

    private static func expandTilde(_ p: String) -> String {
        guard p.hasPrefix("~") else { return p }
        let home = NSHomeDirectory()
        if p == "~" { return home }
        if p.hasPrefix("~/") { return home + String(p.dropFirst(1)) }
        return p
    }

    private static func ensureDir(_ path: String) throws {
        try FileManager.default.createDirectory(
            atPath: path, withIntermediateDirectories: true, attributes: nil)
    }

    private static func atomicWrite(_ data: Data, to path: String) throws {
        let url = URL(fileURLWithPath: path)
        let tmp = url.deletingLastPathComponent().appendingPathComponent(
            ".\(url.lastPathComponent).tmp.\(ProcessInfo.processInfo.processIdentifier)")
        try data.write(to: tmp)
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) {
            _ = try fm.replaceItemAt(url, withItemAt: tmp)
        } else {
            try fm.moveItem(at: tmp, to: url)
        }
    }
}
