import Testing
import Foundation
@testable import Core

/// Pins `ProviderHealthProbe.knownProviderIDs` (added for the V.17b-2
/// Provider-Health dashboard's empty-store "probe known providers"
/// action) in sync with `binaryName(forProviderID:)` — the single
/// source of truth invariant. The dashboard's render is operator-gated
/// (SwiftUI), but this list-vs-map invariant is headless-testable.
@Suite("ProviderHealthProbe known provider ids")
struct ProviderHealthProbeKnownIDsTests {

    @Test func everyKnownIDMapsToANonNilBinary() {
        for id in ProviderHealthProbe.knownProviderIDs {
            #expect(ProviderHealthProbe.binaryName(forProviderID: id) != nil,
                    "known provider id '\(id)' must map to a CLI binary (sync with binaryName)")
        }
    }

    @Test func knownIDsAreTheFourSupportedProviders() {
        #expect(Set(ProviderHealthProbe.knownProviderIDs)
                == ["codex", "claude_code", "gemini", "opencode"])
        #expect(ProviderHealthProbe.knownProviderIDs.count == 4,
                "no duplicates")
    }

    @Test func anUnknownProviderHasNoBinaryAndIsNotKnown() {
        #expect(ProviderHealthProbe.binaryName(forProviderID: "made_up") == nil)
        #expect(!ProviderHealthProbe.knownProviderIDs.contains("made_up"))
    }
}
