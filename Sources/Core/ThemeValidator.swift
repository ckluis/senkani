import Foundation

/// Validates VS Code theme JSON files before loading into the app.
///
/// Security concerns addressed:
/// - Memory exhaustion via oversized theme files
/// - Format string injection via color value strings
/// - Embedded scripts or URLs in string values
/// - Non-color data smuggled into theme files
/// - Malformed JSON causing parser hangs
public enum ThemeValidator {

    // MARK: - Errors

    public enum ValidationError: Error, CustomStringConvertible {
        case fileTooLarge(bytes: Int, maxBytes: Int)
        case fileNotReadable
        case invalidJSON
        case rootNotDictionary
        case invalidColorValue(key: String, value: String)
        case suspiciousContent(key: String, reason: String)
        case valueTooLong(key: String, length: Int, maxLength: Int)

        public var description: String {
            switch self {
            case .fileTooLarge(let bytes, let max):
                return "Theme file too large: \(bytes) bytes (max \(max))"
            case .fileNotReadable:
                return "Theme file is not readable"
            case .invalidJSON:
                return "Theme file is not valid JSON"
            case .rootNotDictionary:
                return "Theme JSON root must be a dictionary"
            case .invalidColorValue(let key, let value):
                return "Invalid color value for '\(key)': '\(value)'"
            case .suspiciousContent(let key, let reason):
                return "Suspicious content in '\(key)': \(reason)"
            case .valueTooLong(let key, let length, let max):
                return "Value too long for '\(key)': \(length) chars (max \(max))"
            }
        }
    }

    // MARK: - Constants

    /// Maximum theme file size: 1 MB. Legitimate VS Code themes are typically 10-50 KB.
    private static let maxFileSize = 1_048_576

    /// Maximum length for any string value in the theme. Color strings are typically
    /// 4-9 characters (#RGB to #RRGGBBAA) or ~30 chars for rgba(). 200 chars is generous.
    private static let maxValueLength = 200

    // MARK: - Validation Patterns

    /// Matches hex color formats: #RGB, #RRGGBB, #RRGGBBAA (case-insensitive)
    private static let hexColorPattern = try! NSRegularExpression(
        pattern: "^#([0-9a-fA-F]{3}|[0-9a-fA-F]{6}|[0-9a-fA-F]{8})$"
    )

    /// Matches rgba()/rgb() color format with integer or percentage values.
    /// e.g., rgba(255, 128, 0, 0.5) or rgb(100%, 50%, 0%)
    private static let rgbaColorPattern = try! NSRegularExpression(
        pattern: "^rgba?\\(\\s*\\d{1,3}%?\\s*,\\s*\\d{1,3}%?\\s*,\\s*\\d{1,3}%?\\s*(,\\s*(0|1|0?\\.\\d+)\\s*)?\\)$"
    )

    /// Patterns that indicate embedded scripts or dangerous content.
    private static let suspiciousPatterns: [(pattern: NSRegularExpression, reason: String)] = {
        let defs: [(String, String)] = [
            ("(?i)<script", "embedded script tag"),
            ("(?i)javascript:", "javascript: URI"),
            ("(?i)data:", "data: URI"),
            ("(?i)(https?|ftp)://", "embedded URL"),
            ("(?i)\\\\u[0-9a-f]{4}", "unicode escape sequence"),
            ("%[0-9a-fA-F]{2}", "percent-encoded content (potential format string)"),
            ("(?i)\\$\\{", "template literal / string interpolation"),
            ("(?i)\\{\\{", "template expression"),
        ]
        return defs.compactMap { pattern, reason in
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
            return (regex, reason)
        }
    }()

    // MARK: - Public API

    /// Validates a VS Code theme JSON file before loading.
    ///
    /// Performs the following checks:
    /// 1. File size must be under 1 MB
    /// 2. Must be valid JSON
    /// 3. Root must be a dictionary
    /// 4. All color values must be valid hex (#RGB, #RRGGBB, #RRGGBBAA) or rgba() format
    /// 5. No embedded scripts, URLs, or template expressions in string values
    /// 6. No string value exceeds 200 characters
    ///
    /// - Parameter url: File URL to the theme JSON file.
    /// - Returns: The parsed and validated colors dictionary.
    /// - Throws: `ValidationError` if any check fails.
    public static func validate(at url: URL) throws -> [String: Any] {
        // 1. Check file size before reading (prevents memory exhaustion)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let fileSize = attributes[.size] as? Int else {
            throw ValidationError.fileNotReadable
        }
        guard fileSize <= maxFileSize else {
            throw ValidationError.fileTooLarge(bytes: fileSize, maxBytes: maxFileSize)
        }

        // 2. Read and parse JSON
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw ValidationError.fileNotReadable
        }

        let jsonObject: Any
        do {
            jsonObject = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            throw ValidationError.invalidJSON
        }

        // 3. Root must be a dictionary
        guard let root = jsonObject as? [String: Any] else {
            throw ValidationError.rootNotDictionary
        }

        // 4-6. Validate all string values recursively
        try validateValues(in: root, keyPath: "")

        return root
    }

    /// Validates a theme dictionary that was already parsed (e.g., from an embedded resource).
    /// Applies the same string-level checks without file I/O.
    public static func validateParsed(_ dict: [String: Any]) throws {
        try validateValues(in: dict, keyPath: "")
    }

    // MARK: - Recursive Validation

    private static func validateValues(in dict: [String: Any], keyPath: String) throws {
        for (key, value) in dict {
            let fullKey = keyPath.isEmpty ? key : "\(keyPath).\(key)"

            switch value {
            case let stringValue as String:
                try validateStringValue(stringValue, key: fullKey)

            case let nestedDict as [String: Any]:
                try validateValues(in: nestedDict, keyPath: fullKey)

            case let array as [Any]:
                for (index, element) in array.enumerated() {
                    let arrayKey = "\(fullKey)[\(index)]"
                    if let str = element as? String {
                        try validateStringValue(str, key: arrayKey)
                    } else if let nested = element as? [String: Any] {
                        try validateValues(in: nested, keyPath: arrayKey)
                    }
                    // Numbers and booleans in arrays are fine
                }

            default:
                // Numbers, booleans, null — all safe
                break
            }
        }
    }

    private static func validateStringValue(_ value: String, key: String) throws {
        // Check length
        guard value.count <= maxValueLength else {
            throw ValidationError.valueTooLong(key: key, length: value.count, maxLength: maxValueLength)
        }

        // Check for suspicious content
        let range = NSRange(value.startIndex..., in: value)
        for (pattern, reason) in suspiciousPatterns {
            if pattern.firstMatch(in: value, range: range) != nil {
                throw ValidationError.suspiciousContent(key: key, reason: reason)
            }
        }

        // If the key path suggests this is a color value, validate the format.
        // VS Code theme keys containing "color", "background", "foreground", "border",
        // "shadow", "highlight" typically hold color values.
        let lowerKey = key.lowercased()
        let colorIndicators = ["color", "background", "foreground", "border", "shadow",
                               "highlight", "selection", "active", "inactive", "hover"]

        let isColorKey = colorIndicators.contains { lowerKey.contains($0) }

        if isColorKey {
            let trimmed = value.trimmingCharacters(in: .whitespaces)
            guard isValidColor(trimmed) else {
                throw ValidationError.invalidColorValue(key: key, value: value)
            }
        }
    }

    /// Returns true if the string is a valid color in hex or rgba() format.
    private static func isValidColor(_ value: String) -> Bool {
        // Empty string means "inherit" / "no override" in VS Code themes
        if value.isEmpty { return true }

        // Named transparency
        if value == "transparent" { return true }

        let range = NSRange(value.startIndex..., in: value)

        // Hex color
        if hexColorPattern.firstMatch(in: value, range: range) != nil {
            return true
        }

        // rgba() / rgb()
        if rgbaColorPattern.firstMatch(in: value, range: range) != nil {
            return true
        }

        return false
    }
}
