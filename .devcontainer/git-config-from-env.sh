#!/usr/bin/env bash
# git-config-from-env.sh
#
# Read GITHUB_NAME and GITHUB_EMAIL from .env (if present) and set them
# as global git defaults via `git config --global`. If a variable is
# unset/empty in .env, the existing global git config is LEFT AS IS.
#
# .env lookup order (kept identical to omo-installer.sh's load_env()):
#   1. $HOME/.env
#   2. <repo>/.devcontainer/.env
#   3. <repo>/.env
#   4. ./.env

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- load .env (mirrors omo-installer.sh's load_env) -----------------------
# We do NOT source omo-installer.sh -- it executes its install main-block
# on source, which would double-install the gist. Keep this helper in sync
# with omo-installer.sh if the lookup order ever changes.
load_env() {
  local src="${BASH_SOURCE[1]:-$0}"
  local script_dir=""
  [ -n "$src" ] && script_dir="$(cd "$(dirname "$src")" 2>/dev/null && pwd || true)"

  local candidate
  for candidate in \
      "$HOME/.env" \
      "${script_dir:+$script_dir/.env}" \
      "${script_dir:+$script_dir/../.env}" \
      "./.env"
  do
    [ -z "$candidate" ] && continue
    if [ -f "$candidate" ]; then
      printf 'loading env from %s\n' "$candidate"
      set -a
      # shellcheck disable=SC1090
      . "$candidate"
      set +a
      return 0
    fi
  done
  return 1
}
# Look alongside this script first (SCRIPT_DIR == its own dir for our caller),
# then fall through to the standard chain.
load_env_for_self() {
  if [ -f "${SCRIPT_DIR}/.env" ]; then
    printf 'loading env from %s\n' "${SCRIPT_DIR}/.env"
    set -a
    # shellcheck disable=SC1090
    . "${SCRIPT_DIR}/.env"
    set +a
    return 0
  fi
  load_env || true
}
load_env_for_self

# --- apply git config ------------------------------------------------------
# Per variable: if .env provided a non-empty value, set it (overwriting the
# existing global config). Otherwise report and leave the current value.
# Each variable is independent -- one being set must not block the other.
apply() {
  local var_name="$1" git_key="$2"
  local val="${!var_name:-}"
  if [ -z "$val" ]; then
    local current
    current="$(git config --global --get "$git_key" 2>/dev/null || true)"
    if [ -n "$current" ]; then
      printf '  -> git %s left as-is: %s (no $%s in .env)\n' \
        "$git_key" "$current" "$var_name"
    else
      printf '  -> git %s left unset (no $%s in .env)\n' "$git_key" "$var_name"
    fi
    return 0
  fi
  if git config --global "$git_key" "$val"; then
    printf '  -> git %s set to %s (from $%s)\n' "$git_key" "$val" "$var_name"
  else
    printf '  !! git %s could not be set (from $%s)\n' "$git_key" "$var_name" >&2
  fi
  return 0
}

if ! command -v git >/dev/null 2>&1; then
  echo "WARN: git not installed; skipping git config from .env" >&2
  exit 0
fi

printf 'applying git config from .env:\n'
apply GITHUB_NAME  "user.name"
apply GITHUB_EMAIL "user.email"