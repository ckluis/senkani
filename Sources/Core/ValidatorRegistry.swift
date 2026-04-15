import Foundation

/// A configured validator: a command that checks code for issues.
public struct ValidatorDef: Codable, Sendable {
    public let name: String          // "typecheck", "lint", "format", "security"
    public let language: String      // "swift", "python", etc.
    public let command: String       // binary to run
    public let args: [String]        // args before the file path
    public let extensions: [String]  // file extensions this applies to
    public let category: String      // "syntax", "type", "lint", "security", "format"
    public var enabled: Bool         // user toggle
    public var installed: Bool?      // nil = unchecked, true/false = detected

    public init(name: String, language: String, command: String, args: [String],
                extensions: [String], category: String, enabled: Bool = true, installed: Bool? = nil) {
        self.name = name
        self.language = language
        self.command = command
        self.args = args
        self.extensions = extensions
        self.category = category
        self.enabled = enabled
        self.installed = installed
    }
}

/// Registry of all available validators. Config-driven, auto-discovers what's installed.
public final class ValidatorRegistry: @unchecked Sendable {
    private var validators: [ValidatorDef]
    private let lock = NSLock()

    public init(validators: [ValidatorDef] = ValidatorRegistry.defaults) {
        self.validators = validators
    }

    /// Process-global shared registry for the hook path.
    /// Lazily initialized with auto-detection of installed validators.
    public static let shared: ValidatorRegistry = {
        let r = ValidatorRegistry()
        r.detectInstalled()
        return r
    }()

    // MARK: - Query

    /// Get all validators for a file extension, filtered to enabled + installed.
    public func validatorsFor(extension ext: String) -> [ValidatorDef] {
        lock.lock()
        defer { lock.unlock() }
        return validators.filter { $0.extensions.contains(ext) && $0.enabled && $0.installed == true }
    }

    /// Get all validators for a language name.
    public func validatorsFor(language: String) -> [ValidatorDef] {
        lock.lock()
        defer { lock.unlock() }
        return validators.filter { $0.language == language && $0.enabled && $0.installed == true }
    }

    /// List all validators with their status.
    public func all() -> [ValidatorDef] {
        lock.lock()
        defer { lock.unlock() }
        return validators
    }

    /// List available (installed) validators grouped by language.
    public func availableByLanguage() -> [String: [ValidatorDef]] {
        lock.lock()
        defer { lock.unlock() }
        let available = validators.filter { $0.installed == true }
        return Dictionary(grouping: available) { $0.language }
    }

    // MARK: - Mutation

    /// Enable or disable a validator by name.
    public func setEnabled(name: String, enabled: Bool) {
        lock.lock()
        defer { lock.unlock() }
        if let idx = validators.firstIndex(where: { $0.name == name }) {
            validators[idx].enabled = enabled
        }
    }

    /// Add a custom validator.
    public func add(_ validator: ValidatorDef) {
        lock.lock()
        defer { lock.unlock() }
        // Remove existing with same name if present
        validators.removeAll { $0.name == validator.name }
        validators.append(validator)
    }

    // MARK: - Auto-detection

    /// Scan PATH for installed tools and update the `installed` flag.
    public func detectInstalled() {
        lock.lock()
        var updated = validators
        lock.unlock()

        for i in updated.indices {
            updated[i].installed = isInstalled(updated[i].command)
        }

        lock.lock()
        validators = updated
        lock.unlock()
    }

    private func isInstalled(_ command: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = [command]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    // MARK: - Persistence

    /// Load from .senkani/config.json, merging with defaults.
    public static func load(projectRoot: String) -> ValidatorRegistry {
        let registry = ValidatorRegistry()
        let configPath = projectRoot + "/.senkani/config.json"

        if let data = FileManager.default.contents(atPath: configPath),
           let config = try? JSONDecoder().decode(RegistryConfig.self, from: data),
           let savedValidators = config.validators {
            // Merge: saved config overrides defaults (by name)
            var merged = registry.validators
            for saved in savedValidators {
                if let idx = merged.firstIndex(where: { $0.name == saved.name }) {
                    merged[idx].enabled = saved.enabled
                    merged[idx].installed = saved.installed
                } else {
                    merged.append(saved)
                }
            }
            registry.lock.lock()
            registry.validators = merged
            registry.lock.unlock()
        }

        registry.detectInstalled()
        return registry
    }

    /// Save current state to .senkani/config.json (merges with existing config).
    public func save(projectRoot: String) throws {
        let configPath = projectRoot + "/.senkani/config.json"
        let dir = (configPath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        // Read existing config to preserve non-validator fields
        var config: [String: Any] = [:]
        if let data = FileManager.default.contents(atPath: configPath),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            config = existing
        }

        // Encode validators
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        lock.lock()
        let validatorData = try encoder.encode(validators)
        lock.unlock()

        if let validatorJSON = try? JSONSerialization.jsonObject(with: validatorData) {
            config["validators"] = validatorJSON
        }

        let data = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: configPath))
    }

    /// Summary string for display.
    public func summaryString() -> String {
        lock.lock()
        let all = validators
        lock.unlock()

        let installed = all.filter { $0.installed == true }
        let enabled = installed.filter { $0.enabled }
        let byLang = Dictionary(grouping: installed) { $0.language }

        var lines: [String] = []
        lines.append("Validators: \(enabled.count) enabled / \(installed.count) installed / \(all.count) known")
        lines.append("")

        for lang in byLang.keys.sorted() {
            let tools = byLang[lang]!
            let toolStr = tools.map { v in
                let status = v.enabled ? "ON" : "off"
                return "\(v.name)(\(status))"
            }.joined(separator: ", ")
            lines.append("  \(lang.padding(toLength: 14, withPad: " ", startingAt: 0))\(toolStr)")
        }

        return lines.joined(separator: "\n")
    }

    struct RegistryConfig: Codable {
        let validators: [ValidatorDef]?
        let features: FeatureFlags?

        struct FeatureFlags: Codable {
            let filter: Bool?
            let secrets: Bool?
            let indexer: Bool?
        }
    }

    // MARK: - Defaults

    public static let defaults: [ValidatorDef] = [
        // Swift
        ValidatorDef(name: "swift-typecheck", language: "swift", command: "swiftc",
                     args: ["-typecheck"], extensions: ["swift"], category: "type"),
        ValidatorDef(name: "swiftlint", language: "swift", command: "swiftlint",
                     args: ["lint", "--quiet", "--path"], extensions: ["swift"], category: "lint", enabled: false),
        ValidatorDef(name: "swift-format-check", language: "swift", command: "swift-format",
                     args: ["lint", "--strict"], extensions: ["swift"], category: "format", enabled: false),

        // TypeScript / JavaScript
        ValidatorDef(name: "tsc", language: "typescript", command: "npx",
                     args: ["tsc", "--noEmit", "--pretty"], extensions: ["ts", "tsx"], category: "type"),
        ValidatorDef(name: "eslint", language: "typescript", command: "npx",
                     args: ["eslint", "--no-warn-ignored"], extensions: ["ts", "tsx", "js", "jsx"], category: "lint", enabled: false),
        ValidatorDef(name: "biome-check", language: "typescript", command: "npx",
                     args: ["biome", "check"], extensions: ["ts", "tsx", "js", "jsx", "json"], category: "lint", enabled: false),
        ValidatorDef(name: "node-check", language: "javascript", command: "node",
                     args: ["--check"], extensions: ["js", "mjs", "cjs"], category: "syntax"),

        // Python
        ValidatorDef(name: "python-compile", language: "python", command: "python3",
                     args: ["-m", "py_compile"], extensions: ["py"], category: "syntax"),
        ValidatorDef(name: "ruff", language: "python", command: "ruff",
                     args: ["check"], extensions: ["py"], category: "lint", enabled: false),
        ValidatorDef(name: "mypy", language: "python", command: "mypy",
                     args: [], extensions: ["py"], category: "type", enabled: false),
        ValidatorDef(name: "pyright", language: "python", command: "pyright",
                     args: [], extensions: ["py"], category: "type", enabled: false),
        ValidatorDef(name: "black-check", language: "python", command: "black",
                     args: ["--check", "--quiet"], extensions: ["py"], category: "format", enabled: false),
        ValidatorDef(name: "bandit", language: "python", command: "bandit",
                     args: ["-q"], extensions: ["py"], category: "security", enabled: false),

        // Go
        ValidatorDef(name: "go-vet", language: "go", command: "go",
                     args: ["vet"], extensions: ["go"], category: "lint"),
        ValidatorDef(name: "gofmt-check", language: "go", command: "gofmt",
                     args: ["-l"], extensions: ["go"], category: "format", enabled: false),
        ValidatorDef(name: "staticcheck", language: "go", command: "staticcheck",
                     args: [], extensions: ["go"], category: "lint", enabled: false),

        // Rust
        ValidatorDef(name: "cargo-check", language: "rust", command: "cargo",
                     args: ["check", "--message-format=short"], extensions: ["rs"], category: "type"),
        ValidatorDef(name: "clippy", language: "rust", command: "cargo",
                     args: ["clippy", "--message-format=short"], extensions: ["rs"], category: "lint", enabled: false),
        ValidatorDef(name: "cargo-audit", language: "rust", command: "cargo",
                     args: ["audit"], extensions: ["rs"], category: "security", enabled: false),

        // Ruby
        ValidatorDef(name: "ruby-check", language: "ruby", command: "ruby",
                     args: ["-c"], extensions: ["rb"], category: "syntax"),
        ValidatorDef(name: "rubocop", language: "ruby", command: "rubocop",
                     args: ["--format", "simple"], extensions: ["rb"], category: "lint", enabled: false),

        // PHP
        ValidatorDef(name: "php-lint", language: "php", command: "php",
                     args: ["-l"], extensions: ["php"], category: "syntax"),
        ValidatorDef(name: "phpstan", language: "php", command: "phpstan",
                     args: ["analyse", "--no-progress"], extensions: ["php"], category: "type", enabled: false),

        // Java / Kotlin
        ValidatorDef(name: "ktlint", language: "kotlin", command: "ktlint",
                     args: [], extensions: ["kt", "kts"], category: "lint", enabled: false),

        // C / C++
        ValidatorDef(name: "clang-check", language: "c", command: "clang",
                     args: ["-fsyntax-only"], extensions: ["c", "h"], category: "syntax"),
        ValidatorDef(name: "clang-tidy", language: "cpp", command: "clang-tidy",
                     args: [], extensions: ["cpp", "cc", "cxx", "hpp"], category: "lint", enabled: false),

        // Zig
        ValidatorDef(name: "zig-check", language: "zig", command: "zig",
                     args: ["ast-check"], extensions: ["zig"], category: "syntax"),

        // Lua
        ValidatorDef(name: "luacheck", language: "lua", command: "luacheck",
                     args: ["--no-color"], extensions: ["lua"], category: "lint", enabled: false),

        // Shell
        ValidatorDef(name: "shellcheck", language: "bash", command: "shellcheck",
                     args: [], extensions: ["sh", "bash", "zsh"], category: "lint", enabled: false),

        // Data formats
        ValidatorDef(name: "json-check", language: "json", command: "python3",
                     args: ["-m", "json.tool"], extensions: ["json"], category: "syntax"),
        ValidatorDef(name: "yamllint", language: "yaml", command: "yamllint",
                     args: ["-d", "relaxed"], extensions: ["yaml", "yml"], category: "lint", enabled: false),

        // Web
        ValidatorDef(name: "prettier-check", language: "web", command: "npx",
                     args: ["prettier", "--check"], extensions: ["html", "css", "scss", "md"], category: "format", enabled: false),
    ]
}
