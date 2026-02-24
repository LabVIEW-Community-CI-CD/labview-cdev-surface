[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$RepoOriginUrl,

    [Parameter(Mandatory = $true)]
    [string]$PinnedSha,

    [Parameter(Mandatory = $true)]
    [string]$TargetRepoPath,

    [Parameter()]
    [string]$RepoName = 'repo',

    [Parameter()]
    [string]$SourceRepoPath,

    [Parameter()]
    [string]$DefaultBranch,

    [Parameter()]
    [string]$OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function ConvertTo-NormalizedPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    $full = [System.IO.Path]::GetFullPath($Path)
    if ($full.Length -gt 3 -and $full.EndsWith('\\')) {
        $full = $full.TrimEnd('\\')
    }
    return $full
}

function Ensure-Directory {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        New-Item -Path $Path -ItemType Directory -Force | Out-Null
    }
}

function Remove-Directory {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (Test-Path -LiteralPath $Path -PathType Container) {
        Remove-Item -LiteralPath $Path -Recurse -Force
    }
}

function Add-GitSafeDirectory {
    param([Parameter(Mandatory = $true)][string]$Path)

    & git config --global --add safe.directory $Path 2>$null
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to configure git safe.directory for '$Path'."
    }
}

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    throw "Required command 'git' was not found on PATH."
}

if ([string]::IsNullOrWhiteSpace($RepoOriginUrl)) {
    throw 'RepoOriginUrl is required.'
}

$pinned = ([string]$PinnedSha).Trim().ToLowerInvariant()
if ($pinned -notmatch '^[0-9a-f]{40}$') {
    throw "PinnedSha must be a 40-character lowercase SHA-1. Received '$PinnedSha'."
}

$resolvedTargetPath = ConvertTo-NormalizedPath -Path $TargetRepoPath
$targetParent = Split-Path -Parent $resolvedTargetPath
Ensure-Directory -Path $targetParent

$resolvedSourcePath = $null
if (-not [string]::IsNullOrWhiteSpace($SourceRepoPath)) {
    $resolvedSourcePath = ConvertTo-NormalizedPath -Path $SourceRepoPath
}

$worktreeAttempted = $false
$worktreeError = ''
$provisionMode = 'detached-clone'

Remove-Directory -Path $resolvedTargetPath

$canUseWorktree = $false
if (-not [string]::IsNullOrWhiteSpace($resolvedSourcePath) -and (Test-Path -LiteralPath $resolvedSourcePath -PathType Container)) {
    if (Test-Path -LiteralPath (Join-Path $resolvedSourcePath '.git')) {
        $canUseWorktree = $true
    }
}

if ($canUseWorktree) {
    $worktreeAttempted = $true
    Add-GitSafeDirectory -Path $resolvedSourcePath

    if (-not [string]::IsNullOrWhiteSpace($DefaultBranch)) {
        & git -C $resolvedSourcePath fetch --no-tags --quiet origin $DefaultBranch
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to fetch origin/$DefaultBranch for source repo '$resolvedSourcePath'."
        }
    }

    & git -C $resolvedSourcePath fetch --no-tags --quiet origin $pinned
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to fetch pinned SHA '$pinned' for source repo '$resolvedSourcePath'."
    }

    $worktreeOutput = & git -C $resolvedSourcePath worktree add --detach $resolvedTargetPath $pinned 2>&1
    if ($LASTEXITCODE -eq 0) {
        $provisionMode = 'worktree'
    } else {
        $worktreeError = [string]::Join("`n", @($worktreeOutput | ForEach-Object { [string]$_ }))
        Remove-Directory -Path $resolvedTargetPath
    }
}

if ($provisionMode -ne 'worktree') {
    & git clone --quiet --no-tags $RepoOriginUrl $resolvedTargetPath
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to clone '$RepoOriginUrl' into '$resolvedTargetPath'."
    }

    & git -C $resolvedTargetPath fetch --no-tags --quiet origin $pinned
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to fetch pinned SHA '$pinned' for target repo '$resolvedTargetPath'."
    }

    & git -C $resolvedTargetPath checkout --quiet --detach $pinned
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to checkout pinned SHA '$pinned' in '$resolvedTargetPath'."
    }
}

Add-GitSafeDirectory -Path $resolvedTargetPath

$result = [ordered]@{
    repo_name = [string]$RepoName
    repo_origin_url = [string]$RepoOriginUrl
    pinned_sha = $pinned
    default_branch = [string]$DefaultBranch
    source_repo_path = [string]$resolvedSourcePath
    target_repo_path = $resolvedTargetPath
    provision_mode = $provisionMode
    worktree_attempted = $worktreeAttempted
    worktree_error = [string]$worktreeError
    timestamp_utc = (Get-Date).ToUniversalTime().ToString('o')
}

if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
    $resolvedOutputPath = ConvertTo-NormalizedPath -Path $OutputPath
    $outputDir = Split-Path -Parent $resolvedOutputPath
    if (-not [string]::IsNullOrWhiteSpace($outputDir)) {
        Ensure-Directory -Path $outputDir
    }
    $result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $resolvedOutputPath -Encoding utf8
}

[pscustomobject]$result
