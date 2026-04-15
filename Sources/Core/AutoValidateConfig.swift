import Foundation

/// Configuration for Phase J auto-validate reactions.
/// Default OFF — projects opt in via `.senkani/config.json`.
///
/// ```json
/// { "autoValidate": { "enabled": true } }
/// ```
public struct AutoValidateConfig: Codable, Sendable {
    public var enabled: Bool
    public var categories: [String]
    public var debounceMs: Int
    public var timeoutMs: Int
    public var maxConcurrent: Int
    public var excludePaths: [String]

    public static let `default` = AutoValidateConfig(
        enabled: false,
        categories: ["syntax", "type"],
        debounceMs: 300,
        timeoutMs: 5000,
        maxConcurrent: 2,
        excludePaths: ["node_modules/**", ".build/**", "dist/**", "*.generated.*"]
    )

    public init(
        enabled: Bool = false,
        categories: [String] = ["syntax", "type"],
        debounceMs: Int = 300,
        timeoutMs: Int = 5000,
        maxConcurrent: Int = 2,
        excludePaths: [String] = ["node_modules/**", ".build/**", "dist/**"]
    ) {
        let validCategories: Set<String> = ["syntax", "type", "lint", "format", "security"]
        self.enabled = enabled
        self.categories = categories.filter { validCategories.contains($0) }
        self.debounceMs = max(50, min(5000, debounceMs))
        self.timeoutMs = max(1000, min(30000, timeoutMs))
        self.maxConcurrent = max(1, min(8, maxConcurrent))
        self.excludePaths = excludePaths
    }

    // MARK: - Loading

    /// Load auto-validate config from `.senkani/config.json` in the project root.
    /// Returns defaults if file doesn't exist or key is missing.
    public static func load(projectRoot: String) -> AutoValidateConfig {
        let path = projectRoot + "/.senkani/config.json"
        guard let data = FileManager.default.contents(atPath: path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let avJSON = json["autoValidate"],
              let avData = try? JSONSerialization.data(withJSONObject: avJSON),
              let config = try? JSONDecoder().decode(AutoValidateConfig.self, from: avData)
        else {
            return .default
        }
        return config
    }

    // MARK: - Exclude Path Matching

    /// Check if a file path (relative to project root) matches any exclude pattern.
    /// Uses fnmatch with FNM_PATHNAME for `**` glob support.
    public func isExcluded(relativePath: String) -> Bool {
        for pattern in excludePaths {
            // fnmatch with FNM_PATHNAME handles directory separators correctly
            if fnmatch(pattern, relativePath, FNM_PATHNAME) == 0 {
                return true
            }
            // Also try without FNM_PATHNAME for patterns like "*.generated.*"
            if fnmatch(pattern, relativePath, 0) == 0 {
                return true
            }
        }
        return false
    }
}
