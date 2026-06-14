import Testing
import Foundation
@testable import Core

/// U.3 (LEG 3) — coverage for the `TaskClass` class-gate vocabulary:
/// keyword inference (incl. precedence), `--allow-classes` CSV parsing
/// (trim + drop-unrecognized), and the `isClassAllowed` predicate truth
/// table. All pure — no DB, no process, no TTY.
@Suite("U.3 autorun TaskClass (leg 3)")
struct TaskClassTests {

    // MARK: - infer

    @Test("infer: keyword table + precedence (test-fix shadows bug-fix, etc.)")
    func inferKeywordTable() {
        // testFix BEFORE bugFix: "fix flaky test" → testFix, not bugFix.
        #expect(TaskClass.infer(from: "fix flaky test") == .testFix)
        #expect(TaskClass.infer(from: "stabilize the flake") == .testFix)
        // bugFix for a plain fix/bug.
        #expect(TaskClass.infer(from: "fix the login bug") == .bugFix)
        // docs BEFORE bugFix.
        #expect(TaskClass.infer(from: "update docs") == .docs)
        // refactor BEFORE bugFix.
        #expect(TaskClass.infer(from: "refactor decomposer") == .refactor)
        // chore BEFORE bugFix.
        #expect(TaskClass.infer(from: "bump deps") == .chore)
        // feature.
        #expect(TaskClass.infer(from: "add feature X") == .feature)
        // default.
        #expect(TaskClass.infer(from: "something vague") == .unknown)
    }

    /// Each precedence edge proven with an input that ALSO contains the
    /// shadowed keyword — so reordering `infer` to put bug-fix first would
    /// FAIL these (the plain-input cases above can't catch that regression).
    @Test("infer: precedence edges proven against competing fix/bug tokens")
    func inferPrecedenceEdges() {
        // docs BEFORE bugFix — "fix" present, must still resolve docs.
        #expect(TaskClass.infer(from: "fix the docs typo") == .docs)
        // refactor BEFORE bugFix — "fix" present, must still resolve refactor.
        #expect(TaskClass.infer(from: "refactor to fix coupling") == .refactor)
        // chore BEFORE bugFix — "fix" present, must still resolve chore.
        #expect(TaskClass.infer(from: "chore: bump deps to fix CVE") == .chore)
        // testFix BEFORE bugFix — both "bug" and "test" present.
        #expect(TaskClass.infer(from: "fix the test for the bug") == .testFix)
    }

    /// Whole-word matching: keywords as SUBSTRINGS of other words must NOT
    /// match, since a substring over-match would widen the unattended surface
    /// past operator intent (the guardrail failure direction).
    @Test("infer: substring keywords do NOT over-match (guardrail — no false-allow)")
    func inferWholeWordOnly() {
        // "doc" ⊄ "dockerfile"; the bump token routes this to chore, not docs.
        #expect(TaskClass.infer(from: "bump dockerfile base image") == .chore)
        // "doc" ⊄ "dockerfile" with no other keyword → unknown, not docs.
        #expect(TaskClass.infer(from: "tidy the dockerfile") == .unknown)
        // "add" ⊄ "address", "fix" ⊄ "prefix" → feature via "add"? no — "add"
        // is not a token here; "address"/"prefix" are. So unknown, not bugFix.
        #expect(TaskClass.infer(from: "validate the address prefix") == .unknown)
        // "bug" ⊄ "debug" → not bugFix; "add" present → feature.
        #expect(TaskClass.infer(from: "add debug logging") == .feature)
        // "test" ⊄ "latest" → not testFix; unknown.
        #expect(TaskClass.infer(from: "ship the latest build") == .unknown)
    }

    // MARK: - parseAllowList

    @Test("parseAllowList: trims, maps raw values, drops unrecognized, empty → []")
    func parseAllowList() {
        #expect(TaskClass.parseAllowList("test-fix, docs") == [.testFix, .docs])
        // Trims surrounding whitespace.
        #expect(TaskClass.parseAllowList("  bug-fix ,  chore ") == [.bugFix, .chore])
        // Drops unrecognized tokens (forward-compat).
        #expect(TaskClass.parseAllowList("docs, nope, refactor") == [.docs, .refactor])
        // Empty / whitespace → [].
        #expect(TaskClass.parseAllowList("") == [])
        #expect(TaskClass.parseAllowList("   ") == [])
        #expect(TaskClass.parseAllowList(",, ,") == [])
    }

    // MARK: - isClassAllowed truth table

    @Test("isClassAllowed: empty list → true for any (incl. nil); in/out-of-list; nil fail-safe")
    func isClassAllowedTruthTable() {
        // Empty allow-list ⇒ allow-all, including a nil class.
        #expect(AutorunLoopDriver.isClassAllowed(.testFix, allowList: []))
        #expect(AutorunLoopDriver.isClassAllowed(nil, allowList: []))
        // Non-empty list: in-list → true.
        #expect(AutorunLoopDriver.isClassAllowed(.docs, allowList: [.docs, .testFix]))
        // Non-empty list: out-of-list → false.
        #expect(!AutorunLoopDriver.isClassAllowed(.feature, allowList: [.docs, .testFix]))
        // Non-empty list: nil class → false (fail-safe).
        #expect(!AutorunLoopDriver.isClassAllowed(nil, allowList: [.docs]))
    }

    // MARK: - taskClass encoding back-compat

    private static func canonicalEncoder() -> JSONEncoder {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        return enc
    }

    private static func bareContract(taskClass: TaskClass?) -> WorkstreamTaskContract {
        WorkstreamTaskContract(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            workstreamID: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            objective: "x",
            fileScope: [],
            allowedTools: [],
            dependencies: [],
            staleSpecAt: nil,
            budget: ContractBudget(tokensMax: 0, wallClockMaxS: 0),
            commands: [],
            acceptance: [],
            reviewLevel: .none,
            taskClass: taskClass
        )
    }

    /// The explicit compat promise: a nil `taskClass` OMITS the `task_class`
    /// key (byte-identical to the pre-leg-3 shape). A regression to plain
    /// `encode` (writing `"task_class": null`) would pass the rest of the
    /// suite while breaking this — so guard it directly.
    @Test("encoding: nil taskClass omits the key; a present class encodes its raw value")
    func taskClassEncodingOmitsNil() throws {
        let enc = Self.canonicalEncoder()

        let nilJSON = String(data: try enc.encode(Self.bareContract(taskClass: nil)), encoding: .utf8)!
        #expect(!nilJSON.contains("task_class"), "nil taskClass must omit the key, got: \(nilJSON)")

        let classedJSON = String(data: try enc.encode(Self.bareContract(taskClass: .testFix)), encoding: .utf8)!
        #expect(classedJSON.contains("\"task_class\":\"test-fix\""),
                "present taskClass must encode its stable raw value, got: \(classedJSON)")
    }

    /// Backward read: a v1-shaped `contracts.json` (no `task_class` key) must
    /// stay readable on this v2 binary, decoding `taskClass` as nil. The
    /// forward-incompatible rejection (a future higher version → nil) is
    /// already covered in `AutorunLoopDriverTests`; this guards the other
    /// direction (the `<=` check + the optional-decode).
    @Test("contracts.json back-compat: a v1 file (no task_class) loads with taskClass nil")
    func v1FileStaysReadable() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("senkani-taskclass-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let runId = "v1-compat-run"
        let dir = AutorunContractStore.runDir(runId: runId, rootDir: root)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // A v1-shaped envelope: schema_version 1, a contract with NO
        // task_class key (the pre-leg-3 on-disk shape).
        let v1JSON = """
        {"schema_version":1,"run_id":"v1-compat-run","contracts":[{"id":"11111111-1111-1111-1111-111111111111","workstream_id":"22222222-2222-2222-2222-222222222222","objective":"legacy task","file_scope":[],"allowed_tools":[],"dependencies":[],"budget":{"tokens_max":0,"wall_clock_max_s":0},"commands":["swift build"],"acceptance":[],"review_level":"none"}]}
        """
        try Data(v1JSON.utf8).write(to: AutorunContractStore.contractsURL(runId: runId, rootDir: root))

        let env = AutorunContractStore.loadEnvelope(runId: runId, rootDir: root)
        #expect(env != nil, "a v1 file must stay readable on the v2 binary (the <= check)")
        #expect(env?.schemaVersion == 1)
        #expect(env?.contracts.count == 1)
        #expect(env?.contracts.first?.taskClass == nil, "an absent task_class key → nil")
        #expect(env?.contracts.first?.objective == "legacy task")
    }
}
