#!/usr/bin/env pwsh
<#
.SYNOPSIS
Analyzes and, when explicitly requested, repairs the Windows OpenCode OMO plugin.

.DESCRIPTION
Runs read-only analysis by default. It inspects the OpenCode global config files,
the exact cache slot for PluginSpec, the installed package version, the npm
registry version when npm is available, relevant running processes, and command
availability.

No files, packages, or processes are changed unless -Repair is supplied together
with one or more explicit action switches. Supported repair actions are:
-RefreshConfig, -RefreshPlugin, -StopProcesses, and -StartOpenChamber.

Repair actions support PowerShell's common -WhatIf and -Confirm parameters.

.PARAMETER Repair
Enables repair mode. This switch alone performs no repair; select one or more
explicit action switches.

.PARAMETER RefreshConfig
Runs the existing omo-installer-win-host.ps1 configuration installer. Requires
-Repair.

.PARAMETER RefreshPlugin
Removes only the validated exact PluginSpec cache slot and runs:
opencode plugin --global --force <PluginSpec>. Requires -Repair.

.PARAMETER StopProcesses
Stops processes whose executable name is exactly OpenChamber.exe or opencode.exe.
Requires -Repair.

.PARAMETER PluginSpec
OpenCode plugin spec and cache-slot name. Defaults to oh-my-openagent@beta.

.PARAMETER ExpectedVersion
Version required by post-repair verification. Defaults to 5.0.0-beta.51.

.PARAMETER InstallerPath
Path to an existing omo-installer-win-host.ps1. If omitted, the script beside
this repair tool is preferred. A fetched standalone copy then defaults to the
verified repository raw installer URL only after -Repair -RefreshConfig is
explicitly requested.

.PARAMETER InstallerUrl
Optional HTTPS URL from which to fetch the config installer when InstallerPath
and the sibling installer do not exist. Defaults to the verified repository raw
installer URL so a fetched standalone copy remains usable.

.PARAMETER InstallerSha256
Optional expected SHA-256 for the installer. When supplied, the local or
downloaded installer must match before execution.

.PARAMETER OpenCodePath
Optional path to the OpenCode executable or shim used for analysis and plugin
refresh. If omitted, opencode is discovered on PATH. OpenChamber Desktop may
bundle it under:
%LOCALAPPDATA%\Programs\OpenChamber\resources\opencode-cli\opencode.exe
The installation path may vary.

.PARAMETER OpenChamberPath
Optional path to OpenChamber.exe. If omitted, command discovery is used.

.PARAMETER StartOpenChamber
Starts OpenChamber after the selected repair actions. Requires -Repair.

.PARAMETER Json
Writes one JSON result object and suppresses human-readable informational output.

.EXAMPLE
# Fetch this repair tool from the verified repository remote, then analyze only:
$repairUrl = 'https://raw.githubusercontent.com/JosiahSiegel/Docker-in-Docker_template/main/.devcontainer/omo-repair-win-host.ps1'
Invoke-WebRequest -Uri $repairUrl -OutFile '.\omo-repair-win-host.ps1'
pwsh -ExecutionPolicy Bypass -File '.\omo-repair-win-host.ps1'

.EXAMPLE
# Preview a targeted plugin refresh; no changes are made:
pwsh -ExecutionPolicy Bypass -File '.\omo-repair-win-host.ps1' -Repair -RefreshPlugin -StopProcesses -WhatIf

.EXAMPLE
# Use OpenChamber Desktop's bundled OpenCode sidecar (installation path may vary):
$bundledOpenCode = Join-Path $env:LOCALAPPDATA 'Programs\OpenChamber\resources\opencode-cli\opencode.exe'
pwsh -ExecutionPolicy Bypass -File '.\omo-repair-win-host.ps1' -OpenCodePath $bundledOpenCode -Repair -RefreshPlugin -StopProcesses

.EXAMPLE
# Refresh config with the installer beside this script, refresh the plugin, and restart OpenChamber:
pwsh -ExecutionPolicy Bypass -File '.\omo-repair-win-host.ps1' -Repair -RefreshConfig -RefreshPlugin -StopProcesses -StartOpenChamber

.EXAMPLE
# Machine-readable analysis:
pwsh -ExecutionPolicy Bypass -File '.\omo-repair-win-host.ps1' -Json
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [switch]$Repair,
    [switch]$RefreshConfig,
    [switch]$RefreshPlugin,
    [switch]$StopProcesses,
    [ValidateNotNullOrEmpty()]
    [string]$PluginSpec = 'oh-my-openagent@beta',
    [ValidateNotNullOrEmpty()]
    [string]$ExpectedVersion = '5.0.0-beta.51',
    [string]$InstallerPath,
    [ValidatePattern('^https://')]
    [string]$InstallerUrl = 'https://raw.githubusercontent.com/JosiahSiegel/Docker-in-Docker_template/main/.devcontainer/omo-installer-win-host.ps1',
    [ValidatePattern('^[A-Fa-f0-9]{64}$')]
    [string]$InstallerSha256,
    [string]$OpenCodePath,
    [string]$OpenChamberPath,
    [switch]$StartOpenChamber,
    [switch]$Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
if ($Json) {
    $InformationPreference = 'SilentlyContinue'
    $VerbosePreference = 'SilentlyContinue'
    $DebugPreference = 'SilentlyContinue'
}

$script:Messages = [System.Collections.Generic.List[object]]::new()
$script:Actions = [System.Collections.Generic.List[object]]::new()
$script:TemporaryInstallerPath = $null
$script:ScriptCmdlet = $PSCmdlet
$script:ConfirmExplicitlyRequested = $PSBoundParameters.ContainsKey('Confirm') -and [bool]$PSBoundParameters['Confirm']

function Test-RepairShouldProcess {
    param(
        [Parameter(Mandatory)][string]$Target,
        [Parameter(Mandatory)][string]$Action
    )

    if ($Json) {
        if ($WhatIfPreference) {
            return $false
        }
        if (-not $script:ConfirmExplicitlyRequested) {
            return $true
        }
    }
    return $script:ScriptCmdlet.ShouldProcess($Target, $Action)
}

function Add-Message {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Info', 'Warning', 'Error', 'Success')]
        [string]$Level,
        [Parameter(Mandatory)]
        [string]$Text
    )

    $script:Messages.Add([pscustomobject][ordered]@{
        level = $Level.ToLowerInvariant()
        text = $Text
    }) | Out-Null

    if (-not $Json) {
        $color = switch ($Level) {
            'Warning' { 'Yellow' }
            'Error' { 'Red' }
            'Success' { 'Green' }
            default { 'Cyan' }
        }
        Write-Host $Text -ForegroundColor $color
    }
}

function Add-ActionResult {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Target,
        [Parameter(Mandatory)][ValidateSet('Completed', 'Skipped', 'Failed', 'WhatIf')][string]$Status,
        [string]$Detail = ''
    )

    $script:Actions.Add([pscustomobject][ordered]@{
        name = $Name
        target = $Target
        status = $Status
        detail = $Detail
    }) | Out-Null
}

function Get-ProcessEnvironmentValue {
    param([Parameter(Mandatory)][string]$Name)

    return [Environment]::GetEnvironmentVariable($Name, 'Process')
}

function Get-OpenCodePaths {
    $userHome = [Environment]::GetFolderPath('UserProfile')
    if ([string]::IsNullOrWhiteSpace($userHome)) {
        throw 'Windows UserProfile could not be resolved.'
    }

    $configOverride = Get-ProcessEnvironmentValue -Name 'OPENCODE_CONFIG_DIR'
    if ([string]::IsNullOrWhiteSpace($configOverride)) {
        $configRoot = Join-Path (Join-Path $userHome '.config') 'opencode'
        $configSource = 'UserProfile/.config/opencode'
    } else {
        $configRoot = $configOverride
        $configSource = 'OPENCODE_CONFIG_DIR'
    }

    $cacheOverride = Get-ProcessEnvironmentValue -Name 'XDG_CACHE_HOME'
    if ([string]::IsNullOrWhiteSpace($cacheOverride)) {
        $cacheBase = Join-Path $userHome '.cache'
        $cacheSource = 'UserProfile/.cache'
    } else {
        $cacheBase = $cacheOverride
        $cacheSource = 'XDG_CACHE_HOME'
    }

    return [pscustomobject][ordered]@{
        userHome = [System.IO.Path]::GetFullPath($userHome)
        configRoot = [System.IO.Path]::GetFullPath($configRoot)
        configSource = $configSource
        cacheRoot = [System.IO.Path]::GetFullPath((Join-Path $cacheBase 'opencode'))
        cacheSource = $cacheSource
    }
}

function Get-PluginPackageName {
    param([Parameter(Mandatory)][string]$Spec)

    if ($Spec.StartsWith('@')) {
        $separator = $Spec.IndexOf('@', 1)
        if ($separator -lt 1) {
            throw "PluginSpec '$Spec' is not a scoped package with a version or tag."
        }
        return $Spec.Substring(0, $separator)
    }

    $separator = $Spec.LastIndexOf('@')
    if ($separator -lt 1) {
        return $Spec
    }
    return $Spec.Substring(0, $separator)
}

function Test-SafeCacheSlotName {
    param([Parameter(Mandatory)][string]$Spec)

    if ([string]::IsNullOrWhiteSpace($Spec) -or
        [System.IO.Path]::IsPathRooted($Spec) -or
        $Spec -match '[\\/]' -or
        $Spec -eq '.' -or
        $Spec -eq '..') {
        return $false
    }

    return $Spec.IndexOfAny([System.IO.Path]::GetInvalidFileNameChars()) -lt 0
}

function Resolve-ValidatedCacheSlot {
    param(
        [Parameter(Mandatory)][string]$CacheRoot,
        [Parameter(Mandatory)][string]$Spec
    )

    if (-not (Test-SafeCacheSlotName -Spec $Spec)) {
        throw "PluginSpec '$Spec' is not a safe single cache-slot name. Path separators, rooted paths, and dot segments are rejected."
    }

    $packagesRoot = [System.IO.Path]::GetFullPath((Join-Path $CacheRoot 'packages'))
    $candidate = [System.IO.Path]::GetFullPath((Join-Path $packagesRoot $Spec))
    $expected = Join-Path $packagesRoot $Spec
    $comparison = if ($IsWindows) {
        [System.StringComparison]::OrdinalIgnoreCase
    } else {
        [System.StringComparison]::Ordinal
    }

    if (-not $candidate.Equals([System.IO.Path]::GetFullPath($expected), $comparison)) {
        throw "Resolved cache slot '$candidate' does not equal the exact expected slot '$expected'."
    }

    $prefix = $packagesRoot.TrimEnd(
        [System.IO.Path]::DirectorySeparatorChar,
        [System.IO.Path]::AltDirectorySeparatorChar
    ) + [System.IO.Path]::DirectorySeparatorChar
    if (-not $candidate.StartsWith($prefix, $comparison)) {
        throw "Resolved cache slot '$candidate' is outside '$packagesRoot'."
    }

    return [pscustomobject][ordered]@{
        packagesRoot = $packagesRoot
        slot = $candidate
    }
}

function Get-RawPluginMatches {
    param(
        [Parameter(Mandatory)][string]$Content,
        [Parameter(Mandatory)][string]$PackageName
    )

    $pluginMatches = [System.Collections.Generic.List[string]]::new()
    $escaped = [regex]::Escape($PackageName)
    $pattern = '(?i)[''"](?<spec>' + $escaped + '(?:@[^''"\s,\]]+)?)[''"]'
    foreach ($match in [regex]::Matches($Content, $pattern)) {
        if (-not $pluginMatches.Contains($match.Groups['spec'].Value)) {
            $pluginMatches.Add($match.Groups['spec'].Value) | Out-Null
        }
    }
    return @($pluginMatches)
}

function Get-PluginEntries {
    param(
        [Parameter(Mandatory)][AllowNull()][object]$PluginValue,
        [Parameter(Mandatory)][string]$PackageName
    )

    $entries = [System.Collections.Generic.List[object]]::new()
    if ($null -eq $PluginValue) {
        return @()
    }

    $values = if ($PluginValue -is [System.Array]) { @($PluginValue) } else { @($PluginValue) }
    foreach ($value in $values) {
        $spec = $null
        $kind = 'unknown'
        if ($value -is [string]) {
            $spec = $value
            $kind = 'string'
        } elseif ($value -is [System.Array] -and $value.Count -gt 0 -and $value[0] -is [string]) {
            $spec = $value[0]
            $kind = 'tuple'
        }

        if ($spec -and ($spec -eq $PackageName -or $spec.StartsWith("$PackageName@", [System.StringComparison]::OrdinalIgnoreCase))) {
            $entries.Add([pscustomobject][ordered]@{
                kind = $kind
                spec = $spec
            }) | Out-Null
        }
    }

    return @($entries)
}

function Get-ConfigInspection {
    param(
        [Parameter(Mandatory)][string]$ConfigRoot,
        [Parameter(Mandatory)][string]$PackageName
    )

    $results = foreach ($fileName in @('opencode.jsonc', 'opencode.json')) {
        $path = Join-Path $ConfigRoot $fileName
        $exists = Test-Path -LiteralPath $path -PathType Leaf
        $rawMatches = @()
        $entries = @()
        $parseStatus = 'not-found'
        $parseError = $null

        if ($exists) {
            try {
                $raw = Get-Content -LiteralPath $path -Raw -Encoding utf8
                $rawMatches = @(Get-RawPluginMatches -Content $raw -PackageName $PackageName)
                try {
                    $parsed = $raw | ConvertFrom-Json -ErrorAction Stop
                    $parseStatus = 'parsed'
                    $pluginProperty = $parsed.PSObject.Properties['plugin']
                    if ($null -ne $pluginProperty) {
                        $entries = @(Get-PluginEntries -PluginValue $pluginProperty.Value -PackageName $PackageName)
                    }
                } catch {
                    $parseStatus = 'parse-failed'
                    $parseError = $_.Exception.Message
                }
            } catch {
                $parseStatus = 'read-failed'
                $parseError = $_.Exception.Message
            }
        }

        [pscustomobject][ordered]@{
            path = $path
            exists = $exists
            parseStatus = $parseStatus
            parseError = $parseError
            pluginEntries = @($entries)
            rawPluginSpecMatches = @($rawMatches)
        }
    }

    return @($results)
}

function Get-JsonFileVersion {
    param([Parameter(Mandatory)][string]$Path)

    $result = [ordered]@{
        path = $Path
        exists = Test-Path -LiteralPath $Path -PathType Leaf
        name = $null
        version = $null
        readError = $null
    }
    if (-not $result.exists) {
        return [pscustomobject]$result
    }

    try {
        $package = Get-Content -LiteralPath $Path -Raw -Encoding utf8 | ConvertFrom-Json -ErrorAction Stop
        $nameProperty = $package.PSObject.Properties['name']
        $versionProperty = $package.PSObject.Properties['version']
        if ($null -ne $nameProperty) { $result.name = [string]$nameProperty.Value }
        if ($null -ne $versionProperty) { $result.version = [string]$versionProperty.Value }
    } catch {
        $result.readError = $_.Exception.Message
    }
    return [pscustomobject]$result
}

function Get-CommandInspection {
    param(
        [Parameter(Mandatory)][string]$Name,
        [string]$ExplicitPath,
        [switch]$RequireExactExeName
    )

    if (-not [string]::IsNullOrWhiteSpace($ExplicitPath)) {
        $resolvedExplicit = try { [System.IO.Path]::GetFullPath($ExplicitPath) } catch { $ExplicitPath }
        $isFile = Test-Path -LiteralPath $ExplicitPath -PathType Leaf
        $nameMatches = -not $RequireExactExeName -or
            [System.IO.Path]::GetFileName($resolvedExplicit).Equals($Name, [System.StringComparison]::OrdinalIgnoreCase)
        return [pscustomobject][ordered]@{
            name = $Name
            available = $isFile -and $nameMatches
            source = $resolvedExplicit
            discovery = 'explicit-path'
            validationError = if ($isFile -and -not $nameMatches) { "Explicit path must name exactly '$Name'." } else { $null }
        }
    }

    $commandTypes = if ($RequireExactExeName) { 'Application' } else { @('Application', 'ExternalScript') }
    $command = Get-Command $Name -CommandType $commandTypes -ErrorAction SilentlyContinue |
        Where-Object { -not $RequireExactExeName -or [System.IO.Path]::GetFileName($_.Source) -ieq $Name } |
        Select-Object -First 1
    return [pscustomobject][ordered]@{
        name = $Name
        available = $null -ne $command
        source = if ($command) { $command.Source } else { $null }
        discovery = 'PATH'
        validationError = $null
    }
}

function Get-RelevantProcesses {
    $wanted = @('OpenChamber.exe', 'opencode.exe')
    $processes = [System.Collections.Generic.List[object]]::new()
    foreach ($process in @(Get-Process -ErrorAction SilentlyContinue)) {
        $executableName = if ($process.Name.EndsWith('.exe', [System.StringComparison]::OrdinalIgnoreCase)) {
            $process.Name
        } else {
            "$($process.Name).exe"
        }
        if ($wanted -notcontains $executableName) {
            continue
        }

        $path = $null
        try {
            $path = $process.Path
        } catch {
            $path = $null
        }
        $processes.Add([pscustomobject][ordered]@{
            id = $process.Id
            name = $executableName
            path = $path
        }) | Out-Null
    }
    return @($processes)
}

function Get-NpmRegistryVersion {
    param(
        [Parameter(Mandatory)][object]$NpmCommand,
        [Parameter(Mandatory)][string]$Spec,
        [Parameter(Mandatory)][string]$PackageName
    )

    $result = [ordered]@{
        queried = $false
        available = [bool]$NpmCommand.available
        version = $null
        registryUri = $null
        error = $null
    }
    if (-not $NpmCommand.available) {
        return [pscustomobject]$result
    }

    try {
        $tagOrVersion = $Spec.Substring($PackageName.Length).TrimStart('@')
        if ([string]::IsNullOrWhiteSpace($tagOrVersion)) {
            $tagOrVersion = 'latest'
        }

        $registry = 'https://registry.npmjs.org/'
        $registryOverride = Get-ProcessEnvironmentValue -Name 'NPM_CONFIG_REGISTRY'
        if (-not [string]::IsNullOrWhiteSpace($registryOverride)) {
            $registryUriCandidate = $null
            if ([Uri]::TryCreate($registryOverride, [UriKind]::Absolute, [ref]$registryUriCandidate) -and
                $registryUriCandidate.Scheme -in @('http', 'https')) {
                $registry = $registryOverride.TrimEnd('/') + '/'
            }
        }

        $encodedName = [Uri]::EscapeDataString($PackageName)
        $encodedTagOrVersion = [Uri]::EscapeDataString($tagOrVersion)
        $registryUri = "$registry$encodedName/$encodedTagOrVersion"
        $result.registryUri = $registryUri
        $result.queried = $true
        $package = Invoke-RestMethod -Uri $registryUri -Method Get -TimeoutSec 12 -ErrorAction Stop
        $versionProperty = $package.PSObject.Properties['version']
        if ($null -ne $versionProperty) {
            $result.version = [string]$versionProperty.Value
        } else {
            $result.error = "Registry response from '$registryUri' did not contain a version."
        }
    } catch {
        $result.error = $_.Exception.Message
    }
    return [pscustomobject]$result
}

function Get-Analysis {
    param(
        [Parameter(Mandatory)][object]$Paths,
        [Parameter(Mandatory)][object]$CacheSlot,
        [Parameter(Mandatory)][string]$PackageName
    )

    $installedPackageJson = Join-Path (Join-Path $CacheSlot.slot 'node_modules') (Join-Path $PackageName 'package.json')
    $opencodeCommand = Get-CommandInspection -Name 'opencode' -ExplicitPath $OpenCodePath
    $npmCommand = Get-CommandInspection -Name 'npm'
    $openChamberCommand = Get-CommandInspection -Name 'OpenChamber.exe' -ExplicitPath $OpenChamberPath -RequireExactExeName
    $installed = Get-JsonFileVersion -Path $installedPackageJson
    $registry = Get-NpmRegistryVersion -NpmCommand $npmCommand -Spec $PluginSpec -PackageName $PackageName

    return [pscustomobject][ordered]@{
        timestamp = [DateTimeOffset]::Now.ToString('o')
        paths = $Paths
        plugin = [pscustomobject][ordered]@{
            spec = $PluginSpec
            packageName = $PackageName
            expectedVersion = $ExpectedVersion
        }
        configFiles = @(Get-ConfigInspection -ConfigRoot $Paths.configRoot -PackageName $PackageName)
        cache = [pscustomobject][ordered]@{
            packagesRoot = $CacheSlot.packagesRoot
            slot = $CacheSlot.slot
            exists = Test-Path -LiteralPath $CacheSlot.slot -PathType Container
            packageJson = $installed
        }
        registry = $registry
        processes = @(Get-RelevantProcesses)
        executables = [pscustomobject][ordered]@{
            opencode = $opencodeCommand
            npm = $npmCommand
            openChamber = $openChamberCommand
        }
        verification = [pscustomobject][ordered]@{
            packageName = $PackageName
            installedName = $installed.name
            expectedVersion = $ExpectedVersion
            installedVersion = $installed.version
            nameMatch = $installed.name -ceq $PackageName
            versionMatch = $installed.version -ceq $ExpectedVersion
            exactMatch = ($installed.name -ceq $PackageName) -and ($installed.version -ceq $ExpectedVersion)
            packageJsonReadable = $installed.exists -and [string]::IsNullOrWhiteSpace($installed.readError)
        }
    }
}

function Write-HumanAnalysis {
    param(
        [Parameter(Mandatory)][object]$Analysis,
        [Parameter(Mandatory)][string]$Title
    )

    if ($Json) { return }

    Write-Host ''
    Write-Host "=== $Title ===" -ForegroundColor White
    Write-Host "User profile : $($Analysis.paths.userHome)"
    Write-Host "Config root  : $($Analysis.paths.configRoot) [$($Analysis.paths.configSource)]"
    Write-Host "Cache root   : $($Analysis.paths.cacheRoot) [$($Analysis.paths.cacheSource)]"
    Write-Host "Plugin       : $($Analysis.plugin.spec)"

    Write-Host 'Config files:'
    foreach ($config in $Analysis.configFiles) {
        $entries = @($config.pluginEntries | ForEach-Object { "$($_.kind):$($_.spec)" })
        $raw = @($config.rawPluginSpecMatches)
        Write-Host "  $($config.path)"
        Write-Host "    exists=$($config.exists) parse=$($config.parseStatus) parsedMatches=$($entries -join ', ') rawMatches=$($raw -join ', ')"
        if ($config.parseError) {
            Write-Host "    parse/read warning: $($config.parseError)" -ForegroundColor Yellow
        }
    }

    Write-Host "Cache slot   : $($Analysis.cache.slot) (exists=$($Analysis.cache.exists))"
    Write-Host "Package JSON : $($Analysis.cache.packageJson.path)"
    Write-Host "Package name : installed=$(if ($Analysis.verification.installedName) { $Analysis.verification.installedName } else { '<unavailable>' }) expected=$($Analysis.verification.packageName) match=$($Analysis.verification.nameMatch)"
    Write-Host "Version      : installed=$(if ($Analysis.cache.packageJson.version) { $Analysis.cache.packageJson.version } else { '<unavailable>' }) expected=$($Analysis.verification.expectedVersion) match=$($Analysis.verification.versionMatch)"
    if ($Analysis.cache.packageJson.readError) {
        Write-Host "  package read warning: $($Analysis.cache.packageJson.readError)" -ForegroundColor Yellow
    }
    Write-Host "npm registry : $(if ($Analysis.registry.version) { $Analysis.registry.version } elseif (-not $Analysis.registry.available) { '<npm unavailable>' } else { '<query unavailable>' })"
    if ($Analysis.registry.error) {
        Write-Host "  registry warning: $($Analysis.registry.error)" -ForegroundColor Yellow
    }

    Write-Host 'Executables:'
    foreach ($command in @($Analysis.executables.opencode, $Analysis.executables.npm, $Analysis.executables.openChamber)) {
        Write-Host "  $($command.name): available=$($command.available) source=$(if ($command.source) { $command.source } else { '<not found>' })"
    }

    Write-Host 'Relevant processes:'
    if ($Analysis.processes.Count -eq 0) {
        Write-Host '  none'
    } else {
        foreach ($process in $Analysis.processes) {
            Write-Host "  PID=$($process.id) name=$($process.name) path=$(if ($process.path) { $process.path } else { '<unavailable>' })"
        }
    }

    $verificationColor = if ($Analysis.verification.exactMatch) { 'Green' } else { 'Yellow' }
    Write-Host "Package check: name and version exactly match expected values: $($Analysis.verification.exactMatch)" -ForegroundColor $verificationColor
}

function Assert-InstallerHash {
    param([Parameter(Mandatory)][string]$Path)

    if ([string]::IsNullOrWhiteSpace($InstallerSha256)) {
        return
    }

    $actual = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
    if (-not $actual.Equals($InstallerSha256, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Installer SHA-256 mismatch for '$Path'. Expected $InstallerSha256; got $actual."
    }
}

function Resolve-InstallerForRepair {
    $candidate = $InstallerPath
    $explicitInstallerPath = -not [string]::IsNullOrWhiteSpace($candidate)
    if (-not $explicitInstallerPath) {
        $scriptDirectory = if ($PSCommandPath) { Split-Path -Parent $PSCommandPath } else { Get-Location }
        $candidate = Join-Path $scriptDirectory 'omo-installer-win-host.ps1'
    }

    if (Test-Path -LiteralPath $candidate -PathType Leaf) {
        Assert-InstallerHash -Path $candidate
        return [System.IO.Path]::GetFullPath($candidate)
    }

    if ($explicitInstallerPath) {
        throw "Explicit config installer '$candidate' was not found. Supply an existing -InstallerPath or omit it to allow -InstallerUrl fallback."
    }
    if ([string]::IsNullOrWhiteSpace($InstallerUrl)) {
        throw "Sibling config installer '$candidate' was not found and no HTTPS -InstallerUrl is available."
    }

    $temporaryPath = Join-Path ([System.IO.Path]::GetTempPath()) ("omo-installer-{0}.ps1" -f [Guid]::NewGuid().ToString('N'))
    $script:TemporaryInstallerPath = $temporaryPath
    try {
        Invoke-WebRequest -Uri $InstallerUrl -OutFile $temporaryPath -UseBasicParsing -ErrorAction Stop
        Assert-InstallerHash -Path $temporaryPath
        return $temporaryPath
    } catch {
        if (Test-Path -LiteralPath $temporaryPath -PathType Leaf) {
            Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
        }
        $script:TemporaryInstallerPath = $null
        throw
    }
}

function Invoke-ExternalCommand {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string[]]$ArgumentList,
        [Parameter(Mandatory)][string]$Description
    )

    $captured = @(& $FilePath @ArgumentList 2>&1)
    $exitCode = $LASTEXITCODE
    $output = ($captured | ForEach-Object { $_.ToString() } | Out-String).Trim()
    if (-not $Json -and -not [string]::IsNullOrWhiteSpace($output)) {
        Write-Host $output
    }

    $result = [pscustomobject][ordered]@{
        description = $Description
        filePath = $FilePath
        arguments = @($ArgumentList)
        exitCode = $exitCode
        output = $output
    }
    if ($exitCode -ne 0) {
        $message = "$Description failed with exit code $exitCode."
        if (-not [string]::IsNullOrWhiteSpace($output)) {
            $message += " Output: $output"
        }
        throw $message
    }
    return $result
}

function Stop-RelevantProcesses {
    $targets = @(
        Get-RelevantProcesses | Where-Object {
            $_.name -ieq 'OpenChamber.exe' -or $_.name -ieq 'opencode.exe'
        }
    )
    if ($targets.Count -eq 0) {
        Add-ActionResult -Name 'StopProcesses' -Target 'OpenChamber.exe, opencode.exe' -Status 'Skipped' -Detail 'No exact-name processes were running.'
        Add-Message -Level Info -Text 'No exact OpenChamber.exe or opencode.exe processes are running.'
        return
    }

    foreach ($target in $targets) {
        if ($target.name -ine 'OpenChamber.exe' -and $target.name -ine 'opencode.exe') {
            throw "Refusing to stop unexpected process name '$($target.name)'."
        }
        $description = "$($target.name) PID $($target.id)"
        if (Test-RepairShouldProcess -Target $description -Action 'Stop exact-name process') {
            try {
                $currentProcess = Get-Process -Id $target.id -ErrorAction SilentlyContinue
                if ($null -eq $currentProcess) {
                    Add-ActionResult -Name 'StopProcess' -Target $description -Status 'Completed' -Detail 'Already exited.'
                    Add-Message -Level Success -Text "$description already exited; continuing."
                    continue
                }

                $currentImageName = if ($currentProcess.Name.EndsWith('.exe', [System.StringComparison]::OrdinalIgnoreCase)) {
                    $currentProcess.Name
                } else {
                    "$($currentProcess.Name).exe"
                }
                if ($currentImageName -ine $target.name) {
                    throw "Refusing to stop PID $($target.id): snapshot expected '$($target.name)', but the current image is '$currentImageName'. The PID may have been reused."
                }

                Stop-Process -Id $target.id -ErrorAction Stop
                Wait-Process -Id $target.id -Timeout 15 -ErrorAction SilentlyContinue
                if ($null -ne (Get-Process -Id $target.id -ErrorAction SilentlyContinue)) {
                    throw "$description did not exit within 15 seconds. Cache deletion and plugin refresh were not attempted."
                }
                Add-ActionResult -Name 'StopProcess' -Target $description -Status 'Completed' -Detail 'Exited within 15 seconds.'
                Add-Message -Level Success -Text "Stopped $description and confirmed it exited."
            } catch {
                Add-ActionResult -Name 'StopProcess' -Target $description -Status 'Failed' -Detail $_.Exception.Message
                throw
            }
        } else {
            Add-ActionResult -Name 'StopProcess' -Target $description -Status 'WhatIf' -Detail 'ShouldProcess declined or -WhatIf was used.'
        }
    }
}

function Invoke-ConfigRefresh {
    $targetDescription = if ($InstallerPath) { $InstallerPath } else { "sibling installer or $InstallerUrl" }
    if (-not (Test-RepairShouldProcess -Target $targetDescription -Action 'Run OMO config installer')) {
        Add-ActionResult -Name 'RefreshConfig' -Target $targetDescription -Status 'WhatIf' -Detail 'ShouldProcess declined or -WhatIf was used.'
        return
    }

    try {
        $installer = Resolve-InstallerForRepair
        $pwsh = Get-Command pwsh -CommandType Application -ErrorAction Stop | Select-Object -First 1
        $commandResult = Invoke-ExternalCommand -FilePath $pwsh.Source -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $installer) -Description 'OMO config installer'
        Add-ActionResult -Name 'RefreshConfig' -Target $installer -Status 'Completed' -Detail $commandResult.output
        Add-Message -Level Success -Text "Config installer completed: $installer$(if ($Json -and $commandResult.output) { ' (output captured in action detail)' })"
    } catch {
        Add-ActionResult -Name 'RefreshConfig' -Target $targetDescription -Status 'Failed' -Detail $_.Exception.Message
        throw
    }
}

function Invoke-PluginRefresh {
    param(
        [Parameter(Mandatory)][object]$CacheSlot,
        [Parameter(Mandatory)][object]$OpenCodeCommand
    )

    if (-not $OpenCodeCommand.available) {
        $reason = if ($OpenCodeCommand.validationError) { " $($OpenCodeCommand.validationError)" } else { '' }
        throw "Cannot refresh the plugin because the selected OpenCode executable is unavailable.$reason Pass -OpenCodePath with an existing executable or shim, or add opencode to PATH."
    }

    if (Test-Path -LiteralPath $CacheSlot.slot) {
        $slotItem = Get-Item -LiteralPath $CacheSlot.slot -Force -ErrorAction Stop
        if ($slotItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
            throw "Refusing to delete cache slot '$($CacheSlot.slot)' because it is a reparse point."
        }
        if (-not $slotItem.PSIsContainer) {
            throw "Refusing to delete cache slot '$($CacheSlot.slot)' because it is not a directory."
        }

        if (Test-RepairShouldProcess -Target $CacheSlot.slot -Action 'Delete validated exact OpenCode plugin cache slot') {
            Remove-Item -LiteralPath $CacheSlot.slot -Recurse -Force
            Add-ActionResult -Name 'DeletePluginCacheSlot' -Target $CacheSlot.slot -Status 'Completed'
            Add-Message -Level Success -Text "Deleted validated cache slot: $($CacheSlot.slot)"
        } else {
            Add-ActionResult -Name 'DeletePluginCacheSlot' -Target $CacheSlot.slot -Status 'WhatIf' -Detail 'ShouldProcess declined or -WhatIf was used.'
        }
    } else {
        Add-ActionResult -Name 'DeletePluginCacheSlot' -Target $CacheSlot.slot -Status 'Skipped' -Detail 'Exact cache slot did not exist.'
        Add-Message -Level Info -Text "Exact cache slot is already absent: $($CacheSlot.slot)"
    }

    $arguments = @('plugin', '--global', '--force', $PluginSpec)
    if (Test-RepairShouldProcess -Target "$($OpenCodeCommand.source) $($arguments -join ' ')" -Action 'Install global OpenCode plugin') {
        try {
            $commandResult = Invoke-ExternalCommand -FilePath $OpenCodeCommand.source -ArgumentList $arguments -Description 'OpenCode plugin refresh'
            Add-ActionResult -Name 'RefreshPlugin' -Target $PluginSpec -Status 'Completed' -Detail $commandResult.output
            Add-Message -Level Success -Text "Plugin refresh completed: $PluginSpec$(if ($Json -and $commandResult.output) { ' (output captured in action detail)' })"
        } catch {
            Add-ActionResult -Name 'RefreshPlugin' -Target $PluginSpec -Status 'Failed' -Detail $_.Exception.Message
            throw
        }
    } else {
        Add-ActionResult -Name 'RefreshPlugin' -Target $PluginSpec -Status 'WhatIf' -Detail 'ShouldProcess declined or -WhatIf was used.'
    }
}

function Start-OpenChamberProcess {
    param([Parameter(Mandatory)][object]$OpenChamberCommand)

    if (-not $OpenChamberCommand.available) {
        $reason = if ($OpenChamberCommand.validationError) { " $($OpenChamberCommand.validationError)" } else { '' }
        throw "Cannot start the desktop OpenChamber.exe because it is unavailable.$reason Pass -OpenChamberPath with the full path to OpenChamber.exe."
    }

    if (Test-RepairShouldProcess -Target $OpenChamberCommand.source -Action 'Start OpenChamber') {
        try {
            Start-Process -FilePath $OpenChamberCommand.source
            Add-ActionResult -Name 'StartOpenChamber' -Target $OpenChamberCommand.source -Status 'Completed'
            Add-Message -Level Success -Text "Started OpenChamber: $($OpenChamberCommand.source)"
        } catch {
            Add-ActionResult -Name 'StartOpenChamber' -Target $OpenChamberCommand.source -Status 'Failed' -Detail $_.Exception.Message
            throw
        }
    } else {
        Add-ActionResult -Name 'StartOpenChamber' -Target $OpenChamberCommand.source -Status 'WhatIf' -Detail 'ShouldProcess declined or -WhatIf was used.'
    }
}

$requestedActions = @(@($RefreshConfig, $RefreshPlugin, $StopProcesses, $StartOpenChamber) | Where-Object { $_ })
if ($requestedActions.Count -gt 0 -and -not $Repair) {
    throw 'Action switches require -Repair. Analysis mode is read-only.'
}
if ($Repair -and $requestedActions.Count -eq 0) {
    throw '-Repair requires at least one explicit action: -RefreshConfig, -RefreshPlugin, -StopProcesses, or -StartOpenChamber.'
}

$paths = Get-OpenCodePaths
$packageName = Get-PluginPackageName -Spec $PluginSpec
$cacheSlot = Resolve-ValidatedCacheSlot -CacheRoot $paths.cacheRoot -Spec $PluginSpec
$before = Get-Analysis -Paths $paths -CacheSlot $cacheSlot -PackageName $packageName
Write-HumanAnalysis -Analysis $before -Title 'OMO analysis'

$repairError = $null
try {
    if ($Repair) {
        if ($StopProcesses) {
            Stop-RelevantProcesses
        }
        if ($RefreshConfig) {
            Invoke-ConfigRefresh
        }
        if ($RefreshPlugin) {
            if (-not $WhatIfPreference) {
                $remainingProcesses = @(Get-RelevantProcesses)
                if ($remainingProcesses.Count -gt 0) {
                    $descriptions = @($remainingProcesses | ForEach-Object { "$($_.name) PID $($_.id)" }) -join ', '
                    if (-not $StopProcesses) {
                        throw "Cannot refresh the plugin while exact OpenChamber.exe or opencode.exe processes are running: $descriptions. Re-run with -Repair -RefreshPlugin -StopProcesses."
                    }
                    throw "Cannot refresh the plugin because matching processes remain after -StopProcesses: $descriptions. Resolve them before retrying."
                }
            }
            Invoke-PluginRefresh -CacheSlot $cacheSlot -OpenCodeCommand $before.executables.opencode
        }
        if ($StartOpenChamber) {
            $currentOpenChamber = Get-CommandInspection -Name 'OpenChamber.exe' -ExplicitPath $OpenChamberPath -RequireExactExeName
            Start-OpenChamberProcess -OpenChamberCommand $currentOpenChamber
        }
    }
} catch {
    $repairError = $_.Exception.Message
    Add-Message -Level Error -Text "Repair failed: $repairError"
} finally {
    if ($script:TemporaryInstallerPath -and (Test-Path -LiteralPath $script:TemporaryInstallerPath -PathType Leaf)) {
        if (Test-RepairShouldProcess -Target $script:TemporaryInstallerPath -Action 'Remove temporary downloaded installer') {
            Remove-Item -LiteralPath $script:TemporaryInstallerPath -Force -ErrorAction SilentlyContinue
        }
    }
}

$after = if ($Repair -and -not $WhatIfPreference) {
    Get-Analysis -Paths $paths -CacheSlot $cacheSlot -PackageName $packageName
} else {
    $before
}

if ($Repair) {
    Write-HumanAnalysis -Analysis $after -Title 'Post-repair verification'
    if ($after.verification.exactMatch) {
        Add-Message -Level Success -Text "Verified cached package name is exactly '$packageName' and version is exactly '$ExpectedVersion'."
    } elseif ($WhatIfPreference) {
        Add-Message -Level Info -Text 'WhatIf mode: no state was changed; post-repair verification reflects the original state.'
    } else {
        Add-Message -Level Warning -Text "Cached package identity mismatch: installed name '$($after.verification.installedName)' (expected '$packageName'), installed version '$($after.verification.installedVersion)' (expected '$ExpectedVersion')."
    }
} else {
    Add-Message -Level Info -Text 'Analysis only: no state was changed. Use -Repair with explicit action switches to make changes.'
}

$result = [pscustomobject][ordered]@{
    mode = if ($Repair) { 'repair' } else { 'analysis' }
    whatIf = [bool]$WhatIfPreference
    success = [string]::IsNullOrWhiteSpace($repairError)
    error = $repairError
    before = $before
    actions = @($script:Actions)
    after = $after
    messages = @($script:Messages)
}

if ($Json) {
    $result | ConvertTo-Json -Depth 20
}

if ($repairError) {
    exit 1
}
