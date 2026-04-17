import Foundation
import MCP
import Core
import Bundle

// MARK: - BundleTool
//
// `senkani_bundle` — the 18th MCP tool. Composes existing primitives
// (SymbolIndex, DependencyGraph, KnowledgeStore, README) into a single
// budget-bounded markdown document suitable for feeding an LLM as
// repo context. Does not re-index. Does not persist. Each call is a
// fresh snapshot.
//
// Params:
//   - `root` (optional string): project root override. Defaults to the
//     session's projectRoot. MUST pass `ProjectSecurity.validateProjectPath`
//     — a prompt-injected subagent cannot bundle ~/.aws or /etc.
//   - `max_tokens` (optional int, default 20000): budget for the
//     bundle in estimated tokens (char/4 approximation — noted in
//     the bundle header so callers don't over-trust).
//   - `include` (optional array of strings): subset of sections to
//     emit. Legal values: "outlines", "deps", "kb", "readme". Defaults
//     to all four. Canonical ordering preserved regardless of input order.
//   - `format` (optional string): "markdown" (default) or "json". The
//     JSON shape is stable (see BundleDocument). Unknown values fall
//     back to markdown.
//
// Safety:
//   - Any free-text content (README, KB `compiledUnderstanding`)
//     passes through `SecretDetector.scan` before landing in output.
//   - Output is ONE call's result — no disk persistence, no caching.
//   - Fails fast with a diagnostic if the symbol index hasn't warmed yet.

enum BundleTool {

    /// Module-scoped client + cache for `--remote` fetches. Shared with
    /// `RepoTool` in spirit (same host allowlist, same secret scan), but
    /// keeping a dedicated instance here avoids cross-tool cache-key
    /// collisions since the bundle path composes tree + readme in a
    /// single logical call.
    private static let remoteClient = RemoteRepoClient()

    static func handle(arguments: [String: Value]?, session: MCPSession) async -> CallTool.Result {
        // Remote branch — short-circuits before any local index access.
        if let repo = arguments?["remote"]?.stringValue, !repo.isEmpty {
            return await handleRemote(repo: repo, arguments: arguments, session: session)
        }

        // 1. Resolve root — validated via ProjectSecurity (Schneier P0).
        let root: String
        if let requested = arguments?["root"]?.stringValue, !requested.isEmpty {
            do {
                let validated = try ProjectSecurity.validateProjectPath(requested)
                root = validated.path
            } catch {
                return .init(content: [.text(
                    text: "Error: invalid `root` — \(error.localizedDescription). Use an absolute path to an existing directory that you own.",
                    annotations: nil, _meta: nil)], isError: true)
            }
        } else {
            root = session.projectRoot
        }

        // 2. Budget — clamp to avoid nonsense values.
        let rawBudget = arguments?["max_tokens"]?.intValue ?? 20_000
        let maxTokens = max(500, min(200_000, rawBudget))

        // 3. Include set — default all, accept user override.
        var include: Set<BundleSection> = Set(BundleSection.allCases)
        if case let .array(incArr)? = arguments?["include"] {
            var parsed: Set<BundleSection> = []
            for v in incArr {
                guard let s = v.stringValue,
                      let sec = BundleSection(rawValue: s) else { continue }
                parsed.insert(sec)
            }
            if !parsed.isEmpty { include = parsed }
        }

        // 3b. Format — default markdown; unknown values fall back silently
        //     (mirrors `include` parsing — a typo shouldn't hard-fail).
        let format: BundleFormat = {
            if let raw = arguments?["format"]?.stringValue,
               let f = BundleFormat(rawValue: raw) {
                return f
            }
            return .markdown
        }()

        // 4. Gather inputs. Index must be ready (Kleppmann P1 — no
        //    partial bundles). Graph / KB / README are optional —
        //    empty sections are OK.
        guard let index = session.indexIfReady() else {
            return .init(content: [.text(
                text: "Symbol index is still warming. Try again in a few seconds (senkani_bundle requires a ready index).",
                annotations: nil, _meta: nil)])
        }
        let graph = session.ensureDependencyGraph()
        let entities = session.knowledgeStore.allEntities(sortedBy: .mentionCountDesc)
        let readme = BundleComposer.readme(at: root)

        let opts = BundleOptions(
            projectRoot: root,
            maxTokens: maxTokens,
            include: include
        )
        let inputs = BundleInputs(
            index: index,
            graph: graph,
            entities: entities,
            readme: readme
        )

        let output = BundleComposer.compose(options: opts, inputs: inputs, format: format)

        // Metrics: the bundle's compression story is the whole repo
        // vs. the single document. Approximate raw bytes as the sum
        // of source file sizes under `root` — capped so we don't
        // stat the entire filesystem on pathological projects.
        let rawBytes = approximateRepoBytes(root: root, cap: 16_777_216)
        session.recordMetrics(
            rawBytes: rawBytes,
            compressedBytes: output.utf8.count,
            feature: "bundle",
            command: "max_tokens=\(maxTokens) format=\(format.rawValue)",
            outputPreview: String(output.prefix(200))
        )

        return .init(content: [.text(text: output, annotations: nil, _meta: nil)])
    }

    // MARK: - Remote branch

    private static func handleRemote(
        repo: String,
        arguments: [String: Value]?,
        session: MCPSession
    ) async -> CallTool.Result {
        // Pre-flight validation — fail cleanly before any network traffic.
        do {
            try RemoteRepoClient.validateRepo(repo)
        } catch {
            return .init(content: [.text(
                text: "Error: invalid `remote` — \(error.localizedDescription).",
                annotations: nil, _meta: nil)], isError: true)
        }

        let ref = arguments?["ref"]?.stringValue
        let rawBudget = arguments?["max_tokens"]?.intValue ?? 20_000
        let maxTokens = max(500, min(200_000, rawBudget))

        var include: Set<BundleSection> = Set(BundleSection.allCases)
        if case let .array(incArr)? = arguments?["include"] {
            var parsed: Set<BundleSection> = []
            for v in incArr {
                guard let s = v.stringValue,
                      let sec = BundleSection(rawValue: s) else { continue }
                parsed.insert(sec)
            }
            if !parsed.isEmpty { include = parsed }
        }
        let format: BundleFormat = {
            if let raw = arguments?["format"]?.stringValue,
               let f = BundleFormat(rawValue: raw) {
                return f
            }
            return .markdown
        }()

        let inputs: RemoteBundleInputs
        do {
            inputs = try await BundleComposer.fetchRemote(
                client: remoteClient, repo: repo, ref: ref)
        } catch let e as RemoteRepoError {
            return .init(content: [.text(
                text: "senkani_bundle --remote: \(e.description)",
                annotations: nil, _meta: nil)], isError: true)
        } catch {
            return .init(content: [.text(
                text: "senkani_bundle --remote: \(error.localizedDescription)",
                annotations: nil, _meta: nil)], isError: true)
        }

        let opts = BundleOptions(
            projectRoot: repo,
            maxTokens: maxTokens,
            include: include
        )
        let output = BundleComposer.composeRemote(
            options: opts, inputs: inputs, format: format)

        // Metrics: raw-bytes here is notional — a clone would be ~20×
        // larger than the composed snapshot. Same heuristic RepoTool
        // uses; keeps the savings pane's math consistent.
        let compressedBytes = output.utf8.count
        let notionalRaw = max(compressedBytes * 20, inputs.files.count * 100)
        session.recordMetrics(
            rawBytes: notionalRaw,
            compressedBytes: compressedBytes,
            feature: "bundle",
            command: "remote=\(repo) max_tokens=\(maxTokens) format=\(format.rawValue)",
            outputPreview: String(output.prefix(200))
        )

        return .init(content: [.text(text: output, annotations: nil, _meta: nil)])
    }

    /// Rough source-byte estimate for the savings metric. Walks the
    /// project with a 16 MB cap. Not a hot path — only fires per
    /// bundle call, not per tool call.
    private static func approximateRepoBytes(root: String, cap: Int) -> Int {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: URL(fileURLWithPath: root),
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return 0 }

        var total = 0
        for case let url as URL in enumerator {
            let rv = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard rv?.isRegularFile == true else { continue }
            total += rv?.fileSize ?? 0
            if total >= cap { return cap }
        }
        return total
    }
}
