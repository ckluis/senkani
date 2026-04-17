# Schneier re-audit — 2026-04-16

Adversarial second-opinion review of the security surfaces shipped in
commits `1e972ed` (v0.2.0 P0/P1) and `ca04e13` (Wave 3). Read-only
pass; any finding rated P1+ is fixed in the same commit as this doc.

## Scope
- `senkani_web` SSRF guard (WebFetchTool.swift)
- InjectionGuard default-on + homoglyph normalize
- Migration runner + kill-switch (MigrationRunner.swift)
- Socket-auth handshake (SocketAuthToken.swift, SocketServer.swift,
  HookRelay.swift)
- SecretDetector short-circuit

## Findings

### F1 — P1: Socket handshake pre-read has no timeout — DoS vector

**Evidence:** `Sources/MCP/SocketServer.swift:280-305`
`validateHandshakeIfRequired(fd:)` calls `Darwin.read(fd, ...)`
unconditionally. Unix-domain sockets in blocking mode (the default
for accepted sockets here) make this read wait indefinitely until
data arrives or the client closes the socket.

**Attack:** a same-UID malicious process opens connections to
`~/.senkani/mcp.sock` without sending bytes. Each accepted connection
spawns a task (`handleConnection`) that calls this validator, blocks
forever on `read()`. The listener's `activeTasks` array fills up to
`maxConnections = 20` (`SocketServer.swift:274`), after which
legitimate clients get `Connection limit reached`. Complete denial of
service on the MCP socket; equivalent on hook.sock / pane.sock.

**The original P2-12 plan called this out explicitly:**
> "Add a 5s read timeout on handshake so malformed clients don't hang
> the listener slot."

I did not ship it in `ca04e13`. This re-audit closes that gap.

**Fix (this commit):** extract `SocketAuthToken.readAndValidate(fd:expectedToken:timeoutMs:)`
that uses `poll(2)` with a 5 s timeout before each `read()`. Wire
into the three accept paths. Tests use `socketpair(2)` to exercise
the timeout path without spinning up a live listener.

**Regression coverage:** 4 new tests in `SocketAuthTests.swift`:
- times out on silent client
- accepts good frame
- rejects wrong token
- times out on partial frame (length prefix sent, payload withheld)

---

### F2 — P2: WebKit subresource SSRF gap (CLOSED)

**Original evidence:** `NavigationHandler.webView(_:decidePolicyFor navigationAction:)`
fires for main-frame navigations and redirects only. WebKit issues
subresource requests (img, script, link, xhr, fetch, etc.) without
consulting the navigation delegate. A malicious public page that
embeds `<img src="http://169.254.169.254/latest/meta-data/">` could
reach the cloud metadata endpoint from inside the user's machine
during `senkani_web` rendering.

**Fix shipped:** `Sources/MCP/Tools/WebContentBlocklist.swift` —
compiles a `WKContentRuleList` at engine warmup with block rules for
RFC 1918 (10/8, 172.16/12, 192.168/16), link-local (169.254/16),
CGNAT (100.64/10), IPv6 ULA (fc/fd), IPv6 link-local (fe80), IPv6
multicast (ff), and IPv4-mapped IPv6 equivalents of all the above.
Attached to `WKWebViewConfiguration.userContentController` BEFORE
WKWebView init (WebKit's configuration is copy-at-init — post-init
attachment has no effect, so ordering matters). Bypass via
`SENKANI_WEB_ALLOW_PRIVATE=on`, mirroring the main-frame guard.

**WebKit surprise caught by the integration test:** URL-filter regex
is a restricted subset — `|` disjunction is NOT supported ("Error
while parsing … Disjunctions are not supported yet."). Every
alternation split into its own rule (20 total). The integration test
`rulesCompileUnderWebKit` asserts the JSON compiles against real
WebKit, so a future pattern with unsupported syntax is caught at
test time, not at production warmup.

**Coverage:**
- 16 mirror-regex tests via `NSRegularExpression` (every blocked
  range + public neighbors + loopback + public IPv4-mapped).
- 1 integration test — real WebKit compilation.

**Known residual gap:** DNS-at-subresource. Pattern-based filter
can't see the resolved IP. A hostile HTML page with `<img src="http://dns-rebind.evil/">`
that resolves to `10.0.0.1` at request time still reaches the private
IP. Same structural limitation as any hostname-blocklist. Could be
closed by running WebKit inside a proxy or `WKURLSchemeHandler`, but
the latter doesn't apply to http/https and the former is a new
process model. Accept the gap; document in the security defaults.

---

### F3 — P2: InjectionGuard keyword list is English-only

**Evidence:** `Sources/Core/InjectionGuard.swift:70-76` —
`keywords = ["ignore previous", ..., "system:"]`. All English.

**Gap:** multilingual prompt-injection payloads bypass. Concrete
examples:
- Spanish: `"ignora todas las instrucciones anteriores"`
- French: `"ignorez toutes les instructions précédentes"`
- Chinese/Japanese/Korean character-script attacks

Practical risk in the current dev workflow is low (most inputs are
English). Upgrade when expanding the user base.

**Fix plan:** add a minimal multilingual keyword set (top 10
languages). Tested by unit cases.

---

### F4 — P2: InjectionGuard homoglyph map only covers Cyrillic

**Evidence:** `Sources/Core/InjectionGuard.swift:89-102` — 14 pairs
all Cyrillic → Latin.

**Gap:** Greek (α/a, ο/o), Fullwidth Latin (ａｂｃ), Mathematical
Alphanumeric Symbols (𝗂𝗀𝗇𝗈𝗋𝖾) all render visually identical to
Latin but are not mapped.

**Fix plan:** extend the map. Consider Unicode NFKC normalization as
a partial pre-step for compatibility-equivalent forms.

---

### F5 — P2: SecretDetector patterns miss common token families

**Evidence:** `Sources/Core/SecretDetector.swift:8-14` — covers
ANTHROPIC, OPENAI, AWS_SECRET_ACCESS_KEY, AWS_ACCESS_KEY_ID,
GITHUB_TOKEN, GENERIC_API_KEY, BEARER_TOKEN.

**Gap:** Slack webhooks (`xoxb-`, `xoxp-`), Google Cloud (`ya29.`),
Stripe live keys (`sk_live_`), npm (`npm_`), HuggingFace (`hf_`).

**Fix plan:** add the above patterns. Trivial — same shape as
existing entries.

---

### F6 — P3: chmod timing in `SocketAuthToken.generate`

**Evidence:** `Sources/Core/SocketAuthToken.swift:71-72` —
`data.write(.atomic)` then `chmod(target, 0o600)`. `.atomic` writes
to a temp file, renames over target. Between rename and chmod the
file at `target` exists with default umask permissions (typically
0644 or 0664).

**Severity:** same-UID local race only. Window is microseconds. The
same-UID threat model already assumes the attacker can read the
file anyway (they just have to wait for chmod).

**Fix plan:** use POSIX `open(target, O_CREAT|O_WRONLY|O_TRUNC, 0o600)`
+ `write()` + `close()` so mode is explicit at creation. Defense in
depth only. Low priority.

---

### F7 — P3: HookRelay duplicates token-load logic

**Evidence:** `Sources/HookRelay/HookRelay.swift:19-50` — inline
`loadAuthToken` and `sendHandshake`. Intentional (zero-dep contract
per Lesson #12), but creates divergence risk if `SocketAuthToken.load`
changes.

**Fix plan:** add a cross-reference comment in both files pointing at
each other so the next editor notices. Keep the duplication until
the zero-dep constraint loosens.

---

## What I looked at and did NOT find

- **Migration lockfile / flock path traversal:** path is constructed
  from `dbPath` which originates in hard-coded Application Support
  lookup, not user input. No traversal vector.
- **inet_pton leading-zero parsing:** macOS `inet_pton(AF_INET)` is
  strict per POSIX — rejects leading zeros. `"010.0.0.1"` returns 0
  from `inet_pton` and the code falls through to
  `hostResolvesToPrivate` which uses getaddrinfo. Getaddrinfo's
  interpretation of `"010.0.0.1"` is platform-dependent but in all
  cases the resolved sockaddr is what the private-range check sees.
  No bypass.
- **Constant-time token compare:** `SocketAuthToken.constantTimeEquals`
  XOR-accumulates over equal-length byte arrays. Correct.
- **JSON escape in Logger:** escapes `\ " \n \r \t`. Tests
  round-trip through JSONSerialization. No injection gap.
- **Retention prune queries:** parameterized via sqlite3_bind_double,
  not string-concat.
- **recordCommand transaction:** BEGIN IMMEDIATE + COMMIT with
  ROLLBACK on failure. Crash-consistent.

---

## Summary

| # | ID | Severity | Status | Closed in |
|---|----|----------|--------|-----------|
| F1 | Handshake read no timeout | **P1** | ✅ fixed | `dde98f9` |
| F2 | WebKit subresource SSRF | P2 | ✅ fixed (F2 round) | WKContentRuleList |
| F3 | English-only injection keywords | P2 | ✅ fixed (multilingual round) | ES/FR/DE/PT/IT added |
| F4 | Cyrillic-only homoglyph map | P2 | ✅ fixed (multilingual round) | NFKC + Greek |
| F5 | Missing secret patterns | P2 | ✅ fixed (multilingual round) | Slack/GCP/Stripe/npm/HF/sk-proj |
| F6 | chmod timing window | P3 | ✅ fixed (debt-closure round) | atomic open+fchmod+rename |
| F7 | HookRelay duplicate logic | P3 | ✅ fixed (debt-closure round) | cross-ref comment |

All findings from the re-audit are now closed.

### F6/F7 closure notes

- **F6:** prior `Data.write(.atomic)` + `chmod(path, 0o600)` sequence had a
  microsecond-wide window where the renamed file carried umask-default perms
  (typically 0644) before the chmod landed. Replaced with atomic write:
  `open(temp, O_CREAT|O_WRONLY|O_TRUNC, 0o600)` + `fchmod(fd, 0o600)` (to
  bypass umask narrowing) + `write` + `close` + `rename(temp, target)`. The
  final path never exists with permissions wider than 0o600.
- **F7:** `HookRelay.swift:loadAuthToken` already cites the zero-dep contract
  and duplication. Added the reverse pointer in `SocketAuthToken.load` docs
  so future editors see the mirror from either side.

### F3 / F4 / F5 closure notes

- **F3:** 5 multilingual `instruction override` patterns (ES, FR, DE,
  PT, IT) with noun-phrase-anchored Phase-1 keywords. FP-guarded by
  tests against benign Spanish/French/Italian tech prose.
- **F4:** NFKC pre-step folds Fullwidth Latin, Mathematical Alphanumeric
  Symbols, ligatures, and other compatibility variants back to basic
  Latin. Explicit Greek→Latin entries added to `homoglyphMap` (α, ε, ο,
  ρ, χ, ι, κ, ν, μ, τ) since Greek is a different script, not NFKC-
  equivalent to Latin. ASCII fast-path skips NFKC on pure-ASCII input.
- **F5:** 6 new patterns — `OPENAI_PROJECT_KEY` (which the generic
  OPENAI pattern missed because `-` breaks its character class),
  Slack (`xoxb`/`xoxp`/etc.), GCP OAuth (`ya29.`), Stripe
  (`sk_live_` / `sk_test_`), npm (`npm_`), HuggingFace (`hf_`).

### Side win: Phase-1 keyword check now 2× faster

Replacing the N-keyword substring-contains loop with a single compiled
regex alternation dropped the 1 MB benign-normalize path from 338 ms
(pre-F3) to **161 ms** (post-F3/F4/F5) — faster than the pre-expansion
baseline despite covering 23 keywords vs. 13.
