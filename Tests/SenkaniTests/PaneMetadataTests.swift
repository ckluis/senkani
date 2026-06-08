import Testing
import Foundation
@testable import Core

/// V.3a — `PaneMetadata` value type + `PaneMetadataResolver` cache /
/// redact-on-write. Acceptance:
///   1. Codable round-trips JSON→struct→JSON identically (+ fixture snapshot).
///   2. Resolver cache hit returns the stored snapshot; absent pane → nil.
///   3. Redaction: a planted `sk-ant-...` key in currentTool /
///      lastReplySummary is stored AND returned as the redaction token
///      (fail-CLOSED: redacted on the write into the cache).
@Suite("V.3a — PaneMetadata + PaneMetadataResolver")
struct PaneMetadataTests {

    // MARK: - Codable round-trip

    @Test("PaneMetadata Codable round-trips encode → decode identically")
    func codableRoundTrip() throws {
        let original = PaneMetadata(
            port: 8080,
            branch: "feature/x",
            prRef: PaneMetadata.PRRef(number: 42, url: "https://github.com/o/r/pull/42"),
            currentTool: "Edit",
            lastReplySummary: "shipped the fix",
            // Whole-second date so JSON Double round-trip is exact.
            lastUpdated: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let encoder = JSONEncoder()
        let data = try encoder.encode(original)
        let decoded = try JSONDecoder().decode(PaneMetadata.self, from: data)
        #expect(decoded == original, "round-trip must preserve every field")
    }

    @Test("PaneMetadata encodes the expected JSON shape (fixture snapshot)")
    func fixtureJSONSnapshot() throws {
        let value = PaneMetadata(
            port: 3000,
            branch: "main",
            prRef: PaneMetadata.PRRef(number: 7, url: "https://x/pull/7"),
            currentTool: "Bash",
            lastReplySummary: "done",
            lastUpdated: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        let json = String(data: data, encoding: .utf8)!

        // Decode the fixture back into a generic dictionary and assert the
        // conformed key set + a few values. (Asserting raw bytes would be
        // brittle on the Double format; the dict assert pins the schema.)
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(Set(obj.keys) == ["port", "branch", "prRef", "currentTool",
                                  "lastReplySummary", "lastUpdated"],
                "JSON key set is the frozen schema; got \(Set(obj.keys))")
        #expect(obj["port"] as? Int == 3000)
        #expect(obj["branch"] as? String == "main")
        #expect(obj["currentTool"] as? String == "Bash")
        let pr = obj["prRef"] as! [String: Any]
        #expect(pr["number"] as? Int == 7)
        #expect(pr["url"] as? String == "https://x/pull/7")
        // sortedKeys → prRef nested keys also sorted; sanity-check ordering.
        #expect(json.contains("\"number\":7"))
    }

    @Test("Nil optionals are omitted/encoded cleanly and round-trip to nil")
    func nilOptionalsRoundTrip() throws {
        let value = PaneMetadata(lastUpdated: Date(timeIntervalSince1970: 1))
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(PaneMetadata.self, from: data)
        #expect(decoded.port == nil)
        #expect(decoded.branch == nil)
        #expect(decoded.prRef == nil)
        #expect(decoded.currentTool == nil)
        #expect(decoded.lastReplySummary == nil)
        #expect(decoded == value)
    }

    // MARK: - Resolver cache hit / absent pane

    @Test("Resolver cache hit returns the stored snapshot")
    func resolverCacheHit() {
        let fixed = Date(timeIntervalSince1970: 1_700_000_000)
        let resolver = PaneMetadataResolver(now: { fixed })
        resolver.updateAgentStatus(paneId: "pane-1", currentTool: "Read",
                                   lastReplySummary: "looked at the file")

        let got = resolver.metadata(for: "pane-1")
        #expect(got != nil, "a stored pane must be readable")
        #expect(got?.currentTool == "Read")
        #expect(got?.lastReplySummary == "looked at the file")
        #expect(got?.lastUpdated == fixed)
    }

    @Test("Resolver returns nil for an absent pane")
    func resolverAbsentPaneNil() {
        let resolver = PaneMetadataResolver()
        #expect(resolver.metadata(for: "never-seen") == nil)
    }

    // MARK: - Redaction (Schneier fail-CLOSED: redact on write)

    @Test("Planted sk-ant key in currentTool is stored + returned as the redaction token")
    func redactsCurrentToolOnWrite() {
        let resolver = PaneMetadataResolver()
        let planted = "running with sk-ant-abcdefghijklmnopqrstuvwxyz0123456789"
        resolver.updateAgentStatus(paneId: "p", currentTool: planted, lastReplySummary: nil)

        let stored = resolver.metadata(for: "p")?.currentTool
        #expect(stored != nil)
        #expect(stored?.contains("[REDACTED:ANTHROPIC_API_KEY]") == true,
                "the secret must be redacted on the write into the cache")
        #expect(stored?.contains("sk-ant-abcdefghijklmnopqrstuvwxyz0123456789") == false,
                "no un-redacted key may be readable at hover-time (fail-CLOSED)")
    }

    @Test("Planted sk-ant key in lastReplySummary is redacted on write too")
    func redactsLastReplySummaryOnWrite() {
        let resolver = PaneMetadataResolver()
        let planted = "reply: sk-ant-ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789xx"
        resolver.updateAgentStatus(paneId: "p", currentTool: nil, lastReplySummary: planted)

        let stored = resolver.metadata(for: "p")?.lastReplySummary
        #expect(stored?.contains("[REDACTED:ANTHROPIC_API_KEY]") == true)
        #expect(stored?.contains("sk-ant-ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789xx") == false)
    }

    @Test("Clean strings pass through redaction unchanged")
    func cleanStringsUnchanged() {
        let resolver = PaneMetadataResolver()
        resolver.updateAgentStatus(paneId: "p", currentTool: "Edit",
                                   lastReplySummary: "no secrets here")
        let got = resolver.metadata(for: "p")
        #expect(got?.currentTool == "Edit")
        #expect(got?.lastReplySummary == "no secrets here")
    }

    // MARK: - updateAgentStatus preserves probe-ingested fields

    @Test("updateAgentStatus preserves port/branch/prRef from a prior probe ingest")
    func updateAgentStatusPreservesProbeFields() {
        let resolver = PaneMetadataResolver(
            portProbe: { _ in 9999 },
            branchProbe: { _ in "wt/branch" },
            prProbe: { _ in PaneMetadata.PRRef(number: 5, url: "https://x/pull/5") }
        )
        resolver.ingestPort(paneId: "p", probeKey: "k")
        resolver.ingestBranch(paneId: "p", probeKey: "k")
        resolver.ingestPR(paneId: "p", probeKey: "k")

        resolver.updateAgentStatus(paneId: "p", currentTool: "Grep", lastReplySummary: "searched")

        let got = resolver.metadata(for: "p")
        #expect(got?.port == 9999, "port from the probe survives an agent-status update")
        #expect(got?.branch == "wt/branch")
        #expect(got?.prRef == PaneMetadata.PRRef(number: 5, url: "https://x/pull/5"))
        #expect(got?.currentTool == "Grep")
        #expect(got?.lastReplySummary == "searched")
    }

    @Test("Default probe seams are no-ops (Core stores nil until the GUI round wires real closures)")
    func defaultProbesAreNoOps() {
        let resolver = PaneMetadataResolver()
        resolver.ingestPort(paneId: "p", probeKey: "k")
        resolver.ingestBranch(paneId: "p", probeKey: "k")
        resolver.ingestPR(paneId: "p", probeKey: "k")
        let got = resolver.metadata(for: "p")
        #expect(got != nil, "ingest still creates a snapshot row")
        #expect(got?.port == nil)
        #expect(got?.branch == nil)
        #expect(got?.prRef == nil)
    }
}
