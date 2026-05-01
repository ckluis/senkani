import Testing
import Foundation
@testable import Core

// Coverage for `onboarding-p2-copy-fcsit-empty-states`.
//
// Two pure deciders + source-level wiring guards:
//
//   - `FCSITDisclosure` is the canonical letter → name → effect
//     mapping the pane header reads when rendering the compact
//     toggles. Tests pin the five entries in render order, the
//     accessibility label format ("Filter, on" / "Filter, off"),
//     and the first-use predicate (`shouldShowFirstUse`).
//
//   - `EmptyStateGuidance` carries the headline / populating-event
//     / next-action triplet for each early-use pane this round
//     touches. Tests pin every surface in the enum to a non-empty
//     entry so a refactor that adds a surface without copy fails
//     loudly here.
//
//   - Source-level guards on `PaneContainerView`, `AnalyticsView`,
//     `KnowledgeBaseView`, `ModelManagerView`, `SprintReviewPane`
//     so SenkaniTests catches regressions without linking SwiftUI.

private let repoRoot: String = {
    var url = URL(fileURLWithPath: #filePath)
    while url.pathComponents.count > 1 {
        url.deleteLastPathComponent()
        let pkg = url.appendingPathComponent("Package.swift")
        if FileManager.default.fileExists(atPath: pkg.path) {
            return url.path
        }
    }
    return FileManager.default.currentDirectoryPath
}()

private func read(_ rel: String) -> String {
    let path = (repoRoot as NSString).appendingPathComponent(rel)
    return (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
}

@Suite("Onboarding P2 — FCSIT disclosure + actionable empty states")
struct OnboardingP2DisclosureTests {

    // MARK: - FCSITDisclosure

    @Test("FCSITDisclosure has five entries in F-C-S-I-T order")
    func fcsitOrderIsStable() {
        let keys = FCSITDisclosure.all.map(\.key)
        let letters = FCSITDisclosure.all.map(\.letter)
        #expect(keys == ["filter", "cache", "secrets", "indexer", "terse"],
                "FCSIT keys must render in F-C-S-I-T order; got \(keys).")
        #expect(letters == ["F", "C", "S", "I", "T"],
                "FCSIT letters must each be a single uppercase letter in render order.")
        for entry in FCSITDisclosure.all {
            #expect(entry.letter.count == 1,
                    "Letter for \(entry.key) must be one character.")
            #expect(!entry.name.isEmpty,
                    "Name for \(entry.key) must be a literal feature name.")
            #expect(!entry.effect.isEmpty,
                    "Effect for \(entry.key) must explain what the toggle does.")
            #expect(!entry.firstUseExplanation.isEmpty,
                    "First-use explanation for \(entry.key) must be present.")
        }
    }

    @Test("Accessibility label combines name and on/off state")
    func accessibilityLabelFormat() {
        #expect(FCSITDisclosure.accessibilityLabel(forKey: "filter", isOn: true) == "Filter, on")
        #expect(FCSITDisclosure.accessibilityLabel(forKey: "filter", isOn: false) == "Filter, off")
        #expect(FCSITDisclosure.accessibilityLabel(forKey: "terse", isOn: false) == "Terse, off")
        #expect(FCSITDisclosure.accessibilityHint(forKey: "secrets")
                == FCSITDisclosure.entry(forKey: "secrets")?.effect)
    }

    @Test("First-use disclosure shows once, then never")
    func firstUsePredicate() {
        #expect(FCSITDisclosure.shouldShowFirstUse(seen: false),
                "An unseen first-use must trigger the popover.")
        #expect(!FCSITDisclosure.shouldShowFirstUse(seen: true),
                "A seen first-use must NOT trigger the popover.")
        #expect(FCSITDisclosure.firstUseSeenDefaultsKey
                == "senkani.fcsit.firstUseDisclosureSeen.v1",
                "UserDefaults key must stay versioned (v1) so a future copy bump can ship a new disclosure without re-prompting users twice.")
        #expect(FCSITDisclosure.firstUseBody.count == 5,
                "First-use popover must list one body line per FCSIT toggle.")
    }

    // MARK: - EmptyStateGuidance

    @Test("Every empty-state surface has headline + populating event + next action")
    func emptyStateGuidanceIsComplete() {
        for surface in EmptyStateGuidance.Surface.allCases {
            let entry = EmptyStateGuidance.entry(for: surface)
            #expect(entry.surface == surface)
            #expect(!entry.headline.isEmpty,
                    "Headline missing for \(surface).")
            #expect(!entry.populatingEvent.isEmpty,
                    "Populating event missing for \(surface).")
            #expect(!entry.nextAction.isEmpty,
                    "Concrete next action missing for \(surface) — that's the entire point of P2.")
        }
        // Pin each surface enum case so a new one can't be added
        // without the round noticing.
        #expect(EmptyStateGuidance.Surface.allCases.map(\.rawValue).sorted()
                == ["analytics", "knowledgeBase", "modelManager", "sprintReview"])
    }

    // MARK: - Source-level wiring

    @Test("PaneContainerView wires FCSITDisclosure into the FCSIT row")
    func paneContainerWiresDisclosure() {
        let src = read("SenkaniApp/Views/PaneContainerView.swift")
        #expect(!src.isEmpty,
                "SenkaniApp/Views/PaneContainerView.swift must exist.")
        #expect(src.contains("FCSITDisclosure.accessibilityLabel(forKey:"),
                "featureButton must call FCSITDisclosure.accessibilityLabel for VoiceOver.")
        #expect(src.contains("FCSITDisclosure.accessibilityHint(forKey:"),
                "featureButton must call FCSITDisclosure.accessibilityHint for VoiceOver.")
        #expect(src.contains("FCSITDisclosure.firstUseSeenDefaultsKey"),
                "PaneContainerView must use the canonical first-use defaults key.")
        #expect(src.contains("FCSITFirstUsePopover"),
                "FCSIT first-use popover must be wired into PaneContainerView.")
    }

    @Test("Empty-state views consume EmptyStateGuidance")
    func emptyStateViewsConsumeGuidance() {
        let analytics = read("SenkaniApp/Views/AnalyticsView.swift")
        let knowledge = read("SenkaniApp/Views/KnowledgeBaseView.swift")
        let models = read("SenkaniApp/Views/ModelManagerView.swift")
        let sprint = read("SenkaniApp/Views/SprintReviewPane.swift")
        for (name, src) in [
            ("AnalyticsView", analytics),
            ("KnowledgeBaseView", knowledge),
            ("ModelManagerView", models),
            ("SprintReviewPane", sprint),
        ] {
            #expect(!src.isEmpty,
                    "Source for \(name) must exist on disk.")
            #expect(src.contains("EmptyStateGuidance.entry(for:"),
                    "\(name) must read EmptyStateGuidance for empty-state copy.")
            #expect(src.contains("guidance.nextAction"),
                    "\(name) must render the concrete next-action string from guidance.")
        }
    }
}
