#!/usr/bin/env pwsh
# omo-installer-win-host.ps1
#
# Windows-native equivalent of .devcontainer/omo-installer.sh.
# Run this on a Windows host (PowerShell 7+) to install the same opencode
# + omo configuration that the devcontainer installs, against the same
# GitHub Gist.
#
# Downloads every file in a GitHub Gist and installs each one at
#   $HOME\<filename>
# (PowerShell on Windows treats backslashes as directory separators, so the
# gist filename ".config\opencode\opencode.json" becomes the real Windows
# path "%USERPROFILE%\.config\opencode\opencode.json".)
#
# Strategy mirrors the bash version:
#   1. `git clone` the gist (preferred).
#   2. If git is unavailable or the clone fails, fall back to the GitHub
#      REST API. Auth priority: `gh` CLI -> $env:GITHUB_TOKEN / $env:GH_TOKEN -> anon.
#
# Requires: PowerShell 7+, AND
#   git (preferred) OR {curl.exe OR PowerShell's Invoke-WebRequest}.
#   The script uses PowerShell's built-in ConvertFrom-Json / Set-Content
#   for JSON substitution -- no jq required. (Earlier versions tried jq
#   on Windows; it was removed because ProcessStartInfo.Arguments splits
#   on spaces and silently truncates filters for values containing URL
#   punctuation.)
#
# Env-driven substitutions (read from .env, see Load-Env):
#   $env:OPENCODE_BASE_URL  -> .config\opencode\opencode.json  ->  .provider.selfHosted.options.baseURL
#   $env:OPENCODE_API_KEY   -> .local\share\opencode\auth.json  ->  .selfHosted.key
# If a variable is unset or empty, the existing placeholder in the gist
# is left in place.
#
# Usage:
#   pwsh -ExecutionPolicy Bypass -File .\omo-installer-win-host.ps1
#   # or, after Set-ExecutionPolicy:
#   .\omo-installer-win-host.ps1
#
# Optional env vars:
#   $env:GIST_ID          override the target gist (default: 6b5162555ef12c6289450683f04c113a)
#   $env:OPENCODE_BASE_URL    LLM endpoint, e.g. https://api.openai.com/v1
#   $env:OPENCODE_API_KEY     LLM API key
#
# Optional flags:
#   -ShowDetails       show the actual jq filter + stderr on substitution failure
#                      (useful for diagnosing "substitution failed" on machines
#                      where the silent PS-native path or a locked file is the cause)

[CmdletBinding()]
param(
    [string]$GistId = $env:GIST_ID,
    [switch]$ShowDetails
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'  # speed up Invoke-WebRequest / Invoke-RestMethod

# --- defaults & globals ----------------------------------------------------
if (-not $GistId) {
    $GistId = '6b5162555ef12c6289450683f04c113a'
}
$UserAgent = 'gist-installer-ps1/1.0'

# --- helpers ---------------------------------------------------------------

function Get-GhToken {
    # Echo the best available token (may be empty). Mirrors bash `gh_token`.
    try {
        $gh = Get-Command gh -ErrorAction Stop
        & $gh auth status *> $null
        if ($LASTEXITCODE -eq 0) {
            return (& $gh auth token 2>$null)
        }
    } catch {
        # gh not installed or not authenticated; fall through.
    }
    if ($env:GITHUB_TOKEN) { return $env:GITHUB_TOKEN }
    if ($env:GH_TOKEN)      { return $env:GH_TOKEN }
    return ''
}

function Find-EnvFile {
    # Returns the first existing .env from the standard search list, or $null.
    # Mirrors the bash load_env() search order.
    $scriptDir = $null
    if ($PSCommandPath) {
        $scriptDir = Split-Path -Parent $PSCommandPath
    } elseif ($MyInvocation.MyCommand.Path) {
        $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
    }

    $candidates = @(
        (Join-Path $HOME '.env')
        if ($scriptDir) { Join-Path $scriptDir '.env' }
        if ($scriptDir) { Join-Path (Split-Path $scriptDir) '.env' }
        (Join-Path (Get-Location) '.env')
    )

    foreach ($c in $candidates) {
        if ($c -and (Test-Path -LiteralPath $c -PathType Leaf)) {
            return $c
        }
    }
    return $null
}

function Load-Env {
    # Source a .env file into the current process. Mirrors bash load_env().
    # Lines starting with '#' and blank lines are ignored. Quotes are stripped.
    $envFile = Find-EnvFile
    if (-not $envFile) {
        Write-Host 'no .env found; placeholders will be kept in installed files'
        return $false
    }
    Write-Host "loading env from $envFile"
    Get-Content -LiteralPath $envFile | ForEach-Object {
        $line = $_.Trim()
        if (-not $line -or $line.StartsWith('#')) { return }
        # Match KEY=VALUE; KEY may be alnum + underscore.
        if ($line -match '^(?<k>[A-Za-z_][A-Za-z0-9_]*)=(?<v>.*)$') {
            $k = $Matches['k']
            $v = $Matches['v']
            # Strip surrounding quotes (single or double).
            if ($v.Length -ge 2) {
                if (($v.StartsWith('"') -and $v.EndsWith('"')) -or
                    ($v.StartsWith("'") -and $v.EndsWith("'"))) {
                    $v = $v.Substring(1, $v.Length - 2)
                }
            }
            # Set in-process env. Do NOT overwrite existing non-empty values
            # so a pre-set $env:OPENCODE_API_KEY in the parent shell wins.
            $existing = [Environment]::GetEnvironmentVariable($k, 'Process')
            if ([string]::IsNullOrEmpty($existing)) {
                [Environment]::SetEnvironmentVariable($k, $v, 'Process')
            }
        }
    }
    return $true
}

function Set-JsonValue {
    # Update a JSON file at a dotted path using PowerShell's built-in
    # ConvertFrom-Json / ConvertTo-Json. No external tools required.
    #   $Path        -> file path
    #   $JsonPath    -> dotted path inside the JSON, e.g. 'provider.selfHosted.options.baseURL'
    #   $Value       -> new value (string)
    # Returns true on success, false on failure. Never throws.
    #
    # Why no jq? Earlier versions of this script tried to use jq.exe on
    # Windows when present, but jq's filter has to be passed via
    # ProcessStartInfo.Arguments, and Windows splits that string on spaces
    # and special characters -- which silently truncated the filter for
    # values containing ?, &, =, or other URL/API-key punctuation. The
    # PowerShell-native path below uses no external process and handles
    # arbitrary value contents.
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$JsonPath,
        [Parameter(Mandatory)][string]$Value
    )

    # Detect file lock BEFORE attempting the write. A locked file (OneDrive
    # sync, antivirus, running opencode) causes a silent failure on Windows
    # that surfaces only as a generic "left untouched" warning downstream.
    try {
        $testStream = [System.IO.File]::Open($Path, 'Open', 'ReadWrite', 'None')
        $testStream.Close()
    } catch {
        Write-Warning "  !! could not open $Path for write: $($_.Exception.Message)"
        Write-Warning "     (file may be locked by OneDrive sync, antivirus, or a running opencode process)"
        return $false
    }

    # Parse, mutate, re-serialize. PowerShell 7+'s ConvertFrom-Json /
    # ConvertTo-Json preserve all known keys and faithfully round-trip
    # simple JSON objects. -Depth 20 is enough for the opencode /
    # auth.json shapes we touch (max nesting observed: ~5 levels).
    try {
        $raw = Get-Content -LiteralPath $Path -Raw -Encoding utf8
        $obj = $raw | ConvertFrom-Json
    } catch {
        Write-Warning "  !! could not parse $Path as JSON: $($_.Exception.Message)"
        return $false
    }

    # Walk the dotted path. Create intermediate objects if missing so
    # this also works the first time the installer runs on a fresh
    # machine (where the placeholder file has no baseURL line).
    $segments = $JsonPath.Split('.')
    $node = $obj
    for ($i = 0; $i -lt $segments.Count - 1; $i++) {
        $seg = $segments[$i]
        $next = $segments[$i + 1]
        if ($null -eq $node.$seg) {
            if ($next -match '^\d+$') {
                $node.$seg = @()
            } else {
                $node.$seg = [ordered]@{}
            }
        }
        $node = $node.$seg
    }

    $leaf = $segments[-1]
    if ($node -is [System.Collections.IList]) {
        $idx = [int]$leaf
        while ($node.Count -le $idx) { $node.Add($null) }
        $node[$idx] = $Value
    } else {
        $node.$leaf = $Value
    }

    try {
        $newJson = $obj | ConvertTo-Json -Depth 20
        # Preserve a trailing newline if the original had one. ConvertTo-Json
        # always omits it; matching the original style keeps diffs minimal
        # and avoids touching bytes the user didn't ask us to touch.
        if ($raw.EndsWith("`n") -and -not $newJson.EndsWith("`n")) {
            $newJson += "`n"
        }
        Set-Content -LiteralPath $Path -Value $newJson -Encoding utf8 -NoNewline
        return $true
    } catch {
        Write-Warning "  !! could not rewrite ${Path}: $($_.Exception.Message)"
        return $false
    }
}

function Substitute-IfSet {
    #   $JsonPath    -> dotted path inside the JSON
    #   $EnvVar      -> env var name to read from
    #   $Label       -> human-readable label for logging
    #   [switch]$Secret   -> suppress the value in the log line
    # Always returns $true (never aborts the loop).
    param(
        [Parameter(Mandatory)][string]$JsonPath,
        [Parameter(Mandatory)][string]$EnvVar,
        [Parameter(Mandatory)][string]$Label,
        [switch]$Secret
    )
    $val = [Environment]::GetEnvironmentVariable($EnvVar, 'Process')
    if ([string]::IsNullOrEmpty($val)) {
        Write-Host "  -> $Label kept as placeholder (`$env:$EnvVar not set)"
        return $true
    }
    if (Set-JsonValue -Path $Target -JsonPath $JsonPath -Value $val) {
        if ($Secret) {
            Write-Host "  -> $Label set from `$env:$EnvVar (value redacted)"
        } else {
            Write-Host "  -> $Label set to $val (from `$env:$EnvVar)"
        }
    } else {
        Write-Warning "  !! $Label substitution failed; left untouched"
    }
    return $true
}

function Get-GistFiles {
    # Returns an array of [pscustomobject]@{ Name = ...; Source = ... }
    # where Source is either a local path inside the cloned repo, or an
    # https:// raw URL (API fallback). Mirrors bash enumerate().
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("gist-" + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tmp | Out-Null
    $repo = Join-Path $tmp 'gist'

    $git = Get-Command git -ErrorAction SilentlyContinue
    if ($git) {
        try {
            & $git clone --depth 1 --quiet "https://gist.github.com/$GistId.git" $repo 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) {
                # Use `git ls-files -z` so each filename is NUL-terminated with
                # no quoting, escaping, or trailing newline. `-z` is required
                # because gist filenames contain literal backslashes (the gist
                # author uses ".config\opencode\opencode.json" as a single
                # filename, where '\' is part of the name, NOT a separator
                # from git's perspective). With `-z` there are no surrounding
                # quotes to strip and no confusion with `core.quotePath`,
                # which does NOT cover backslash escaping.
                # Convert NUL to LF so PowerShell's -split can handle it.
                $raw = & $git -C $repo ls-files -z
                $names = $raw -split "`0" | Where-Object { $_ -ne '' }
                $out = foreach ($n in $names) {
                    [pscustomobject]@{ Name = $n; Source = (Join-Path $repo $n) }
                }
                $script:GistTmp = $tmp
                return ,$out
            }
        } catch {
            # fall through to API
        }
        Write-Host 'git clone failed; trying GitHub API fallback...' -ForegroundColor Yellow
    }

    # Fallback: REST API. Subject to 60/h anonymous rate limit per IP.
    # On Windows, the bare 'curl' name resolves to PowerShell's
    # Invoke-WebRequest alias -- which has completely different flags and
    # will reject the *nix-style -fsSL. We need the real curl.exe. Try it
    # first, then fall back to PowerShell-native (Invoke-WebRequest) so the
    # script still works on a fresh Windows box with no curl installed.
    $curl = Get-Command curl.exe -ErrorAction SilentlyContinue
    if ($curl) {
        $token = Get-GhToken
        $headerLines = @("Accept: application/vnd.github+json", "User-Agent: $UserAgent")
        if ($token) { $headerLines += "Authorization: Bearer $token" }
        $headerArgs = $headerLines | ForEach-Object { @('-H', $_) }
        $body = & curl.exe -fsSL -A $UserAgent @headerArgs "https://api.github.com/gists/$GistId"
        if ($LASTEXITCODE -ne 0) {
            if ($LASTEXITCODE -eq 22) {
                Write-Host ''
                Write-Host 'GitHub API returned 403. Public gists still need auth above' -ForegroundColor Red
                Write-Host '60 req/h per IP, which a shared cloud host hits fast.'      -ForegroundColor Red
                Write-Host 'Fixes (pick one):'                                          -ForegroundColor Red
                Write-Host '  - run:  gh auth login'                                    -ForegroundColor Red
                Write-Host '  - or:   $env:GITHUB_TOKEN = "<a fine-grained PAT>"'       -ForegroundColor Red
            }
            throw "curl failed (exit $LASTEXITCODE)"
        }
    } else {
        $token = Get-GhToken
        $headers = @{ 'Accept' = 'application/vnd.github+json'; 'User-Agent' = $UserAgent }
        if ($token) { $headers['Authorization'] = "Bearer $token" }
        try {
            $response = Invoke-WebRequest -Uri "https://api.github.com/gists/$GistId" -Headers $headers -UseBasicParsing -ErrorAction Stop
            $body = $response.Content
        } catch {
            $statusCode = $_.Exception.Response.StatusCode.value__
            if ($statusCode -eq 403) {
                Write-Host ''
                Write-Host 'GitHub API returned 403. Public gists still need auth above' -ForegroundColor Red
                Write-Host '60 req/h per IP, which a shared cloud host hits fast.'      -ForegroundColor Red
                Write-Host 'Fixes (pick one):'                                          -ForegroundColor Red
                Write-Host '  - run:  gh auth login'                                    -ForegroundColor Red
                Write-Host '  - or:   $env:GITHUB_TOKEN = "<a fine-grained PAT>"'       -ForegroundColor Red
            }
            throw "Invoke-WebRequest failed (HTTP $statusCode)"
        }
    }

    # Parse the API response with PowerShell. The earlier $jq branch was
    # removed because Windows' ProcessStartInfo.Arguments splits on spaces
    # and strips the outer quotes before they reach jq, which turns a
    # well-formed filter such as '.files | to_entries[] | "\(.value.filename)
    # \t\(.value.raw_url)"' into an invalid program on jq -- the parser
    # reports "unexpected INVALID_CHARACTER (Unix shell quoting issues?)"
    # for any '\' or '\t' in the string interpolation. The PowerShell path
    # below needs no external process and avoids every quoting landmine.
    $namesAndUrls = $body | ConvertFrom-Json | ForEach-Object {
        $_.files.PSObject.Properties | ForEach-Object {
            "$($_.Value.filename)`t$($_.Value.raw_url)"
        }
    }

    $out = $namesAndUrls | Where-Object { $_ -match '\A(.+)\t(.+)\z' } | ForEach-Object {
        [pscustomobject]@{ Name = $Matches[1]; Source = $Matches[2] }
    }
    return ,$out
}

# --- main ------------------------------------------------------------------

# 0. Load .env so the substitutions below have values to read.
$null = Load-Env

# 1. Purge old config variants. These are alternate filenames from earlier
#    versions of the same tool that the canonical gist files replace.
Write-Host 'purging old variants (if present):'
$purgeTargets = @(
    (Join-Path $HOME '.omo\omo.jsonc')
    (Join-Path $HOME '.config\opencode\oh-my-openagent.json')
)
foreach ($p in $purgeTargets) {
    if (Test-Path -LiteralPath $p) {
        Write-Host "  removing $p"
        Remove-Item -LiteralPath $p -Force
    }
}

# 2. Install the canonical files from the gist, then substitute env values
#    into the files that have placeholders.
$script:GistTmp = $null
$files = Get-GistFiles
try {
    foreach ($f in $files) {
        $filename = $f.Name
        $source = $f.Source
        if (-not $filename) { continue }

        # The gist filename uses backslashes as directory separators, which
        # is the Windows-native convention. On Windows, Join-Path below
        # correctly materializes the path as a directory tree.
        $target = Join-Path $HOME $filename

        $targetDir = Split-Path -Parent $target
        if ($targetDir -and -not (Test-Path -LiteralPath $targetDir)) {
            New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
        }

        Write-Host "installing $target"
        # If $source is a URL (API fallback), download into $target.
        if ($source -match '^https?://') {
            Invoke-WebRequest -Uri $source -OutFile $target -UseBasicParsing -Headers @{ 'User-Agent' = $UserAgent }
        } else {
            Copy-Item -LiteralPath $source -Destination $target -Force
        }

        # Env-driven substitutions (per file). Each call is a no-op if the
        # corresponding env var is unset/empty -- the placeholder is kept.
        switch ($filename) {
            '.config\opencode\opencode.json' {
                $null = Substitute-IfSet -JsonPath 'provider.selfHosted.options.baseURL' -EnvVar 'OPENCODE_BASE_URL' -Label 'baseURL'
            }
            '.local\share\opencode\auth.json' {
                $null = Substitute-IfSet -JsonPath 'selfHosted.key' -EnvVar 'OPENCODE_API_KEY' -Label 'api key' -Secret
            }
            '.omo\omo.json' {
                Write-Host '  -> no env-driven substitution for this file'
            }
        }
    }
} finally {
    if ($script:GistTmp -and (Test-Path -LiteralPath $script:GistTmp)) {
        Remove-Item -LiteralPath $script:GistTmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}
