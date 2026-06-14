import Testing
@testable import CLI
@testable import Core

/// U.3 leg 2 — the CLI `ProcessSupervisionPrompt` fronts stdin for the
/// `--supervise-first` operator y/n. The stdin READ is untested I/O wiring
/// (the `ProcessCommandRunner` precedent), but the answer CLASSIFICATION is
/// pure fail-safe logic with a documented contract: only `y`/`yes` advances;
/// everything else — including EOF — aborts. `classify(_:)` is extracted so
/// that contract is pinned without touching a real TTY.
@Suite("U.3 autorun --supervise-first stdin classifier (leg 2)")
struct AutorunSupervisionPromptClassifierTests {
    @Test("y / yes (any case, surrounding whitespace) → proceed")
    func proceedsOnAffirmative() {
        for raw in ["y", "Y", "yes", "YES", "Yes", "  y  ", " yes ", "\ty\t"] {
            #expect(
                ProcessSupervisionPrompt.classify(raw) == .proceed,
                "expected .proceed for \(raw.debugDescription)"
            )
        }
    }

    @Test("empty / n / partial / garbage → abort (fail-safe)")
    func abortsOnEverythingElse() {
        // Bare newline reaches classify as "" (readLine strips the newline).
        for raw in ["", " ", "n", "N", "no", "nope", "ye", "yep", "yeah", "yess", "1", "abort", "ok"] {
            #expect(
                ProcessSupervisionPrompt.classify(raw) == .abort,
                "expected .abort for \(raw.debugDescription)"
            )
        }
    }

    @Test("EOF (nil from readLine) → abort — never advance unattended")
    func abortsOnEOF() {
        #expect(ProcessSupervisionPrompt.classify(nil) == .abort)
    }
}
