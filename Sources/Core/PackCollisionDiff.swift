import Foundation

/// Renders a `[PackInstaller.Collision]` list as the human-readable
/// table the CLI prints. Pure function so unit tests can pin exact
/// string output without spinning up the installer.
public enum PackCollisionDiff {

    /// Build the multi-line diff string. `incomingPack` is the name of
    /// the pack the operator is trying to install; the renderer groups
    /// rows by collision kind under that header. Returns
    /// `"(no collisions)"` when the input list is empty.
    public static func render(
        incomingPack: String,
        collisions: [PackInstaller.Collision]
    ) -> String {
        guard !collisions.isEmpty else {
            return "(no collisions)"
        }

        var lines: [String] = []
        lines.append("Collision diff for pack '\(incomingPack)':")

        let skillRows = collisions.compactMap { c -> (String, String)? in
            if case let .skillName(name, conflictingPack) = c {
                return (name, conflictingPack)
            }
            return nil
        }
        if !skillRows.isEmpty {
            lines.append("")
            lines.append("  Skill name clashes:")
            lines.append("    incoming-skill        installed-pack")
            for (name, pack) in skillRows {
                lines.append("    " + pad(name, 22) + pack)
            }
        }

        let scopeRows = collisions.compactMap { c -> (String, String)? in
            if case let .policyScopeKey(key, conflictingPack) = c {
                return (key, conflictingPack)
            }
            return nil
        }
        if !scopeRows.isEmpty {
            lines.append("")
            lines.append("  Policy scope-key clashes:")
            lines.append("    scope-key             installed-pack")
            for (key, pack) in scopeRows {
                lines.append("    " + pad(key, 22) + pack)
            }
        }

        let ctxRows = collisions.compactMap { c -> (String, String)? in
            if case let .contextFilename(name, conflictingPack) = c {
                return (name, conflictingPack)
            }
            return nil
        }
        if !ctxRows.isEmpty {
            lines.append("")
            lines.append("  Context filename clashes:")
            lines.append("    filename              installed-pack")
            for (name, pack) in ctxRows {
                lines.append("    " + pad(name, 22) + pack)
            }
        }

        return lines.joined(separator: "\n")
    }

    private static func pad(_ s: String, _ width: Int) -> String {
        if s.count >= width { return s + " " }
        return s + String(repeating: " ", count: width - s.count)
    }
}
