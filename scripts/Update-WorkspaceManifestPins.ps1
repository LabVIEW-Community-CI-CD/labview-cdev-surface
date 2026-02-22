#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter()]
    [string]$ManifestPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'workspace-governance.json'),

    [Parameter()]
    [string]$OutputPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'artifacts\workspace-drift\workspace-sha-refresh-report.json'),

    [Parameter()]
    [switch]$WriteChanges
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
$changes = @()
$errors = @()

foreach ($repo in @($manifest.managed_repos)) {
    $repoPath = [string]$repo.path
    $repoSlug = [string]$repo.required_gh_repo
    $defaultBranch = [string]$repo.default_branch
    $currentPinnedSha = ([string]$repo.pinned_sha).ToLowerInvariant()

    $check = [ordered]@{
        path = $repoPath
        required_gh_repo = $repoSlug
        default_branch = $defaultBranch
        previous_pinned_sha = $currentPinnedSha
        latest_default_branch_sha = ''
        status = 'unknown'
        message = ''
    }

    if ([string]::IsNullOrWhiteSpace($repoSlug) -or [string]::IsNullOrWhiteSpace($defaultBranch) -or $currentPinnedSha -notmatch '^[0-9a-f]{40}$') {
        $check.status = 'invalid_contract'
        $check.message = 'Manifest entry missing required_gh_repo/default_branch or has invalid pinned_sha.'
        $errors += "$repoPath :: $($check.message)"
        $checks += [pscustomobject]$check
        continue
    }

    $encodedBranch = [System.Uri]::EscapeDataString($defaultBranch)
    $latestShaOutput = & gh api "repos/$repoSlug/commits/$encodedBranch" --jq '.sha' 2>&1
    if ($LASTEXITCODE -ne 0) {
        $check.status = 'lookup_failed'
        $check.message = [string]::Join("`n", @($latestShaOutput))
        $errors += "{0}:{1} :: {2}" -f $repoSlug, $defaultBranch, $check.message
        $checks += [pscustomobject]$check
        continue
    }

    $latestSha = ([string]$latestShaOutput).Trim().ToLowerInvariant()
    $check.latest_default_branch_sha = $latestSha
    if ($latestSha -notmatch '^[0-9a-f]{40}$') {
        $check.status = 'lookup_invalid'
        $check.message = "Latest branch SHA is invalid: '$latestSha'"
        $errors += "{0}:{1} :: {2}" -f $repoSlug, $defaultBranch, $check.message
        $checks += [pscustomobject]$check
        continue
    }

    if ($latestSha -eq $currentPinnedSha) {
        $check.status = 'in_sync'
        $check.message = 'Pinned SHA already matches default branch head.'
    } else {
        $check.status = 'updated'
        $check.message = 'Pinned SHA updated to latest default branch head.'
        if ($WriteChanges) {
            $repo.pinned_sha = $latestSha
        }
        $changes += [pscustomobject]@{
            path = $repoPath
            required_gh_repo = $repoSlug
            default_branch = $defaultBranch
            previous_pinned_sha = $currentPinnedSha
            new_pinned_sha = $latestSha
        }
    }

    $checks += [pscustomobject]$check
}

if ($WriteChanges -and $errors.Count -eq 0 -and $changes.Count -gt 0) {
    $manifest | ConvertTo-Json -Depth 50 | Set-Content -LiteralPath $resolvedManifestPath -Encoding utf8
}

$status = if ($errors.Count -gt 0) { 'error' } elseif ($changes.Count -gt 0) { if ($WriteChanges) { 'updated' } else { 'drift_detected' } } else { 'no_changes' }

$report = [ordered]@{
    timestamp_utc = (Get-Date).ToUniversalTime().ToString('o')
    manifest_path = $resolvedManifestPath
    output_path = $resolvedOutputPath
    token_source = $tokenSource
    write_changes = [bool]$WriteChanges
    status = $status
    changed = ($changes.Count -gt 0)
    change_count = $changes.Count
    error_count = $errors.Count
    checks = $checks
    changes = $changes
    errors = $errors
}

New-Item -Path (Split-Path -Parent $resolvedOutputPath) -ItemType Directory -Force | Out-Null
$report | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $resolvedOutputPath -Encoding utf8
Write-Host "Workspace SHA refresh report: $resolvedOutputPath"

if ($errors.Count -gt 0) {
    exit 1
}

exit 0
