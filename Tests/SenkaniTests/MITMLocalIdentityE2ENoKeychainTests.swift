import Foundation
import Testing
import Security
#if canImport(Darwin)
import Darwin.POSIX
#endif
@testable import Core

/// T.1d-1 follow-up — e2e: memory-only `SecIdentity` consumed through the
/// TLS-termination consumer with a no-Keychain-mutation guarantee.
///
/// Parent finding (audit 2026-05-31, Allspaw/Carmack P2):
///
/// > "No real `sec_protocol_options_set_local_identity` /
/// > `set_local_identity` consumer exists yet (only a doc comment);
/// > `leafPKCS12LoadsAsSecIdentity` only checks the identity synchronously
/// > right after the call. Add a runtime/integration test that consumes
/// > the memory-only `SecIdentity` through the eventual local-identity
/// > TLS path to lock in the no-retaining-keychain guarantee once the
/// > consumer is wired."
///
/// The consumer landed at `phase-t1d-2b-tls-termination-impl`
/// (`MITMTermination.runTermination` calls
/// `MITMCertificateAuthority.loadIdentity(from: leafPKCS12)` and hands the
/// `SecIdentity` to `SSLSetCertificate`). The `MITMTerminationSeamTests`
/// suite already drives a real TLS handshake through that path
/// end-to-end and asserts the peer leaf byte-equals the minted t1d-1
/// leaf — i.e. the memory-only `SecIdentity` IS the identity the server
/// presented to the client. That existing test is the e2e proof-of-
/// consumption; this suite locks in the COMPLEMENTARY guarantee that the
/// audit asked for: the codepath from `loadIdentity` through the handshake
/// performs zero Keychain mutations on macOS 15+.
///
/// ### Strategy: structural source-scan, not runtime Keychain probe
///
/// A runtime probe that listed user-Keychain items before + after the
/// handshake would violate constraint #2 of the round (test does NOT
/// touch the user's Keychain). A process-keychain symbol-intercept seam
/// does not exist in the codebase. So we lock the guarantee STRUCTURALLY:
/// enumerate the production-resident source files that the macOS-15+
/// `loadIdentity` dispatcher + the `MITMTermination` handshake actually
/// reach, and assert NONE of them references a Keychain-mutation symbol.
/// Mirrors the deny-list scan pattern from
/// `ServeArmEgressAuditDualRowTests` (T1).
///
/// The reachable codepath on macOS 15+ is:
///   `MITMCertificateAuthority.loadIdentity`
///     → `if #available(macOS 15.0, *)` →
///     `MITMCertificateAuthority.loadIdentityMemoryOnly` (no keychain)
///   then `MITMTermination.runTermination` → `SSLCreateContext` /
///   `SSLSetCertificate` / `SSLHandshake` (SecureTransport, not Keychain).
///
/// The deny-listed symbols are the ones that, if they appeared in either
/// of those files, would mean the memory-only path is silently mutating
/// the Keychain:
///
///   - `SecKeychainCreate` / `SecKeychainDelete` (ephemeral-keychain
///     allocation — the macOS-14 floor uses these; the memory-only path
///     must not).
///   - `kSecImportExportKeychain` (forces `SecPKCS12Import` to land items
///     in a keychain — the memory-only path uses `kSecImportToMemoryOnly`
///     instead).
///   - `SecItemAdd` / `SecItemUpdate` / `SecItemDelete` (data-protection
///     keychain mutations).
///
/// A textual scope-marker pair carves the macOS-15+ memory-only region
/// out of `MITMCertificateAuthority.swift` so the floor's deliberate use
/// of these symbols (in `loadIdentityViaEphemeralKeychain` and
/// `exportPKCS12`) does not false-positive. The `MITMTermination.swift`
/// file is scanned whole — the handshake codepath is the entire file's
/// purpose and it must NEVER touch Keychain APIs.
@Suite("MITM local-identity e2e — no Keychain mutation on the memory-only path (t1d-1 follow-up)")
struct MITMLocalIdentityE2ENoKeychainTests {

    // MARK: - Acceptance bullet 1: e2e handshake consumes the memory-only identity

    /// Re-asserts the round's e2e acceptance bullet INLINE so this suite
    /// itself contains the proof that the memory-only `SecIdentity` is
    /// what the TLS-termination consumer hands to `SSLSetCertificate`.
    /// The full handshake-with-real-TLS-client round-trip is
    /// `MITMTerminationSeamTests.clientHelloNotDoubleConsumedAfterPeek`
    /// (which asserts `peerLeafDER == mintedLeafDER`); here we just
    /// confirm the load → set sequence completes against the
    /// production dispatch path. Treating this as a positive-control
    /// sentinel: if a future refactor breaks the consumer, this fails
    /// before the source-scan does.
    @Test("memory-only SecIdentity loads via production dispatch and is accepted by SSLSetCertificate")
    func memoryOnlyIdentityIsAcceptedByTerminationConsumer() async throws {
        // Mint a leaf via the same actor production uses.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("senkani-mitm-e2e-nokc-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let paths = MITMCertificateAuthority.Paths(
            publicCertPEM: dir.appendingPathComponent("egress-ca.pem").path,
            privateKeyPEM: dir.appendingPathComponent("egress-ca.key").path
        )
        let ca = MITMCertificateAuthority(paths: paths, keyBits: 2048)
        _ = try await ca.generateRoot()
        let leaf = try await ca.leaf(forHost: "memory-only.example.invalid")

        // Drive the PRODUCTION dispatcher (`loadIdentity`) — on the
        // macOS-15+ build host this routes to `loadIdentityMemoryOnly`
        // (the no-keychain branch). This is the exact call site
        // `MITMTermination.runTermination` reaches.
        let identity = try MITMCertificateAuthority.loadIdentity(from: leaf.pkcs12)

        // The consumer hands the identity to `SSLSetCertificate`. We
        // recreate that handoff here without standing up a socket so
        // the test stays hermetic; the real-socket version is
        // `MITMTerminationSeamTests.clientHelloNotDoubleConsumedAfterPeek`.
        guard let ssl = SSLCreateContext(nil, .serverSide, .streamType) else {
            Issue.record("SSLCreateContext returned nil")
            return
        }
        let setStatus = SSLSetCertificate(ssl, [identity] as CFArray)
        #expect(setStatus == errSecSuccess,
                "SSLSetCertificate must accept the memory-only SecIdentity; got OSStatus \(setStatus)")
    }

    // MARK: - Acceptance bullet 2: no-Keychain-mutation structural guarantee

    /// Repo root resolved from `#filePath` — same trick the
    /// `ServeArmEgressAuditDualRow` deny-list scan uses.
    private static func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Tests/SenkaniTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repo root
    }

    /// Strip Swift comments (`///` doc comments, `//` line comments,
    /// `/* */` block comments) from a source body. The deny-list scan
    /// must inspect EXECUTABLE references to Keychain symbols, not the
    /// (extensive, deliberate) doc-comment mentions in
    /// `MITMCertificateAuthority.swift` that explain WHY the floor
    /// retains them. Block comments are stripped first (non-greedy)
    /// because they can span multiple lines and contain `//` sequences.
    private static func stripSwiftComments(_ source: String) -> String {
        // Block comments first (non-greedy across newlines).
        var s = source
        if let regex = try? NSRegularExpression(pattern: #"/\*[\s\S]*?\*/"#, options: []) {
            let range = NSRange(s.startIndex..<s.endIndex, in: s)
            s = regex.stringByReplacingMatches(in: s, options: [], range: range, withTemplate: "")
        }
        // Then line comments: anything from `//` (which catches `///`
        // too) to end-of-line. Naive but adequate — our targets are
        // not embedded inside string literals in the audited files.
        let lines = s.split(separator: "\n", omittingEmptySubsequences: false)
        let stripped = lines.map { line -> String in
            let str = String(line)
            if let r = str.range(of: "//") {
                return String(str[..<r.lowerBound])
            }
            return str
        }
        return stripped.joined(separator: "\n")
    }

    /// Symbols whose presence in the macOS-15+ memory-only codepath
    /// would indicate a Keychain mutation. Anchored as whole-word
    /// regexes (`\b`) so e.g. `kSecImportToMemoryOnly` doesn't get
    /// confused with `kSecImportExportKeychain`.
    private static let deniedKeychainMutationSymbols: [String] = [
        #"\bSecKeychainCreate\b"#,
        #"\bSecKeychainDelete\b"#,
        #"\bkSecImportExportKeychain\b"#,
        #"\bSecItemAdd\b"#,
        #"\bSecItemUpdate\b"#,
        #"\bSecItemDelete\b"#,
        // `SecItemCopyMatching` is a READ, not a mutation, but it's a
        // Keychain query and the memory-only path must not touch the
        // user Keychain at all. The macOS-14-floor `exportPKCS12` uses
        // it deliberately; the scope-marker carve-out below excludes
        // that region.
        #"\bSecItemCopyMatching\b"#,
    ]

    /// The macOS-15+ memory-only branch of `loadIdentity` is the only
    /// region of `MITMCertificateAuthority.swift` reachable through the
    /// production termination consumer on supported hosts. We carve
    /// that region out by textually slicing between
    /// `loadIdentityMemoryOnly` and the next function declaration —
    /// `loadIdentityViaEphemeralKeychain` (the macOS-14 floor, which
    /// LEGITIMATELY uses `kSecImportExportKeychain` + the ephemeral
    /// keychain pair) — and scan only that slice for the deny-listed
    /// symbols.
    ///
    /// The dispatcher (`loadIdentity`) itself is plain `if #available`
    /// + two function calls — no Keychain symbols by construction —
    /// but we include it in the slice anyway to lock the property in
    /// case a future maintainer inlines logic into it.
    @Test("macOS-15+ memory-only loadIdentity branch references no Keychain-mutation symbol")
    func memoryOnlyLoadIdentityBranchHasNoKeychainSymbols() throws {
        let url = Self.repoRoot()
            .appendingPathComponent("Sources/Core/EgressProxy/MITMCertificateAuthority.swift")
        let raw = try String(contentsOf: url, encoding: .utf8)
        // Strip comments BEFORE slicing so the doc comment that
        // immediately precedes `loadIdentityViaEphemeralKeychain` (and
        // mentions `SecKeychainCreate`/`SecKeychainDelete` deliberately)
        // does not bleed into the macOS-15+ slice as a false-positive.
        let body = Self.stripSwiftComments(raw)

        // Slice: from the dispatcher's signature down to (not
        // including) `loadIdentityViaEphemeralKeychain`'s signature.
        // This covers `loadIdentity(from:)` + `loadIdentityMemoryOnly`
        // — the entire macOS-15+ codepath.
        let startMarker = "public static func loadIdentity(from p12: Data) throws -> SecIdentity"
        let endMarker = "static func loadIdentityViaEphemeralKeychain"
        guard let startRange = body.range(of: startMarker),
              let endRange = body.range(of: endMarker, range: startRange.upperBound..<body.endIndex)
        else {
            Issue.record("could not locate memory-only slice in MITMCertificateAuthority.swift — markers moved? (start=\(startMarker), end=\(endMarker))")
            return
        }
        let slice = String(body[startRange.lowerBound..<endRange.lowerBound])

        // The slice MUST reference `kSecImportToMemoryOnly` — otherwise
        // we've sliced the wrong region (positive control).
        #expect(slice.range(of: #"\bkSecImportToMemoryOnly\b"#, options: .regularExpression) != nil,
                "positive-control failed: memory-only slice does not contain kSecImportToMemoryOnly — slice markers may be stale")

        var hits: [String] = []
        for pattern in Self.deniedKeychainMutationSymbols {
            if let r = slice.range(of: pattern, options: .regularExpression) {
                let line = slice[..<r.lowerBound].split(separator: "\n").count
                let matched = String(slice[r])
                hits.append("memory-only slice line ~\(line): \(matched)")
            }
        }
        #expect(hits.isEmpty,
                "macOS-15+ memory-only loadIdentity branch must not reference Keychain-mutation symbols; offenders: \(hits)")
    }

    /// `MITMTermination.swift` is the TLS-termination consumer's entire
    /// implementation — `runTermination`, `runTerminationWithUpstream`,
    /// the IO callbacks, the select() helpers. Every reachable
    /// codepath after `loadIdentity` returns lives in this file. It
    /// MUST NEVER reference a Keychain symbol — neither the
    /// mutation set above nor the read symbol — because the handshake
    /// uses SecureTransport (SSLContext) and the SecIdentity already
    /// in hand.
    @Test("MITMTermination.swift references no Keychain symbol at all")
    func terminationConsumerHasNoKeychainSymbol() throws {
        let url = Self.repoRoot()
            .appendingPathComponent("Sources/Core/EgressProxy/MITMTermination.swift")
        let raw = try String(contentsOf: url, encoding: .utf8)
        // Strip comments — the file's own docstring explains the design
        // (no Keychain calls) using the same symbol names we deny-list.
        let body = Self.stripSwiftComments(raw)

        // Whole-file scan: not just the mutation set, but ANY
        // `SecKeychain*`, `SecItem*`, `kSecClass*`, or
        // `kSecImportExport*` reference. The consumer must rely
        // exclusively on the in-hand SecIdentity + SecureTransport.
        let patterns: [String] = [
            #"\bSecKeychain[A-Z]\w*"#,    // SecKeychainCreate, SecKeychainDelete, ...
            #"\bSecItem[A-Z]\w*"#,        // SecItemAdd, SecItemCopyMatching, ...
            #"\bkSecClass\w*"#,           // kSecClassIdentity, kSecClassCertificate, ...
            #"\bkSecImportExport\w*"#,    // kSecImportExportKeychain, ...
            #"\bkSecImportToMemoryOnly\b"#,  // even the memory-only flag belongs to load, not termination
        ]
        var hits: [String] = []
        let lines = body.split(separator: "\n", omittingEmptySubsequences: false)
        for (idx, line) in lines.enumerated() {
            let s = String(line)
            for pattern in patterns {
                if s.range(of: pattern, options: .regularExpression) != nil {
                    hits.append("MITMTermination.swift:\(idx + 1): \(s.trimmingCharacters(in: .whitespaces))")
                    break
                }
            }
        }
        #expect(hits.isEmpty,
                "MITMTermination.swift must not reference any Keychain API; offenders: \(hits)")
    }
}
