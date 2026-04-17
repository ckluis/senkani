import Foundation
import Core

// MARK: - BundleComposer remote path
//
// Compose a bundle from a public GitHub repo. Uses `RemoteRepoClient`
// for tree + readme fetches — the client enforces the host allowlist,
// size caps, and `SecretDetector.scan`. The composer does NOT weaken
// any of those.
//
// Output mirrors the local composer's section order (header → stats →
// outlines → deps → kb → readme). Deps + KB render as empty because
// a remote snapshot has no dependency graph or knowledge store.
// Outlines render the file list from the tree response — no symbols
// because we don't clone and parse.

extension BundleComposer {

    /// Errors raised while composing a remote bundle. Transport errors
    /// from `RemoteRepoClient` come through as `RemoteRepoError` (not
    /// re-wrapped) so callers can pattern-match rate-limit / 404.
    public enum RemoteBundleError: Error, CustomStringConvertible, Sendable {
        case malformedTreeResponse(String)

        public var description: String {
            switch self {
            case .malformedTreeResponse(let msg):
                return "malformed tree response: \(msg)"
            }
        }
    }

    /// Fetch a repo's tree + README and assemble `RemoteBundleInputs`.
    /// - Parameters:
    ///   - client: the `RemoteRepoClient` (supply a URLProtocol-backed
    ///     session for tests).
    ///   - repo: `owner/name` — validated by the client.
    ///   - ref: optional git ref; nil == HEAD.
    ///   - now: generation timestamp (injectable for tests).
    /// - Returns: a populated `RemoteBundleInputs`.
    /// - Throws: `RemoteRepoError` on network / rate-limit / host / 404
    ///   for the tree call. README 404s are swallowed (a repo with no
    ///   README is still bundleable).
    public static func fetchRemote(
        client: RemoteRepoClient,
        repo: String,
        ref: String? = nil,
        now: Date = Date()
    ) async throws -> RemoteBundleInputs {
        let treeResponse = try await client.tree(repo: repo, ref: ref)
        let (files, treeTruncated) = try parseTree(body: treeResponse.body)

        // README probing mirrors the local helper — try common
        // casings via raw.githubusercontent.com so we get the raw text
        // instead of the API's base64-wrapped JSON. Any 404 simply
        // means "no README at this name" and falls through.
        var readme: String? = nil
        for candidate in ["README.md", "README", "Readme.md", "readme.md"] {
            do {
                let r = try await client.file(repo: repo, path: candidate, ref: ref)
                readme = r.body
                break
            } catch RemoteRepoError.notFound {
                continue
            }
        }

        return RemoteBundleInputs(
            repo: repo, ref: ref, files: files,
            readme: readme, generated: now,
            treeTruncated: treeTruncated
        )
    }

    /// Compose the bundle. Deterministic given inputs. Same section
    /// order as the local variant; deps + kb blocks are rendered as
    /// empty placeholders so a consumer parsing either format sees the
    /// same shape.
    public static func composeRemote(
        options: BundleOptions,
        inputs: RemoteBundleInputs,
        format: BundleFormat = .markdown
    ) -> String {
        switch format {
        case .markdown: return composeRemoteMarkdown(options: options, inputs: inputs)
        case .json:     return composeRemoteJSON(options: options, inputs: inputs)
        }
    }

    // MARK: - Tree parser

    /// Extract relative paths from a GitHub `git/trees/:ref?recursive=1`
    /// response. Only `blob` entries are included — directories are
    /// implied by their children and add no value to the bundle.
    static func parseTree(body: String) throws -> (files: [String], truncated: Bool) {
        guard let data = body.data(using: .utf8) else {
            throw RemoteBundleError.malformedTreeResponse("non-utf8 body")
        }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            throw RemoteBundleError.malformedTreeResponse(error.localizedDescription)
        }
        guard let dict = object as? [String: Any] else {
            throw RemoteBundleError.malformedTreeResponse("top-level not an object")
        }
        let truncated = (dict["truncated"] as? Bool) ?? false
        guard let entries = dict["tree"] as? [[String: Any]] else {
            throw RemoteBundleError.malformedTreeResponse("missing `tree` array")
        }
        var paths: [String] = []
        paths.reserveCapacity(entries.count)
        for entry in entries {
            let type = (entry["type"] as? String) ?? ""
            guard type == "blob" else { continue }
            guard let path = entry["path"] as? String, !path.isEmpty else { continue }
            paths.append(path)
        }
        return (paths.sorted(), truncated)
    }

    // MARK: - Markdown

    private static func composeRemoteMarkdown(
        options: BundleOptions,
        inputs: RemoteBundleInputs
    ) -> String {
        let charBudget = max(0, options.maxTokens) * 4
        var out = ""

        // 1. Header — includes remote repo identifier + ref + truncation
        //    notice so consumers know the snapshot is partial.
        out += remoteHeaderLines(options: options, inputs: inputs)

        // 2. Stats — remote file count, zero symbols/deps/kb.
        out += remoteStatsLines(inputs: inputs)

        // 3-6. Canonical section order. Deps + KB are rendered as empty
        //      placeholders (same shape as local "(no KB entities yet)"
        //      path) so the output structure matches.
        for section in BundleSection.canonicalOrder where options.include.contains(section) {
            let block: String
            switch section {
            case .outlines: block = remoteOutlinesSection(inputs: inputs)
            case .deps:     block = remoteDepsSection()
            case .kb:       block = remoteKBSection()
            case .readme:   block = remoteReadmeSection(inputs: inputs)
            }
            if out.count + block.count > charBudget {
                out += "\n\n---\n"
                out += "_Bundle truncated at \(section.rawValue) section — budget (≈\(options.maxTokens) tokens / \(charBudget) chars) exceeded._\n"
                break
            }
            out += block
        }
        return out
    }

    private static func remoteHeaderLines(
        options: BundleOptions,
        inputs: RemoteBundleInputs
    ) -> String {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        let now = iso.string(from: options.now)
        let refLabel = inputs.ref.map { " @ \($0)" } ?? ""
        var header = ""
        header += "# \(inputs.repo)\(refLabel)\n\n"
        header += "\(provenanceMarker) — remote GitHub snapshot — generated \(now) — budget ≈\(options.maxTokens) tokens (\(options.maxTokens * 4) chars, char/4 approx)\n\n"
        if inputs.treeTruncated {
            header += "> **Note:** GitHub flagged the tree response as truncated — this file listing is partial.\n\n"
        }
        return header
    }

    private static func remoteStatsLines(inputs: RemoteBundleInputs) -> String {
        var out = "## Stats\n\n"
        out += "- **Files (remote)**: \(inputs.files.count)\n"
        out += "- **Symbols**: 0 _(remote snapshots don't parse symbols)_\n"
        out += "- **Import edges**: 0 _(remote snapshots don't build a dep graph)_\n"
        out += "- **KB entities**: 0 _(remote snapshots have no knowledge store)_\n\n"
        return out
    }

    private static func remoteOutlinesSection(inputs: RemoteBundleInputs) -> String {
        var out = "## Outlines\n\n"
        if inputs.files.isEmpty {
            out += "_(tree returned no file entries)_\n\n"
            return out
        }
        out += "_Remote snapshot — file listing only (no symbol parse)._\n\n"
        for file in inputs.files {
            out += "- `\(file)`\n"
        }
        out += "\n"
        return out
    }

    private static func remoteDepsSection() -> String {
        "## Dependency Highlights\n\n_(remote snapshot — no dependency graph)_\n\n"
    }

    private static func remoteKBSection() -> String {
        "## Knowledge Base\n\n_(remote snapshot — no knowledge base)_\n\n"
    }

    private static func remoteReadmeSection(inputs: RemoteBundleInputs) -> String {
        var out = "## README\n\n"
        guard let readme = inputs.readme, !readme.isEmpty else {
            out += "_(no README discovered in remote repo)_\n\n"
            return out
        }
        // The client already ran SecretDetector.scan; we cap length to
        // match the local path's 4 KB readme window.
        let trimmed = String(readme.prefix(4000))
        out += trimmed
        if readme.count > 4000 {
            out += "\n\n_(README truncated — fetch the file directly for the full text)_\n"
        }
        out += "\n"
        return out
    }

    // MARK: - JSON

    private static func composeRemoteJSON(
        options: BundleOptions,
        inputs: RemoteBundleInputs
    ) -> String {
        let charBudget = max(0, options.maxTokens) * 4
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]

        var doc = BundleDocument(
            header: remoteJSONHeader(options: options, inputs: inputs),
            stats: remoteJSONStats(inputs: inputs),
            outlines: nil, deps: nil, kb: nil, readme: nil,
            truncated: nil
        )

        for section in BundleSection.canonicalOrder where options.include.contains(section) {
            let probe = doc
            var candidate = doc
            switch section {
            case .outlines: candidate.outlines = remoteJSONOutlines(inputs: inputs)
            case .deps:     candidate.deps     = BundleDocument.Deps(topImportedBy: [])
            case .kb:       candidate.kb       = BundleDocument.KnowledgeBase(entities: [])
            case .readme:   candidate.readme   = remoteJSONReadme(inputs: inputs)
            }
            if jsonSizeProbe(of: candidate, encoder: encoder) > charBudget {
                doc = probe
                doc.truncated = BundleDocument.Truncation(
                    section: section.rawValue,
                    reason: "budget (≈\(options.maxTokens) tokens / \(charBudget) chars) exceeded"
                )
                break
            }
            doc = candidate
        }

        guard let data = try? encoder.encode(doc),
              let s = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return s
    }

    private static func jsonSizeProbe(
        of doc: BundleDocument,
        encoder: JSONEncoder
    ) -> Int {
        (try? encoder.encode(doc).count) ?? Int.max
    }

    private static func remoteJSONHeader(
        options: BundleOptions,
        inputs: RemoteBundleInputs
    ) -> BundleDocument.Header {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        let refLabel = inputs.ref.map { "\(inputs.repo)@\($0)" } ?? inputs.repo
        return BundleDocument.Header(
            projectName: refLabel,
            generated: iso.string(from: options.now),
            indexUpdated: iso.string(from: inputs.generated),
            maxTokens: options.maxTokens,
            charBudget: options.maxTokens * 4,
            provenance: provenanceMarker + " (remote)"
        )
    }

    private static func remoteJSONStats(inputs: RemoteBundleInputs) -> BundleDocument.Stats {
        BundleDocument.Stats(
            filesIndexed: inputs.files.count,
            symbols: 0, importEdges: 0, kbEntities: 0
        )
    }

    private static func remoteJSONOutlines(inputs: RemoteBundleInputs) -> BundleDocument.Outlines {
        let files = inputs.files.map { path in
            BundleDocument.FileOutline(path: path, symbols: [])
        }
        return BundleDocument.Outlines(files: files)
    }

    private static func remoteJSONReadme(inputs: RemoteBundleInputs) -> BundleDocument.Readme {
        guard let readme = inputs.readme, !readme.isEmpty else {
            return BundleDocument.Readme(content: "", truncated: false)
        }
        let trimmed = String(readme.prefix(4000))
        return BundleDocument.Readme(content: trimmed, truncated: readme.count > 4000)
    }
}
