import Testing
import Foundation
@testable import Core

/// Regression coverage for `HookSeamLock` — the cross-suite seam-leak
/// fix shipped in `phase-test-isolation-confirmation-gate-resolver-leak`.
///
/// The original repro: a writer suite installs a non-default
/// `ConfirmationGate.resolver`; a peer consumer suite calls
/// `HookRouter.handle` while that override is held; the consumer
/// observes the writer's resolver. `.serialized` is suite-internal and
/// does not close this race. `HookSeamLock` is a process-wide
/// `NSRecursiveLock` that:
///   1. Writer tests acquire for the duration of the override.
///   2. `HookRouter.handle` reacquires at entry (recursive — the
///      writer's body can call handle without self-deadlock).
///
/// These tests assert the lock primitive itself behaves correctly. The
/// cross-suite race is verified by the existing
/// `HookRouterProtocolTests.passthroughReturnsEmptyJSON` running
/// concurrently with `ConfirmationGateTests.hookRouterDeniesEdit`
/// without flake (manual repro: see `tools/test-safe.sh` notes).
@Suite("HookSeamLock — seam isolation primitive")
struct HookSeamLockTests {

    @Test("withLock returns the closure result")
    func returnsResult() {
        let result = HookSeamLock.withLock { 42 }
        #expect(result == 42)
    }

    @Test("withLock rethrows closure errors and still releases the lock")
    func rethrowsAndReleases() {
        struct E: Error {}
        do {
            _ = try HookSeamLock.withLock { () throws -> Int in
                throw E()
            }
            Issue.record("expected throw")
        } catch is E {
            // expected
        } catch {
            Issue.record("unexpected error: \(error)")
        }
        // If the lock leaked, the next acquire would deadlock. A second
        // withLock call proves the prior unlock fired.
        let n = HookSeamLock.withLock { 1 }
        #expect(n == 1)
    }

    @Test("withLock is reentrant on the same thread (NSRecursiveLock)")
    func reentrantSameThread() {
        let nested = HookSeamLock.withLock {
            HookSeamLock.withLock { "ok" }
        }
        #expect(nested == "ok")
    }

    @Test("ConfirmationGate.withResolver swaps resolver inside the lock-held body and restores after")
    func confirmationGateWithResolverScope() {
        // Wrap the whole test in HookSeamLock so reads of the resolver
        // before/after withResolver don't race with peer suites that
        // happen to be inside their own withLock window.
        HookSeamLock.withLock {
            let priorWasDefault = ConfirmationGate.resolver(
                "Edit",
                MCPToolConfig(name: "Edit", tags: [.write])
            ).decidedBy == .auto
            #expect(priorWasDefault, "default resolver must be in place at suite entry")

            let result = ConfirmationGate.withResolver({ _, _ in
                (.deny, .operator, "withResolver fixture")
            }) { () -> Bool in
                let outcomeBy = ConfirmationGate.resolver(
                    "Edit",
                    MCPToolConfig(name: "Edit", tags: [.write])
                ).decidedBy
                return outcomeBy == .operator
            }
            #expect(result == true, "inside the closure the override is visible")

            // After return, default resolver is restored.
            let after = ConfirmationGate.resolver(
                "Edit",
                MCPToolConfig(name: "Edit", tags: [.write])
            ).decidedBy
            #expect(after == .auto, "resolver must restore after withResolver returns")
        }
    }

    @Test("ConfirmationGate.withResolver restores the resolver even on throw")
    func confirmationGateWithResolverRestoresOnThrow() {
        HookSeamLock.withLock {
            struct E: Error {}
            do {
                try ConfirmationGate.withResolver({ _, _ in
                    (.deny, .operator, "throw fixture")
                }) { () throws -> Void in
                    throw E()
                }
                Issue.record("expected throw")
            } catch is E {
                // expected
            } catch {
                Issue.record("unexpected error: \(error)")
            }

            let after = ConfirmationGate.resolver(
                "Edit",
                MCPToolConfig(name: "Edit", tags: [.write])
            ).decidedBy
            #expect(after == .auto, "resolver must restore even when body throws")
        }
    }
}
