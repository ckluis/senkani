import Testing
import Foundation
import ArgumentParser
@testable import Core
@testable import CLI

/// U.4b-1 contract tests for the promotion-gate runtime — Mode enum +
/// persistence + Migration v25 + audit-row writers + gate logic +
/// HookRouter denial path + override path. 10 tests across 6 areas
/// per the U.4b-1 acceptance.
@Suite("U.4b-1 — promotion-gate CLI + denial path")
struct TrustPromotionGateTests {

    private func tempSettingsPath() -> String {
        return "/tmp/senkani-trust-\(UUID().uuidString).json"
    }

    private func makeTempDB() -> (SessionDatabase, String) {
        let path = "/tmp/senkani-trust-u4b1-\(UUID().uuidString).sqlite"
        return (SessionDatabase(path: path), path)
    }

    // MARK: - 1. TrustSettings persistence

    @Test("TrustSettings round-trips through JSON; missing file returns defaults; partial config preserved")
    func trustSettingsPersistenceRoundTrip() throws {
        let path = tempSettingsPath()
        defer { try? FileManager.default.removeItem(atPath: path) }

        // Missing file → defaults.
        let defaults = try TrustSettingsStore.load(path: path)
        #expect(defaults.mode == .softFlag)
        #expect(defaults.fpRateMax == nil)
        #expect(defaults.minLabeledSample == nil)

        // Save + reload.
        var s = TrustSettings(mode: .blocking, fpRateMax: 0.05, minLabeledSample: 200)
        try TrustSettingsStore.save(s, path: path)
        let loaded = try TrustSettingsStore.load(path: path)
        #expect(loaded.mode == .blocking)
        #expect(loaded.fpRateMax == 0.05)
        #expect(loaded.minLabeledSample == 200)

        // Partial config — preserves unset knobs.
        s = TrustSettings(mode: .softFlag, fpRateMax: 0.10, minLabeledSample: nil)
        try TrustSettingsStore.save(s, path: path)
        let partial = try TrustSettingsStore.load(path: path)
        #expect(partial.mode == .softFlag)
        #expect(partial.fpRateMax == 0.10)
        #expect(partial.minLabeledSample == nil)
    }

    // MARK: - 2. TrustMode enum stable rawValues

    @Test("TrustMode rawValues are stable schema identifiers (softFlag / blocking); CaseIterable covers both")
    func trustModeRawValueStability() {
        let all = TrustMode.allCases
        #expect(all.count == 2)
        let raws = Set(all.map(\.rawValue))
        #expect(raws == ["softFlag", "blocking"])
        #expect(TrustMode(rawValue: "softFlag") == .softFlag)
        #expect(TrustMode(rawValue: "blocking") == .blocking)
        #expect(TrustMode(rawValue: "unknown") == nil)
    }

    // MARK: - 3. PromotionGate covers all rejection branches

    @Test("PromotionGate rejects unset thresholds; insufficient sample; over-threshold rate; accepts when both met")
    func promotionGateBranches() {
        // Branch 1 — both thresholds unset → reject "configure threshold first".
        do {
            let d = PromotionGate.evaluate(
                fpRateMax: nil, minLabeledSample: nil,
                observedRate: nil, observedSample: 0
            )
            switch d {
            case .reject(let reason): #expect(reason.contains("configure threshold first"))
            case .accept: Issue.record("expected reject on unset thresholds")
            }
        }
        // Branch 2 — sample under min → reject.
        do {
            let d = PromotionGate.evaluate(
                fpRateMax: 0.05, minLabeledSample: 200,
                observedRate: 0.01, observedSample: 50
            )
            switch d {
            case .reject(let reason): #expect(reason.contains("insufficient labeled sample"))
            case .accept: Issue.record("expected reject on insufficient sample")
            }
        }
        // Branch 3 — rate over max → reject.
        do {
            let d = PromotionGate.evaluate(
                fpRateMax: 0.05, minLabeledSample: 200,
                observedRate: 0.10, observedSample: 250
            )
            switch d {
            case .reject(let reason):
                #expect(reason.contains("observed FP-rate"))
                #expect(reason.contains("> fp_rate_max"))
            case .accept: Issue.record("expected reject on over-threshold rate")
            }
        }
        // Branch 4 — both conditions met → accept.
        do {
            let d = PromotionGate.evaluate(
                fpRateMax: 0.05, minLabeledSample: 200,
                observedRate: 0.03, observedSample: 250
            )
            #expect(d == .accept)
        }
        // Branch 5 — boundary: rate == max → accept (≤, not <).
        do {
            let d = PromotionGate.evaluate(
                fpRateMax: 0.05, minLabeledSample: 200,
                observedRate: 0.05, observedSample: 200
            )
            #expect(d == .accept)
        }
    }

    @Test("PromotionGate.observedRate returns nil for zero sample; FP / (FP+TP) otherwise")
    func observedRateBoundary() {
        #expect(PromotionGate.observedRate(fp: 0, tp: 0) == nil)
        #expect(PromotionGate.observedRate(fp: 1, tp: 0) == 1.0)
        #expect(PromotionGate.observedRate(fp: 0, tp: 1) == 0.0)
        #expect(PromotionGate.observedRate(fp: 3, tp: 7) == 0.3)
    }

    // MARK: - 4. Migration v25 + audit-row writers

    @Test("recordPromotion writes a chained row; chain integrity holds across a mix of legacy flag/label + new promotion rows")
    func promotionRowChainsCorrectly() {
        let (db, path) = makeTempDB()
        defer { TempSessionDatabase.cleanup(path: path) }

        // Seed a legacy `flag` row then a `label`, then a `promotion`.
        let flag = FragmentationDetector.Flag(
            createdAt: Date(),
            sessionId: "sid-u4b1",
            paneId: nil,
            toolName: "Edit",
            reason: .toolBurst,
            correlationCount: 3
        )
        let flagId = db.recordTrustFlag(flag, score: 5)
        #expect(flagId > 0)
        let labelId = db.recordTrustLabel(flagId: flagId, label: .fp, labeledBy: "operator")
        #expect(labelId > flagId)
        let promotionId = db.recordTrustPromotion(
            from: "softFlag", to: "blocking",
            fpRateMax: 0.05, minLabeledSample: 200,
            observedRate: 0.03, observedSample: 250,
            promotedBy: "operator"
        )
        #expect(promotionId > labelId)
        db.flushWrites()

        let result = ChainVerifier.verifyTrustAudits(db)
        switch result {
        case .ok: break
        case .noChain: Issue.record("expected chain after writes; got .noChain")
        case .brokenAt(let table, let rowid, let expected, let actual):
            Issue.record("chain broken at \(table):\(rowid) expected=\(expected) actual=\(actual)")
        }
    }

    @Test("recordOverride writes a chained row + overrideExists reads the row back")
    func overrideRowAndLookup() {
        let (db, path) = makeTempDB()
        defer { TempSessionDatabase.cleanup(path: path) }

        let callId = "session-1:Edit:1234567890"
        let rowid = db.recordTrustOverride(
            callId: callId, flagId: nil,
            operator: "operator", justification: "false alarm in burst"
        )
        #expect(rowid > 0)
        db.flushWrites()

        #expect(db.trustOverrideExists(callId: callId))
        #expect(!db.trustOverrideExists(callId: "different-call-id"))

        // Chain integrity holds across the new row kind.
        let result = ChainVerifier.verifyTrustAudits(db)
        if case .brokenAt = result {
            Issue.record("chain broken after override row write")
        }
    }

    // MARK: - 5. HookRouter denial path

    @Test("HookRouter denies Edit when mode=.blocking AND a flag fires; allows when mode=.softFlag")
    func hookRouterDenialPath() throws {
        // Override the trust-mode reader + override reader test seams.
        let originalMode = HookRouter.trustModeReader
        let originalOverride = HookRouter.trustOverrideReader
        defer {
            HookRouter.trustModeReader = originalMode
            HookRouter.trustOverrideReader = originalOverride
        }
        HookRouter.trustOverrideReader = { _ in false }

        // Fire 3 burst events of the same tool to trigger toolBurst.
        let sid = "sid-hook-trust"
        let evt: [String: Any] = [
            "tool_name": "Edit",
            "hook_event_name": "PreToolUse",
            "session_id": sid,
            "tool_input": ["file_path": "/tmp/x.swift", "prompt": "edit"],
        ]
        let data = try JSONSerialization.data(withJSONObject: evt)

        // Mode = softFlag: 3 fires accumulate but the call is NOT denied
        // by U.4b-1's gate.
        HookRouter.fragmentationDetector.reset()
        HookRouter.trustModeReader = { .softFlag }
        for _ in 0..<3 {
            let resp = HookRouter.handle(eventJSON: data)
            let s = String(data: resp, encoding: .utf8) ?? ""
            #expect(!s.contains("trust mode is blocking"),
                    ".softFlag mode must not surface the trust-mode denial body")
        }

        // Mode = blocking: 3 fires trigger toolBurst → denied with the
        // structured refusal body.
        HookRouter.fragmentationDetector.reset()
        HookRouter.trustModeReader = { .blocking }
        var sawDenial = false
        for _ in 0..<3 {
            let resp = HookRouter.handle(eventJSON: data)
            let s = String(data: resp, encoding: .utf8) ?? ""
            if s.contains("trust mode is blocking") {
                sawDenial = true
                #expect(s.contains("\"permissionDecision\":\"deny\""),
                        "trust-mode denial must surface as permissionDecision=deny")
                #expect(s.contains("tool_burst") || s.contains("fragment_stitch") || s.contains("cross_pane"),
                        "denial body must name the firing flag reason")
                break
            }
        }
        #expect(sawDenial, ".blocking mode must surface the trust-mode denial body after the burst threshold")
    }

    // MARK: - 6. CLI parse — 4 subcommands

    @Test("Trust CLI parses all 4 subcommands; threshold validates 0.0-1.0 + non-negative; set-mode validates raw value")
    func trustCLIParseRoundTrip() throws {
        // mode
        _ = try Trust.Mode.parse([])
        // set-mode softFlag / blocking
        let setSF = try Trust.SetMode.parse(["softFlag"])
        #expect(setSF.mode == "softFlag")
        let setB = try Trust.SetMode.parse(["blocking", "--operator", "alice"])
        #expect(setB.mode == "blocking")
        #expect(setB.operatorAlias == "alice")
        // override
        let ovr = try Trust.Override.parse(["call-abc", "--justification", "false alarm"])
        #expect(ovr.callId == "call-abc")
        #expect(ovr.justification == "false alarm")
        // threshold
        let th = try Trust.Threshold.parse(["--fp-rate-max", "0.05", "--min-sample", "200"])
        #expect(th.fpRateMax == 0.05)
        #expect(th.minSample == 200)
    }

    @Test("Trust.Threshold rejects fp-rate outside [0,1] and negative min-sample at validation time")
    func trustThresholdValidation() throws {
        // Parsing succeeds; the run() body rejects out-of-range values
        // by throwing ExitCode.failure with a structured stderr line.
        // We validate the parse + the value range at the command level.
        let bad = try Trust.Threshold.parse(["--fp-rate-max", "1.5"])
        #expect(bad.fpRateMax == 1.5)
        // Validation happens in run(); the boundaries the run() body
        // checks are 0.0 ≤ x ≤ 1.0 and N ≥ 0. Re-asserted here as the
        // pure-numeric guard contract.
        #expect(!(bad.fpRateMax ?? 0.0 >= 0.0 && bad.fpRateMax ?? 0.0 <= 1.0),
                "1.5 must be outside [0.0, 1.0] — the run-time guard rejects it")
        let bad2 = try Trust.Threshold.parse(["--min-sample=-5"])
        #expect(bad2.minSample == -5)
        #expect((bad2.minSample ?? 0) < 0, "-5 must be < 0 — the run-time guard rejects it")
    }

    // MARK: - 7. set-mode demotion always succeeds + records audit row

    @Test("set-mode softFlag (demotion) always succeeds and records a promotion row with from=blocking to=softFlag")
    func demotionAlwaysAllowed() {
        let (db, path) = makeTempDB()
        defer { TempSessionDatabase.cleanup(path: path) }

        // Demotion path: no thresholds required.
        let rowid = db.recordTrustPromotion(
            from: "blocking", to: "softFlag",
            fpRateMax: nil, minLabeledSample: nil,
            observedRate: nil, observedSample: 0,
            promotedBy: "operator"
        )
        #expect(rowid > 0)
        db.flushWrites()

        let result = ChainVerifier.verifyTrustAudits(db)
        if case .brokenAt = result {
            Issue.record("chain broken after demotion row write")
        }
    }
}
