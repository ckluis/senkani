# Security policy

## Reporting a vulnerability

**Please do not open a public GitHub issue for security reports.**

Email **ckluis@gmail.com** with:

- A description of the issue
- Steps to reproduce
- The version you tested against (`senkani_version` tool output, or
  the commit SHA)
- Any relevant logs (with secrets redacted)

You can expect an acknowledgement within **7 days**. This is a
solo-maintained project, so please be patient — but the inbox is
watched.

If you'd prefer GitHub's private channel, you can also use
[Private vulnerability reporting](https://github.com/ckluis/senkani/security/advisories/new).

## Scope

Senkani sits between Claude Code and the local filesystem, so the
following surfaces are in scope for security reports:

- **Prompt injection** — `InjectionGuard` on MCP tool responses
- **SSRF** — `senkani_web` host validation + redirect re-validation
- **Secret redaction** — `SecretDetector` (logs, KB, MCP responses)
- **Schema migrations** — DB migration safety + kill-switch
- **Socket auth** — `SENKANI_SOCKET_AUTH` handshake on `mcp.sock` /
  `hook.sock` / `pane.sock`
- **Sandbox** — any path that lets a tool escape its declared scope

See [spec/architecture.md](spec/architecture.md) for the full trust
boundary description.

## Out of scope

- Issues that require an attacker who already has local code
  execution as your user
- Vulnerabilities in upstream Swift packages (please report those
  to the upstream project; we'll pick up the fix on the next bump)
- Theoretical issues without a concrete reproduction

## Disclosure

We aim to fix confirmed vulnerabilities within 30 days and credit
the reporter in the CHANGELOG, unless you'd prefer to remain
anonymous.
