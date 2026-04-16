#!/bin/bash
# S11 — secret-redaction fixture. Fake credentials, not real.
set -e

mkdir -p /tmp/senkani-soak
cat > /tmp/senkani-soak/secret.env <<'EOF'
# Fake credentials for soak testing — NOT real.
ANTHROPIC_API_KEY=sk-ant-soaktest-00000000000000000000
OPENAI_API_KEY=sk-soak0000000000000000000000
AWS_ACCESS_KEY_ID=AKIASOAKSOAKSOAK1234
GITHUB_TOKEN=ghp_SoakSoakSoakSoakSoakSoakSoakSoakSoakSo
EOF
chmod 600 /tmp/senkani-soak/secret.env
echo "Fixture written: /tmp/senkani-soak/secret.env"
echo ""
echo "Now call from Claude Code:"
echo '  senkani_read path:"/tmp/senkani-soak/secret.env"  full:true'
echo ""
echo "Expected: every fake value replaced with [REDACTED:*] markers."
