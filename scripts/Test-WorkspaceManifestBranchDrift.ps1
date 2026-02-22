#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter()]
    [string]$ManifestPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'workspace-governance.json'),

    [Parameter()]
    [string]$OutputPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'artifacts\workspace-drift\workspace-drift-report.json')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Initialize-GhToken {
    if (-not [string]::IsNullOrWhiteSpace($env:WORKFLOW_BOT_TOKEN)) {
        $env:GH_TOKEN = $env:WORKFLOW_BOT_TOKEN
        return 'WORKFLOW_BOT_TOKEN'
    }
    if (-not [string]::IsNullOrWhiteSpace($env:GH_TOKEN)) {
        return 'GH_TOKEN'
    }
    if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_TOKEN)) {
        $env:GH_TOKEN = $env:GITHUB_TOKEN
        return 'GITHUB_TOKEN'
    }
    return ''
}
$tokenSource = Initialize-GhToken

if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
    throw "Required command 'gh' was not found on PATH."
}

$resolvedManifestPath = [System.IO.Path]::GetFullPath($ManifestPath)
$resolvedOutputPath = [System.IO.Path]::GetFullPath($OutputPath)
if (-not (Test-Path -LiteralPath $resolvedManifestPath -PathType Leaf)) {
    throw "Manifest not found: $resolvedManifestPath"
}

$manifest = Get-Content -LiteralPath $resolvedManifestPath -Raw | ConvertFrom-Json -ErrorAction Stop
$checks = @()
$drifts = @()
$errors = @()

foreach ($repo in @($manifest.managed_repos)) {
    $repoSlug = [string]$repo.required_gh_repo
    $defaultBranch = [string]$repo.default_branch
    $pinnedSha = ([string]$repo.pinned_sha).ToLowerInvariant()
    $repoPath = [string]$repo.path

    $check = [ordered]@{
        path = $repoPath
        required_gh_repo = $repoSlug
        default_branch = $defaultBranch
        pinned_sha = $pinnedSha
        actual_default_branch_sha = ''
        status = 'unknown'
        message = ''
    }

    if ([string]::IsNullOrWhiteSpace($repoSlug) -or [string]::IsNullOrWhiteSpace($defaultBranch) -or $pinnedSha -notmatch '^[0-9a-f]{40}$') {
        $check.status = 'invalid_contract'
        $check.message = 'Manifest entry missing required_gh_repo/default_branch or has invalid pinned_sha.'
        $errors += "$repoPath :: $($check.message)"
        $checks += [pscustomobject]$check
        continue
    }

    $encodedBranch = [System.Uri]::EscapeDataString($defaultBranch)
    $actualShaOutput = & gh api "repos/$repoSlug/commits/$encodedBranch" --jq '.sha' 2>&1
    if ($LASTEXITCODE -ne 0) {
        $check.status = 'lookup_failed'
        $check.message = [string]::Join("`n", @($actualShaOutput))
        $errors += "{0}:{1} :: {2}" -f $repoSlug, $defaultBranch, $check.message
        $checks += [pscustomobject]$check
        continue
    }

    $actualSha = ([string]$actualShaOutput).Trim().ToLowerInvariant()
    $check.actual_default_branch_sha = $actualSha
    if ($actualSha -eq $pinnedSha) {
        $check.status = 'in_sync'
        $check.message = 'Default branch SHA matches manifest pin.'
    } else {
        $check.status = 'drifted'
        $check.message = 'Default branch SHA differs from manifest pin.'
        $drifts += "{0}:{1}" -f $repoSlug, $defaultBranch
    }

    $checks += [pscustomobject]$check
}

$status = 'in_sync'
if ($errors.Count -gt 0) {
    $status = 'error'
} elseif ($drifts.Count -gt 0) {
    $status = 'drift_detected'
}

$report = [ordered]@{
    timestamp_utc = (Get-Date).ToUniversalTime().ToString('o')
    manifest_path = $resolvedManifestPath
    token_source = $tokenSource
    status = $status
    drift_count = $drifts.Count
    error_count = $errors.Count
    checks = $checks
    drifts = $drifts
    errors = $errors
}

New-Item -Path (Split-Path -Parent $resolvedOutputPath) -ItemType Directory -Force | Out-Null
$report | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $resolvedOutputPath -Encoding UTF8
Write-Host "Workspace SHA drift report: $resolvedOutputPath"

if ($errors.Count -gt 0 -or $drifts.Count -gt 0) {
    exit 1
}

exit 0
