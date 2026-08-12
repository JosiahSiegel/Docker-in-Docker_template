#!/usr/bin/env bash
# DevContainer Post-Create Script
#
# Runs after every create (including from prebuild).
# User-specific setup that should re-run on each fresh container.
#
# This script is environment-only. It MUST NOT touch files in /workspace —
# the work repo bind-mounted there is not ours to modify.

set -euo pipefail

echo "==> post-create: bootstrapping agent tooling"

# ============================================
# NVM — ensure nvm-managed Node is on PATH
# ============================================
# DevContainer lifecycle hooks run as non-interactive bash, so ~/.bashrc
# (which sources nvm.sh) is never loaded. Without this, the system Node (v20)
# from the base image shadows the v22 installed by on-create.sh via nvm.
export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
# shellcheck disable=SC1091
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
nvm use --silent default 2>/dev/null || true
echo "  Node.js active: $(node -v 2>/dev/null || echo 'not found')"

# Install oh-my-opencode into the container's $HOME.
# This is idempotent and required for the agent runtime to work.
if command -v bunx >/dev/null 2>&1; then
    bunx oh-my-opencode install \
        --no-tui \
        --platform=opencode \
        --claude=no \
        --openai=no \
        --gemini=no \
        --copilot=no
else
    echo "WARN: bunx not on PATH; skipping oh-my-opencode install" >&2
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bash "${SCRIPT_DIR}/omo-installer.sh" \
    || echo "WARN: omo-installer.sh failed (continuing)" >&2

bash "${SCRIPT_DIR}/git-config-from-env.sh" \
    || echo "WARN: git-config-from-env.sh failed (continuing)" >&2

# Bootstrap OpenChamber into the container's $HOME.
curl -fsSL https://raw.githubusercontent.com/openchamber/openchamber/main/scripts/install.sh | bash

echo "==> post-create: done"
