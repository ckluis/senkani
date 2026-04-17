import Testing
import Foundation
@testable import Core

/// Luminary wave 2026-04-17 — `senkani stats --security` dashboard tests.
/// Exercises the pure `render(projectRows:globalRows:options:)` path so the
/// singleton DB is not touched.
@Suite("SecurityEventsFormatter")
struct SecurityEventsFormatterTests {

    private static func row(
        project: String = "",
        type: String,
        count: Int,
        last: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) -> SessionDatabase.EventCountRow {
        SessionDatabase.EventCountRow(
            projectRoot: project,
            eventType: type,
            count: count,
            firstSeenAt: last,
            lastSeenAt: last
        )
    }

    // MARK: - Empty state

    @Test func noRowsReturnsEmptyString() {
        let out = SecurityEventsFormatter.render(
            projectRows: [],
            globalRows: [],
            options: .init()
        )
        #expect(out.isEmpty, "no rows → empty string (quiet dashboard on fresh install)")
    }

    // MARK: - Terse

    @Test func tersePrintsOneLinePerType() {
        let out = SecurityEventsFormatter.render(
            projectRows: [],
            globalRows: [
                Self.row(type: "security.injection.detected", count: 4),
                Self.row(type: "security.ssrf.blocked", count: 1)
            ],
            options: .init(verbose: false)
        )
        #expect(out.contains("security.injection.detected  4"))
        #expect(out.contains("security.ssrf.blocked  1"))
        #expect(!out.contains("last="), "terse hides last-seen — verbose only")
    }

    @Test func terseSumsProjectAndGlobalForSameType() {
        let out = SecurityEventsFormatter.render(
            projectRows: [Self.row(project: "/p", type: "security.injection.detected", count: 3)],
            globalRows: [Self.row(type: "security.injection.detected", count: 2)],
            options: .init(verbose: false)
        )
        #expect(out.contains("security.injection.detected  5"),
                "terse collapses scope for same event type, got:\n\(out)")
    }

    @Test func terseOrdersSecurityBeforeRetentionBeforeSchema() {
        let out = SecurityEventsFormatter.render(
            projectRows: [],
            globalRows: [
                Self.row(type: "schema.migration.applied", count: 1),
                Self.row(type: "retention.pruned.token_events", count: 100),
                Self.row(type: "security.injection.detected", count: 4)
            ],
            options: .init(verbose: false)
        )
        let secIdx = out.range(of: "security.")!.lowerBound
        let retIdx = out.range(of: "retention.")!.lowerBound
        let schIdx = out.range(of: "schema.")!.lowerBound
        #expect(secIdx < retIdx, "security.* must precede retention.*")
        #expect(retIdx < schIdx, "retention.* must precede schema.*")
    }

    // MARK: - Gelman: rate annotation

    @Test func securityRateShownWhenDenominatorProvided() {
        let out = SecurityEventsFormatter.render(
            projectRows: [],
            globalRows: [Self.row(type: "security.injection.detected", count: 4)],
            options: .init(verbose: false, totalCommands: 200)
        )
        #expect(out.contains("(4/200 = 2.00%)"),
                "Gelman rate must attach when denominator > 0, got:\n\(out)")
    }

    @Test func retentionEventGetsNoRateEvenWithDenominator() {
        let out = SecurityEventsFormatter.render(
            projectRows: [],
            globalRows: [Self.row(type: "retention.pruned.token_events", count: 100)],
            options: .init(verbose: false, totalCommands: 200)
        )
        #expect(!out.contains("="), "retention.* is not a per-command rate; no rate suffix")
        #expect(out.contains("retention.pruned.token_events  100"))
    }

    @Test func zeroDenominatorOmitsRate() {
        let out = SecurityEventsFormatter.render(
            projectRows: [],
            globalRows: [Self.row(type: "security.injection.detected", count: 4)],
            options: .init(verbose: false, totalCommands: 0)
        )
        #expect(!out.contains("%)"), "zero-commands DB must not divide-by-zero into the output")
    }

    // MARK: - Cavoukian: project path redaction

    @Test func verboseRedactsProjectRootWithForeignUser() {
        let out = SecurityEventsFormatter.render(
            projectRows: [Self.row(project: "/Users/alice/secret", type: "security.injection.detected", count: 1)],
            globalRows: [],
            options: .init(verbose: true)
        )
        #expect(!out.contains("alice"),
                "username must not reach the dashboard, got:\n\(out)")
        #expect(out.contains("/Users/***") || out.contains("~"),
                "path must be redacted to /Users/*** or ~, got:\n\(out)")
    }

    @Test func verboseShowsLastSeenAndPerRow() {
        let out = SecurityEventsFormatter.render(
            projectRows: [],
            globalRows: [Self.row(type: "security.injection.detected", count: 4)],
            options: .init(verbose: true)
        )
        #expect(out.contains("[global]"))
        #expect(out.contains("count=4"))
        #expect(out.contains("last="))
    }
}
