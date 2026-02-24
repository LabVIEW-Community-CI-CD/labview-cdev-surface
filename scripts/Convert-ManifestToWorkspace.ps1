[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ManifestPath,

    [Parameter(Mandatory = $true)]
    [string]$WorkspaceRoot,

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

$resolvedManifestPath = ConvertTo-NormalizedPath -Path $ManifestPath
if (-not (Test-Path -LiteralPath $resolvedManifestPath -PathType Leaf)) {
    throw "Manifest was not found: $resolvedManifestPath"
}

$resolvedWorkspaceRoot = ConvertTo-NormalizedPath -Path $WorkspaceRoot
$resolvedOutputPath = if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $resolvedManifestPath
} else {
    ConvertTo-NormalizedPath -Path $OutputPath
}

$manifest = Get-Content -LiteralPath $resolvedManifestPath -Raw | ConvertFrom-Json -ErrorAction Stop
$sourceWorkspaceRoot = [string]$manifest.workspace_root
if ([string]::IsNullOrWhiteSpace($sourceWorkspaceRoot)) {
    throw "Manifest does not define workspace_root: $resolvedManifestPath"
}

$normalizedSourceRoot = ConvertTo-NormalizedPath -Path $sourceWorkspaceRoot
$manifest.workspace_root = $resolvedWorkspaceRoot

$updatedRepoCount = 0
foreach ($repo in @($manifest.managed_repos)) {
    $repoPath = [string]$repo.path
    if ([string]::IsNullOrWhiteSpace($repoPath)) {
        throw "Managed repo path is empty in manifest: $resolvedManifestPath"
    }

    $fullRepoPath = ConvertTo-NormalizedPath -Path $repoPath
    if ($fullRepoPath.StartsWith($normalizedSourceRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        $suffix = $fullRepoPath.Substring($normalizedSourceRoot.Length).TrimStart('\\')
        $repo.path = if ([string]::IsNullOrWhiteSpace($suffix)) {
            $resolvedWorkspaceRoot
        } else {
            Join-Path $resolvedWorkspaceRoot $suffix
        }
        $updatedRepoCount++
    } else {
        $repo.path = $fullRepoPath
    }
}

$outputDir = Split-Path -Parent $resolvedOutputPath
if (-not [string]::IsNullOrWhiteSpace($outputDir) -and -not (Test-Path -LiteralPath $outputDir -PathType Container)) {
    New-Item -Path $outputDir -ItemType Directory -Force | Out-Null
}

$manifest | ConvertTo-Json -Depth 50 | Set-Content -LiteralPath $resolvedOutputPath -Encoding utf8

[pscustomobject]@{
    manifest_path = $resolvedManifestPath
    output_path = $resolvedOutputPath
    source_workspace_root = $normalizedSourceRoot
    target_workspace_root = $resolvedWorkspaceRoot
    updated_repo_count = $updatedRepoCount
    timestamp_utc = (Get-Date).ToUniversalTime().ToString('o')
}
