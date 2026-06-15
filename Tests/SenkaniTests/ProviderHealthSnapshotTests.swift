import Testing
import Foundation
import SQLite3
@testable import Core

/// V.17b-1 — ProviderHealthSnapshot core: type + table + event-driven
/// refresh + `senkani provider refresh` probe + no-network invariant.
///
/// 7 tests per the build plan:
///   1. stale-TTL transition (>24h ⇒ .stale)
///   2. error-TTL transition (>7d ⇒ .error)
///   3. event-refresh: a turn_completed provider_runtime_event flips
///      last_refresh forward (no timer)
///   4. explicit-refresh: the probe upserts a fresh snapshot from local
///      --version (injected probe, no spawn)
///   5. no-network invariant: a representative refresh session writes
///      ZERO egress_decisions rows
///   6. provider absence: CLI not installed ⇒ cliInstalled=false +
///      remediation hint populated
///   7. auth-state enum coverage (signed_in / signed_out / expired /
///      unknown round-trip through the store)
@Suite("ProviderHealthSnapshot — V.17b-1 core")
struct ProviderHealthSnapshotTests {

    private static func makeTempDB() -> (SessionDatabase, String) {
        let path = "/tmp/senkani-v17b1-test-\(UUID().uuidString).sqlite"
        return (SessionDatabase(path: path), path)
    }

    private static func cleanupDB(_ db: SessionDatabase, _ path: String) {
        // Route through the single-source-of-truth helper so the primary
        // file AND all migration sidecars (.migrating / .schema.lock) are
        // reclaimed. `close(_:path:)` drains + closes the live handle before
        // unlinking, avoiding a deinit `sqlite3_close` on a deleted -wal/-shm.
        TempSessionDatabase.close(db, path: path)
    }

    // MARK: - 1 + 2: staleness derivation (pure, table-driven)

    @Test("staleness is a deterministic function of (lastRefresh, now, ttl): fresh / stale / error boundaries")
    func stalenessDerivation() {
        let ttl = ProviderHealthSnapshot.TTL.standard // 24h stale, 7d error
        let now = Date(timeIntervalSince1970: 10_000_000)

        func snap(ageSeconds: TimeInterval) -> ProviderHealthSnapshot {
            ProviderHealthSnapshot(
                providerID: "codex",
                cliInstalled: true,
                lastRefresh: now.addingTimeInterval(-ageSeconds),
                ttl: ttl
            )
        }

        // Fresh: just refreshed.
        #expect(snap(ageSeconds: 60).staleness(now: now) == .fresh)
        // Fresh: just under 24h.
        #expect(snap(ageSeconds: 24 * 3600 - 1).staleness(now: now) == .fresh)
        // Stale: exactly at 24h (inclusive of the older tier — fail-safe).
        #expect(snap(ageSeconds: 24 * 3600).staleness(now: now) == .stale)
        // Stale: between 24h and 7d.
        #expect(snap(ageSeconds: 3 * 24 * 3600).staleness(now: now) == .stale)
        // Stale: just under 7d.
        #expect(snap(ageSeconds: 7 * 24 * 3600 - 1).staleness(now: now) == .stale)
        // Error: exactly at 7d (inclusive of the older tier).
        #expect(snap(ageSeconds: 7 * 24 * 3600).staleness(now: now) == .error)
        // Error: well past 7d.
        #expect(snap(ageSeconds: 30 * 24 * 3600).staleness(now: now) == .error)
    }

    // MARK: - 3: event-driven refresh (no timer)

    @Test("a turn_completed provider_runtime_event flips the snapshot last_refresh forward (no timer)")
    func eventDrivenRefresh() {
        let (db, path) = Self.makeTempDB()
        defer { Self.cleanupDB(db, path) }

        // Seed a snapshot with an OLD last_refresh.
        let old = Date(timeIntervalSince1970: 1_000)
        db.providerHealthSnapshotStore.upsert(
            ProviderHealthSnapshot(providerID: "codex", cliInstalled: true, lastRefresh: old)
        )
        #expect(db.providerHealthSnapshotStore.read(providerID: "codex")?.lastRefresh == old)

        // A turn_completed event for that provider flips last_refresh forward.
        let newTime = Date(timeIntervalSince1970: 2_000_000)
        let event = ProviderRuntimeEvent(
            providerID: "codex",
            type: .turnCompleted,
            observedAt: newTime,
            rawPayloadHash: "evt-turn-1"
        )
        let outcome = db.providerRuntimeEventStore.insert(event: event)
        #expect(outcome == .insertedRow)

        let after = db.providerHealthSnapshotStore.read(providerID: "codex")
        #expect(after?.lastRefresh == newTime, "turn_completed must flip last_refresh forward")

        // A NON-turn_completed event does NOT flip last_refresh.
        let messageEvent = ProviderRuntimeEvent(
            providerID: "codex",
            type: .messageDelta,
            observedAt: Date(timeIntervalSince1970: 9_000_000),
            rawPayloadHash: "evt-msg-1"
        )
        db.providerRuntimeEventStore.insert(event: messageEvent)
        #expect(db.providerHealthSnapshotStore.read(providerID: "codex")?.lastRefresh == newTime,
                "non-turn_completed events must not refresh the snapshot")

        // A turn_completed for a provider with NO snapshot does NOT fabricate one.
        let orphan = ProviderRuntimeEvent(
            providerID: "gemini",
            type: .turnCompleted,
            observedAt: Date(),
            rawPayloadHash: "evt-orphan-1"
        )
        db.providerRuntimeEventStore.insert(event: orphan)
        #expect(db.providerHealthSnapshotStore.read(providerID: "gemini") == nil,
                "an event for an un-probed provider must not fabricate a snapshot row")
    }

    // MARK: - 4: explicit refresh via the probe (injected, no spawn)

    @Test("provider refresh upserts a fresh snapshot from the local probe (no spawn)")
    func explicitRefreshUpserts() {
        let (db, path) = Self.makeTempDB()
        defer { Self.cleanupDB(db, path) }

        let probe = ProviderHealthProbe { providerID in
            ProviderHealthProbe.LocalProbeResult(
                cliInstalled: true,
                version: "codex 1.4.2",
                authState: .signedIn,
                selectedModel: "gpt-5-codex",
                subscriptionState: "pro"
            )
        }
        let now = Date(timeIntervalSince1970: 5_000_000)
        let snapshot = probe.snapshot(providerID: "codex", now: now)
        db.providerHealthSnapshotStore.upsert(snapshot)

        let stored = db.providerHealthSnapshotStore.read(providerID: "codex")
        #expect(stored?.cliInstalled == true)
        #expect(stored?.version == "codex 1.4.2")
        #expect(stored?.authState == .signedIn)
        #expect(stored?.selectedModel == "gpt-5-codex")
        #expect(stored?.subscriptionState == "pro")
        #expect(stored?.lastRefresh == now)
        #expect(stored?.remediationHint == nil, "a signed-in installed provider needs no remediation hint")

        // A second refresh REPLACES the row (last-write-wins, one per provider).
        let later = probe.snapshot(providerID: "codex", now: now.addingTimeInterval(3600))
        db.providerHealthSnapshotStore.upsert(later)
        #expect(db.providerHealthSnapshotStore.readAll().filter { $0.providerID == "codex" }.count == 1)
        #expect(db.providerHealthSnapshotStore.read(providerID: "codex")?.lastRefresh == now.addingTimeInterval(3600))
    }

    // MARK: - 5: no-network invariant

    @Test("a representative refresh session writes ZERO egress_decisions rows (no-network invariant)")
    func noNetworkInvariant() {
        let (db, path) = Self.makeTempDB()
        defer { Self.cleanupDB(db, path) }

        let egressBefore = db.egressDecisionCount()

        // Representative session: an injected probe (no spawn, no network)
        // for two providers + a couple of event-driven refreshes.
        let probe = ProviderHealthProbe { providerID in
            ProviderHealthProbe.LocalProbeResult(cliInstalled: true, version: "\(providerID) 1.0.0", authState: .signedIn)
        }
        for pid in ["codex", "claude_code"] {
            db.providerHealthSnapshotStore.upsert(probe.snapshot(providerID: pid))
        }
        for i in 0..<3 {
            db.providerRuntimeEventStore.insert(event: ProviderRuntimeEvent(
                providerID: "codex",
                type: .turnCompleted,
                observedAt: Date(),
                rawPayloadHash: "no-net-evt-\(i)"
            ))
        }

        let egressAfter = db.egressDecisionCount()
        #expect(egressAfter == egressBefore, "provider-health refresh must write ZERO egress_decisions rows; before=\(egressBefore) after=\(egressAfter)")
    }

    // MARK: - 6: provider absence

    @Test("CLI not installed ⇒ cliInstalled=false + remediation hint populated")
    func providerAbsence() {
        let probe = ProviderHealthProbe { _ in .notInstalled }
        let snapshot = probe.snapshot(providerID: "opencode")
        #expect(snapshot.cliInstalled == false)
        #expect(snapshot.version == nil)
        #expect(snapshot.authState == .unknown)
        #expect(snapshot.remediationHint != nil)
        #expect(snapshot.remediationHint?.contains("opencode") == true)
        #expect(snapshot.remediationHint?.contains("install") == true)
    }

    // MARK: - 7: auth-state enum coverage (round-trip through the store)

    @Test("auth-state enum round-trips through the store: signed_in / signed_out / expired / unknown")
    func authStateRoundTrip() {
        let (db, path) = Self.makeTempDB()
        defer { Self.cleanupDB(db, path) }

        let cases: [(String, ProviderHealthSnapshot.AuthState)] = [
            ("p_signed_in", .signedIn),
            ("p_signed_out", .signedOut),
            ("p_expired", .expired),
            ("p_unknown", .unknown),
        ]
        for (pid, state) in cases {
            db.providerHealthSnapshotStore.upsert(
                ProviderHealthSnapshot(
                    providerID: pid,
                    cliInstalled: true,
                    authState: state,
                    lastRefresh: Date(timeIntervalSince1970: 1_000)
                )
            )
        }
        for (pid, state) in cases {
            #expect(db.providerHealthSnapshotStore.read(providerID: pid)?.authState == state,
                    "auth state \(state.rawValue) must round-trip for \(pid)")
        }
        // The store's raw-value column maps every enum case correctly.
        #expect(Set(ProviderHealthSnapshot.AuthState.allCases.map { $0.rawValue })
                == ["signed_in", "signed_out", "expired", "unknown"])
    }
}
