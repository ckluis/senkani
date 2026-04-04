import Foundation

/// Type of discovered skill/tool.
public enum SkillType: String, Codable, Sendable, CaseIterable {
    case command
    case hook
    case rule
    case skill
}

/// Information about a discovered AI tool skill or plugin.
public struct SkillInfo: Identifiable, Codable, Sendable {
    public var id: String
    public var name: String
    public var description: String
    public var source: String       // "claude", "cursor", "continue", "project"
    public var filePath: String
    public var type: SkillType

    public init(id: String, name: String, description: String, source: String, filePath: String, type: SkillType) {
        self.id = id
        self.name = name
        self.description = description
        self.source = source
        self.filePath = filePath
        self.type = type
    }
}

/// Scans the filesystem for AI tool skills, plugins, and configuration files.
public final class SkillScanner: Sendable {

    public init() {}

    /// Maximum directory depth for recursive scans to prevent runaway traversal.
    private static let maxScanDepth = 10

    /// Asynchronous scan with cancellation support. Prefer this over the synchronous
    /// variant when calling from the main thread or UI code.
    public static func scanAsync() async -> [SkillInfo] {
        await Task.detached(priority: .utility) {
            scan()
        }.value
    }

    /// Synchronously scan all known directories and return discovered skills.
    /// FIXME: Call scanAsync() from UI code to avoid blocking the main thread
    /// if dotfile directories are large.
    public static func scan() -> [SkillInfo] {
        var skills: [SkillInfo] = []
        let fm = FileManager.default
        let home = NSHomeDirectory()

        // 1. Claude Code: ~/.claude/
        let claudeDir = (home as NSString).appendingPathComponent(".claude")
        skills.append(contentsOf: scanClaudeDir(claudeDir, fm: fm))

        // 2. Cursor: ~/.cursor/
        let cursorDir = (home as NSString).appendingPathComponent(".cursor")
        skills.append(contentsOf: scanCursorDir(cursorDir, fm: fm))

        // 3. Continue.dev: ~/.continue/
        let continueDir = (home as NSString).appendingPathComponent(".continue")
        skills.append(contentsOf: scanContinueDir(continueDir, fm: fm))

        // 4. Project-level files in current directory
        let cwd = fm.currentDirectoryPath
        skills.append(contentsOf: scanProjectDir(cwd, fm: fm))

        // Deduplicate: prefer project-local over global.
        // Key by lowercased name + type to catch the same skill found in multiple locations.
        let sourcePriority: [String: Int] = ["project": 0, "claude": 1, "cursor": 2, "continue": 3]
        var seen: [String: Int] = [:]  // dedup key -> index in deduped array
        var deduped: [SkillInfo] = []

        for skill in skills {
            let key = "\(skill.name.lowercased())|\(skill.type.rawValue)"
            let priority = sourcePriority[skill.source.lowercased()] ?? 99

            if let existingIndex = seen[key] {
                let existingPriority = sourcePriority[deduped[existingIndex].source.lowercased()] ?? 99
                if priority < existingPriority {
                    // Replace with higher-priority (lower number) source
                    deduped[existingIndex] = skill
                }
            } else {
                seen[key] = deduped.count
                deduped.append(skill)
            }
        }

        // Sort by source then name
        return deduped.sorted { a, b in
            if a.source != b.source { return a.source < b.source }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    // MARK: - Claude

    private static func scanClaudeDir(_ dir: String, fm: FileManager) -> [SkillInfo] {
        guard fm.fileExists(atPath: dir) else { return [] }
        var skills: [SkillInfo] = []

        // Commands in ~/.claude/commands/
        let commandsDir = (dir as NSString).appendingPathComponent("commands")
        if let files = try? fm.contentsOfDirectory(atPath: commandsDir) {
            for file in files where file.hasSuffix(".md") {
                let path = (commandsDir as NSString).appendingPathComponent(file)
                let name = (file as NSString).deletingPathExtension
                let desc = parseDescription(atPath: path)
                skills.append(SkillInfo(
                    id: "claude-cmd-\(name)",
                    name: name,
                    description: desc,
                    source: "claude",
                    filePath: path,
                    type: .command
                ))
            }
        }

        // Nested project command dirs: ~/.claude/commands/<project>/
        if let entries = try? fm.contentsOfDirectory(atPath: commandsDir) {
            for entry in entries {
                let subdir = (commandsDir as NSString).appendingPathComponent(entry)
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: subdir, isDirectory: &isDir), isDir.boolValue {
                    if let subfiles = try? fm.contentsOfDirectory(atPath: subdir) {
                        for file in subfiles where file.hasSuffix(".md") {
                            let path = (subdir as NSString).appendingPathComponent(file)
                            let name = (file as NSString).deletingPathExtension
                            let desc = parseDescription(atPath: path)
                            skills.append(SkillInfo(
                                id: "claude-cmd-\(entry)-\(name)",
                                name: "\(entry)/\(name)",
                                description: desc,
                                source: "claude",
                                filePath: path,
                                type: .command
                            ))
                        }
                    }
                }
            }
        }

        // SKILL.md files — scan recursively under ~/.claude/
        scanRecursive(dir: dir, filename: "SKILL.md", fm: fm) { path in
            let (name, desc) = parseSkillMd(atPath: path)
            skills.append(SkillInfo(
                id: "claude-skill-\(name)",
                name: name,
                description: desc,
                source: "claude",
                filePath: path,
                type: .skill
            ))
        }

        // Hooks — look for settings.json with hooks
        let settingsPath = (dir as NSString).appendingPathComponent("settings.json")
        if fm.fileExists(atPath: settingsPath) {
            skills.append(SkillInfo(
                id: "claude-hooks-settings",
                name: "Claude Settings (hooks)",
                description: "Claude Code settings including hooks configuration",
                source: "claude",
                filePath: settingsPath,
                type: .hook
            ))
        }

        return skills
    }

    // MARK: - Cursor

    private static func scanCursorDir(_ dir: String, fm: FileManager) -> [SkillInfo] {
        guard fm.fileExists(atPath: dir) else { return [] }
        var skills: [SkillInfo] = []

        // Rules in ~/.cursor/rules/
        let rulesDir = (dir as NSString).appendingPathComponent("rules")
        if let files = try? fm.contentsOfDirectory(atPath: rulesDir) {
            for file in files where file.hasSuffix(".md") || file.hasSuffix(".mdc") {
                let path = (rulesDir as NSString).appendingPathComponent(file)
                let name = (file as NSString).deletingPathExtension
                let desc = parseDescription(atPath: path)
                skills.append(SkillInfo(
                    id: "cursor-rule-\(name)",
                    name: name,
                    description: desc,
                    source: "cursor",
                    filePath: path,
                    type: .rule
                ))
            }
        }

        return skills
    }

    // MARK: - Continue.dev

    private static func scanContinueDir(_ dir: String, fm: FileManager) -> [SkillInfo] {
        guard fm.fileExists(atPath: dir) else { return [] }
        var skills: [SkillInfo] = []

        // config.json
        let configPath = (dir as NSString).appendingPathComponent("config.json")
        if fm.fileExists(atPath: configPath) {
            skills.append(SkillInfo(
                id: "continue-config",
                name: "Continue Config",
                description: "Continue.dev IDE extension configuration",
                source: "continue",
                filePath: configPath,
                type: .rule
            ))
        }

        // config.ts
        let configTsPath = (dir as NSString).appendingPathComponent("config.ts")
        if fm.fileExists(atPath: configTsPath) {
            skills.append(SkillInfo(
                id: "continue-config-ts",
                name: "Continue Config (TS)",
                description: "Continue.dev TypeScript configuration",
                source: "continue",
                filePath: configTsPath,
                type: .rule
            ))
        }

        // Plugins in ~/.continue/plugins/
        let pluginsDir = (dir as NSString).appendingPathComponent("plugins")
        if let files = try? fm.contentsOfDirectory(atPath: pluginsDir) {
            for file in files {
                let path = (pluginsDir as NSString).appendingPathComponent(file)
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
                    skills.append(SkillInfo(
                        id: "continue-plugin-\(file)",
                        name: file,
                        description: "Continue.dev plugin",
                        source: "continue",
                        filePath: path,
                        type: .skill
                    ))
                }
            }
        }

        return skills
    }

    // MARK: - Project-level

    private static func scanProjectDir(_ dir: String, fm: FileManager) -> [SkillInfo] {
        var skills: [SkillInfo] = []

        let projectFiles: [(String, String, SkillType)] = [
            ("CLAUDE.md", "Claude Code project instructions", .rule),
            (".cursorrules", "Cursor project rules", .rule),
            (".cursorignore", "Cursor ignore rules", .rule),
            (".continue/config.json", "Continue project config", .rule),
        ]

        for (filename, desc, type) in projectFiles {
            let path = (dir as NSString).appendingPathComponent(filename)
            if fm.fileExists(atPath: path) {
                let source = filename.lowercased().contains("claude") ? "claude"
                    : filename.lowercased().contains("cursor") ? "cursor"
                    : "continue"
                skills.append(SkillInfo(
                    id: "project-\(filename)",
                    name: filename,
                    description: "\(desc) (project-level)",
                    source: source,
                    filePath: path,
                    type: type
                ))
            }
        }

        // Project-level commands: .claude/commands/
        let projectCmdsDir = (dir as NSString).appendingPathComponent(".claude/commands")
        if let files = try? fm.contentsOfDirectory(atPath: projectCmdsDir) {
            for file in files where file.hasSuffix(".md") {
                let path = (projectCmdsDir as NSString).appendingPathComponent(file)
                let name = (file as NSString).deletingPathExtension
                let desc = parseDescription(atPath: path)
                skills.append(SkillInfo(
                    id: "project-cmd-\(name)",
                    name: "/\(name)",
                    description: desc,
                    source: "claude",
                    filePath: path,
                    type: .command
                ))
            }
        }

        return skills
    }

    // MARK: - Parsing Helpers

    /// Extract the first non-empty, non-heading line as a description.
    private static func parseDescription(atPath path: String) -> String {
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else {
            return "No description available"
        }
        let lines = content.components(separatedBy: .newlines)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") || trimmed.hasPrefix("---") { continue }
            // Return the first real content line, capped at 200 chars
            return String(trimmed.prefix(200))
        }
        return "No description available"
    }

    /// Parse a SKILL.md file for name and description from frontmatter.
    private static func parseSkillMd(atPath path: String) -> (name: String, description: String) {
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else {
            let fallback = ((path as NSString).deletingLastPathComponent as NSString).lastPathComponent
            return (fallback, "No description available")
        }

        var name: String?
        var description: String?

        let lines = content.components(separatedBy: .newlines)
        var inFrontmatter = false

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "---" {
                if !inFrontmatter { inFrontmatter = true; continue }
                else { break }
            }
            if inFrontmatter {
                if trimmed.lowercased().hasPrefix("name:") {
                    name = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)
                } else if trimmed.lowercased().hasPrefix("description:") {
                    description = trimmed.dropFirst(12).trimmingCharacters(in: .whitespaces)
                }
            }
        }

        // Fallback: use directory name and first content line
        if name == nil {
            name = ((path as NSString).deletingLastPathComponent as NSString).lastPathComponent
        }
        if description == nil {
            description = parseDescription(atPath: path)
        }

        return (name ?? "Unknown", description ?? "No description available")
    }

    /// Recursively find files with a specific name.
    /// Guards against symlink loops by resolving real paths and tracking visited directories.
    /// Enforces maxScanDepth to prevent runaway traversal in deeply nested structures.
    private static func scanRecursive(dir: String, filename: String, fm: FileManager, handler: (String) -> Void) {
        guard let enumerator = fm.enumerator(
            at: URL(fileURLWithPath: dir),
            includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey],
            options: [.skipsPackageDescendants]
        ) else { return }

        var visitedRealPaths: Set<String> = []
        let realRoot = URL(fileURLWithPath: dir).resolvingSymlinksInPath().path
        visitedRealPaths.insert(realRoot)

        while let url = enumerator.nextObject() as? URL {
            // Enforce depth limit
            let relativeComponents = url.pathComponents.count - URL(fileURLWithPath: dir).pathComponents.count
            if relativeComponents > maxScanDepth {
                enumerator.skipDescendants()
                continue
            }

            // Detect symlink loops by resolving real paths for directories
            let resourceValues = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
            if resourceValues?.isDirectory == true {
                let realPath = url.resolvingSymlinksInPath().path
                if visitedRealPaths.contains(realPath) {
                    enumerator.skipDescendants()
                    continue
                }
                visitedRealPaths.insert(realPath)
            }

            if url.lastPathComponent == filename {
                handler(url.path)
            }
        }
    }
}
