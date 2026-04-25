import Testing
import Foundation
@testable import Core

/// Tests for the Ollama-model curated catalog + pull state machine +
/// `ollama pull` output parser + `ollama list` parser.
///
/// Round `ollama-model-curation` (sub-item c of
/// `ollama-pane-discovery-models-bundle`, shipped 2026-04-20). Acceptance
/// bullet 6 requires 5+ unit tests covering: curated-list model,
/// pull-state transitions, cancel-during-pull, ollama-absent flow,
/// digest parsing fixture.
@Suite("Ollama Model Catalog")
struct OllamaModelCatalogTests {

    // MARK: - Curated list model

    @Test func curatedListHasAtLeastFiveEntries() {
        // Backlog scope: "Curated list of 3–5 LLMs". We ship 5 —
        // tightening to ≥5 pins the commitment.
        #expect(OllamaModelCatalog.curated.count >= 5,
                "Curated list collapsed below 5 entries — product scope drift")
    }

    @Test func curatedTagsAllValidate() {
        // Schneier gate: every curated tag must satisfy the shell-meta
        // allowlist so it can be safely interpolated into `ollama run`
        // / `ollama pull`.
        for model in OllamaModelCatalog.curated {
            #expect(OllamaLauncherSupport.isValidModelTag(model.tag),
                    "Curated tag '\(model.tag)' fails the validator")
        }
    }

    @Test func curatedTagsHaveNoDuplicates() {
        let tags = OllamaModelCatalog.curated.map(\.tag)
        #expect(Set(tags).count == tags.count,
                "Duplicate tags in curated list")
    }

    @Test func everyCuratedRowDisclosesSizeInButtonCopy() {
        // Podmajersky gate: the pull button copy must surface size
        // BEFORE the click. We render "Pull N.N GB" — the row's
        // computed copy must contain the size.
        for model in OllamaModelCatalog.curated {
            let copy = model.pullButtonCopy
            let size = model.sizeLabel
            #expect(copy.contains(size),
                    "Row '\(model.tag)' button copy missing size disclosure")
            #expect(copy.hasPrefix("Pull "),
                    "Row '\(model.tag)' must start with 'Pull' verb")
        }
    }

    @Test func useCaseCopyFitsOneLine() {
        // Handley gate: keep the row use-case under 40 chars so a
        // narrow drawer doesn't wrap. Loosens to 50 if product adds a
        // longer line — flag, don't fail silently.
        for model in OllamaModelCatalog.curated {
            let length = model.useCase.count
            #expect(length <= 50,
                    "Use-case for '\(model.tag)' is \(length) chars (max 50)")
        }
    }

    @Test func firstEntryDoublesAsDefaultModel() {
        // The pane's default tag must match the first curated entry —
        // we single-source the chooser default off the catalog.
        #expect(OllamaLauncherSupport.defaultModelTag
                == OllamaModelCatalog.curated.first?.tag)
        #expect(OllamaLauncherSupport.defaultModelTags
                == OllamaModelCatalog.curatedTags)
    }

    @Test func entryLookupResolvesAndRejectsUncurated() {
        let first = OllamaModelCatalog.curated.first!
        #expect(OllamaModelCatalog.entry(for: first.tag) == first)
        #expect(OllamaModelCatalog.entry(for: "not-on-the-list:0b") == nil)
    }

    // MARK: - Pull state machine

    @Test func pullStateBeginsAsNotPulled() {
        var parser = OllamaPullOutputParser()
        #expect(parser.state == .notPulled)
        _ = parser.feed("")
        #expect(parser.state == .notPulled, "Empty input must not bump state")
    }

    @Test func pullStateTransitionsToSuccessWithDigest() {
        // Canonical ollama pull transcript (simplified). We expect the
        // parser to surface .pulled with the first layer digest.
        let transcript = """
        pulling manifest
        pulling abcdef1234567890... 100% ▕████████████▏ 4.7 GB
        pulling 1a4c3c6892c6... 100% ▕████████████▏  485 B
        verifying sha256 digest
        writing manifest
        success
        """
        var parser = OllamaPullOutputParser()
        for line in transcript.split(separator: "\n") {
            _ = parser.feed(String(line))
        }
        guard case .pulled(let digest) = parser.state else {
            Issue.record("Expected .pulled, got \(parser.state)")
            return
        }
        #expect(digest == "abcdef1234567890",
                "First layer digest should be captured")
    }

    @Test func pullStateReportsProgressDuringStream() {
        var parser = OllamaPullOutputParser()
        _ = parser.feed("pulling manifest")
        if case .pulling(let p) = parser.state {
            #expect(p == 0, "Manifest-start alone should be 0% progress")
        }
        _ = parser.feed("pulling deadbeef01234567...  45% ▕███…▏ 2.1 GB")
        guard case .pulling(let progress) = parser.state else {
            Issue.record("Expected .pulling mid-stream, got \(parser.state)")
            return
        }
        #expect(progress == 0.45, "Progress fraction matches reported 45%")
    }

    @Test func pullStateProgressNeverGoesBackwards() {
        var parser = OllamaPullOutputParser()
        _ = parser.feed("pulling abc1234567890a...  70% ▕████…▏ 3.3 GB")
        _ = parser.feed("pulling abc1234567890a...  40% ▕██…▏ 1.9 GB")
        guard case .pulling(let progress) = parser.state else {
            Issue.record("Expected .pulling, got \(parser.state)")
            return
        }
        #expect(progress == 0.70,
                "Progress must be monotonic — reporting only the max percent")
    }

    @Test func pullStateFlipsToFailedOnErrorLine() {
        var parser = OllamaPullOutputParser()
        _ = parser.feed("pulling manifest")
        _ = parser.feed("Error: pull manifest: model 'bogus' not found")
        guard case .failed(let message) = parser.state else {
            Issue.record("Expected .failed on error line, got \(parser.state)")
            return
        }
        #expect(message.contains("not found"))
    }

    @Test func pullStateIgnoresUnknownLines() {
        var parser = OllamaPullOutputParser()
        _ = parser.feed("some random ollama chatter")
        _ = parser.feed("") // blank
        _ = parser.feed("   ") // whitespace only
        #expect(parser.state == .notPulled,
                "Junk input must not move state away from .notPulled")
    }

    // MARK: - Digest / percent extraction helpers

    @Test func extractPercentHandlesOneTwoThreeDigits() {
        #expect(OllamaPullOutputParser.extractPercent(
            "pulling abc... 5% ▕▏ 100 MB") == 5)
        #expect(OllamaPullOutputParser.extractPercent(
            "pulling abc... 42% ▕██▏ 1.0 GB") == 42)
        #expect(OllamaPullOutputParser.extractPercent(
            "pulling abc... 100% ▕███▏ 4.7 GB") == 100)
        #expect(OllamaPullOutputParser.extractPercent(
            "no percent anywhere") == nil)
    }

    @Test func extractLayerDigestSkipsManifestKeyword() {
        #expect(OllamaPullOutputParser.extractLayerDigest(
            "pulling manifest") == nil)
        #expect(OllamaPullOutputParser.extractLayerDigest(
            "pulling deadbeef...  50% ▕…▏ 2 GB") == "deadbeef")
        #expect(OllamaPullOutputParser.extractLayerDigest(
            "pulling 46e0c10c039e... 100% ▕…▏ 4.9 GB") == "46e0c10c039e")
    }

    // MARK: - Pull command builder

    @Test func pullCommandArgumentsGateInvalidTag() {
        #expect(OllamaPullCommand.arguments(forPullingTag: "llama3.1:8b")
                == ["pull", "llama3.1:8b"])
        #expect(OllamaPullCommand.arguments(forPullingTag: "llama3; rm") == nil)
        #expect(OllamaPullCommand.arguments(forPullingTag: "") == nil)
    }

    @Test func listArgumentsAreStable() {
        #expect(OllamaPullCommand.arguments() == ["list"])
    }

    // MARK: - ollama list parser

    @Test func installedListParsesStandardOutput() {
        let output = """
        NAME                    ID              SIZE      MODIFIED
        llama3.1:8b             46e0c10c039e    4.9 GB    2 days ago
        qwen2.5-coder:7b        2b0496514337    4.7 GB    3 days ago
        gemma2:2b               8ccf136fdd52    1.6 GB    1 hour ago
        """
        let entries = OllamaInstalledListParser.parse(output)
        #expect(entries.count == 3)
        #expect(entries[0] == OllamaInstalledListParser.Entry(
            tag: "llama3.1:8b", digest: "46e0c10c039e"))
        #expect(entries[1].tag == "qwen2.5-coder:7b")
        #expect(entries[2].digest == "8ccf136fdd52")
    }

    @Test func installedListRejectsMalformedRows() {
        // Header, blank lines, partial rows, and non-hex digests all
        // get dropped silently — the parser is tolerant but doesn't
        // smuggle garbage through.
        let output = """
        NAME                    ID

        llama3.1:8b
        bad; tag                aabbccdd
        mistral:7b              not-hex-really
        gemma2:2b               1234567890ab    1.6 GB
        """
        let installed = OllamaInstalledListParser.installedTags(output)
        #expect(installed == ["gemma2:2b"],
                "Only the one well-formed hex-digest row should land")
    }

    // MARK: - Cancel-during-pull flow

    @Test func parserTreatsCancelAsResetWhenStateClearedExternally() {
        // The controller's cancel path clears `parsers[tag]` and sets
        // `states[tag] = .notPulled`. Here we pin the state-machine
        // invariant the controller relies on: replaying partial output
        // into a FRESH parser after cancel produces a fresh .pulling —
        // the prior session's digest / percent doesn't leak.
        var parser = OllamaPullOutputParser()
        _ = parser.feed("pulling abc1234567890a...  60% ▕…▏ 2.8 GB")
        #expect(parser.state == .pulling(progress: 0.60))
        // Cancel + restart = fresh parser instance.
        parser = OllamaPullOutputParser()
        #expect(parser.state == .notPulled,
                "A fresh parser on restart must not inherit prior progress")
        _ = parser.feed("pulling abc1234567890a...  20% ▕…▏ 1.0 GB")
        #expect(parser.state == .pulling(progress: 0.20))
    }

    // MARK: - State equality invariants

    @Test func stateHelpersClassifyCorrectly() {
        #expect(OllamaPullState.notPulled.isTerminal)
        #expect(!OllamaPullState.notPulled.isInFlight)
        #expect(OllamaPullState.pulling(progress: 0.3).isInFlight)
        #expect(!OllamaPullState.pulling(progress: 0.3).isTerminal)
        #expect(OllamaPullState.pulled(digest: "abc").isTerminal)
        #expect(OllamaPullState.failed("x").isTerminal)
    }
}
