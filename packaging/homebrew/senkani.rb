# DRAFT Homebrew formula for the `ckluis/homebrew-tap` tap.
#
# Operator decision 2026-06-08 (luminary groom D9 — Jansen/Swyx/Dunford/Meeker):
# ship senkani's CLI/MCP via a Homebrew tap for v0.2.0; the signed/notarized
# DMG of the GUI app is a fast-follow once an Apple Developer ID cert exists.
#
# This is a DRAFT prepared autonomously. Shipping it is OPERATOR-GATED:
#   1. Create the public repo  github.com/ckluis/homebrew-tap  (gh repo create).
#   2. Build the release tarball (the 4 CLI binaries below, arm64) and publish
#      it as a GitHub release asset; capture its sha256.
#   3. Fill `version`, `url`, and `sha256` below, drop this file at
#      Formula/senkani.rb in the tap repo, and push.
#   4. Verify:  brew install ckluis/tap/senkani  &&  senkani --version
# See packaging/homebrew/README.md and THIRD-PARTY-NOTICES.md (Meeker: ship the
# notices before publishing).
class Senkani < Formula
  desc "Token-compression + autonomous-development layer (CLI + MCP server)"
  homepage "https://github.com/ckluis/senkani"
  license "MIT"

  # OPERATOR: set at release time.
  version "0.0.0-DRAFT"
  url "https://github.com/ckluis/senkani/releases/download/vX.Y.Z/senkani-vX.Y.Z-macos-arm64.tar.gz"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"

  # macOS-14 (Sonoma) floor, matching the project's @available baseline.
  depends_on macos: :sonoma
  depends_on arch: :arm64

  def install
    # CLI/MCP binaries only — the SenkaniApp GUI ships via the notarized DMG.
    bin.install "senkani"
    bin.install "senkani-mcp"
    bin.install "senkani-hook"
    bin.install "senkani-mig-helper"
  end

  test do
    assert_match "senkani", shell_output("#{bin}/senkani --version")
  end
end
