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

### F2 — P2: WebKit subresource SSRF gap

**Evidence:** `NavigationHandler.webView(_:decidePolicyFor navigationAction:)`
fires for main-frame navigations and redirects only. WebKit issues
subresource requests (img, script, link, xhr, fetch, etc.) without
consulting the navigation delegate. A malicious public page that
embeds `<img src="http://169.254.169.254/latest/meta-data/">` can
reach the cloud metadata endpoint from inside the user's machine
during `senkani_web` rendering.

**Exploitability today:** attacker must return HTML via a public URL
that the user (or prompt-injected LLM) passes to `senkani_web`. Loose
but not unreasonable — this tool is explicitly designed to accept
LLM-chosen URLs, so the LLM *is* the attacker in a prompt-injection
scenario.

**Data exfil vector:** subresource request LINE (URL + headers)
reaches the attacker if they control the target domain. Subresource
BODY is not parsed into AXTree output, so the LLM doesn't see it —
but an attacker who can observe the request (e.g., AWS metadata
endpoint response logging) may still leak.

**Fix plan (not this commit):** install a `WKContentRuleList` with
block rules for RFC 1918 / link-local / CGNAT / IPv4-mapped IPv6
literal patterns at the URL-filter level. Does not catch DNS →
private resolutions at subresource time (WebKit doesn't expose that
hook), but blocks the literal-IP cases which cover the vast majority
of known SSRF probes.

**Defer rationale:** WKContentRuleList surgery is a separate focused
patch; F1 is the more urgent kill. Captured as follow-up.

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

| # | ID | Severity | Fixed in this commit | Follow-up |
|---|----|----------|----------------------|-----------|
| F1 | Handshake read no timeout | **P1** | ✅ | — |
| F2 | WebKit subresource SSRF | P2 | — | Plan: WKContentRuleList |
| F3 | English-only injection keywords | P2 | — | Plan: multilingual |
| F4 | Cyrillic-only homoglyph map | P2 | — | Plan: Greek + Fullwidth + MAS |
| F5 | Missing secret patterns | P2 | — | Plan: add xoxb/ya29/sk_live_/npm_/hf_ |
| F6 | chmod timing window | P3 | — | open(2) with mode |
| F7 | HookRelay duplicate logic | P3 | — | cross-ref comments |

Exit: **F1 fixed this round**; F2–F7 converted to tracked
follow-ups. Soak can now measure the fixed state on the socket-auth
path.
