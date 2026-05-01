import Testing
import Foundation
@testable import Core

// Phase V.5b — `AuthorshipPromptResolver` tests.
// Locks the V.5b contract:
//   1. Predicate is total: nil + `.unset` prompt; the three explicit
//      tags don't.
//   2. Resolver is a pure pass-through (no inference, no defaulting).
//   3. Podmajersky-reviewed copy strings are stable.
//   4. The save-path bypass works end-to-end: an explicit `authorship`
//      argument lands the chosen tag without touching the prompt path.
//
// See `spec/roadmap.md` "V.5 — `AuthorshipTracker`" round 2 (V.5b)
// and the `phase-v5b-authorship-ui-prompts` backlog row.

@Suite("AuthorshipPromptResolver — predicate")
struct AuthorshipPromptResolverPredicateTests {

    @Test func unsetPriorTriggersPrompt() {
        #expect(AuthorshipPromptResolver.needsPrompt(priorAuthorship: .unset))
    }

    @Test func nilPriorTriggersPrompt() {
        // Legacy NULL row — column was never written through the V.5
        // path. Same operator-decision-required state as `.unset`.
        #expect(AuthorshipPromptResolver.needsPrompt(priorAuthorship: nil))
    }

    @Test func aiAuthoredPriorSkipsPrompt() {
        #expect(!AuthorshipPromptResolver.needsPrompt(priorAuthorship: .aiAuthored))
    }

    @Test func humanAuthoredPriorSkipsPrompt() {
        #expect(!AuthorshipPromptResolver.needsPrompt(priorAuthorship: .humanAuthored))
    }

    @Test func mixedPriorSkipsPrompt() {
        #expect(!AuthorshipPromptResolver.needsPrompt(priorAuthorship: .mixed))
    }
}

@Suite("AuthorshipPromptResolver — resolution")
struct AuthorshipPromptResolverResolutionTests {

    // Pure pass-through: no content inspection, no defaulting.
    // Every input maps to itself.
    @Test func resolveIsPassThrough() {
        for tag in AuthorshipTag.allCases {
            #expect(AuthorshipPromptResolver.resolve(choice: tag) == tag)
        }
    }
}

@Suite("AuthorshipPromptResolver — Podmajersky copy")
struct AuthorshipPromptResolverCopyTests {

    // Voice rules: 1-line verb-first question, no marketing voice,
    // no jargon. Locks the strings so a casual edit can't drift the
    // voice without a deliberate test update.
    @Test func questionCopyIsVerbFirstAndShort() {
        let q = AuthorshipPromptResolver.questionCopy
        #expect(!q.isEmpty)
        #expect(q.count <= 30, "1-line question must stay short (got \(q.count) chars)")
        #expect(q.hasSuffix("?"), "verb-first question form ends in '?'")
        #expect(!q.contains("\n"), "must be one line")
    }

    @Test func buttonLabelsMatchEnumDisplayLabels() {
        // The three primary buttons mirror `AuthorshipTag.displayLabel`
        // exactly so the prompt copy and the badge copy never drift.
        #expect(AuthorshipPromptResolver.aiButtonLabel    == AuthorshipTag.aiAuthored.displayLabel)
        #expect(AuthorshipPromptResolver.humanButtonLabel == AuthorshipTag.humanAuthored.displayLabel)
        #expect(AuthorshipPromptResolver.mixedButtonLabel == AuthorshipTag.mixed.displayLabel)
    }

    @Test func skipLabelExistsAndIsDistinct() {
        // Skip is a tertiary action — it MUST exist (Cavoukian: never
        // force a tag) and MUST be distinct from the three primary
        // buttons so the operator can never confuse "deferral" with
        // "explicit choice".
        let skip = AuthorshipPromptResolver.skipButtonLabel
        #expect(!skip.isEmpty)
        #expect(skip != AuthorshipPromptResolver.aiButtonLabel)
        #expect(skip != AuthorshipPromptResolver.humanButtonLabel)
        #expect(skip != AuthorshipPromptResolver.mixedButtonLabel)
    }
}

@Suite("AuthorshipPromptResolver — save-path bypass")
struct AuthorshipPromptResolverBypassTests {

    // Pure-headless callers (CLI, tests, programmatic seeds) pass an
    // explicit tag at the API boundary and never touch the prompt.
    // This locks the bypass: an explicit `.humanAuthored` upsert
    // round-trips the tag, and the prompt predicate is `false` against
    // the resulting row.
    @Test func explicitTagBypassesPromptOnRoundTrip() {
        let path = "/tmp/senkani-v5b-bypass-\(UUID().uuidString).sqlite"
        defer {
            let fm = FileManager.default
            try? fm.removeItem(atPath: path)
            try? fm.removeItem(atPath: path + "-wal")
            try? fm.removeItem(atPath: path + "-shm")
        }
        let store = KnowledgeStore(path: path)

        let entity = KnowledgeEntity(
            name: "BypassProbe",
            markdownPath: ".senkani/knowledge/BypassProbe.md"
        )
        _ = store.upsertEntity(entity, authorship: .humanAuthored)

        guard let read = store.entity(named: "BypassProbe") else {
            Issue.record("Entity disappeared after explicit-tag upsert")
            return
        }
        #expect(read.authorship == .humanAuthored)
        // The row's prior tag is now explicit — a future save on this
        // row would NOT trigger the prompt path.
        #expect(!AuthorshipPromptResolver.needsPrompt(priorAuthorship: read.authorship))
    }
}
