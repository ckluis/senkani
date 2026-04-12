import Foundation

/// Result of checking a grammar's upstream version.
public struct GrammarCheckResult: Sendable {
    public let grammar: GrammarInfo
    public let latestVersion: String?
    public let isOutdated: Bool
    public let error: String?

    public init(grammar: GrammarInfo, latestVersion: String?, isOutdated: Bool, error: String?) {
        self.grammar = grammar
        self.latestVersion = latestVersion
        self.isOutdated = isOutdated
        self.error = error
    }
}

/// Checks GitHub for newer versions of vendored grammars.
/// Uses a 24-hour on-disk cache to avoid redundant API calls.
public enum GrammarVersionChecker {

    /// Cache file location: ~/.senkani/cache/grammar-versions.json
    private static var cachePath: String {
        NSHomeDirectory() + "/.senkani/cache/grammar-versions.json"
    }

    /// TTL for cached results: 24 hours.
    private static let cacheTTL: TimeInterval = 24 * 60 * 60

    // MARK: - Public API

    /// Check all grammars for updates, using cache unless `forceRefresh` is true.
    public static func checkAll(forceRefresh: Bool = false) async -> [GrammarCheckResult] {
        let cached = forceRefresh ? nil : loadCache()

        var results: [GrammarCheckResult] = []
        for info in GrammarManifest.sorted {
            if let cached = cached, let entry = cached[info.language] {
                let isOutdated = entry.latest != nil
                    && GrammarManifest.compareSemver(entry.latest!, info.version) > 0
                results.append(GrammarCheckResult(
                    grammar: info,
                    latestVersion: entry.latest,
                    isOutdated: isOutdated,
                    error: entry.error
                ))
            } else {
                let result = await checkOne(info)
                results.append(result)
            }
        }

        // Save results to cache
        saveCache(results)
        return results
    }

    /// Check a single grammar against its upstream GitHub repo.
    public static func checkOne(_ info: GrammarInfo) async -> GrammarCheckResult {
        // Try /releases/latest first, fall back to /tags
        if let version = await fetchLatestRelease(repo: info.repo) {
            let isOutdated = GrammarManifest.compareSemver(version, info.version) > 0
            return GrammarCheckResult(grammar: info, latestVersion: version, isOutdated: isOutdated, error: nil)
        }

        if let version = await fetchLatestTag(repo: info.repo) {
            let isOutdated = GrammarManifest.compareSemver(version, info.version) > 0
            return GrammarCheckResult(grammar: info, latestVersion: version, isOutdated: isOutdated, error: nil)
        }

        return GrammarCheckResult(grammar: info, latestVersion: nil, isOutdated: false, error: "Could not reach GitHub API")
    }

    // MARK: - GitHub API

    /// Fetch latest release version from GitHub API.
    private static func fetchLatestRelease(repo: String) async -> String? {
        let urlString = "https://api.github.com/repos/\(repo)/releases/latest"
        guard let url = URL(string: urlString) else { return nil }

        var request = URLRequest(url: url)
        request.setValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 10

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tagName = json["tag_name"] as? String else { return nil }
            return stripVersionPrefix(tagName)
        } catch {
            return nil
        }
    }

    /// Fetch latest tag version from GitHub API (fallback when no releases exist).
    private static func fetchLatestTag(repo: String) async -> String? {
        let urlString = "https://api.github.com/repos/\(repo)/tags?per_page=1"
        guard let url = URL(string: urlString) else { return nil }

        var request = URLRequest(url: url)
        request.setValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 10

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            guard let tags = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
                  let first = tags.first,
                  let name = first["name"] as? String else { return nil }
            return stripVersionPrefix(name)
        } catch {
            return nil
        }
    }

    /// Strip common version prefixes ("v", "v.", "release-") from a tag name.
    static func stripVersionPrefix(_ tag: String) -> String {
        var s = tag
        if s.hasPrefix("v") { s = String(s.dropFirst()) }
        if s.hasPrefix(".") { s = String(s.dropFirst()) }
        return s
    }

    // MARK: - Cache

    private struct CacheEntry: Codable {
        let latest: String?
        let error: String?
        let checked: Date
    }

    private static func loadCache() -> [String: CacheEntry]? {
        guard let data = FileManager.default.contents(atPath: cachePath) else { return nil }
        guard let cache = try? JSONDecoder().decode([String: CacheEntry].self, from: data) else { return nil }

        // Check TTL — if any entry is older than 24h, invalidate entire cache
        let now = Date()
        for entry in cache.values {
            if now.timeIntervalSince(entry.checked) > cacheTTL {
                return nil
            }
        }
        return cache
    }

    private static func saveCache(_ results: [GrammarCheckResult]) {
        var cache: [String: CacheEntry] = [:]
        for result in results {
            cache[result.grammar.language] = CacheEntry(
                latest: result.latestVersion,
                error: result.error,
                checked: Date()
            )
        }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        guard let data = try? encoder.encode(cache) else { return }

        // Ensure cache directory exists
        let cacheDir = (cachePath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: cacheDir, withIntermediateDirectories: true)
        try? data.write(to: URL(fileURLWithPath: cachePath))
    }

    /// Load cached results without hitting the network. Returns nil if cache is missing or expired.
    public static func cachedResults() -> [GrammarCheckResult]? {
        guard let cache = loadCache() else { return nil }

        var results: [GrammarCheckResult] = []
        for info in GrammarManifest.sorted {
            guard let entry = cache[info.language] else { return nil }
            let isOutdated = entry.latest != nil
                && GrammarManifest.compareSemver(entry.latest!, info.version) > 0
            results.append(GrammarCheckResult(
                grammar: info,
                latestVersion: entry.latest,
                isOutdated: isOutdated,
                error: entry.error
            ))
        }
        return results
    }
}
