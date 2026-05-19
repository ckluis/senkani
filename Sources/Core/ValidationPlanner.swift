import Foundation

/// A single step in a `ValidationPlanner` plan. Keyed by
/// `(axis, assertion_id, target_path, selector?, expected?)` per the
/// U.2a-1 contract. Encodes byte-stably so `validation_results.plan_steps`
/// (TEXT, JSON array) round-trips through SQLite without renormalization.
///
/// `selector` carries the symbolic target where a tree-sitter parser is
/// available for the file's extension (e.g. `"function:foo"`,
/// `"class:Bar"`). `nil` means "the whole file" — the runner walks the
/// page or file holistically rather than scoped to a symbol.
///
/// `expected` is JSON-encoded so per-axis assertion libraries can pack
/// arbitrary expected-value shapes (an INP threshold, an a11y selector
/// list, a security header set) without bloating this contract. The
/// planner emits `nil` when the axis has no expected value to pre-seed.
public struct ValidationStep: Codable, Sendable, Equatable, Hashable {
    public let axis: ValidationAxes
    public let assertionId: String
    public let targetPath: String
    public let selector: String?
    public let expected: String?

    public init(
        axis: ValidationAxes,
        assertionId: String,
        targetPath: String,
        selector: String? = nil,
        expected: String? = nil
    ) {
        self.axis = axis
        self.assertionId = assertionId
        self.targetPath = targetPath
        self.selector = selector
        self.expected = expected
    }

    enum CodingKeys: String, CodingKey {
        case axis
        case assertionId = "assertion_id"
        case targetPath = "target_path"
        case selector
        case expected
    }
}

/// Injection point for tree-sitter symbolic targeting. The planner asks
/// the targeter for a selector keyed on `(path, diff)`. The default
/// implementation (`NoopSymbolicTargeter`) returns nil, so the planner
/// falls back to whole-file targeting; U.2b-axes will wire a real
/// tree-sitter-backed implementation that walks the diff hunks and
/// returns the enclosing function/class.
public protocol SymbolicTargeter: Sendable {
    func selector(forFile path: String, diff: String) -> String?
}

/// Default no-op targeter — file-level targeting only. Tests use this
/// directly; production callers will pass a real implementation once
/// U.2b-axes lands.
public struct NoopSymbolicTargeter: SymbolicTargeter {
    public init() {}
    public func selector(forFile _: String, diff _: String) -> String? { nil }
}

/// Walks U.10b's `DiffSelector` + `DiffRequest` into an ordered
/// `[ValidationStep]` plan. Stateless; pure. The output order is
/// `(target_path ASC, axis declaration order)` — deterministic so
/// callers can serialize the plan to `validation_results.plan_steps`
/// and recompute hashes without ordering drift.
///
/// Reuses U.10b's `DiffSelector` enum (no duplicate parsing). The
/// `DiffRequest` already encodes the four selector shapes (`unstaged`,
/// `staged`, `branch(ref)`, `range(a, b)`); this planner is selector-
/// agnostic — it walks `perFileDiff` regardless of which shape produced
/// it.
public enum ValidationPlanner {
    /// Build a plan for the given diff under the requested axes. Returns
    /// one `ValidationStep` per `(file, axis)` pair. Files with empty
    /// diff bodies are skipped (no signal to validate). Axes are emitted
    /// in their `[ValidationAxes]` argument order so callers can pin
    /// downstream comparison ordering.
    public static func plan(
        diff: DiffRequest,
        axes: [ValidationAxes],
        targeter: SymbolicTargeter = NoopSymbolicTargeter()
    ) -> [ValidationStep] {
        guard !axes.isEmpty else { return [] }
        var steps: [ValidationStep] = []
        steps.reserveCapacity(diff.perFileDiff.count * axes.count)

        let sortedPaths = diff.perFileDiff.keys.sorted()
        for path in sortedPaths {
            let body = diff.perFileDiff[path] ?? ""
            guard !body.isEmpty else { continue }
            let selector = targeter.selector(forFile: path, diff: body)
            for axis in axes {
                steps.append(ValidationStep(
                    axis: axis,
                    assertionId: "\(axis.rawValue).default",
                    targetPath: path,
                    selector: selector,
                    expected: nil
                ))
            }
        }
        return steps
    }
}
