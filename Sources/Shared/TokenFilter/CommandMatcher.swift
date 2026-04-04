import Foundation

/// Extracts and matches command names from shell command strings.
public enum CommandMatcher {
    public struct Match: Sendable {
        public let base: String       // e.g. "git"
        public let subcommand: String? // e.g. "status"
    }

    /// Extract the base command and optional subcommand from a shell command string.
    /// Handles: env vars ("FOO=bar git status"), paths ("/usr/bin/git status"),
    /// sudo ("sudo git status"), and flags before subcommands.
    public static func parse(_ command: String) -> Match? {
        let tokens = command.split(separator: " ", omittingEmptySubsequences: true)
            .map(String.init)
        guard !tokens.isEmpty else { return nil }

        var idx = 0

        // Skip env var assignments (FOO=bar)
        while idx < tokens.count && tokens[idx].contains("=") && !tokens[idx].hasPrefix("-") {
            idx += 1
        }

        // Skip sudo/env wrappers
        while idx < tokens.count {
            let basename = extractBasename(tokens[idx])
            if basename == "sudo" || basename == "env" || basename == "nice" || basename == "nohup" {
                idx += 1
            } else {
                break
            }
        }

        guard idx < tokens.count else { return nil }

        let base = extractBasename(tokens[idx])
        idx += 1

        // Find subcommand: skip flags (tokens starting with -)
        var subcommand: String? = nil
        while idx < tokens.count {
            let token = tokens[idx]
            if token.hasPrefix("-") {
                idx += 1
                // If it's a flag that takes a value (e.g. -c value), skip the value too
                if !token.contains("=") && token.count <= 3 && idx < tokens.count && !tokens[idx].hasPrefix("-") {
                    idx += 1
                }
            } else {
                subcommand = token
                break
            }
        }

        return Match(base: base, subcommand: subcommand)
    }

    /// Extract basename from a possibly full path: "/usr/bin/git" -> "git"
    private static func extractBasename(_ token: String) -> String {
        if let lastSlash = token.lastIndex(of: "/") {
            return String(token[token.index(after: lastSlash)...])
        }
        return token
    }
}
