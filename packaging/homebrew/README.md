# Homebrew tap packaging (DRAFT — operator-gated)

Prepared by the 2026-06-08 luminary groom (decision **D9**, panel
Jansen/Swyx/Dunford/Meeker; Jobs dissent recorded). Channel decision:
**Homebrew tap for the CLI/MCP** for v0.2.0 (no Apple Developer cert required);
a **signed/notarized DMG** of the `SenkaniApp` GUI is a fast-follow once a cert
exists.

`senkani.rb` here is a **draft formula**. The autonomous loop produced it +
`THIRD-PARTY-NOTICES.md` (Meeker: ship the notices before publishing). The
remaining steps are operator-only (shared-system publishing, outside the
autonomous envelope) — and per the operator's standing preference, run them
**one at a time**:

1. `gh repo create ckluis/homebrew-tap --public` — confirmed non-existent today.
2. Build the v0.2.0 release tarball: the four CLI binaries
   (`senkani`, `senkani-mcp`, `senkani-hook`, `senkani-mig-helper`), stripped,
   arm64; publish as a GitHub release asset.
3. `shasum -a 256 <tarball>` → paste into `senkani.rb` `sha256`; set `version`
   and `url`.
4. Copy `senkani.rb` → `Formula/senkani.rb` in the tap repo; commit + push.
5. Verify: `brew install ckluis/tap/senkani && senkani --version`.
6. Ship `THIRD-PARTY-NOTICES.md` alongside the release (license attribution).

Regenerate the notices after any dependency change: `tools/generate-notices.sh`.
