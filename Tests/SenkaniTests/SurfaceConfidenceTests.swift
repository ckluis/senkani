import Testing
@testable import Bench

@Suite("Confidence — Surface defaults")
struct SurfaceConfidenceTests {

    @Test func fixtureBenchSurfaceIsExact() {
        #expect(Confidence.defaultForSurface(.fixtureBench) == .exact)
    }

    @Test func liveSessionReplaySurfaceIsEstimated() {
        #expect(Confidence.defaultForSurface(.liveSessionReplay) == .estimated)
    }

    @Test func scenarioSimulatorSurfaceIsEstimated() {
        #expect(Confidence.defaultForSurface(.scenarioSimulator) == .estimated)
    }
}
