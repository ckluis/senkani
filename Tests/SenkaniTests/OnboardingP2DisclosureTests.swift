import Testing
import Foundation
@testable import Core

// Coverage for `onboarding-p2-copy-fcsit-empty-states`, updated
// 2026-05-11 by `fcsit-pane-toggles-ux-redesign` to retire the
// first-use disclosure popover and replace it with a
// click-letter-opens-settings affordance.
//
// Two pure deciders + source-level wiring guards:
//
//   - `FCSITDisclosure` is the canonical letter → name → effect
//     mapping the pane header reads when rendering the compact
//     toggles. Tests pin the five entries in render order, the
//     accessibility label format ("Filter, on" / "Filter, off"),
//     the per-toggle `Learn more` URL shape, and the retired
//     first-use UserDefaults key (still exposed for the one-shot
//     launch-time cleanup).
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

    @Test("Retired first-use defaults key still exposed for launch-time cleanup")
    func retiredFirstUseKey() {
        // The first-use popover was retired by
        // `fcsit-pane-toggles-ux-redesign-2026-05-11`. The defaults
        // key is kept on the type so SenkaniGUI can run an
        // idempotent removeObject(forKey:) at launch to clear stale
        // state on cfprefsd for upgrading users.
        #expect(FCSITDisclosure.retiredFirstUseSeenDefaultsKey
                == "senkani.fcsit.firstUseDisclosureSeen.v1",
                "Retired UserDefaults key spelling must stay byte-identical so the cleanup actually clears the original key.")
    }

    @Test("Learn-more URL per FCSIT toggle points at the per-pane-optimizers concept page")
    func learnMoreURLPerKey() {
        let expected: [String: String] = [
            "filter":  "https://senkani.app/docs/concepts/per-pane-optimizers.html#filter",
            "cache":   "https://senkani.app/docs/concepts/per-pane-optimizers.html#cache",
            "secrets": "https://senkani.app/docs/concepts/per-pane-optimizers.html#secrets",
            "indexer": "https://senkani.app/docs/concepts/per-pane-optimizers.html#indexer",
            "terse":   "https://senkani.app/docs/concepts/per-pane-optimizers.html#terse",
        ]
        for (key, want) in expected {
            let url = FCSITDisclosure.learnMoreURL(forKey: key)
            #expect(url?.absoluteString == want,
                    "Learn-more URL for \(key) must point at the per-pane-optimizers concept anchor.")
        }
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
    }

    @Test("PaneContainerView header retires chevron + gear + first-use popover")
    func paneContainerHeaderRetiresLegacyAffordances() {
        // `fcsit-pane-toggles-ux-redesign-2026-05-11` collapsed three
        // explainer surfaces (popover / drawer / settings panel) into
        // one canonical surface (settings panel), reached by clicking
        // any FCSIT letter. Pin the no-chevron / no-gear / no-popover
        // header shape so a refactor can't silently re-introduce a
        // toggle-from-header path.
        let src = read("SenkaniApp/Views/PaneContainerView.swift")
        #expect(!src.contains("FCSITFirstUsePopover"),
                "First-use popover must be fully retired from the header.")
        #expect(!src.contains("showFCSITFirstUse"),
                "First-use popover state must be fully retired from the header.")
        #expect(!src.contains("showFeatureDrawer"),
                "FeatureDetailDrawer state must be fully retired from the header.")
        #expect(!src.contains("FeatureDetailDrawer("),
                "FeatureDetailDrawer call site must be fully removed from the header.")
        #expect(!src.contains("\"gearshape\""),
                "Gear icon must be fully retired from the header — click any letter opens settings.")
        #expect(!src.contains("chevron.down"),
                "Disclosure chevron must be fully retired from the header.")
        #expect(src.contains("showSettings = true"),
                "Clicking a FCSIT letter must open the settings panel.")
    }

    @Test("PaneSettingsPanel wires Learn-more URLs into each FCSIT row")
    func paneSettingsPanelWiresLearnMoreURLs() {
        let src = read("SenkaniApp/Views/PaneSettingsPanel.swift")
        #expect(!src.isEmpty,
                "SenkaniApp/Views/PaneSettingsPanel.swift must exist.")
        // Each F/C/S/I/T row must pass a learnMoreURL — pin by the
        // FCSITDisclosure.learnMoreURL(forKey:) call site so a rename
        // here doesn't silently drop the link from the row.
        for key in ["filter", "cache", "secrets", "indexer", "terse"] {
            #expect(src.contains("FCSITDisclosure.learnMoreURL(forKey: \"\(key)\")"),
                    "Optimization row for \(key) must wire FCSITDisclosure.learnMoreURL into the settings panel.")
        }
        #expect(src.contains("Learn more →"),
                "SettingsToggleRow must render the Learn-more link copy when a URL is supplied.")
    }

    @Test("SenkaniApp clears the retired FCSIT first-use defaults key on launch")
    func senkaniAppClearsRetiredFCSITKey() {
        let src = read("SenkaniApp/App/SenkaniApp.swift")
        #expect(!src.isEmpty,
                "SenkaniApp/App/SenkaniApp.swift must exist.")
        #expect(src.contains("cleanupRetiredFCSITFirstUseKey"),
                "App init must invoke cleanupRetiredFCSITFirstUseKey for the one-shot UserDefaults migration.")
        #expect(src.contains("FCSITDisclosure.retiredFirstUseSeenDefaultsKey"),
                "Cleanup must reference the canonical retired-key constant — keeps the spelling honest.")
        #expect(src.contains("UserDefaults.standard.removeObject"),
                "Cleanup must actually call removeObject on UserDefaults.standard.")
    }

    @Test("FCSITFirstUsePopover view is fully removed from the app target")
    func firstUsePopoverFileRemoved() {
        let src = read("SenkaniApp/Views/FCSITFirstUsePopover.swift")
        #expect(src.isEmpty,
                "FCSITFirstUsePopover.swift must not exist after `fcsit-pane-toggles-ux-redesign-2026-05-11`.")
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
