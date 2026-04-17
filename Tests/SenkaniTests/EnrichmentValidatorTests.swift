import Testing
import Foundation
@testable import Core

@Suite("EnrichmentValidator (F+3 Round 6)")
struct EnrichmentValidatorTests {

    private let live = """
    # Foo

    **Type:** class

    ## Compiled Understanding

    Foo is the main coordinator for the compound-learning loop. It schedules post-session analysis, gates proposals through the regression check, and persists artifacts to the typed-artifact store.

    ## Relations
    - depends_on: Bar
    """

    @Test func identicalProposedYieldsNoConcerns() {
        let result = EnrichmentValidator.validate(live: live, proposed: live)
        #expect(result.isSafe)
    }

    @Test func flagsInformationLoss() {
        let stripped = """
        # Foo

        ## Compiled Understanding

        Foo is a coordinator.
        """
        let result = EnrichmentValidator.validate(live: live, proposed: stripped)
        #expect(!result.isSafe)
        #expect(result.concerns.contains {
            if case .informationLoss = $0 { return true } else { return false }
        })
    }

    @Test func flagsContradiction() {
        let livePositive = """
        # Foo

        ## Compiled Understanding

        SessionDatabase is an actor-based singleton that serializes all writes.
        """
        let proposedNegative = """
        # Foo

        ## Compiled Understanding

        SessionDatabase is not an actor and does not serialize writes — it uses NSLock with per-table semantics.
        """
        let result = EnrichmentValidator.validate(live: livePositive, proposed: proposedNegative)
        #expect(result.concerns.contains {
            if case .contradiction = $0 { return true } else { return false }
        })
    }

    @Test func flagsExcessiveRewrite() {
        let proposal = """
        # Foo

        ## Compiled Understanding

        Entirely different text using completely unrelated vocabulary like zebra giraffe elephant hippopotamus flamingo.
        """
        let result = EnrichmentValidator.validate(live: live, proposed: proposal)
        #expect(result.concerns.contains {
            if case .excessiveRewrite = $0 { return true } else { return false }
        })
    }

    @Test func extractHandlesMissingSection() {
        let body = "# Foo\n\nNo section here."
        #expect(EnrichmentValidator.extractCompiledUnderstanding(body) == "")
    }

    @Test func extractStopsAtNextHeading() {
        let body = """
        # Foo

        ## Compiled Understanding

        First paragraph.

        ## Relations
        - other
        """
        let extracted = EnrichmentValidator.extractCompiledUnderstanding(body)
        #expect(extracted.contains("First paragraph"))
        #expect(!extracted.contains("Relations"))
    }
}
