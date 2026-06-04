import Foundation
import Testing
import Security
#if canImport(Darwin)
import Darwin.POSIX
#endif
@testable import Core

/// T.1d-2b-iv — inner HTTP Host/`:authority` rebind tests.
///
/// THE P0: a request whose inner `Host:` header does NOT match the
/// SNI/CONNECT-validated host MUST be rejected with a stable
/// `mitm_inner_host_mismatch` deny outcome and the bytes MUST NOT
/// flow to the upstream. This closes the HTTP/1.1 connection-reuse
/// domain-fronting smuggling bypass.
///
/// We split the test surface into:
///   - PURE PARSER tests (no IO): exercise the head parse, port-strip,
///     case-insensitive comparison, and protocol detection logic.
///   - DECISION tests (pure): exercise the `decide(headBytes:validatedHost:)`
///     surface end-to-end on representative request heads.
///
/// The end-to-end pipeBidirectional wiring + audit-row contract is
/// covered indirectly by the `EgressConnectionHandler` outcome
/// switch — adding a full TLS-on-loopback rebind round-trip here
/// would duplicate the heavy plumbing in `MITMTerminationSeamTests`
/// without strengthening the inner-Host invariant (the rebind
/// surface is the `decide()` function the pipe calls).
@Suite("MITM inner-Host rebind (T.1d-2b-iv)")
struct MITMInnerHostRebindTests {

    // MARK: - Helpers

    private func headFor(method: String = "GET", path: String = "/v1/test",
                         hostHeader: String, extraHeaders: [String] = []) -> [UInt8] {
        var s = "\(method) \(path) HTTP/1.1\r\n"
        s += "Host: \(hostHeader)\r\n"
        for h in extraHeaders {
            s += "\(h)\r\n"
        }
        s += "\r\n"
        return Array(s.utf8)
    }

    // MARK: - THE P0: reused-connection mismatch rejection

    /// Load-bearing P0: an HTTP/1.1 request carrying a different inner
    /// `Host:` than the validated SNI/CONNECT host is rejected with
    /// `.rejectMismatch`. This is the connection-reuse / domain-fronting
    /// smuggling close.
    @Test("reused connection with different inner Host is rejected (P0)")
    func reusedConnectionDifferentInnerHostRejected() async throws {
        let head = headFor(hostHeader: "evil.example")
        let decision = MITMInnerHostRebind.decide(
            headBytes: head,
            validatedHost: "api.anthropic.com"
        )
        switch decision {
        case .rejectMismatch:
            break  // ✓
        default:
            Issue.record("FAIL-CLOSED VIOLATION: inner Host 'evil.example' on validated 'api.anthropic.com' connection was NOT rejected. Got: \(decision)")
        }
    }

    // MARK: - Positive paths

    /// Matching inner Host → `.allow` with the buffered head bytes
    /// surfaced for replay.
    @Test("matching inner Host passes through with head bytes preserved")
    func validInnerHostMatchPassesThrough() async throws {
        let head = headFor(hostHeader: "api.anthropic.com")
        let decision = MITMInnerHostRebind.decide(
            headBytes: head,
            validatedHost: "api.anthropic.com"
        )
        switch decision {
        case .allow(let bytes):
            #expect(bytes == head,
                    "allow case must surface the buffered head bytes for replay")
        default:
            Issue.record("expected .allow, got \(decision)")
        }
    }

    /// Case-insensitive Host match. `API.Anthropic.COM` matches
    /// `api.anthropic.com`.
    @Test("case-insensitive Host match")
    func caseInsensitiveHostMatch() async throws {
        let head = headFor(hostHeader: "API.Anthropic.COM")
        let decision = MITMInnerHostRebind.decide(
            headBytes: head,
            validatedHost: "api.anthropic.com"
        )
        if case .allow = decision { /* ok */ }
        else { Issue.record("case-insensitive Host should match — got \(decision)") }
    }

    /// Host header with port is stripped before comparison.
    /// `api.anthropic.com:443` matches `api.anthropic.com`.
    @Test("Host header with port strips correctly before compare")
    func hostHeaderWithPortStripsCorrectly() async throws {
        let head = headFor(hostHeader: "api.anthropic.com:443")
        let decision = MITMInnerHostRebind.decide(
            headBytes: head,
            validatedHost: "api.anthropic.com"
        )
        if case .allow = decision { /* ok */ }
        else { Issue.record("port-suffixed Host should match — got \(decision)") }
    }

    /// Non-default port still strips — port-binding is enforced by the
    /// TCP upstream connect, not the Host header.
    @Test("Host header with non-443 port still matches by hostname")
    func hostHeaderNonDefaultPortMatches() async throws {
        let head = headFor(hostHeader: "api.anthropic.com:8443")
        let decision = MITMInnerHostRebind.decide(
            headBytes: head,
            validatedHost: "api.anthropic.com"
        )
        if case .allow = decision { /* ok */ }
        else { Issue.record("non-default port suffix should still match — got \(decision)") }
    }

    // MARK: - Defensive rejections

    /// Missing Host header → `.rejectMissingHost` (mapped to the
    /// `mitm_inner_no_host` ruleId, distinct from `.rejectMismatch` /
    /// `mitm_inner_host_mismatch`). Karpathy r92 P2 — operator-
    /// distinguishable forensics: a missing-Host smuggling attempt is
    /// a different attacker shape from a reused-connection mismatch.
    @Test("missing Host header is rejected as mitm_inner_no_host (distinct ruleId)")
    func missingHostHeaderRejected() async throws {
        let s = "GET /v1/test HTTP/1.1\r\nAccept: */*\r\n\r\n"
        let decision = MITMInnerHostRebind.decide(
            headBytes: Array(s.utf8),
            validatedHost: "api.anthropic.com"
        )
        if case .rejectMissingHost = decision { /* ok */ }
        else { Issue.record("missing Host should reject as .rejectMissingHost — got \(decision)") }
        // Pin the ruleId mapping at the corpus seam so the audit-row
        // distinction is verified end-to-end.
        #expect(MITMBodyInspectionCorpus.ruleIdForRebind(decision) == "mitm_inner_no_host")
    }

    /// Unknown method (non-HTTP/1.x) → `.rejectUnknownProtocol`. The
    /// HTTP/2 client preface (`PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n`) is
    /// the canonical example.
    @Test("HTTP/2 client preface rejected as unknown protocol")
    func http2PrefaceRejected() async throws {
        let preface = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"
        let decision = MITMInnerHostRebind.decide(
            headBytes: Array(preface.utf8),
            validatedHost: "api.anthropic.com"
        )
        if case .rejectUnknownProtocol = decision { /* ok */ }
        else { Issue.record("HTTP/2 preface should reject as unknown protocol — got \(decision)") }
    }

    /// Arbitrary binary garbage → unknown protocol.
    @Test("arbitrary binary garbage rejected as unknown protocol")
    func arbitraryBinaryRejected() async throws {
        let bytes: [UInt8] = [0xFF, 0xFE, 0xFD, 0xFC, 0x00, 0x01, 0x02, 0x03,
                              0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
        let decision = MITMInnerHostRebind.decide(
            headBytes: bytes,
            validatedHost: "api.anthropic.com"
        )
        if case .rejectUnknownProtocol = decision { /* ok */ }
        else { Issue.record("binary garbage should reject as unknown protocol — got \(decision)") }
    }

    // MARK: - Unit tests on the pure helpers

    @Test("hostsMatch — basic case-insensitive equality")
    func hostsMatchCaseInsensitive() async throws {
        #expect(MITMInnerHostRebind.hostsMatch(innerHostHeader: "api.anthropic.com", validatedHost: "API.ANTHROPIC.COM"))
        #expect(MITMInnerHostRebind.hostsMatch(innerHostHeader: "api.anthropic.com", validatedHost: "api.anthropic.com"))
        #expect(!MITMInnerHostRebind.hostsMatch(innerHostHeader: "evil.example", validatedHost: "api.anthropic.com"))
    }

    @Test("hostsMatch — port strip on either side")
    func hostsMatchPortStrip() async throws {
        #expect(MITMInnerHostRebind.hostsMatch(innerHostHeader: "api.anthropic.com:443", validatedHost: "api.anthropic.com"))
        #expect(MITMInnerHostRebind.hostsMatch(innerHostHeader: "api.anthropic.com", validatedHost: "api.anthropic.com:443"))
        #expect(MITMInnerHostRebind.hostsMatch(innerHostHeader: "api.anthropic.com:8443", validatedHost: "api.anthropic.com"))
    }

    @Test("hostsMatch — empty inner host is never a match")
    func hostsMatchEmptyInnerNeverMatches() async throws {
        #expect(!MITMInnerHostRebind.hostsMatch(innerHostHeader: "", validatedHost: "api.anthropic.com"))
        #expect(!MITMInnerHostRebind.hostsMatch(innerHostHeader: "   ", validatedHost: "api.anthropic.com"))
    }

    @Test("hostsMatch — IPv6 bracketed host preserves brackets, strips port")
    func hostsMatchIPv6Bracketed() async throws {
        // Both bracketed identically → match.
        #expect(MITMInnerHostRebind.hostsMatch(innerHostHeader: "[::1]", validatedHost: "[::1]"))
        // Bracketed with port matches bracketed without port.
        #expect(MITMInnerHostRebind.hostsMatch(innerHostHeader: "[::1]:443", validatedHost: "[::1]"))
    }

    @Test("extractHostHeader — finds Host case-insensitively")
    func extractHostCaseInsensitive() async throws {
        let lower = headFor(hostHeader: "api.example.com")
        let upper = "GET / HTTP/1.1\r\nHOST: api.example.com\r\n\r\n"
        let mixed = "GET / HTTP/1.1\r\nhOsT: api.example.com\r\n\r\n"
        #expect(MITMInnerHostRebind.extractHostHeader(headBytes: lower) == "api.example.com")
        #expect(MITMInnerHostRebind.extractHostHeader(headBytes: Array(upper.utf8)) == "api.example.com")
        #expect(MITMInnerHostRebind.extractHostHeader(headBytes: Array(mixed.utf8)) == "api.example.com")
    }

    @Test("looksLikeHTTP1 — accepts known methods, rejects others")
    func looksLikeHTTP1Surface() async throws {
        for m in ["GET", "POST", "PUT", "DELETE", "HEAD", "OPTIONS", "PATCH", "CONNECT", "TRACE"] {
            let bytes = Array("\(m) / HTTP/1.1\r\n".utf8)
            #expect(MITMInnerHostRebind.looksLikeHTTP1(headBytes: bytes),
                    "method \(m) should be recognized as HTTP/1.x")
        }
        // HTTP/2 client preface starts with "PRI " — not in whitelist.
        #expect(!MITMInnerHostRebind.looksLikeHTTP1(headBytes: Array("PRI * HTTP/2.0\r\n".utf8)))
        // Junk → false.
        #expect(!MITMInnerHostRebind.looksLikeHTTP1(headBytes: [0xFF, 0xFE, 0xFD, 0xFC]))
        // Empty → false.
        #expect(!MITMInnerHostRebind.looksLikeHTTP1(headBytes: []))
    }

    @Test("headTerminatorIndex — locates CRLF CRLF")
    func headTerminatorIndexFound() async throws {
        let head = headFor(hostHeader: "x")
        let idx = MITMInnerHostRebind.headTerminatorIndex(in: head)
        #expect(idx == head.count, "terminator should be at the end of the buffered head")
        // No terminator yet → nil.
        let partial = Array("GET / HTTP/1.1\r\nHost: x\r\n".utf8)
        #expect(MITMInnerHostRebind.headTerminatorIndex(in: partial) == nil)
    }

    // MARK: - r92 Allspaw P3 — stripPort edge cases (lastIndex + bracketed/multi-colon)

    /// stripPort exhaustive edge cases on the six canonical input shapes.
    /// Bracketed IPv6 must preserve brackets + strip port. Unbracketed
    /// multi-colon (ambiguous IPv6) must NOT strip — there's no
    /// unambiguous way to know where host ends and port begins.
    @Test("stripPort — bracketed IPv6 with port → host kept, port stripped")
    func stripPortBracketedIPv6WithPort() async throws {
        #expect(MITMInnerHostRebind.stripPort("[::1]:443") == "[::1]")
    }

    @Test("stripPort — bracketed IPv6 without port → unchanged")
    func stripPortBracketedIPv6NoPort() async throws {
        #expect(MITMInnerHostRebind.stripPort("[::1]") == "[::1]")
    }

    @Test("stripPort — unbracketed multi-colon IPv6 → unchanged (ambiguous)")
    func stripPortUnbracketedIPv6NoPort() async throws {
        // Ambiguous: can't tell if `::1` is a host or a host:port. Be
        // conservative and treat the whole string as the host.
        #expect(MITMInnerHostRebind.stripPort("::1") == "::1")
    }

    @Test("stripPort — single-colon IPv4 with port → port stripped")
    func stripPortIPv4WithPort() async throws {
        #expect(MITMInnerHostRebind.stripPort("127.0.0.1:443") == "127.0.0.1")
    }

    @Test("stripPort — DNS hostname with port → port stripped")
    func stripPortHostnameWithPort() async throws {
        #expect(MITMInnerHostRebind.stripPort("api.anthropic.com:443") == "api.anthropic.com")
    }

    @Test("stripPort — DNS hostname without port → unchanged")
    func stripPortHostnameNoPort() async throws {
        #expect(MITMInnerHostRebind.stripPort("api.anthropic.com") == "api.anthropic.com")
    }

    // MARK: - r92 Allspaw P2 — positive .rejectHeadTooLarge with a recognized method

    /// `peekAndDecide` rejects with `.rejectUnknownProtocol` as soon as
    /// `buf.count >= 4` and the first token isn't a known method. To
    /// reach the head-too-large path, the payload MUST start with a
    /// recognized method then drag past 16 KB without `\r\n\r\n` (a
    /// massive header smuggling attempt on a valid method line). This
    /// test exercises the pure `decide()` surface, which is reachable
    /// only when the corpus probe sees the size-overflow shape —
    /// `decide()` itself does not enforce the size cap (that's done by
    /// `peekAndDecide`'s outer loop). So we use the
    /// `probeHeadSizeOverflow` corpus helper to assert the size-cap
    /// classification on a method-prefixed oversized head, complementing
    /// scenario 4 of the corpus (which uses a pure probe shape).
    @Test("peekAndDecide head-too-large positive: valid method + oversized header drag past 16 KB")
    func headTooLargePositiveWithRecognizedMethod() async throws {
        // Construct a head that STARTS with a recognized method so
        // `looksLikeHTTP1` does not short-circuit to
        // `.rejectUnknownProtocol`, then drags well past 16 KB without
        // a `\r\n\r\n` terminator (massive header smuggling shape).
        var bytes: [UInt8] = Array("GET / HTTP/1.1\r\nHost: api.anthropic.com\r\nX-Filler: ".utf8)
        bytes.append(contentsOf: [UInt8](repeating: 0x41 /* 'A' */, count: 16384))
        // No trailing `\r\n\r\n` → would have dragged past peekAndDecide's
        // 16 KiB budget in the live IO path.

        // Sanity 1: this DOES look like HTTP/1.x (so the
        // unknown-protocol short-circuit would not have fired).
        #expect(MITMInnerHostRebind.looksLikeHTTP1(headBytes: bytes),
                "payload must be classified HTTP/1.x so the unknown-protocol short-circuit does not pre-empt the head-too-large path")
        // Sanity 2: no head terminator present anywhere in the buffer.
        #expect(MITMInnerHostRebind.headTerminatorIndex(in: bytes) == nil,
                "payload must NOT contain `\\r\\n\\r\\n` so the head-too-large path is the only reachable outcome")
        // Sanity 3: payload size MUST exceed the head-budget cap.
        #expect(bytes.count >= MITMInnerHostRebind.maxHeadBytes,
                "payload must exceed maxHeadBytes (\(MITMInnerHostRebind.maxHeadBytes)) — got \(bytes.count)")

        // The size-overflow corpus probe mirrors the conditional inside
        // `peekAndDecide` that would have returned `.rejectHeadTooLarge`.
        let probed = MITMBodyInspectionCorpus.probeHeadSizeOverflow(
            bytes: bytes,
            limit: MITMInnerHostRebind.maxHeadBytes
        )
        #expect(probed == "mitm_inner_head_too_large",
                "valid-method + oversized-header head MUST classify as mitm_inner_head_too_large; got \(probed)")
    }
}
