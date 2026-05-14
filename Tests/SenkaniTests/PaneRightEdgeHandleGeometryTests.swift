import Testing
import Foundation

// Geometry-invariant regression test for
// `pane-close-x-button-drag-handle-collision-2026-05-14`.
//
// Finding: the right-edge resize handle's hit region was overlapping
// the pane-close `X` in the 24pt header, making the X operationally
// hard to click. The fix gates the handle's hit region with a top
// inset (`SenkaniTheme.resizeHandleTopExclusionInset`) that's large
// enough to clear both the header X and the settings-panel X.
//
// SenkaniTheme lives in the SenkaniApp target which SenkaniTests
// doesn't link, so this test reads the theme + view source files
// and parses the relevant constants as text — the same pattern the
// onboarding-disclosure source-level guards use.

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

private func cgFloat(_ source: String, name: String) -> Double? {
    // Matches `static let <name>: CGFloat = <number>` (number may be int
    // or decimal, optionally signed) on a single line.
    let pattern = #"static let \#(name): CGFloat = (-?\d+(?:\.\d+)?)"#
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
    let range = NSRange(source.startIndex..., in: source)
    guard let match = regex.firstMatch(in: source, range: range),
          match.numberOfRanges >= 2,
          let valueRange = Range(match.range(at: 1), in: source)
    else { return nil }
    return Double(source[valueRange])
}

@Suite("Pane right-edge handle — geometry invariants")
struct PaneRightEdgeHandleGeometryTests {

    @Test("resizeHandleTopExclusionInset clears header X and settings-panel X")
    func topExclusionInsetClearsCloseButtons() {
        let theme = read("SenkaniApp/Theme/SenkaniTheme.swift")
        #expect(!theme.isEmpty, "SenkaniTheme.swift must be readable from the repo root.")

        let inset = cgFloat(theme, name: "resizeHandleTopExclusionInset")
        let headerHeight = cgFloat(theme, name: "headerHeight")
        let accentLine = cgFloat(theme, name: "accentLineHeight")
        let activeAccent = cgFloat(theme, name: "activeAccentLineHeight")

        #expect(inset != nil,
                "SenkaniTheme.resizeHandleTopExclusionInset must be declared as a CGFloat literal — the right-edge resize handle reads it to gate its top hit region.")
        #expect(headerHeight != nil, "SenkaniTheme.headerHeight must be declared.")
        #expect(accentLine != nil, "SenkaniTheme.accentLineHeight must be declared.")
        #expect(activeAccent != nil, "SenkaniTheme.activeAccentLineHeight must be declared.")

        guard let inset, let headerHeight, let accentLine, let activeAccent else { return }

        // The pane top stack-up that must remain clickable above the handle:
        //   active accent line (worst case) + 24pt header + 0.5pt separator
        //   + 8pt settings-panel-X top padding + 14pt settings-panel-X icon.
        // Total ≈ 49pt today. The inset must cover that with a safety margin
        // so unrelated 1-2pt drift doesn't silently regress the close button.
        let settingsPanelXTopOffset = 8.0  // PaneSettingsPanel.swift: .padding(8)
        let settingsPanelXIconHeight = 14.0  // .font(.system(size: 14))
        let separator = 0.5  // PaneContainerView header→body separator
        let requiredMinimum = activeAccent + headerHeight + separator
            + settingsPanelXTopOffset + settingsPanelXIconHeight

        #expect(inset >= requiredMinimum,
                "resizeHandleTopExclusionInset (\(inset)) must be ≥ \(requiredMinimum) to keep the header X and settings-panel X clickable. Lower this only when accentLineHeight, headerHeight, or the settings panel X-button layout actually shrinks.")
        #expect(inset >= headerHeight + accentLine + 4,
                "Inset must clear the header strip with at least a 4pt safety margin (got inset=\(inset), header+accent=\(headerHeight + accentLine)).")
    }

    @Test("PaneRightEdgeHandle reads the named exclusion inset, not a magic literal")
    func handleViewReferencesNamedConstant() {
        let source = read("SenkaniApp/Views/PaneGridView.swift")
        #expect(!source.isEmpty, "PaneGridView.swift must be readable from the repo root.")
        #expect(source.contains("SenkaniTheme.resizeHandleTopExclusionInset"),
                "PaneRightEdgeHandle must apply its top inset via SenkaniTheme.resizeHandleTopExclusionInset so the geometry invariant is testable. A bare numeric literal here is a regression.")
        // The handle still owns a `.padding(.top, ...)` on its hit-target
        // frame — the named constant is the only intended argument.
        #expect(source.contains(".padding(.top, SenkaniTheme.resizeHandleTopExclusionInset)"),
                "PaneRightEdgeHandle must call `.padding(.top, SenkaniTheme.resizeHandleTopExclusionInset)` on the resize-handle hit-target frame. Removing or renaming this is the regression we're guarding against.")
    }

    @Test("Pane-close `X` button keeps a 44pt-class hit target via .padding(15)")
    func paneCloseButtonHitTargetIsLargeEnough() {
        let source = read("SenkaniApp/Views/PaneContainerView.swift")
        #expect(!source.isEmpty, "PaneContainerView.swift must be readable from the repo root.")

        // The close button uses:
        //   Image("xmark").frame(width: 14, height: 14).padding(15).contentShape(Rectangle()).padding(-15)
        // The `.padding(15)` + `.contentShape(Rectangle())` is what gives a 44pt hit target
        // while the visible icon stays 14×14. Both must remain present together.
        #expect(source.contains("Image(systemName: \"xmark\")"),
                "Pane close button must render an `xmark` image.")
        #expect(source.range(of: #"\.frame\(width: 14, height: 14\)\s*\.padding\(15\)\s*\.contentShape\(Rectangle\(\)\)"#,
                              options: .regularExpression) != nil,
                "Pane close button must expand its hit shape to ~44pt via `.frame(14×14).padding(15).contentShape(Rectangle())`. Shrinking the padding makes the X hard to click again.")
    }
}
