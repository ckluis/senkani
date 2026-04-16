# S1 — SSRF probes (Schneier)

Run each of these from a Senkani-spawned Claude Code pane. Record
outcome in the journal.

## Must be blocked

```
senkani_web url:"file:///etc/passwd"
```
Expected: `invalidURL` error — file:// not accepted.

```
senkani_web url:"http://169.254.169.254/latest/meta-data/"
```
Expected: `privateAddressBlocked` — cloud metadata service.

```
senkani_web url:"http://10.0.0.1/"
```
Expected: `privateAddressBlocked` — RFC1918 /8.

```
senkani_web url:"http://[::ffff:10.0.0.1]/"
```
Expected: `privateAddressBlocked` — IPv4-mapped IPv6.

```
senkani_web url:"http://0x7f.0.0.1/"
```
Expected: depends on host OS resolver. If the host is parsed as
127.x it should be allowed (loopback); if parsed as public it
should succeed. The unit-test suite covers `0x7f000001` as a loopback
via `inet_pton`; the wider soak verifies the behavior in the wild.

## Must be allowed

```
senkani_web url:"https://example.com/"
```
Expected: AXTree markdown returned.

```
senkani_web url:"http://127.0.0.1:<port>/"
```
Expected: allowed (loopback developer use case).

## Adversarial — redirect chain

If you have an HTTP server you control: redirect a public URL to
`http://10.0.0.1/`. Call `senkani_web` on the public URL. The
`decidePolicyFor` check should cancel the redirect with
`privateAddressBlocked`.
