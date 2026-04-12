import Foundation

/// Shared JSON settings file I/O used by AutoRegistration and HookRegistration.
/// Handles atomic writes and corrupt-file safety.
public enum SettingsIO {

    /// Read a JSON file as a dictionary, or return empty dict if file doesn't exist.
    /// Throws if file exists but contains corrupt JSON.
    public static func readJSONOrEmpty(at path: String) throws -> [String: Any] {
        guard let data = FileManager.default.contents(atPath: path) else {
            return [:]
        }
        guard let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SettingsIOError.corruptJSON(path)
        }
        return parsed
    }

    /// Write a JSON dictionary to a file atomically (write to temp, then rename).
    /// Prevents corruption if the process crashes mid-write.
    public static func writeJSONAtomically(_ dict: [String: Any], to path: String) throws {
        let data = try JSONSerialization.data(
            withJSONObject: dict,
            options: [.prettyPrinted, .sortedKeys]
        )

        let url = URL(fileURLWithPath: path)
        let dir = url.deletingLastPathComponent()
        let tempURL = dir.appendingPathComponent(
            ".\(url.lastPathComponent).tmp.\(ProcessInfo.processInfo.processIdentifier)"
        )

        try data.write(to: tempURL)

        if FileManager.default.fileExists(atPath: path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tempURL)
        } else {
            try FileManager.default.moveItem(at: tempURL, to: url)
        }
    }

    /// Create a .bak backup only if one doesn't already exist.
    public static func backupIfFirstWrite(path: String) {
        let backupPath = path + ".bak"
        let fm = FileManager.default
        if fm.fileExists(atPath: path) && !fm.fileExists(atPath: backupPath) {
            try? fm.copyItem(atPath: path, toPath: backupPath)
        }
    }

    // MARK: - Errors

    public enum SettingsIOError: Error, LocalizedError {
        case corruptJSON(String)

        public var errorDescription: String? {
            switch self {
            case .corruptJSON(let path):
                return "\(path) contains invalid JSON -- refusing to modify"
            }
        }
    }
}
