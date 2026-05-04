import Testing
import Foundation
@testable import Core

/// Locks in the half-open `[from, to)` semantics of
/// `CostLedger.rate(model:at:)` BEFORE the live ledger gains a real v2
/// entry. The shipped v1 snapshot uses `effectiveFrom: epoch,
/// effectiveTo: nil` for every model, so production rows never cross a
/// dated boundary today; the first off-by-one would otherwise surface
/// in production. Tests run against a synthetic two-version fixture
/// for `claude-haiku-3.5` injected via the internal `rate(model:at:in:)`
/// overload — production data stays untouched.
@Suite("CostLedger version-boundary resolution")
struct CostLedgerVersionBoundaryTests {

    // 2026-06-01 00:00:00 UTC — synthetic v1→v2 boundary.
    private static let boundary = Date(timeIntervalSince1970: 1_780_272_000)
    private static let oneSecond: TimeInterval = 1

    private static let fixture: [CostLedgerEntry] = [
        CostLedgerEntry(
            modelId: "claude-haiku-3.5",
            displayName: "Claude Haiku 3.5",
            inputPerMillion: 0.80,
            outputPerMillion: 4.0,
            cachedInputPerMillion: 0.08,
            effectiveFrom: Date(timeIntervalSince1970: 0),
            effectiveTo: boundary,
            version: 1
        ),
        CostLedgerEntry(
            modelId: "claude-haiku-3.5",
            displayName: "Claude Haiku 3.5",
            inputPerMillion: 1.00,
            outputPerMillion: 5.0,
            cachedInputPerMillion: 0.10,
            effectiveFrom: boundary,
            effectiveTo: nil,
            version: 2
        ),
    ]

    @Test func boundaryInstantBelongsToV2() {
        let entry = CostLedger.rate(model: "claude-haiku-3.5", at: Self.boundary, in: Self.fixture)
        #expect(entry?.version == 2)
        #expect(entry?.inputPerMillion == 1.00)
    }

    @Test func oneSecondBeforeBoundaryReturnsV1() {
        let at = Self.boundary.addingTimeInterval(-Self.oneSecond)
        let entry = CostLedger.rate(model: "claude-haiku-3.5", at: at, in: Self.fixture)
        #expect(entry?.version == 1)
        #expect(entry?.inputPerMillion == 0.80)
    }

    @Test func oneSecondAfterBoundaryReturnsV2() {
        let at = Self.boundary.addingTimeInterval(Self.oneSecond)
        let entry = CostLedger.rate(model: "claude-haiku-3.5", at: at, in: Self.fixture)
        #expect(entry?.version == 2)
        #expect(entry?.inputPerMillion == 1.00)
    }

    @Test func farPastReturnsV1() {
        let at = Date(timeIntervalSince1970: 1_000_000_000) // 2001-09-09
        let entry = CostLedger.rate(model: "claude-haiku-3.5", at: at, in: Self.fixture)
        #expect(entry?.version == 1)
    }

    @Test func farFutureReturnsV2() {
        let at = Date(timeIntervalSince1970: 4_000_000_000) // 2096-10-02
        let entry = CostLedger.rate(model: "claude-haiku-3.5", at: at, in: Self.fixture)
        #expect(entry?.version == 2)
    }

    /// Sub-second sanity: the boundary instant is the literal first
    /// nanosecond of v2. Any `at` strictly less than `boundary` — even
    /// by 1 ms — falls in v1.
    @Test func subSecondBeforeBoundaryReturnsV1() {
        let at = Self.boundary.addingTimeInterval(-0.001)
        let entry = CostLedger.rate(model: "claude-haiku-3.5", at: at, in: Self.fixture)
        #expect(entry?.version == 1)
    }

    /// Substring routing must still work against a synthetic ledger —
    /// confirms the test path uses the same algorithm as the public
    /// `rate(model:at:)` and isn't a parallel re-implementation.
    @Test func substringRoutingHonorsBoundary() {
        let beforeBoundary = Self.boundary.addingTimeInterval(-Self.oneSecond)
        let afterBoundary = Self.boundary.addingTimeInterval(Self.oneSecond)

        let v1 = CostLedger.rate(
            model: "claude-haiku-3.5-20241022",
            at: beforeBoundary,
            in: Self.fixture
        )
        let v2 = CostLedger.rate(
            model: "claude-haiku-3.5-20241022",
            at: afterBoundary,
            in: Self.fixture
        )

        #expect(v1?.version == 1)
        #expect(v2?.version == 2)
    }

    /// Outside-every-interval safety. With a fixture whose latest
    /// `effectiveTo` is set (no open-ended entry), an `at` past that
    /// timestamp must return nil — not silently fall back to the
    /// most-recent entry.
    @Test func dateAfterClosedFinalIntervalReturnsNil() {
        let closedFixture: [CostLedgerEntry] = [
            CostLedgerEntry(
                modelId: "claude-haiku-3.5",
                displayName: "Claude Haiku 3.5",
                inputPerMillion: 0.80,
                outputPerMillion: 4.0,
                cachedInputPerMillion: 0.08,
                effectiveFrom: Date(timeIntervalSince1970: 0),
                effectiveTo: Self.boundary,
                version: 1
            ),
        ]
        let at = Self.boundary.addingTimeInterval(Self.oneSecond)
        let entry = CostLedger.rate(model: "claude-haiku-3.5", at: at, in: closedFixture)
        #expect(entry == nil)
    }

    /// Three-version chain: confirms boundaries chain cleanly when
    /// `v1.effectiveTo == v2.effectiveFrom` and
    /// `v2.effectiveTo == v3.effectiveFrom`. Querying inside each
    /// interval returns the right version with no overlap.
    @Test func threeVersionChainHasNoOverlapAndNoGap() {
        let b1 = Self.boundary
        let b2 = b1.addingTimeInterval(86_400) // +1 day
        let chain: [CostLedgerEntry] = [
            CostLedgerEntry(
                modelId: "claude-haiku-3.5",
                displayName: "Claude Haiku 3.5",
                inputPerMillion: 0.80, outputPerMillion: 4.0, cachedInputPerMillion: 0.08,
                effectiveFrom: Date(timeIntervalSince1970: 0),
                effectiveTo: b1, version: 1
            ),
            CostLedgerEntry(
                modelId: "claude-haiku-3.5",
                displayName: "Claude Haiku 3.5",
                inputPerMillion: 1.00, outputPerMillion: 5.0, cachedInputPerMillion: 0.10,
                effectiveFrom: b1,
                effectiveTo: b2, version: 2
            ),
            CostLedgerEntry(
                modelId: "claude-haiku-3.5",
                displayName: "Claude Haiku 3.5",
                inputPerMillion: 1.20, outputPerMillion: 6.0, cachedInputPerMillion: 0.12,
                effectiveFrom: b2,
                effectiveTo: nil, version: 3
            ),
        ]

        #expect(CostLedger.rate(model: "claude-haiku-3.5", at: b1.addingTimeInterval(-1), in: chain)?.version == 1)
        #expect(CostLedger.rate(model: "claude-haiku-3.5", at: b1, in: chain)?.version == 2)
        #expect(CostLedger.rate(model: "claude-haiku-3.5", at: b2.addingTimeInterval(-1), in: chain)?.version == 2)
        #expect(CostLedger.rate(model: "claude-haiku-3.5", at: b2, in: chain)?.version == 3)
    }
}
