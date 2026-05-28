import Foundation
import Testing
@testable import Core
@testable import MLXProseCompiler

/// U.8b-2 — full mock-driven coverage for the MLX prose-cadence
/// compiler. Supersedes the U.8b-1 scaffold file (which only locked
/// the `.unavailable` contract). Mock-driven means: no Gemma model
/// download required, no MLX inference call. The real-model
/// integration test is deferred to U.8b-5.
///
/// Coverage:
///   - JSON parse: well-formed → returns cron.
///   - JSON parse: malformed JSON → `.invalidJSON(raw)`.
///   - JSON parse: missing `cron` field → `.invalidJSON(raw)`.
///   - JSON parse: extra fields ignored (forward-compatible).
///   - Cron-validation gate: range form (`1-5`) → `.invalidCron(cron)`.
///   - Locale gate: non-en throws `.unsupportedLocale` AND
///     `ensureModel()` is NOT entered.
///   - Cancellation: `Task.cancel()` before the body throws
///     `.cancelled` AND `ensureModel()` is NOT entered.
@Suite("MLXProseCadenceCompiler (U.8b-2)")
struct MLXProseCadenceCompilerTests {

    // MARK: - JSON parse + cron-validation gate (static, mock-driven)

    @Test
    func parseAndValidate_wellFormedJSON_returnsCron() throws {
        let cron = try MLXProseCadenceCompiler.parseAndValidate(
            raw: #"{"cron": "0 9 * * 1,2,3,4,5"}"#
        )
        #expect(cron == "0 9 * * 1,2,3,4,5")
    }

    @Test
    func parseAndValidate_malformedJSON_throwsInvalidJSON() throws {
        let raw = "not a json document"
        do {
            _ = try MLXProseCadenceCompiler.parseAndValidate(raw: raw)
            Issue.record("expected .invalidJSON")
        } catch let error as ProseCadenceCompilerError {
            guard case let .invalidJSON(reported) = error else {
                Issue.record("expected .invalidJSON, got \(error)")
                return
            }
            #expect(reported == raw)
        }
    }

    @Test
    func parseAndValidate_missingCronField_throwsInvalidJSON() throws {
        let raw = #"{"explanation": "every weekday at 9am"}"#
        do {
            _ = try MLXProseCadenceCompiler.parseAndValidate(raw: raw)
            Issue.record("expected .invalidJSON")
        } catch let error as ProseCadenceCompilerError {
            guard case .invalidJSON = error else {
                Issue.record("expected .invalidJSON, got \(error)")
                return
            }
        }
    }

    @Test
    func parseAndValidate_extraFieldsIgnored() throws {
        let cron = try MLXProseCadenceCompiler.parseAndValidate(
            raw: #"{"cron": "0 0 * * *", "explanation": "midnight"}"#
        )
        #expect(cron == "0 0 * * *")
    }

    @Test
    func parseAndValidate_rangeCronFailsValidationGate() throws {
        // The few-shot prompt instructs comma-lists; the gate catches
        // drift. Defense-in-depth.
        do {
            _ = try MLXProseCadenceCompiler.parseAndValidate(
                raw: #"{"cron": "0 0 * * 1-5"}"#
            )
            Issue.record("expected .invalidCron")
        } catch let error as ProseCadenceCompilerError {
            guard case let .invalidCron(cron) = error else {
                Issue.record("expected .invalidCron, got \(error)")
                return
            }
            #expect(cron == "0 0 * * 1-5")
        }
    }

    // MARK: - Locale gate (no MLX call)

    @Test
    func compile_nonEnglishLocale_throwsUnsupportedAndDoesNotLoadModel() async throws {
        let compiler = MLXProseCadenceCompiler()
        do {
            _ = try await compiler.compile(
                prose: "every day",
                locale: "fr-FR"
            )
            Issue.record("expected .unsupportedLocale")
        } catch let error as ProseCadenceCompilerError {
            guard case let .unsupportedLocale(locale) = error else {
                Issue.record("expected .unsupportedLocale, got \(error)")
                return
            }
            #expect(locale == "fr-FR")
        }
        let count = await compiler.ensureModelCallCountForTesting
        #expect(count == 0, "ensureModel() must NOT be called on locale rejection")
    }

    // MARK: - Cancellation (no MLX call)

    @Test
    func compile_cancellation_throwsCancelledAndDoesNotLoadModel() async throws {
        let compiler = MLXProseCadenceCompiler()
        let t = Task { () async throws -> ProseCadence in
            try await compiler.compile(
                prose: "every day",
                locale: "en-US"
            )
        }
        t.cancel()
        do {
            _ = try await t.value
            Issue.record("expected .cancelled")
        } catch let error as ProseCadenceCompilerError {
            guard case .cancelled = error else {
                Issue.record("expected .cancelled, got \(error)")
                return
            }
        } catch {
            Issue.record("expected ProseCadenceCompilerError.cancelled, got \(error)")
        }
        let count = await compiler.ensureModelCallCountForTesting
        #expect(count == 0, "ensureModel() must NOT be called on cancellation")
    }
}
