#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$PayloadRoot,

    [Parameter()]
    [string]$OutputRoot = (Join-Path (Split-Path -Parent $PSScriptRoot) 'artifacts\reproducibility'),

    [Parameter()]
    [string]$WorkspaceRootDefault = 'C:\dev',

    [Parameter()]
    [string]$NsisRoot = 'C:\Program Files (x86)\NSIS',

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
$buildScript = Join-Path $repoRoot 'scripts\Build-WorkspaceBootstrapInstaller.ps1'
if (-not (Test-Path -LiteralPath $buildScript -PathType Leaf)) {
    throw "Required script not found: $buildScript"
}

$resolvedPayloadRoot = [System.IO.Path]::GetFullPath($PayloadRoot)
$resolvedOutputRoot = [System.IO.Path]::GetFullPath($OutputRoot)
Ensure-Directory -Path $resolvedOutputRoot

$installerPath = Join-Path $resolvedOutputRoot 'workspace-installer-deterministic.exe'
$reportPath = Join-Path $resolvedOutputRoot 'workspace-installer-determinism.json'
if (Test-Path -LiteralPath $installerPath -PathType Leaf) {
    Remove-Item -LiteralPath $installerPath -Force
}
if (Test-Path -LiteralPath $reportPath -PathType Leaf) {
    Remove-Item -LiteralPath $reportPath -Force
}

if ($PSBoundParameters.ContainsKey('SourceDateEpoch')) {
    & $buildScript `
        -PayloadRoot $resolvedPayloadRoot `
        -OutputPath $installerPath `
        -WorkspaceRootDefault $WorkspaceRootDefault `
        -NsisRoot $NsisRoot `
        -Deterministic $true `
        -VerifyDeterminism `
        -DeterminismReportPath $reportPath `
        -SourceDateEpoch $SourceDateEpoch
} else {
    & $buildScript `
        -PayloadRoot $resolvedPayloadRoot `
        -OutputPath $installerPath `
        -WorkspaceRootDefault $WorkspaceRootDefault `
        -NsisRoot $NsisRoot `
        -Deterministic $true `
        -VerifyDeterminism `
        -DeterminismReportPath $reportPath
}
if ($LASTEXITCODE -ne 0) {
    throw "Build-WorkspaceBootstrapInstaller determinism check failed with exit code $LASTEXITCODE."
}

if (-not (Test-Path -LiteralPath $installerPath -PathType Leaf)) {
    throw "Deterministic installer output missing: $installerPath"
}
if (-not (Test-Path -LiteralPath $reportPath -PathType Leaf)) {
    throw "Determinism report missing: $reportPath"
}

$report = Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json -ErrorAction Stop
if ([string]$report.status -ne 'pass') {
    throw "Installer determinism report status is '$($report.status)'."
}

$hash = (Get-FileHash -LiteralPath $installerPath -Algorithm SHA256).Hash.ToLowerInvariant()
$summaryPath = Join-Path $resolvedOutputRoot 'workspace-installer-determinism-summary.json'
[ordered]@{
    timestamp_utc = (Get-Date).ToUniversalTime().ToString('o')
    status = 'pass'
    output_path = $installerPath
    output_sha256 = $hash
    report_path = $reportPath
    report = $report
} | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $summaryPath -Encoding utf8

Write-Host "Workspace installer determinism summary: $summaryPath"
exit 0
