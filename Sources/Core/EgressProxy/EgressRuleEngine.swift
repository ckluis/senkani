import Foundation

/// One entry in the static egress allow / deny list. The rule engine is
/// deny-wins: if any matching rule is `.deny`, the request is blocked;
/// otherwise an `.allow` match wins; otherwise the engine falls back to
/// the deny-on-miss default.
///
/// Match modes (Carmack audit 2026-05-06: keep matchers boring):
///   - `.exact`  — host equals (post-normalization) the rule pattern.
///   - `.prefix` — host starts with the rule pattern. The pattern MUST
///     end at a host-label boundary (`.`) or be the full host. So
///     `example.com` (prefix) matches `example.com` and
///     `api.example.com` does NOT match — that's what `.suffix` is for.
///     `.prefix` is intended for path-style allowlists (rare here).
///   - `.suffix` — host ends with the rule pattern at a label boundary.
///     `example.com` matches `example.com` AND `api.example.com` AND
///     `deep.api.example.com`, but NOT `notexample.com`. This is the
///     usual mode an operator means by "allow example.com and its
///     subdomains."
///   - `.glob`   — `*` matches any single label sequence; one `*` only;
///     intended for `*.example.com` style. We deliberately don't ship
///     full POSIX glob — the surface is too forgiving and the deny-by-
///     default semantics are what matter.
public struct EgressRule: Sendable, Equatable {
    public enum Mode: String, Sendable, Equatable, Codable {
        case exact, prefix, suffix, glob
    }
    public enum Decision: String, Sendable, Equatable, Codable {
        case allow, deny
    }

    /// Header matcher (T.1d.3). Header NAME comparison is
    /// case-INSENSITIVE per RFC 7230 §3.2 (field-name is case-insensitive);
    /// we lowercase both sides AND strip CR/LF + OWS from both names before
    /// the compare (T.1d.3 hardening — a CRLF/whitespace-laced request
    /// header name must not silently fail-open past the deny matcher).
    /// `valueContains`, when present, is a case-SENSITIVE substring test
    /// against the header value AFTER the leading/trailing OWS (optional
    /// whitespace — spaces and tabs) is trimmed. When `valueContains` is
    /// nil, the matcher is satisfied by mere presence of any header with
    /// the (normalized, case-insensitive) name.
    public struct HeaderMatch: Sendable, Equatable {
        public let name: String
        public let valueContains: String?

        public init(name: String, valueContains: String? = nil) {
            self.name = name
            self.valueContains = valueContains
        }
    }

    /// Path-segment match mode (T.1d.3). All comparisons run against the
    /// NORMALIZED request path (see `EgressRule.normalizePath`) and are
    /// CASE-SENSITIVE.
    public enum PathMode: String, Sendable, Equatable, Codable {
        case exact, prefix, contains
    }

    /// Path matcher (T.1d.3). `value` is matched against the normalized
    /// request path per `mode`. Note: `value` is NOT normalized here — the
    /// operator is expected to supply an already-canonical path (a single
    /// leading slash, no dot-segments). The REQUEST path is the side that
    /// gets normalized so encoding/dot-segment bypasses are caught.
    public struct PathMatch: Sendable, Equatable {
        public let value: String
        public let mode: PathMode

        public init(value: String, mode: PathMode) {
            self.value = value
            self.mode = mode
        }
    }

    public let id: String
    public let pattern: String
    public let mode: Mode
    public let decision: Decision

    // --- T.1d.3 request-dimension matchers (all optional) -------------
    //
    // SECURITY NOTE (best-effort defense-in-depth, NOT an enforcement
    // boundary): body / header / path DENY matchers are advisory. They are
    // trivially evadable and they SILENTLY FAIL OPEN:
    //   - `bodyContains` is a raw, case-SENSITIVE substring test. An
    //     adversary evades it by changing case, inserting whitespace /
    //     CRLF, percent- or base64-encoding the payload, or splitting the
    //     token across the excerpt boundary. There is no semantic parse.
    //   - The body excerpt is PRE-TRUNCATED by the caller (T.1d.4 policy:
    //     ≤4 KB). A deny-substring that appears only AFTER the bound never
    //     matches — a silent fail-open. The engine NEVER buffers or
    //     truncates an unbounded body itself; it only ever sees what the
    //     caller already bounded.
    //   - AND-ACROSS-DIMENSIONS: a rule matches only if EVERY dimension it
    //     specifies matches. An over-specified deny (e.g. host AND path AND
    //     body) therefore matches FEWER requests than an operator may
    //     intuit — the extra conjuncts make the deny LESS aggressive, not
    //     more. Recommendation: write SINGLE-dimension deny rules so the
    //     deny fires whenever ANY one signal is present.
    // Treat these as telemetry / belt-and-suspenders, never as the egress
    // boundary — the host allowlist + deny-on-miss default is the boundary.

    /// Case-SENSITIVE substring required somewhere in the request's
    /// (pre-truncated) body excerpt. nil ⇒ dimension not specified.
    public let bodyContains: String?

    /// Header matcher (see `HeaderMatch`). nil ⇒ dimension not specified.
    public let header: HeaderMatch?

    /// Path matcher (see `PathMatch`). nil ⇒ dimension not specified.
    public let path: PathMatch?

    /// Backward-compatible host-only initializer. All request dimensions
    /// default to nil, so every existing call site (and test) compiles and
    /// behaves unchanged.
    public init(id: String, pattern: String, mode: Mode, decision: Decision) {
        self.init(
            id: id,
            pattern: pattern,
            mode: mode,
            decision: decision,
            bodyContains: nil,
            header: nil,
            path: nil
        )
    }

    /// Full initializer including the optional T.1d.3 request dimensions.
    public init(
        id: String,
        pattern: String,
        mode: Mode,
        decision: Decision,
        bodyContains: String?,
        header: HeaderMatch?,
        path: PathMatch?
    ) {
        self.id = id
        self.pattern = pattern
        self.mode = mode
        self.decision = decision
        self.bodyContains = bodyContains
        self.header = header
        self.path = path
    }

    /// True iff this rule carries any request-only dimension (body,
    /// header, or path). Such a rule CANNOT be satisfied by a host-only
    /// evaluation, so `matches(host:)` returns false for it — keeping
    /// `evaluate(host:)` byte-identical for legacy host-only rule sets and
    /// making any body/header/path deny INERT under `evaluate(host:)`.
    public var hasRequestDimension: Bool {
        bodyContains != nil || header != nil || path != nil
    }

    /// Does this rule match the (already-normalized) host? Pattern is
    /// also normalized at evaluation time so the operator doesn't have
    /// to remember to lowercase / strip ports in their config.
    ///
    /// IMPORTANT (backward-compat): a rule that specifies ANY request-only
    /// dimension (body / header / path) returns false here — those
    /// dimensions are unsatisfiable without a full request, so a host-only
    /// evaluation must never let such a rule fire. This is what keeps
    /// `evaluate(host:)` identical to its pre-T.1d.3 behavior.
    public func matches(host: String) -> Bool {
        if hasRequestDimension { return false }
        return matchesHost(host)
    }

    /// Host-dimension match, factored out so both `matches(host:)` (which
    /// also guards on request-only dimensions) and `matches(request:)`
    /// (which evaluates host alongside the other dimensions) share it.
    private func matchesHost(_ host: String) -> Bool {
        let p = EgressHostNormalizer.normalize(pattern)
        switch mode {
        case .exact:
            return host == p
        case .prefix:
            if host == p { return true }
            return host.hasPrefix(p)
        case .suffix:
            if host == p { return true }
            // Label-boundary anchor: `api.example.com` matches `example.com`
            // because the character before `example.com` in the host is `.`.
            // `notexample.com` does NOT match because the character before
            // `example.com` is `t` (no boundary).
            guard host.hasSuffix(p) else { return false }
            let prefixLen = host.count - p.count
            if prefixLen == 0 { return true }
            let boundaryIdx = host.index(host.startIndex, offsetBy: prefixLen - 1)
            return host[boundaryIdx] == "."
        case .glob:
            return Self.globMatch(pattern: p, host: host)
        }
    }

    /// Single-`*` glob matcher. Examples:
    ///   - `*.example.com`     matches `api.example.com`, `a.b.example.com`
    ///   - `api.*.example.com` matches `api.east.example.com`
    /// Multiple `*` returns false rather than falling back to a more
    /// permissive matcher — keeps blast radius bounded.
    private static func globMatch(pattern: String, host: String) -> Bool {
        let parts = pattern.split(separator: "*", omittingEmptySubsequences: false)
        guard parts.count == 2 else {
            return parts.count == 1 && String(parts[0]) == host
        }
        let head = String(parts[0])
        let tail = String(parts[1])
        guard host.hasPrefix(head), host.hasSuffix(tail) else { return false }
        let middleLen = host.count - head.count - tail.count
        if middleLen < 0 { return false }
        // Disallow empty middle UNLESS the pattern was something like
        // `*foo` (head empty) — the empty-middle case there is fine.
        if middleLen == 0 && !head.isEmpty && !tail.isEmpty { return false }
        return true
    }

    // --- T.1d.3 request matching --------------------------------------

    /// Does this rule match the given parsed request? AND-WITHIN-RULE:
    /// returns true iff EVERY dimension the rule SPECIFIES matches.
    ///   - host: existing host-mode match against `request.host`.
    ///   - bodyContains: `request.bodyExcerpt` contains it (case-sensitive
    ///     substring). If the rule specifies bodyContains but the request
    ///     has no body excerpt ⇒ NO match.
    ///   - header: some request header whose lowercased name equals the
    ///     matcher's lowercased name; if `valueContains` is set, that
    ///     header's OWS-trimmed value must contain it (case-sensitive).
    ///     Absent ⇒ no match.
    ///   - path: the NORMALIZED request path matches per `PathMode`. If
    ///     `request.path` is nil ⇒ no match.
    /// A dimension the request LACKS ⇒ the rule does NOT match.
    public func matches(request: EgressRequest) -> Bool {
        // Host always participates (host is mandatory on every request).
        guard matchesHost(request.host) else { return false }

        if let needle = bodyContains {
            guard let excerpt = request.bodyExcerpt,
                  excerpt.contains(needle) else { return false }
        }

        if let hm = header {
            // T.1d.3 hardening: normalize the NAME on BOTH sides (strip
            // CR/LF + OWS, then lowercase) before the case-insensitive
            // compare. A CRLF/whitespace-laced request header name (e.g.
            // "Authorization\r\n" or " authorization\t") previously caused
            // a clean deny MISS — a silent fail-open. Stripping makes the
            // deny still fire. Value behavior is UNCHANGED (OWS-trim +
            // case-SENSITIVE substring).
            let wantName = Self.normalizeHeaderName(hm.name)
            let found = request.headers.contains { h in
                guard Self.normalizeHeaderName(h.name) == wantName else { return false }
                guard let wantValue = hm.valueContains else {
                    return true // name-presence-only
                }
                let trimmed = Self.trimOWS(h.value)
                return trimmed.contains(wantValue)
            }
            if !found { return false }
        }

        if let pm = path {
            guard let raw = request.path else { return false }
            let normalized = Self.normalizePath(raw)
            switch pm.mode {
            case .exact:
                guard normalized == pm.value else { return false }
            case .prefix:
                guard normalized.hasPrefix(pm.value) else { return false }
            case .contains:
                guard normalized.contains(pm.value) else { return false }
            }
        }

        return true
    }

    /// Trim OWS (optional whitespace per RFC 7230 — spaces and horizontal
    /// tabs) from both ends of a header value before substring matching.
    private static func trimOWS(_ s: String) -> String {
        s.trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
    }

    /// Normalize a header NAME for the case-insensitive compare (T.1d.3
    /// hardening): remove ALL CR/LF and OWS (spaces / tabs) characters,
    /// then lowercase. A field-name has no legal interior whitespace or
    /// line breaks (RFC 7230 §3.2: `token`), so removing them entirely
    /// canonicalizes a CRLF/whitespace-laced name to the same key on both
    /// the rule and request side — closing the silent fail-open where a
    /// "Authorization\r\n" request name slipped past an "authorization"
    /// deny matcher.
    private static func normalizeHeaderName(_ s: String) -> String {
        // Operate on Unicode SCALARS, not Characters: Swift folds a CRLF
        // ("\r\n") into a SINGLE extended grapheme cluster, so iterating
        // `Character`s would never see a standalone "\r"/"\n" to strip. The
        // scalar view sees each of CR (U+000D) and LF (U+000A) individually.
        var scalars = String.UnicodeScalarView()
        for u in s.unicodeScalars {
            switch u {
            case "\r", "\n", " ", "\t":
                continue
            default:
                scalars.append(u)
            }
        }
        return String(scalars).lowercased()
    }

    /// Upper bound on percent-decode passes (T.1d.3 hardening). Decoding to
    /// a fixed point lets `%2561dmin` (double-encoded `a`) resolve to
    /// `/admin`, but an attacker-supplied string could in principle keep
    /// shrinking; we cap iterations and use the last result if still
    /// changing at the cap. 5 passes covers any realistic nesting depth.
    private static let maxPercentDecodePasses = 5

    /// Canonicalize a request path so a `/admin` deny is not bypassed by
    /// `/./admin`, `/a/../admin`, `//admin`, `%61dmin`, `%2561dmin`,
    /// `\admin`, `/admin;x=1`, `/admin%00`, or `/admin/`.
    /// Committed policy (CASE-SENSITIVE — paths are case-sensitive):
    ///   1. Strip NUL (`\0`) bytes outright (a `/admin%00.txt` truncation
    ///      trick must not let an extension slip past a `/admin` matcher;
    ///      the cleaned path is what every dimension compares against).
    ///   2. Iterated percent-decode to a FIXED POINT, BOUNDED at
    ///      `maxPercentDecodePasses` passes (so `%2561dmin` → `%61dmin` →
    ///      `admin`). If decoding still changes at the cap, the last result
    ///      is used — no unbounded loop. NUL is re-stripped after each pass
    ///      (a `%00` only decodes mid-loop).
    ///   3. Convert backslashes (`\`) to forward slashes BEFORE splitting —
    ///      many servers treat `\` as a path separator, so `\admin` and
    ///      `/a\..\admin` must normalize like their `/` forms.
    ///   4. Strip any query / fragment (`?`, `#`) — path only.
    ///   5. Strip `;`-matrix-params per segment (`/admin;x=1` → `/admin`).
    ///   6. Ensure a single leading slash.
    ///   7. Collapse duplicate slashes (`//` → `/`).
    ///   8. Collapse `.` / `..` dot-segments (RFC 3986 remove_dot_segments,
    ///      bounded — `..` never escapes the root).
    ///   9. Drop a trailing slash (except for the root `/`).
    ///
    // residual gap (narrowed): this is OUR normalization, and after the
    // T.1d.3 hardening it closes backslash, NUL, matrix-param, and
    // (bounded) double-percent-encoding bypasses on top of the original
    // slash/dot-segment/single-decode set. A NON-ZERO divergence from
    // arbitrary upstream-server canonicalization remains and is NOT closed
    // here: unicode/UTF-8 overlong forms, case-folding on case-insensitive
    // filesystems, and decode nestings DEEPER than the iteration cap. A
    // path deny is best-effort defense-in-depth, NOT the boundary — the
    // host allowlist + deny-on-miss default is the boundary.
    static func normalizePath(_ raw: String) -> String {
        // 1 + 2. Strip NUL, then iterated bounded percent-decode to a fixed
        //        point. removingPercentEncoding can fail on invalid
        //        sequences; in that case we keep the current string (still
        //        normalize slashes/dot-segments). NUL is stripped both up
        //        front and after each decode pass (a `%00` decodes mid-loop).
        var s = Self.stripNUL(raw)
        for _ in 0..<Self.maxPercentDecodePasses {
            guard let decoded = s.removingPercentEncoding else { break }
            let cleaned = Self.stripNUL(decoded)
            if cleaned == s { break } // fixed point reached
            s = cleaned
        }

        // 3. Treat backslash as a path separator (server-canonicalization
        //    parity) BEFORE splitting on "/".
        if s.contains("\\") {
            s = s.replacingOccurrences(of: "\\", with: "/")
        }

        // 4. Strip query / fragment.
        if let q = s.firstIndex(of: "?") {
            s = String(s[..<q])
        }
        if let h = s.firstIndex(of: "#") {
            s = String(s[..<h])
        }

        // Split on "/", dropping empties (this collapses `//` and handles
        // a leading slash uniformly). Then strip matrix-params + resolve
        // dot-segments.
        let rawSegments = s.split(separator: "/", omittingEmptySubsequences: true)
        var stack: [Substring] = []
        for rawSeg in rawSegments {
            // 5. Strip `;`-matrix-params: keep only the text before the
            //    first `;` in the segment (`admin;x=1` → `admin`).
            let seg: Substring
            if let semi = rawSeg.firstIndex(of: ";") {
                seg = rawSeg[..<semi]
            } else {
                seg = rawSeg
            }
            if seg.isEmpty {
                // A segment that was nothing but matrix-params (`;x=1`) or
                // empty collapses away like a duplicate slash.
                continue
            } else if seg == "." {
                continue
            } else if seg == ".." {
                if !stack.isEmpty { stack.removeLast() }
                // `..` at root is dropped (never escapes root).
            } else {
                stack.append(seg)
            }
        }

        // 6 + 7 + 9: rebuild with a single leading slash, no duplicate
        // slashes, no trailing slash (root stays "/").
        if stack.isEmpty { return "/" }
        return "/" + stack.joined(separator: "/")
    }

    /// Strip NUL (`\0`) bytes from a string. Used by `normalizePath` so a
    /// `%00` truncation/extension trick cannot slip a payload past a
    /// substring/exact path matcher.
    private static func stripNUL(_ s: String) -> String {
        guard s.contains("\0") else { return s }
        return s.replacingOccurrences(of: "\0", with: "")
    }
}

/// Static rule engine evaluation result.
public struct EgressEvaluation: Sendable, Equatable {
    public let decision: EgressRule.Decision
    public let ruleId: String

    public init(decision: EgressRule.Decision, ruleId: String) {
        self.decision = decision
        self.ruleId = ruleId
    }

    /// Sentinel emitted when no rule matches. The default policy is
    /// `deny-wins-on-miss` — Schneier audit 2026-05-06: any future
    /// "deferred decision to operator" mode must NOT silently change
    /// this sentinel; it must add a separate path.
    public static let defaultDeny = EgressEvaluation(decision: .deny, ruleId: "default-deny")
}

/// A parsed egress request, carrying the dimensions the T.1d.3 matchers
/// can inspect: host, method, path, headers, and a body excerpt.
///
/// Relationship to `HTTPRequestLine.ParsedRequest`: that type is the
/// product of parsing the FIRST request line only (method / host / port /
/// path / httpVersion — no headers, no body) and is what the live proxy
/// uses for its host decision. `EgressRequest` is a SUPERSET shaped for
/// the rule engine's body/header/path dimensions; it deliberately does
/// NOT collide with `ParsedRequest`. A caller bridges from one to the
/// other by carrying over host/method/path and supplying the headers +
/// body excerpt it gathered separately.
///
/// IMPORTANT: `bodyExcerpt` is a PRE-TRUNCATED excerpt. The CALLER bounds
/// it (T.1d.4 policy: ≤4 KB) before constructing the request. The rule
/// engine NEVER buffers or truncates an unbounded body — it only ever
/// inspects the bounded excerpt it is handed. A deny-substring that lives
/// past the excerpt bound therefore silently fails open (see the security
/// note on `EgressRule`).
public struct EgressRequest: Sendable, Equatable {
    /// Request host (raw or normalized — `evaluate(request:)` normalizes
    /// it, mirroring `evaluate(host:)`).
    public let host: String
    public let method: String?
    public let path: String?
    /// Headers as an ARRAY of (name, value) to preserve duplicate header
    /// names (e.g. multiple `Set-Cookie` / `X-Forwarded-For`).
    public let headers: [(name: String, value: String)]
    /// Pre-truncated body excerpt supplied by the caller (≤4 KB), or nil.
    public let bodyExcerpt: String?

    public init(
        host: String,
        method: String? = nil,
        path: String? = nil,
        headers: [(name: String, value: String)] = [],
        bodyExcerpt: String? = nil
    ) {
        self.host = host
        self.method = method
        self.path = path
        self.headers = headers
        self.bodyExcerpt = bodyExcerpt
    }

    // [(String, String)] tuples aren't auto-Equatable; compare element-wise.
    public static func == (lhs: EgressRequest, rhs: EgressRequest) -> Bool {
        guard lhs.host == rhs.host,
              lhs.method == rhs.method,
              lhs.path == rhs.path,
              lhs.bodyExcerpt == rhs.bodyExcerpt,
              lhs.headers.count == rhs.headers.count else { return false }
        for (l, r) in zip(lhs.headers, rhs.headers) {
            if l.name != r.name || l.value != r.value { return false }
        }
        return true
    }
}

public struct EgressRuleEngine: Sendable, Equatable {
    public let rules: [EgressRule]

    public init(rules: [EgressRule]) {
        self.rules = rules
    }

    /// Evaluate a host against the rule set. The host argument may be
    /// raw — the engine normalizes it internally before matching.
    /// Deny-wins: the first matching `.deny` short-circuits regardless
    /// of any later `.allow`.
    public func evaluate(host: String) -> EgressEvaluation {
        let normalized = EgressHostNormalizer.normalize(host)
        var firstAllow: EgressRule?
        for rule in rules where rule.matches(host: normalized) {
            if rule.decision == .deny {
                return EgressEvaluation(decision: .deny, ruleId: rule.id)
            }
            if firstAllow == nil {
                firstAllow = rule
            }
        }
        if let allow = firstAllow {
            return EgressEvaluation(decision: .allow, ruleId: allow.id)
        }
        return .defaultDeny
    }

    /// Evaluate a parsed request against the rule set, using all available
    /// dimensions (host / body / header / path). Same DENY-WINS loop as
    /// `evaluate(host:)`: the request host is normalized first, then the
    /// first matching `.deny` short-circuits (so a body/header/path deny
    /// OVERRIDES a separate host allow), else the first `.allow` wins, else
    /// the deny-on-miss default sentinel.
    ///
    /// Note: a host-only rule still participates here — it simply matches on
    /// the host dimension alone (it specifies no body/header/path). This is
    /// the converse of `evaluate(host:)`, where request-dimension rules are
    /// INERT because they cannot be satisfied without a request.
    public func evaluate(request: EgressRequest) -> EgressEvaluation {
        let normalizedHost = EgressHostNormalizer.normalize(request.host)
        let normalizedRequest = EgressRequest(
            host: normalizedHost,
            method: request.method,
            path: request.path,
            headers: request.headers,
            bodyExcerpt: request.bodyExcerpt
        )
        var firstAllow: EgressRule?
        for rule in rules where rule.matches(request: normalizedRequest) {
            if rule.decision == .deny {
                return EgressEvaluation(decision: .deny, ruleId: rule.id)
            }
            if firstAllow == nil {
                firstAllow = rule
            }
        }
        if let allow = firstAllow {
            return EgressEvaluation(decision: .allow, ruleId: allow.id)
        }
        return .defaultDeny
    }
}
