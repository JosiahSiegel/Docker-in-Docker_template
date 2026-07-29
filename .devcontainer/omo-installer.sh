#!/usr/bin/env bash
# install-gist-files.sh
#
# Download every file in a GitHub Gist and install each one at
#   $HOME/<filename>
# where the filename's backslashes are treated as directory separators
# (so ".config\opencode\opencode.json" becomes "$HOME/.config/opencode/opencode.json").
#
# Works on Linux and on Windows under Git Bash / WSL.
#
# Strategy:
#   1. `git clone` the gist (preferred). Public gists clone over HTTPS
#      without auth and are NOT subject to the API's 60-req/hour per-IP
#      limit that 403s shared cloud/devcontainer IPs.
#   2. If git is unavailable or the clone fails, fall back to the GitHub
#      REST API. Auth priority: `gh` CLI -> $GITHUB_TOKEN / $GH_TOKEN -> anon.
#
# Requires: git (preferred) OR {curl/wget, jq/python3} (fallback).
# Plus: jq for the env-driven JSON substitutions (baseURL / api key).
#
# Env-driven substitutions (read from .env, see load_env() below):
#   $OPENCODE_BASE_URL   -> .config/opencode/opencode.json  ->  .provider.selfHosted.options.baseURL
#   $OPENCODE_API_KEY    -> .local/share/opencode/auth.json  ->  .selfHosted.key
# The OPENCODE_* namespace is intentionally NOT tied to any specific LLM
# provider -- you can point baseURL/key at OpenAI, Anthropic, a local Ollama,
# a private gateway, or anything else. The JSON's "provider" name (here
# "selfHosted") is just the alias the opencode tool uses internally.
# If a variable is unset or empty, the existing placeholder in the gist
# (e.g. "https://xxx/v1" and "xxx") is left in place.

set -euo pipefail

GIST_ID="${GIST_ID:-6b5162555ef12c6289450683f04c113a}"
UA="gist-installer/1.0"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

# --- helpers ----------------------------------------------------------------
gh_token() {                             # echo the best available token (may be empty)
  if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
    gh auth token 2>/dev/null && return 0
  fi
  printf '%s' "${GITHUB_TOKEN:-${GH_TOKEN:-}}"
}

# Load a .env file (sourcing it). First hit wins. Looks in:
#   1. $HOME/.env
#   2. <script dir>/.env           (e.g. .devcontainer/.env)
#   3. <script dir>/../.env        (e.g. workspace root .env)
#   4. ./.env                      (current working dir)
load_env() {
  local src="${BASH_SOURCE[0]:-$0}"
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
  echo "no .env found; placeholders will be kept in installed files"
  return 1
}

# Substitute a JSON value from an env var if it's set and non-empty.
#   $1 target file path
#   $2 jq filter that assigns from $v
#   $3 env var name (read indirectly)
#   $4 human-readable label
#   $5 if "secret", the value is NOT echoed in the log line
# Always returns 0 -- the function is best-effort, the loop must keep going.
# (Returning 1 here would abort the install loop under `set -e`, even though
# the call is "in a while body". The bash docs say it should be exempt; the
# observed behavior is that it isn't, when the while is on the right side of
# a pipeline. So: never return non-zero from this function.)
substitute_if_set() {
  local target="$1" filter="$2" env_var="$3" label="$4" redact="${5:-}"
  local val="${!env_var:-}"
  if [ -z "$val" ]; then
    printf '  -> %s kept as placeholder ($%s not in .env)\n' "$label" "$env_var"
    return 0
  fi
  if ! command -v jq >/dev/null 2>&1; then
    printf '  !! %s not substituted: jq not installed\n' "$label" >&2
    return 0
  fi
  local tmp; tmp="$(mktemp)"
  if jq --arg v "$val" "$filter" "$target" > "$tmp"; then
    mv -- "$tmp" "$target"
    if [ "$redact" = "secret" ]; then
      printf '  -> %s set from $%s (value redacted)\n' "$label" "$env_var"
    else
      printf '  -> %s set to %s (from $%s)\n' "$label" "$val" "$env_var"
    fi
    return 0
  fi
  rm -f -- "$tmp"
  printf '  !! %s substitution failed; left untouched\n' "$label" >&2
  return 0
}

# Enumerate the gist as "filename<TAB>source-path" lines on stdout.
# `source-path` is either a local file inside the cloned repo, or a
# https:// raw URL (in the API fallback).
enumerate() {
  local repo="$tmp_dir/gist"

  # Preferred: git clone. Even on a totally fresh devcontainer this should
  # work for a public gist without any credentials.
  if command -v git >/dev/null 2>&1; then
    if git clone --depth 1 --quiet "https://gist.github.com/$GIST_ID.git" "$repo" 2>/dev/null; then
      # -c core.quotePath=false  -> emit raw paths, no double-quote wrapping
      #                            (the default wraps paths with backslashes
      #                            or non-ASCII bytes in "..." with \\ etc.)
      # -z                       -> NUL-terminated, so paths with newlines
      #                            (rare but possible) still parse cleanly.
      git -C "$repo" -c core.quotePath=false ls-files -z | \
        while IFS= read -r -d '' filename; do
          [ -z "$filename" ] && continue
          printf '%s\t%s\n' "$filename" "$repo/$filename"
        done
      return 0
    fi
    echo "git clone failed; trying GitHub API fallback..." >&2
  fi

  # Fallback: REST API. Subject to 60/h anonymous rate limit per IP.
  if ! command -v curl >/dev/null 2>&1; then
    echo "Error: need git or curl installed." >&2
    return 1
  fi

  local token
  token="$(gh_token)"
  local auth=()
  [ -n "$token" ] && auth=(-H "Authorization: Bearer $token")

  local body
  if ! body="$(curl -fsSL -A "$UA" -H "Accept: application/vnd.github+json" \
                  "${auth[@]}" "https://api.github.com/gists/$GIST_ID")"; then
    local rc=$?
    if [ "$rc" -eq 22 ]; then
      echo "" >&2
      echo "GitHub API returned 403. Public gists still need auth above" >&2
      echo "60 req/h per IP, which a shared devcontainer hits fast." >&2
      echo "Fixes (pick one):" >&2
      echo "  - run:  gh auth login" >&2
      echo "  - or:   export GITHUB_TOKEN=<a fine-grained PAT>" >&2
    fi
    return "$rc"
  fi

  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$body" | jq -r '.files | to_entries[] | "\(.value.filename)\t\(.value.raw_url)"'
  elif command -v python3 >/dev/null 2>&1; then
    printf '%s' "$body" | python3 -c "
import json, sys
for f in json.load(sys.stdin)['files'].values():
    print(f['filename'] + '\t' + f['raw_url'])
"
  else
    echo "Error: need jq or python3 to parse the API response." >&2
    return 1
  fi
}

# --- main -------------------------------------------------------------------

# 0. Load .env (if present) so we can substitute placeholders below.
#    $OPENCODE_BASE_URL  -> baseURL in opencode.json
#    $OPENCODE_API_KEY   -> key in auth.json
load_env || true

# 1. Purge old config variants. These are alternate filenames from earlier
#    versions of the same tool that the canonical gist files replace.
#    Edit this list to add/remove cleanup targets as the tool evolves.
printf 'purging old variants (if present):\n'
for path in \
    "$HOME/.omo/omo.jsonc" \
    "$HOME/.config/opencode/oh-my-openagent.json"
do
  if [ -e "$path" ] || [ -L "$path" ]; then
    printf '  removing %s\n' "$path"
    rm -f -- "$path"
  fi
done

# 2. Install the canonical files from the gist, then substitute env values
#    into the files that have placeholders.
enumerate | while IFS=$'\t' read -r filename source; do
  [ -z "$filename" ] && continue
  # Treat backslashes in the filename as directory separators so the
  # same script produces correct paths on both Linux and Windows.
  #   .config\opencode\opencode.json  ->  .config/opencode/opencode.json
  rel="${filename//\\//}"
  target="$HOME/$rel"
  mkdir -p -- "$(dirname -- "$target")"
  printf 'installing %s\n' "$target"
  cp -- "$source" "$target"

  # Env-driven substitutions (per file). Each call is a no-op if the
  # corresponding env var is unset/empty -- the placeholder is kept.
  case "$rel" in
    .config/opencode/opencode.json)
      substitute_if_set "$target" \
        '.provider.selfHosted.options.baseURL = $v' \
        OPENCODE_BASE_URL "baseURL" ""
      ;;
    .local/share/opencode/auth.json)
      substitute_if_set "$target" \
        '.selfHosted.key = $v' \
        OPENCODE_API_KEY "api key" "secret"
      ;;
    .omo/omo.json)
      printf '  -> no env-driven substitution for this file\n'
      ;;
  esac
done
