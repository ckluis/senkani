import Foundation

// MARK: - SearchWebCoolDownLedger
//
// Per-region cool-down ledger for `senkani_search_web`. Once a region
// returns a DDG Lite CAPTCHA / soft-block page, the region is marked
// cooling-down for `defaultDuration` (default 30 minutes — picked from
// observed DDG soft-block recovery times during the 2026-05-16
// release-v0-3-0-surface-pass walk). Subsequent calls skip the region
// in the rotation order until `cooldownUntil > now` no longer holds.
//
// Persisted under `~/.senkani/state/search_web_cooldown.json` with
// mode 0600 (same convention as `~/.senkani/onboarding/milestones.json`).
// Tests can redirect via `SearchWebCoolDownLedger.withPath(_:)` — a
// `@TaskLocal`-scoped path so parallel suites don't race on the shared
// production file (same pattern as `LearnedRulesStore.withPath`).
//
// Originating finding:
// `search-web-ddg-soft-block-resilience-2026-05-16` (parent
// finding: `release-v0-3-0-surface-pass` Step 1 sub-check).

public struct SearchWebCoolDown: Codable, Equatable, Sendable {
    public let captchaSeenAt: Date
    public let cooldownUntil: Date

    public init(captchaSeenAt: Date, cooldownUntil: Date) {
        self.captchaSeenAt = captchaSeenAt
        self.cooldownUntil = cooldownUntil
    }
}

public struct SearchWebCoolDownFile: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var regions: [String: SearchWebCoolDown]

    public static let currentSchemaVersion: Int = 1
    public static let empty = SearchWebCoolDownFile(
        schemaVersion: currentSchemaVersion,
        regions: [:]
    )

    public init(schemaVersion: Int, regions: [String: SearchWebCoolDown]) {
        self.schemaVersion = schemaVersion
        self.regions = regions
    }
}

public enum SearchWebCoolDownLedger {
    public static let defaultPath: String =
        NSHomeDirectory() + "/.senkani/state/search_web_cooldown.json"

    /// Observed DDG soft-block recovery duration during the 2026-05-16
    /// surface-pass walk was ~12+ minutes (the 12-minute manual cool-down
    /// did not clear the block). 30 minutes is conservatively above that.
    public static let defaultDuration: TimeInterval = 30 * 60

    // MARK: TaskLocal scope (test override)

    final class Scoped: @unchecked Sendable {
        var path: String
        init(path: String) { self.path = path }
    }

    @TaskLocal static var scoped: Scoped?

    /// Current on-disk path. Inside a `withPath(_:)` scope this returns
    /// the scoped temp path; otherwise the production default.
    public static var path: String { Self.scoped?.path ?? defaultPath }

    /// TEST ONLY: redirect persistence to `temp` for the duration of
    /// `body`. Mirror of `LearnedRulesStore.withPath`.
    public static func withPath<T>(_ temp: String, _ body: () throws -> T) rethrows -> T {
        try $scoped.withValue(Scoped(path: temp), operation: body)
    }

    /// Async variant — needed because `SearchWebTool.handle` is `async`.
    public static func withPath<T>(
        _ temp: String,
        _ body: () async throws -> T
    ) async rethrows -> T {
        try await $scoped.withValue(Scoped(path: temp), operation: body)
    }

    // MARK: Persistence

    public static func load() -> SearchWebCoolDownFile {
        let url = URL(fileURLWithPath: path)
        guard let data = try? Data(contentsOf: url) else { return .empty }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard var file = try? decoder.decode(SearchWebCoolDownFile.self, from: data)
        else { return .empty }
        // Forward-compat: if the on-disk schema version is unrecognized,
        // treat as empty rather than crash.
        if file.schemaVersion != SearchWebCoolDownFile.currentSchemaVersion {
            file = .empty
        }
        return file
    }

    public static func save(_ file: SearchWebCoolDownFile) {
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(
            atPath: dir,
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(file) else { return }
        let url = URL(fileURLWithPath: path)
        try? data.write(to: url, options: .atomic)
        // Best-effort permission tighten — `.atomic` writes via a temp
        // file + rename, so the rename may carry default umask perms; we
        // set 0600 explicitly to match the onboarding/milestones.json
        // convention.
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: path
        )
    }

    // MARK: Public surface used by SearchWebTool

    /// Record a CAPTCHA / soft-block event for `region`. Idempotent —
    /// repeated calls overwrite the prior entry with a fresh expiry.
    public static func recordCaptcha(
        region: String,
        now: Date = Date(),
        duration: TimeInterval = defaultDuration
    ) {
        var file = load()
        file.regions[region] = SearchWebCoolDown(
            captchaSeenAt: now,
            cooldownUntil: now.addingTimeInterval(duration)
        )
        save(file)
    }

    /// `true` iff the region has a cool-down entry whose `cooldownUntil`
    /// is still in the future relative to `now`. Returns false for
    /// regions that have never been recorded or whose cool-down expired.
    public static func isCooling(region: String, now: Date = Date()) -> Bool {
        guard let entry = load().regions[region] else { return false }
        return entry.cooldownUntil > now
    }

    /// The expiry of an active cool-down for `region`, or `nil` if the
    /// region is not cooling. Used to format `allRegionsCooling` errors.
    public static func cooldownUntil(region: String, now: Date = Date()) -> Date? {
        guard let entry = load().regions[region], entry.cooldownUntil > now
        else { return nil }
        return entry.cooldownUntil
    }
}

// MARK: - SearchWebRetryConfig

/// Per-task override for `senkani_search_web`'s inter-attempt back-off.
/// Production reads `SENKANI_SEARCH_WEB_RETRY_DELAY_MS` (default 2000
/// ms); tests set the TaskLocal slot to 0 so the rotation-retry
/// behavioural tests don't sleep for 2 seconds per blocked region.
/// Mirrors the `SearchWebCoolDownLedger.withPath` shape so both
/// overrides cohabit a single `await` scope.
public enum SearchWebRetryConfig {
    public static let defaultBackoffMs: Int = 2000

    final class Scoped: @unchecked Sendable {
        let backoffMs: Int
        init(backoffMs: Int) { self.backoffMs = backoffMs }
    }

    @TaskLocal static var scoped: Scoped?

    /// Effective back-off in milliseconds. Order: TaskLocal scope >
    /// environment variable > default 2000.
    public static var backoffMs: Int {
        if let v = scoped?.backoffMs { return v }
        if let env = ProcessInfo.processInfo.environment["SENKANI_SEARCH_WEB_RETRY_DELAY_MS"],
           let n = Int(env) { return n }
        return defaultBackoffMs
    }

    public static func withBackoffMs<T>(
        _ ms: Int,
        _ body: () async throws -> T
    ) async rethrows -> T {
        try await $scoped.withValue(Scoped(backoffMs: ms), operation: body)
    }
}

// MARK: - SearchWebRegionRotation

/// Deterministic region rotation order for `senkani_search_web` retry
/// on soft-block. The primary region (caller-supplied or default
/// `wt-wt`) leads; the remaining default regions follow in fixed order.
/// Duplicates are removed so a caller-supplied region that's also in
/// the default list doesn't appear twice.
public enum SearchWebRegionRotation {
    /// Default rotation order. `wt-wt` is DDG's worldwide region;
    /// `us-en` / `uk-en` / `de-de` are the next-best English+EU regions
    /// that historically don't share IP rate-limit pools.
    public static let defaultOrder: [String] = ["wt-wt", "us-en", "uk-en", "de-de"]

    /// Build the rotation for a given primary region. The primary
    /// region leads; the default order's other entries follow in order,
    /// skipping the primary if it's already in the default list.
    public static func order(primary: String) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for region in [primary] + defaultOrder {
            if !seen.contains(region) {
                seen.insert(region)
                result.append(region)
            }
        }
        return result
    }
}
