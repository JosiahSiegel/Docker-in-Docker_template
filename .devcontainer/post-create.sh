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
