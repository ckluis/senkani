import Foundation

// MARK: - WikiLinkResolver
//
// V.7 — resolve `[[Name]]` references against an Obsidian-style vault
// of `*.md` files. Resolution is the missing complement to
// `WikiLinkHelpers.applyCompletion` (in the MCP target): completion is
// the typing-assist surface, resolution is the click-through surface.
//
// Resolution order (Obsidian semantics):
//   1. Exact stem match (`Name` → `Name.md`) at any depth.
//   2. Folder-hint disambiguation: `folder/Name` → `<vault>/folder/Name.md`.
//   3. Multiple hits at different depths → ambiguous; caller chooses.
//   4. No hits → notFound.
//
// The resolver is a pure function over an enumerated file list — it
// does NOT walk the filesystem itself, so callers can supply a curated
// list (e.g. from an FSEvents-debounced cache) and unit-test against
// fixed paths.

public enum WikiLinkResolver {

    public enum Resolution: Equatable, Sendable {
        case exact(URL)
        case ambiguous([URL])
        case notFound
    }

    /// Resolve `[[name]]` against `vaultFiles` (absolute file URLs to `*.md` files).
    /// `name` may carry a folder hint as `folder/Name` or `subdir/sub/Name`.
    public static func resolve(name: String, in vaultFiles: [URL]) -> Resolution {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return .notFound }

        // Folder-hint form: split off the trailing path component as the stem;
        // the prefix is the folder hint. Hint match is suffix-anchored so
        // `subdir/Name` matches `<vault>/anyparent/subdir/Name.md`.
        let parts = trimmed.split(separator: "/", omittingEmptySubsequences: true)
        let stem = String(parts.last ?? Substring(trimmed))
        let hintComponents = parts.dropLast().map(String.init)

        // Filter by stem (filename without `.md`).
        let stemMatches = vaultFiles.filter {
            $0.deletingPathExtension().lastPathComponent == stem
        }

        if stemMatches.isEmpty { return .notFound }

        // No folder hint → if exactly one stem match, that wins; otherwise ambiguous.
        if hintComponents.isEmpty {
            return stemMatches.count == 1
                ? .exact(stemMatches[0])
                : .ambiguous(stemMatches.sorted { $0.path < $1.path })
        }

        // Folder hint present — keep matches whose path components contain the
        // hint as an ordered, contiguous suffix-anchored subsequence.
        let hintMatches = stemMatches.filter { url in
            pathHasHintSuffix(url: url, hint: hintComponents, stem: stem)
        }

        switch hintMatches.count {
        case 0: return .ambiguous(stemMatches.sorted { $0.path < $1.path })
        case 1: return .exact(hintMatches[0])
        default: return .ambiguous(hintMatches.sorted { $0.path < $1.path })
        }
    }

    // MARK: - Private

    /// True iff the URL's path contains `hint` as the immediate parent
    /// chain of the stem. e.g. for url `…/skills/auth/Login.md`, stem
    /// `Login`, hint `["auth"]` → true; hint `["skills","auth"]` → true;
    /// hint `["other"]` → false.
    private static func pathHasHintSuffix(url: URL, hint: [String], stem: String) -> Bool {
        let comps = url.pathComponents
        // Find the position of the file (stem.md) and walk backwards over hint.
        guard let last = comps.last, last == "\(stem).md" else { return false }
        var idx = comps.count - 2
        for h in hint.reversed() {
            guard idx >= 0, comps[idx] == h else { return false }
            idx -= 1
        }
        return true
    }
}
