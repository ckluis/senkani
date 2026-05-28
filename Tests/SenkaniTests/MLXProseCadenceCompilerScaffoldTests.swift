import Foundation
import Testing
@testable import Core
@testable import MLXProseCompiler

/// U.8b-1 scaffold tests — locks the actor's `.unavailable` contract
/// in place so U.8b-2's body fill (`ensureModel()` + JSON parse + cron
/// gate) can replace the throw without inadvertently changing the
/// actor's public shape, init signature, or wrapper topology.
///
/// This file ships in U.8b-1 and stays green throughout U.8b-2…U.8b-5;
/// U.8b-2 will append additional `@Test`s for the real-model path,
/// each gated on `ModelManager.shared.isReady(_:)` per the
/// `MLPipelineTests` skip-on-no-model precedent (see
/// `phase-u8b-prose-compiler-adapter`'s reusable-codebase-patterns
/// table, child u8b-5 row).
@Suite("MLXProseCadenceCompiler scaffold (U.8b-1)")
struct MLXProseCadenceCompilerScaffoldTests {

    /// Lock-in for the scaffold contract: every input throws
    /// `.unavailable` until U.8b-2 fills the body. The specific phrase
    /// and locale come from the item's `## Acceptance` bullet 5.
    @Test
    func compileThrowsUnavailableOnEveryInput() async {
        let compiler = MLXProseCadenceCompiler()
        do {
            _ = try await compiler.compile(
                prose: "every weekday at 9am",
                locale: "en-US"
            )
            Issue.record("expected MLXProseCadenceCompiler scaffold to throw .unavailable")
        } catch let error as ProseCadenceCompilerError {
            #expect(error == .unavailable)
        } catch {
            Issue.record("expected ProseCadenceCompilerError.unavailable, got \(error)")
        }
    }
}
