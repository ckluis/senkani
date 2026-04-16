import Foundation
import Filter

// MARK: - LearnedRuleStatus

public enum LearnedRuleStatus: String, Codable, Sendable, CaseIterable {
    case staged
    case applied
    case rejected
}

// MARK: - LearnedFilterRule

/// A filter rule proposed by the compound learning loop, with metadata tracking its lifecycle.
public struct LearnedFilterRule: Codable, Sendable {
    /// Stable UUID — used for apply/reject by ID.
    public let id: String
    /// Base command name, e.g. "docker"
    public let command: String
    /// Optional subcommand, e.g. "compose". nil matches any subcommand.
    public let subcommand: String?
    /// Serialized FilterOp descriptions, e.g. ["head(50)"]. Parsed back at load time.
    public let ops: [String]
    /// session_id of the session that triggered this proposal.
    public let source: String
    /// 0.0–1.0. 1.0 = completely unfiltered; 0.0 = already well-filtered.
    public let confidence: Double
    /// Lifecycle state: staged → applied | rejected.
    public var status: LearnedRuleStatus
    /// Number of distinct sessions where the triggering pattern appeared.
    public let sessionCount: Int
    /// When this rule was proposed.
    public let createdAt: Date

    public init(
        id: String,
        command: String,
        subcommand: String?,
        ops: [String],
        source: String,
        confidence: Double,
        status: LearnedRuleStatus,
        sessionCount: Int = 0,
        createdAt: Date
    ) {
        self.id = id
        self.command = command
        self.subcommand = subcommand
        self.ops = ops
        self.source = source
        self.confidence = confidence
        self.status = status
        self.sessionCount = sessionCount
        self.createdAt = createdAt
    }

    /// Convert serialized ops strings back into a FilterRule.
    /// Supported ops: "head(N)", "tail(N)", "truncateBytes(N)", "dedupLines", "stripANSI".
    public var asFilterRule: FilterRule {
        let filterOps: [FilterOp] = ops.compactMap { op in
            if op.hasPrefix("head("), let n = parseArg(op) { return .head(n) }
            if op.hasPrefix("tail("), let n = parseArg(op) { return .tail(n) }
            if op.hasPrefix("truncateBytes("), let n = parseArg(op) { return .truncateBytes(n) }
            if op == "dedupLines" { return .dedupLines }
            if op == "stripANSI" { return .stripANSI }
            return nil
        }
        return FilterRule(command: command, subcommand: subcommand, ops: filterOps)
    }

    private func parseArg(_ s: String) -> Int? {
        guard let open = s.firstIndex(of: "("),
              let close = s.lastIndex(of: ")") else { return nil }
        return Int(s[s.index(after: open)..<close])
    }
}

// MARK: - LearnedRulesFile

/// Top-level JSON container. Version field enables future schema migration.
public struct LearnedRulesFile: Codable {
    public var version: Int
    public var rules: [LearnedFilterRule]

    public static let currentVersion = 1

    public static var empty: LearnedRulesFile {
        LearnedRulesFile(version: currentVersion, rules: [])
    }

    public init(version: Int, rules: [LearnedFilterRule]) {
        self.version = version
        self.rules = rules
    }
}

// MARK: - LearnedRulesStore

public enum LearnedRulesStore {

    static let path: String = {
        NSHomeDirectory() + "/.senkani/learned-rules.json"
    }()

    // MARK: - Singleton

    /// In-process cache — loaded once. Tests should call `reload()` after writing to disk.
    nonisolated(unsafe) public static var shared: LearnedRulesFile = {
        load() ?? .empty
    }()

    // MARK: - Persistence

    public static func load() -> LearnedRulesFile? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(LearnedRulesFile.self, from: data)
    }

    public static func save(_ file: LearnedRulesFile) throws {
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true, attributes: nil)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(file)
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    /// Reload singleton from disk. Used in tests after writing rules.
    public static func reload() {
        shared = load() ?? .empty
    }

    // MARK: - Mutations

    /// Add a rule with status=staged. No-ops if a rule for the same command+subcommand already exists in staged/applied state.
    public static func stage(_ rule: LearnedFilterRule) throws {
        var file = load() ?? .empty
        // Deduplicate: skip if already staged or applied for same command+subcommand
        let duplicate = file.rules.contains {
            $0.command == rule.command &&
            $0.subcommand == rule.subcommand &&
            ($0.status == .staged || $0.status == .applied)
        }
        guard !duplicate else { return }
        file.rules.append(rule)
        try save(file)
        shared = file
    }

    /// Move a staged rule to applied status.
    public static func apply(id: String) throws {
        var file = load() ?? .empty
        guard let idx = file.rules.firstIndex(where: { $0.id == id }) else { return }
        file.rules[idx].status = .applied
        try save(file)
        shared = file
    }

    /// Apply all staged rules at once.
    public static func applyAll() throws {
        var file = load() ?? .empty
        for idx in file.rules.indices where file.rules[idx].status == .staged {
            file.rules[idx].status = .applied
        }
        try save(file)
        shared = file
    }

    /// Move a staged rule to rejected status.
    public static func reject(id: String) throws {
        var file = load() ?? .empty
        guard let idx = file.rules.firstIndex(where: { $0.id == id }) else { return }
        file.rules[idx].status = .rejected
        try save(file)
        shared = file
    }

    /// Delete all learned rules and reset the file.
    public static func reset() throws {
        let empty = LearnedRulesFile.empty
        try save(empty)
        shared = empty
    }

    // MARK: - Queries

    /// Returns only rules currently in applied status as FilterRules.
    public static func loadApplied() -> [LearnedFilterRule] {
        (load() ?? .empty).rules.filter { $0.status == .applied }
    }
}
