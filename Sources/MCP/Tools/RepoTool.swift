import Foundation
import MCP
import Core

// MARK: - RepoTool
//
// `senkani_repo` — 19th MCP tool. Query any public GitHub repo without
// cloning. Host-allowlisted, secret-scanned, cached. Pairs with
// `senkani_bundle` (`--remote` wiring is a follow-up round).
//
// Actions:
//   - tree      — list files in the repo (or a subtree)
//   - file      — fetch one file's text
//   - readme    — fetch README (GitHub auto-selects best format)
//   - search    — GitHub code search scoped to the repo
//
// All actions write `senkani_repo` metrics via `session.recordMetrics`
// so the Agent Timeline + savings pane aggregate them.

enum RepoTool {

    /// Module-scoped cache + client. One pair per process; we don't
    /// tie them to the MCPSession because that would thrash the cache
    /// on every session restart. Schneier-safe: the cache holds
    /// already-redacted strings (SecretDetector ran before storage).
    nonisolated(unsafe) private static let cache = RemoteRepoCache()
    nonisolated(unsafe) private static let client = RemoteRepoClient()

    static func handle(arguments: [String: Value]?, session: MCPSession) async -> CallTool.Result {
        guard let actionStr = arguments?["action"]?.stringValue,
              let action = RemoteRepoAction(rawValue: actionStr) else {
            return .init(content: [.text(
                text: "Error: `action` is required (tree | file | readme | search).",
                annotations: nil, _meta: nil)], isError: true)
        }
        guard let repo = arguments?["repo"]?.stringValue, !repo.isEmpty else {
            return .init(content: [.text(
                text: "Error: `repo` is required (e.g. 'owner/name').",
                annotations: nil, _meta: nil)], isError: true)
        }
        let ref   = arguments?["ref"]?.stringValue
        let path  = arguments?["path"]?.stringValue
        let query = arguments?["query"]?.stringValue
        let limit = arguments?["limit"]?.intValue ?? 10

        // Cache key — stable across sessions for the same inputs.
        let cacheKey = "\(action.rawValue):\(repo):\(ref ?? ""):\(path ?? ""):\(query ?? ""):\(limit)"
        if let cached = await cache.get(cacheKey) {
            SessionDatabase.shared.recordEvent(
                type: "repo_tool.cache.hit", projectRoot: session.projectRoot)
            return metricsWrap(text: cached, session: session,
                               rawBytes: cached.utf8.count, action: action,
                               repo: repo, cached: true)
        }
        SessionDatabase.shared.recordEvent(
            type: "repo_tool.cache.miss", projectRoot: session.projectRoot)

        do {
            let response: RemoteRepoResponse
            switch action {
            case .tree:
                response = try await client.tree(repo: repo, ref: ref)
            case .file:
                guard let path = path, !path.isEmpty else {
                    return .init(content: [.text(
                        text: "Error: `file` action requires `path`.",
                        annotations: nil, _meta: nil)], isError: true)
                }
                response = try await client.file(repo: repo, path: path, ref: ref)
            case .readme:
                response = try await client.readme(repo: repo)
            case .search:
                guard let query = query, !query.isEmpty else {
                    return .init(content: [.text(
                        text: "Error: `search` action requires `query`.",
                        annotations: nil, _meta: nil)], isError: true)
                }
                response = try await client.search(
                    repo: repo, query: query, limit: limit)
            }

            await cache.put(cacheKey, body: response.body)
            SessionDatabase.shared.recordEvent(
                type: "repo_tool.request.success", projectRoot: session.projectRoot)
            return metricsWrap(text: response.body, session: session,
                               rawBytes: response.rawByteCount, action: action,
                               repo: repo, cached: false)
        } catch let e as RemoteRepoError {
            let counterType: String
            if case .rateLimited = e {
                counterType = "repo_tool.request.rate_limited"
            } else {
                counterType = "repo_tool.request.failed"
            }
            SessionDatabase.shared.recordEvent(
                type: counterType, projectRoot: session.projectRoot)
            return .init(content: [.text(
                text: "senkani_repo error: \(e.description)",
                annotations: nil, _meta: nil)], isError: true)
        } catch {
            SessionDatabase.shared.recordEvent(
                type: "repo_tool.request.failed", projectRoot: session.projectRoot)
            return .init(content: [.text(
                text: "senkani_repo error: \(error.localizedDescription)",
                annotations: nil, _meta: nil)], isError: true)
        }
    }

    /// Record metrics + wrap in CallTool.Result. The "savings" story
    /// for a remote repo fetch is "how many tokens would the agent
    /// have spent cloning + walking". We approximate with a 20x
    /// savings multiplier against the returned body size — same
    /// shape `DepsTool` uses.
    private static func metricsWrap(
        text: String,
        session: MCPSession,
        rawBytes: Int,
        action: RemoteRepoAction,
        repo: String,
        cached: Bool
    ) -> CallTool.Result {
        let returnedBytes = text.utf8.count
        // Notional raw-vs-compressed: a clone would be ~20× bigger than
        // the targeted response. Same heuristic DepsTool uses for
        // import-graph queries.
        let notionalRaw = max(returnedBytes * 20, rawBytes)
        session.recordMetrics(
            rawBytes: notionalRaw,
            compressedBytes: returnedBytes,
            feature: "repo",
            command: "\(action.rawValue) \(repo)",
            outputPreview: String(text.prefix(200))
        )
        let prefix = cached ? "// senkani_repo: cached\n" : ""
        return .init(content: [.text(
            text: prefix + text, annotations: nil, _meta: nil)])
    }
}
