import Foundation

// MARK: - ProseCadenceCompiler
//
// Phase U.8 — narrow protocol for compiling a natural-language schedule
// expression ("every weekday at 9am") into a 5-field cron string.
//
// The protocol lives in Core so wiring (CLI, App, MCP) can compose with
// any compiler backend without importing MLX into every Core client.
// Production wires an MLX-backed Gemma 4 adapter that runs a strict
// JSON-schema response; tests wire a `MockProseCadenceCompiler`. When
// no model is available, `NullProseCadenceCompiler` throws `.unavailable`
// and callers either fall back to operator-entered cron OR refuse the
// schedule registration with a "no model" message.
//
// Contract:
//   - `compile(prose:locale:)` accepts a prose expression and a
//     BCP-47 locale tag (default "en-US"). Returns a `ProseCadence`
//     with the original prose and the compiled cron.
//   - The compiled cron MUST validate against `CronToLaunchd.convert`
//     before the schedule is saved; the compiler is best-effort, the
//     validation is the gate.
//   - Adapters MAY be slow (LLM inference); caller is responsible for
//     timeouts.
//   - Errors propagate as `ProseCadenceCompilerError`. The .unavailable
//     case is the silent-fallback signal; .invalidJSON / .invalidCron
//     surface to the user so they can correct the prose.

public struct ProseCadence: Equatable, Sendable, Codable {
    /// Original prose as the user typed it.
    public let prose: String
    /// Locale used to parse the prose (BCP-47, e.g. "en-US").
    public let locale: String
    /// 5-field cron expression that the compiler emitted.
    public let cron: String

    public init(prose: String, locale: String, cron: String) {
        self.prose = prose
        self.locale = locale
        self.cron = cron
    }
}

public protocol ProseCadenceCompiler: Sendable {
    /// Compile `prose` (in `locale`) into a 5-field cron expression.
    func compile(prose: String, locale: String) async throws -> ProseCadence
}

extension ProseCadenceCompiler {
    /// Convenience overload defaulting to en-US.
    public func compile(prose: String) async throws -> ProseCadence {
        try await compile(prose: prose, locale: "en-US")
    }
}

// MARK: - NullProseCadenceCompiler
//
// Default wiring when no LLM adapter is available. Every call throws
// `.unavailable` so callers can short-circuit prose-driven registration
// with a "no model installed; type a cron expression instead" message.

public struct NullProseCadenceCompiler: ProseCadenceCompiler {
    public init() {}

    public func compile(prose: String, locale: String) async throws -> ProseCadence {
        throw ProseCadenceCompilerError.unavailable
    }
}

// MARK: - MockProseCadenceCompiler
//
// Test-time adapter. Maps prose → cron via a closure so each test can
// pin the compiler's behavior to a specific output (success, malformed
// cron, throw, etc.) without spinning up an LLM.

public struct MockProseCadenceCompiler: ProseCadenceCompiler {
    public typealias Handler = @Sendable (String, String) throws -> String
    private let handler: Handler

    public init(handler: @escaping Handler) {
        self.handler = handler
    }

    /// Convenience: every prose maps to `cron`.
    public init(constantCron cron: String) {
        self.handler = { _, _ in cron }
    }

    public func compile(prose: String, locale: String) async throws -> ProseCadence {
        let cron = try handler(prose, locale)
        guard CronToLaunchd.convert(cron) != nil else {
            throw ProseCadenceCompilerError.invalidCron(cron)
        }
        return ProseCadence(prose: prose, locale: locale, cron: cron)
    }
}

// MARK: - Errors

public enum ProseCadenceCompilerError: Error, Equatable, Sendable {
    /// No backend is configured or the model isn't downloaded.
    case unavailable
    /// The backend returned malformed JSON.
    case invalidJSON(String)
    /// The backend emitted a cron string that fails CronToLaunchd validation.
    case invalidCron(String)
    /// The inference timed out or was cancelled.
    case cancelled
}
