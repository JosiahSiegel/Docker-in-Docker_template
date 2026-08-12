#!/bin/bash
# DevContainer On-Create Script
# Runs once during prebuild (or first create if no prebuild).
# Heavy one-time setup that doesn't depend on source code changes.

set -euo pipefail

echo "Setting up development environment..."

# ============================================
# SSH / GIT CREDENTIALS
# ============================================
echo "Setting up git credentials..."
if [ "${CODESPACES:-}" = "true" ]; then
    echo "Running in Codespaces - git credentials managed by GitHub"
elif [ -d "$HOME/.ssh" ] && ls "$HOME/.ssh/id_*" 1>/dev/null 2>&1; then
    echo "SSH keys found"
else
    echo "No SSH keys found - use 'gh auth login' or SSH agent forwarding"
fi

# ============================================
# CLAUDE CODE SETTINGS CHECK
# ============================================
echo "Checking Claude Code configuration..."
mkdir -p "$HOME/.claude"
if [ "${CODESPACES:-}" = "true" ]; then
    echo "Codespaces: Run 'claude' to authenticate via browser"
    echo "  Or set ANTHROPIC_API_KEY in Codespaces secrets for API key auth"
elif [ -f "$HOME/.claude/.credentials.json" ]; then
    echo "Claude Code credentials found"
else
    echo "Run 'claude' to authenticate via browser"
fi

# ============================================
# GIT CONFIGURATION
# ============================================
echo "Configuring Git..."
git config --global core.autocrlf input
git config --global core.eol lf
git config --global init.defaultBranch main
git config --global pull.rebase false
git config --global safe.directory /workspace

# ============================================
# NODE.JS — ensure v22+ (required by OpenChamber)
# ============================================
echo "Ensuring Node.js 22+..."
export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
if ! command -v nvm >/dev/null 2>&1; then
    curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash
fi
# Always (re)source — non-interactive shells don't load ~/.bashrc where nvm
# normally gets sourced, so nvm won't be a function even after install above.
# shellcheck disable=SC1091
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
nvm install 22
nvm alias default 22
echo "Node.js $(node -v) active"

echo "On-create setup complete."
