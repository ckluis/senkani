import Testing
@testable import Core
import Foundation

@Suite("PresetPrerequisiteCheck — missing companion surfaces warn, don't block")
struct PresetHookPrerequisiteTests {

    @Test("autoresearch warns on every listed prerequisite when none are stubbed ready")
    func autoresearchWarnsWhenProbesMissing() {
        let preset = PresetCatalog.find("autoresearch")!
        PresetPrerequisiteCheck.withProbes([
            "senkani_search_web": false,
            "guard-research": false,
            "ollama": false
        ]) {
            let result = PresetPrerequisiteCheck.check(preset)
            #expect(result.warnings.count == 3)
            let prereqs = Set(result.warnings.map { $0.prerequisite })
            #expect(prereqs == ["senkani_search_web", "guard-research", "ollama"])
        }
    }

    @Test("senkani-improve warns on guard-autoimprove + senkani-improve-cli")
    func senkaniImproveWarnsOnCompanions() {
        let preset = PresetCatalog.find("senkani-improve")!
        PresetPrerequisiteCheck.withProbes([
            "senkani-improve-cli": false,
            "guard-autoimprove": false
        ]) {
            let result = PresetPrerequisiteCheck.check(preset)
            #expect(result.warnings.count == 2)
            #expect(result.fullyReady == false)
        }
    }

    @Test("log-rotation has no prerequisites, so the check is clean")
    func logRotationHasNoPrereqs() {
        let preset = PresetCatalog.find("log-rotation")!
        let result = PresetPrerequisiteCheck.check(preset)
        #expect(result.warnings.isEmpty)
        #expect(result.fullyReady)
    }

    @Test("All-ready stub yields empty warnings + a nil summary message")
    func allReadyProducesNilSummary() {
        let preset = PresetCatalog.find("autoresearch")!
        PresetPrerequisiteCheck.withProbes([
            "senkani_search_web": true,
            "guard-research": true,
            "ollama": true
        ]) {
            let result = PresetPrerequisiteCheck.check(preset)
            #expect(result.fullyReady)
            #expect(PresetPrerequisiteCheck.summaryMessage(result) == nil)
        }
    }
}
