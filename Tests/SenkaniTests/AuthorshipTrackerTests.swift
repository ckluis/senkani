import Testing
import Foundation
@testable import Core

// Phase V.5 round 1 — `AuthorshipTracker` foundation tests.
// Locks the round 1 contract:
//   1. Enum has all four cases (incl. `.unset`).
//   2. Tracker is a pure facade with no inference path.
//   3. KB schema has the `authorship` column (migration v7) and the
//      EntityStore upsert path persists it explicitly.
//   4. NULL in the column round-trips as `nil` (legacy state),
//      distinct from the in-band `.unset` rawValue.
//   5. The default-arg facade form lands `.unset` — never silently
//      something else (Gebru's red flag).
//
// See `spec/roadmap.md` "V.5 — `AuthorshipTracker`" + the
// `phase-v5-authorship-tracker` backlog row.

// MARK: - Helpers

private func makeTempKB() -> (KnowledgeStore, String) {
    let path = "/tmp/senkani-authorship-test-\(UUID().uuidString).sqlite"
    return (KnowledgeStore(path: path), path)
}

private func cleanupKB(_ path: String) {
    let fm = FileManager.default
    try? fm.removeItem(atPath: path)
    try? fm.removeItem(atPath: path + "-wal")
    try? fm.removeItem(atPath: path + "-shm")
}

private func makeEntity(_ name: String) -> KnowledgeEntity {
    KnowledgeEntity(
        name: name,
        markdownPath: ".senkani/knowledge/\(name).md"
    )
}

// MARK: - AuthorshipTag enum

@Suite("AuthorshipTag — enum surface")
struct AuthorshipTagTests {

    @Test func allFourCasesPresent() {
        let cases = AuthorshipTag.allCases
        #expect(cases.contains(.aiAuthored))
        #expect(cases.contains(.humanAuthored))
        #expect(cases.contains(.mixed))
        #expect(cases.contains(.unset))
        #expect(cases.count == 4, "Round 1 ships exactly 4 cases")
    }

    @Test func rawValuesAreStableOnDisk() {
        // These rawValues are persisted to SQLite. Renaming any of
        // them is a schema break — this test is the canary.
        #expect(AuthorshipTag.aiAuthored.rawValue == "ai-authored")
        #expect(AuthorshipTag.humanAuthored.rawValue == "human-authored")
        #expect(AuthorshipTag.mixed.rawValue == "mixed")
        #expect(AuthorshipTag.unset.rawValue == "unset")
    }

    @Test func isExplicitGatesOnUnset() {
        #expect(AuthorshipTag.aiAuthored.isExplicit)
        #expect(AuthorshipTag.humanAuthored.isExplicit)
        #expect(AuthorshipTag.mixed.isExplicit)
        #expect(!AuthorshipTag.unset.isExplicit, "unset is the only non-explicit state")
    }
}

// MARK: - AuthorshipTracker facade

@Suite("AuthorshipTracker — pure facade, no inference")
struct AuthorshipTrackerFacadeTests {

    @Test func explicitChoicePassesThrough() {
        // Pass-through invariant: each case round-trips verbatim.
        for tag in AuthorshipTag.allCases {
            #expect(AuthorshipTracker.tag(forExplicitChoice: tag) == tag)
        }
    }

    @Test func unknownProvenanceAlwaysReturnsUnset() {
        // Gebru contract: never silently resolved to anything else.
        // Re-running ten times ensures no hidden state-dependent
        // inference creeps in.
        for _ in 0..<10 {
            #expect(AuthorshipTracker.tagForUnknownProvenance() == .unset)
        }
    }

    @Test func decodeNilReturnsUnsetSentinel() {
        // NULL column → `.unset`. Callers that need to distinguish
        // legacy NULL from in-band `.unset` must inspect the column
        // BEFORE calling decode.
        #expect(AuthorshipTracker.decode(nil) == .unset)
        #expect(AuthorshipTracker.decode("") == .unset)
    }

    @Test func decodeRoundtripsAllCases() {
        for tag in AuthorshipTag.allCases {
            let raw = AuthorshipTracker.encode(tag)
            #expect(AuthorshipTracker.decode(raw) == tag)
        }
    }

    @Test func decodeUnknownStringIsCorruptSignal() {
        // A non-NULL column whose value isn't a known rawValue is
        // a corrupt-row signal (returns nil). Callers should treat
        // that as "untagged" rather than crash; the prompt path
        // will heal it on next save.
        #expect(AuthorshipTracker.decode("definitely-not-a-tag") == nil)
        #expect(AuthorshipTracker.decode("HUMAN-AUTHORED") == nil, "case-sensitive")
    }
}

// MARK: - Schema + persistence (migration v7 + EntityStore)

@Suite("Authorship — KB schema + EntityStore persistence")
struct AuthorshipPersistenceTests {

    @Test func columnExistsAfterFreshInstall() {
        let (store, path) = makeTempKB()
        defer { cleanupKB(path) }

        // Fresh-install path goes through `EntityStore.setupSchema`
        // which lands the column via the idempotent ALTER guard.
        // We probe it with an upsert+read round-trip.
        _ = store.upsertEntity(makeEntity("ColumnProbe"), authorship: .humanAuthored)
        let entity = store.entity(named: "ColumnProbe")
        #expect(entity?.authorship == .humanAuthored)
    }

    @Test func explicitTagRoundTripsForEachCase() {
        let (store, path) = makeTempKB()
        defer { cleanupKB(path) }

        let cases: [(String, AuthorshipTag)] = [
            ("AlphaAI", .aiAuthored),
            ("BetaHuman", .humanAuthored),
            ("GammaMixed", .mixed),
            ("DeltaUnset", .unset)
        ]
        for (name, tag) in cases {
            _ = store.upsertEntity(makeEntity(name), authorship: tag)
        }
        for (name, tag) in cases {
            #expect(store.entity(named: name)?.authorship == tag,
                    "\(name) round-trips as \(tag.rawValue)")
        }
    }

    @Test func defaultFacadeArgLandsAsUnsetNotHuman() {
        // Critical test for Gebru's red flag. The single-arg facade
        // form must NEVER silently land as `.humanAuthored`. It
        // must land as `.unset` so the prompt path resolves it.
        let (store, path) = makeTempKB()
        defer { cleanupKB(path) }

        _ = store.upsertEntity(makeEntity("DefaultBehavior"))
        let entity = store.entity(named: "DefaultBehavior")
        #expect(entity?.authorship == .unset,
                "Default arg must be .unset — never silently humanAuthored")
        #expect(entity?.authorship != .humanAuthored,
                "Belt-and-suspenders: NOT humanAuthored")
    }

    @Test func upsertOverwritesAuthorshipOnConflict() {
        // The UPSERT path must let an operator change their mind.
        // First write `.unset`, then update to `.humanAuthored`.
        let (store, path) = makeTempKB()
        defer { cleanupKB(path) }

        _ = store.upsertEntity(makeEntity("Mutable"), authorship: .unset)
        #expect(store.entity(named: "Mutable")?.authorship == .unset)

        _ = store.upsertEntity(makeEntity("Mutable"), authorship: .humanAuthored)
        #expect(store.entity(named: "Mutable")?.authorship == .humanAuthored)
    }

    @Test func searchPreservesAuthorshipColumnIndex() {
        // The EntityStore search SQL was reshaped (snippet/rank
        // shifted by one column when authorship was inserted). The
        // load-bearing regression check is: the entity hydrating
        // out of search() carries the authorship value AND the rank
        // is a sane finite double (not a column-pun on the snippet
        // text). If the column indices drifted, rank would either
        // be 0 / NaN / a coerced string-to-double mess.
        let (store, path) = makeTempKB()
        defer { cleanupKB(path) }

        _ = store.upsertEntity(
            KnowledgeEntity(
                name: "SearchableEntity",
                markdownPath: ".senkani/knowledge/SearchableEntity.md",
                compiledUnderstanding: "the quick brown fox jumps over the lazy dog"
            ),
            authorship: .aiAuthored
        )

        let hits = store.search(query: "brown")
        #expect(hits.count == 1, "FTS finds the row")
        #expect(hits.first?.entity.name == "SearchableEntity")
        #expect(hits.first?.entity.authorship == .aiAuthored,
                "Authorship hydrates through search rowToEntity")
        // BM25 ranks are negative finite doubles in SQLite FTS5.
        // A column-index drift would produce 0.0 (not finite-but-zero)
        // or trigger a column-type cast error. Asserting finite +
        // non-zero is enough to detect either drift mode.
        let rank = hits.first?.bm25Rank ?? .nan
        #expect(rank.isFinite, "rank is a real double, not NaN")
        #expect(rank != 0.0, "rank is non-zero — proves SQL column 15 is bound")
    }
}
