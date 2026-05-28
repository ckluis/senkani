import Foundation
import Testing
@testable import Core

/// U.8b-3 — selection seam for `CompositeProseCadenceCompiler`.
///
/// Validates the rule-first / MLX-fallback-on-recognition-failure
/// decision tree chosen at the 2026-05-28 operator interview (Q3).
/// Every test is mock-driven (no MLX cold load, no real model). The
/// real-model integration test is deferred to U.8b-5.
///
/// Coverage (6 seam cases):
///   (a) rule hits  → MLX never called (call count == 0).
///   (b) rule .unrecognizedPhrase → MLX hit, returns MLX's cron.
///   (c) rule .unsupportedLocale  → MLX hit; MLX also rejects locale;
///                                   composite re-throws MLX's
///                                   .unsupportedLocale (not rule's).
///   (d) rule .unrecognizedPhrase + MLX .unavailable → composite
///       re-throws .unavailable unchanged.
///   (e) rule .unrecognizedPhrase + MLX .invalidJSON → composite
///       re-throws .invalidJSON unchanged.
///   (f) rule .invalidCron → composite re-throws .invalidCron and
///       MLX is NEVER called (call count == 0). Defense-in-depth:
///       .invalidCron is operator-actionable; falling through to
///       MLX would mask a real bug in the rule arm.
@Suite("CompositeProseCadenceCompiler (U.8b-3 selection seam)")
struct CompositeProseCadenceCompilerTests {

    /// Call-counting wrapper around any inner compiler. Used as the
    /// MLX arm so each seam test can assert how many times MLX was
    /// reached. Actor satisfies `Sendable` for the `ProseCadenceCompiler`
    /// protocol with no `@unchecked` needed.
    private actor CallCountingMockCompiler: ProseCadenceCompiler {
        typealias Handler = @Sendable (String, String) throws -> ProseCadence
        private let handler: Handler
        private(set) var callCount: Int = 0

        init(handler: @escaping Handler) {
            self.handler = handler
        }

        func compile(prose: String, locale: String) async throws -> ProseCadence {
            callCount += 1
            return try handler(prose, locale)
        }
    }

    // Convenience constructors for the patterns we need.

    /// MLX arm that, when called, returns a fixed cron.
    private func mlxReturning(_ cron: String) -> CallCountingMockCompiler {
        CallCountingMockCompiler { prose, locale in
            ProseCadence(prose: prose, locale: locale, cron: cron)
        }
    }

    /// MLX arm that, when called, throws a specific `ProseCadenceCompilerError`.
    private func mlxThrowing(_ error: ProseCadenceCompilerError) -> CallCountingMockCompiler {
        CallCountingMockCompiler { _, _ in throw error }
    }

    /// Rule arm that returns a valid cron without error.
    private func ruleReturning(_ cron: String) -> MockProseCadenceCompiler {
        MockProseCadenceCompiler(constantCron: cron)
    }

    /// Rule arm that throws a specific `ProseCadenceCompilerError`.
    private func ruleThrowing(_ error: ProseCadenceCompilerError) -> MockProseCadenceCompiler {
        MockProseCadenceCompiler { _, _ in throw error }
    }

    // MARK: - (a) rule hits → MLX never called

    @Test("rule hit → MLX is not called (call count stays 0)")
    func ruleHit_mlxNeverCalled() async throws {
        let rule = ruleReturning("0 9 * * 1,2,3,4,5")
        let mlx = mlxReturning("0 12 * * *") // would-be MLX answer, never reached
        let composite = CompositeProseCadenceCompiler(rule: rule, mlx: mlx)

        let cadence = try await composite.compile(
            prose: "every weekday at 9am",
            locale: "en-US"
        )

        #expect(cadence.cron == "0 9 * * 1,2,3,4,5")
        #expect(cadence.prose == "every weekday at 9am")
        #expect(cadence.locale == "en-US")
        let mlxCalls = await mlx.callCount
        #expect(mlxCalls == 0, "MLX must not be called when the rule arm succeeds.")
    }

    // MARK: - (b) rule .unrecognizedPhrase → MLX hit

    @Test("rule .unrecognizedPhrase → MLX is called and its result is returned")
    func ruleUnrecognized_mlxHit() async throws {
        let rule = ruleThrowing(.unrecognizedPhrase("every other Tuesday at 6pm"))
        let mlx = mlxReturning("0 18 * * 2/2")
        let composite = CompositeProseCadenceCompiler(rule: rule, mlx: mlx)

        let cadence = try await composite.compile(
            prose: "every other Tuesday at 6pm",
            locale: "en-US"
        )

        #expect(cadence.cron == "0 18 * * 2/2")
        let mlxCalls = await mlx.callCount
        #expect(mlxCalls == 1, "MLX must be called exactly once on rule's .unrecognizedPhrase.")
    }

    // MARK: - (c) rule .unsupportedLocale → MLX hit (defensive)

    @Test("rule .unsupportedLocale → MLX is called; MLX's .unsupportedLocale propagates")
    func ruleUnsupportedLocale_mlxHit_propagatesMLXError() async throws {
        let rule = ruleThrowing(.unsupportedLocale("fr-FR"))
        let mlx = mlxThrowing(.unsupportedLocale("fr-FR"))
        let composite = CompositeProseCadenceCompiler(rule: rule, mlx: mlx)

        do {
            _ = try await composite.compile(prose: "tous les jours à midi", locale: "fr-FR")
            Issue.record("expected .unsupportedLocale to be thrown")
            return
        } catch let e as ProseCadenceCompilerError {
            #expect(e == .unsupportedLocale("fr-FR"))
        }
        // Proves the error came from MLX, not from rule: MLX was hit.
        let mlxCalls = await mlx.callCount
        #expect(mlxCalls == 1, "MLX must be called on rule's .unsupportedLocale; thrown error is MLX's verdict.")
    }

    // MARK: - (d) MLX .unavailable re-throw

    @Test("rule .unrecognizedPhrase + MLX .unavailable → composite re-throws .unavailable")
    func mlxUnavailable_reThrownUnchanged() async throws {
        let rule = ruleThrowing(.unrecognizedPhrase("first day of every month"))
        let mlx = mlxThrowing(.unavailable)
        let composite = CompositeProseCadenceCompiler(rule: rule, mlx: mlx)

        do {
            _ = try await composite.compile(prose: "first day of every month", locale: "en-US")
            Issue.record("expected .unavailable to be thrown")
            return
        } catch let e as ProseCadenceCompilerError {
            #expect(e == .unavailable)
        }
        let mlxCalls = await mlx.callCount
        #expect(mlxCalls == 1, "MLX must be called on rule's .unrecognizedPhrase.")
    }

    // MARK: - (e) MLX .invalidJSON re-throw

    @Test("rule .unrecognizedPhrase + MLX .invalidJSON → composite re-throws .invalidJSON")
    func mlxInvalidJSON_reThrownUnchanged() async throws {
        let rule = ruleThrowing(.unrecognizedPhrase("twice a day on weekdays"))
        let mlx = mlxThrowing(.invalidJSON("garbage"))
        let composite = CompositeProseCadenceCompiler(rule: rule, mlx: mlx)

        do {
            _ = try await composite.compile(prose: "twice a day on weekdays", locale: "en-US")
            Issue.record("expected .invalidJSON(\"garbage\") to be thrown")
            return
        } catch let e as ProseCadenceCompilerError {
            #expect(e == .invalidJSON("garbage"))
        }
        let mlxCalls = await mlx.callCount
        #expect(mlxCalls == 1, "MLX must be called on rule's .unrecognizedPhrase.")
    }

    // MARK: - (f) rule .invalidCron re-throw (no MLX fall-through)

    @Test("rule .invalidCron → composite re-throws; MLX is never called")
    func ruleInvalidCron_reThrownAndMLXNeverCalled() async throws {
        let rule = ruleThrowing(.invalidCron("0 9 * * X"))
        let mlx = mlxReturning("0 9 * * 1,2,3,4,5") // would-be MLX answer, never reached
        let composite = CompositeProseCadenceCompiler(rule: rule, mlx: mlx)

        do {
            _ = try await composite.compile(prose: "every weekday at 9am", locale: "en-US")
            Issue.record("expected .invalidCron to be thrown")
            return
        } catch let e as ProseCadenceCompilerError {
            #expect(e == .invalidCron("0 9 * * X"))
        }
        let mlxCalls = await mlx.callCount
        #expect(mlxCalls == 0, "MLX must NOT be called on rule's .invalidCron — that's operator-actionable.")
    }
}
