#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter()]
    [string]$ManifestPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'workspace-governance.json'),

    [Parameter()]
    [string]$RepoName = 'labview-icon-editor',

    [Parameter()]
    [string]$Runtime = 'win-x64',

    [Parameter()]
    [string]$OutputRoot = (Join-Path (Split-Path -Parent $PSScriptRoot) 'artifacts\reproducibility'),

    [Parameter()]
    [long]$SourceDateEpoch
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Ensure-Directory {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        New-Item -Path $Path -ItemType Directory -Force | Out-Null
    }
}

$repoRoot = (Resolve-Path -Path (Join-Path $PSScriptRoot '..')).Path
$bundleScript = Join-Path $repoRoot 'scripts\Build-RunnerCliBundleFromManifest.ps1'
if (-not (Test-Path -LiteralPath $bundleScript -PathType Leaf)) {
    throw "Required script not found: $bundleScript"
}

$resolvedManifestPath = [System.IO.Path]::GetFullPath($ManifestPath)
$resolvedOutputRoot = [System.IO.Path]::GetFullPath($OutputRoot)
Ensure-Directory -Path $resolvedOutputRoot

$runRoot = Join-Path $resolvedOutputRoot ("runner-cli-{0}" -f $Runtime)
if (Test-Path -LiteralPath $runRoot -PathType Container) {
    Remove-Item -LiteralPath $runRoot -Recurse -Force
}
Ensure-Directory -Path $runRoot

$results = @()
foreach ($index in 1..2) {
    $outDir = Join-Path $runRoot ("build-{0}" -f $index)
    Ensure-Directory -Path $outDir
    if ($PSBoundParameters.ContainsKey('SourceDateEpoch')) {
        & $bundleScript `
            -ManifestPath $resolvedManifestPath `
            -OutputRoot $outDir `
            -RepoName $RepoName `
            -Runtime $Runtime `
            -Deterministic $true `
            -SourceDateEpoch $SourceDateEpoch
    } else {
        & $bundleScript `
            -ManifestPath $resolvedManifestPath `
            -OutputRoot $outDir `
            -RepoName $RepoName `
            -Runtime $Runtime `
            -Deterministic $true
    }
    if ($LASTEXITCODE -ne 0) {
        throw "Build-RunnerCliBundleFromManifest failed for run $index with exit code $LASTEXITCODE."
    }

    $exePath = Join-Path $outDir 'runner-cli.exe'
    if (-not (Test-Path -LiteralPath $exePath -PathType Leaf)) {
        throw "runner-cli executable missing in build output: $exePath"
    }
    $metadataPath = Join-Path $outDir 'runner-cli.metadata.json'
    if (-not (Test-Path -LiteralPath $metadataPath -PathType Leaf)) {
        throw "runner-cli metadata missing in build output: $metadataPath"
    }
    $hash = (Get-FileHash -LiteralPath $exePath -Algorithm SHA256).Hash.ToLowerInvariant()
    $metadata = Get-Content -LiteralPath $metadataPath -Raw | ConvertFrom-Json -ErrorAction Stop
    $results += [pscustomobject]@{
        build_index = $index
        output_root = $outDir
        sha256 = $hash
        metadata = $metadata
    }
}

$status = if ($results[0].sha256 -eq $results[1].sha256) { 'pass' } else { 'fail' }
$reportPath = Join-Path $resolvedOutputRoot ("runner-cli-determinism-{0}.json" -f $Runtime)
[ordered]@{
    timestamp_utc = (Get-Date).ToUniversalTime().ToString('o')
    status = $status
    runtime = $Runtime
    repo_name = $RepoName
    manifest_path = $resolvedManifestPath
    output_root = $runRoot
    hash_1 = $results[0].sha256
    hash_2 = $results[1].sha256
    deterministic = ($status -eq 'pass')
    results = $results
} | ConvertTo-Json -Depth 16 | Set-Content -LiteralPath $reportPath -Encoding utf8

Write-Host "Runner CLI determinism report: $reportPath"

if ($status -ne 'pass') {
    exit 1
}

exit 0
