import Testing
import Foundation
@testable import Core

/// `RuleBasedProseCadenceCompiler` (schedule-cli-prose-flag-2026-05-21) —
/// the deterministic, MLX-free production compiler for `senkani schedule
/// create --prose`. Maps a curated set of common English cadence phrases
/// to a 5-field cron, validated by `CronToLaunchd.convert`. No silent
/// fallback: unrecognized phrases and non-English locales throw.
@Suite("RuleBasedProseCadenceCompiler (U.8 prose)")
struct RuleBasedProseCadenceCompilerTests {

    // MARK: - (a) phrase → cron table

    @Test("Supported phrases compile to the expected cron",
          arguments: [
            ("hourly",                      "0 * * * *"),
            ("daily",                       "0 0 * * *"),
            ("weekly",                      "0 0 * * 0"),
            ("every minute",                "* * * * *"),
            ("every hour",                  "0 * * * *"),
            ("every day",                   "0 0 * * *"),
            ("every 5 minutes",             "*/5 * * * *"),
            ("every 30 minutes",            "*/30 * * * *"),
            ("every 6 hours",               "0 */6 * * *"),
            ("every 2 hours",               "0 */2 * * *"),
            ("every day at 9am",            "0 9 * * *"),
            ("every day at 9:30am",         "30 9 * * *"),
            ("every day at 14:00",          "0 14 * * *"),
            ("every day at 2pm",            "0 14 * * *"),
            ("every day at 12am",           "0 0 * * *"),
            ("every day at 12pm",           "0 12 * * *"),
            ("every weekday at 9am",        "0 9 * * 1,2,3,4,5"),
            ("every weekday at 8:15",       "15 8 * * 1,2,3,4,5"),
            ("every monday at 9am",         "0 9 * * 1"),
            ("every sunday at 6pm",         "0 18 * * 0"),
            ("every fri at 17:30",          "30 17 * * 5"),
            // case-insensitive + surplus whitespace
            ("Every Weekday at 9AM",        "0 9 * * 1,2,3,4,5"),
            ("  every   day  at  9am  ",    "0 9 * * *"),
          ])
    func phraseCompilesToExpectedCron(phrase: String, expected: String) async throws {
        let compiler = RuleBasedProseCadenceCompiler()
        let result = try await compiler.compile(prose: phrase, locale: "en-US")
        #expect(result.cron == expected, "phrase \"\(phrase)\" should compile to \(expected), got \(result.cron)")
        // Every emitted cron must validate via the gate.
        #expect(CronToLaunchd.convert(result.cron) != nil, "emitted cron \(result.cron) must pass CronToLaunchd.convert")
        // ProseCadence carries the original prose verbatim.
        #expect(result.prose == phrase)
        #expect(result.locale == "en-US")
    }

    @Test("No emitted weekday cron uses the unsupported range form `1-5`")
    func weekdayUsesCommaFormNotRange() async throws {
        // CronToLaunchd.convert rejects ranges; assert the compiler never
        // emits one (the trap the acceptance bullet's literal `1-5` would hit).
        let compiler = RuleBasedProseCadenceCompiler()
        let result = try await compiler.compile(prose: "every weekday at 9am", locale: "en-US")
        #expect(!result.cron.contains("-"))
        #expect(result.cron.contains("1,2,3,4,5"))
    }

    // MARK: - (b) unrecognized phrases throw

    @Test("Unrecognized phrases throw .unrecognizedPhrase (no silent fallback)",
          arguments: [
            "every blue moon",
            "sometimes",
            "",
            "   ",
            "every 0 minutes",       // N must be > 0
            "every 90 minutes",      // out of 1...59 range
            "every 30 hours",        // out of 1...23 range
            "every day at 25:00",    // invalid hour
            "every day at 9:99am",   // invalid minute
            "every funday at 9am",   // not a weekday
            "at 9am",                // no subject
          ])
    func unrecognizedPhraseThrows(phrase: String) async {
        let compiler = RuleBasedProseCadenceCompiler()
        do {
            _ = try await compiler.compile(prose: phrase, locale: "en-US")
            Issue.record("expected \"\(phrase)\" to throw .unrecognizedPhrase")
        } catch let error as ProseCadenceCompilerError {
            if case .unrecognizedPhrase(let echoed) = error {
                #expect(echoed == phrase)
            } else {
                Issue.record("expected .unrecognizedPhrase for \"\(phrase)\", got \(error)")
            }
        } catch {
            Issue.record("unexpected error type for \"\(phrase)\": \(error)")
        }
    }

    // MARK: - (c) non-English locales throw

    @Test("Non-English locales throw .unsupportedLocale",
          arguments: ["fr-FR", "de_DE", "ja-JP", "es", "zh-Hant"])
    func nonEnglishLocaleThrows(locale: String) async {
        let compiler = RuleBasedProseCadenceCompiler()
        do {
            _ = try await compiler.compile(prose: "every weekday at 9am", locale: locale)
            Issue.record("expected locale \"\(locale)\" to throw .unsupportedLocale")
        } catch let error as ProseCadenceCompilerError {
            if case .unsupportedLocale(let echoed) = error {
                #expect(echoed == locale)
            } else {
                Issue.record("expected .unsupportedLocale for \"\(locale)\", got \(error)")
            }
        } catch {
            Issue.record("unexpected error type for \"\(locale)\": \(error)")
        }
    }

    @Test("English locale variants are accepted",
          arguments: ["en", "en-US", "en_US", "en-GB", "EN-us"])
    func englishLocaleVariantsAccepted(locale: String) async throws {
        let compiler = RuleBasedProseCadenceCompiler()
        let result = try await compiler.compile(prose: "daily", locale: locale)
        #expect(result.cron == "0 0 * * *")
        #expect(result.locale == locale)
    }

    @Test("The error userMessage points the operator at a recovery path")
    func errorMessagesAreActionable() {
        #expect(ProseCadenceCompilerError.unrecognizedPhrase("every blue moon").userMessage.contains("--cron"))
        #expect(ProseCadenceCompilerError.unsupportedLocale("fr-FR").userMessage.contains("--locale en-US"))
    }
}
