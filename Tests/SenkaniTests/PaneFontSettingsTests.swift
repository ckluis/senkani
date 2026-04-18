import Testing
import Foundation
@testable import Core

@Suite("PaneFontSettings")
struct PaneFontSettingsTests {
    // MARK: - Defaults

    @Test func defaultsMatchFirstRun() {
        let s = PaneFontSettings()
        #expect(s.fontSize == PaneFontSettings.defaultFontSize)
        #expect(s.fontFamily == PaneFontSettings.defaultFontFamily)
        #expect(s.fontSize == 12.0)
        #expect(s.fontFamily == "SF Mono")
    }

    @Test func boundsAreInclusive() {
        // The slider range advertised to the UI must span at least the
        // 9–20pt backlog window; we actually ship a 8–24pt superset.
        #expect(PaneFontSettings.minFontSize <= 9.0)
        #expect(PaneFontSettings.maxFontSize >= 20.0)
        #expect(PaneFontSettings.minFontSize == 8.0)
        #expect(PaneFontSettings.maxFontSize == 24.0)
    }

    // MARK: - Clamp

    @Test func clampBelowMin() {
        #expect(PaneFontSettings.clampFontSize(4) == PaneFontSettings.minFontSize)
        #expect(PaneFontSettings.clampFontSize(-100) == PaneFontSettings.minFontSize)
    }

    @Test func clampAboveMax() {
        #expect(PaneFontSettings.clampFontSize(99) == PaneFontSettings.maxFontSize)
        #expect(PaneFontSettings.clampFontSize(24.1) == PaneFontSettings.maxFontSize)
    }

    @Test func clampInRangeIsIdentity() {
        #expect(PaneFontSettings.clampFontSize(8) == 8)
        #expect(PaneFontSettings.clampFontSize(13) == 13)
        #expect(PaneFontSettings.clampFontSize(24) == 24)
        #expect(PaneFontSettings.clampFontSize(15.5) == 15.5)
    }

    // MARK: - Family fallback

    @Test func availableFamiliesIncludeCuratedSet() {
        let set = Set(PaneFontSettings.availableMonospaceFamilies)
        // These four names are hard-coded into the Display picker; if
        // one is removed, the picker must be audited too. The test
        // guards against silent churn of the curated list.
        #expect(set.contains("SF Mono"))
        #expect(set.contains("Menlo"))
        #expect(set.contains("Monaco"))
        #expect(set.contains("Courier"))
    }

    @Test func resolveKnownFamilyRoundTrips() {
        for family in PaneFontSettings.availableMonospaceFamilies {
            #expect(PaneFontSettings.resolveFamily(requested: family) == family)
        }
    }

    @Test func resolveUnknownFamilyFallsBackToDefault() {
        #expect(PaneFontSettings.resolveFamily(requested: "Comic Sans MS") == PaneFontSettings.defaultFontFamily)
        #expect(PaneFontSettings.resolveFamily(requested: "") == PaneFontSettings.defaultFontFamily)
        #expect(PaneFontSettings.resolveFamily(requested: "Helvetica") == PaneFontSettings.defaultFontFamily)
    }

    // MARK: - Change detection (applyToView gate)

    @Test func sizeDidChangeRespectsHalfPointThreshold() {
        // Matches the existing TerminalViewRepresentable.updateNSView
        // diff gate: only re-apply when |Δsize| > 0.5pt. Slider step is
        // 1pt, so every user-visible change clears the gate.
        #expect(PaneFontSettings.fontSizeDidChange(from: 12, to: 13))
        #expect(PaneFontSettings.fontSizeDidChange(from: 13, to: 12))
        #expect(!PaneFontSettings.fontSizeDidChange(from: 12, to: 12))
        #expect(!PaneFontSettings.fontSizeDidChange(from: 12.0, to: 12.4))
        #expect(!PaneFontSettings.fontSizeDidChange(from: 12.0, to: 12.5))
        #expect(PaneFontSettings.fontSizeDidChange(from: 12.0, to: 12.6))
    }

    @Test func familyDidChangeIsExactStringCompare() {
        #expect(PaneFontSettings.fontFamilyDidChange(from: "SF Mono", to: "Menlo"))
        #expect(!PaneFontSettings.fontFamilyDidChange(from: "SF Mono", to: "SF Mono"))
        // Case-sensitive — NSFont family names are canonical.
        #expect(PaneFontSettings.fontFamilyDidChange(from: "sf mono", to: "SF Mono"))
    }

    // MARK: - Codable

    @Test func codableRoundTripPreservesFields() throws {
        let s = PaneFontSettings(fontSize: 15, fontFamily: "Menlo")
        let encoded = try JSONEncoder().encode(s)
        let decoded = try JSONDecoder().decode(PaneFontSettings.self, from: encoded)
        #expect(decoded == s)
        #expect(decoded.fontSize == 15)
        #expect(decoded.fontFamily == "Menlo")
    }
}
