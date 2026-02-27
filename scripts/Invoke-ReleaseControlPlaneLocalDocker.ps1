#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter()]
    [ValidatePattern('^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$')]
    [string]$Repository = 'LabVIEW-Community-CI-CD/labview-cdev-surface-fork',

    [Parameter()]
    [ValidatePattern('^[A-Za-z0-9._/-]+$')]
    [string]$Branch = 'main',

    [Parameter()]
    [ValidateSet('Validate', 'CanaryCycle', 'PromotePrerelease', 'PromoteStable', 'FullCycle')]
    [string]$Mode = 'Validate',

    [Parameter()]
    [ValidateRange(1, 168)]
    [int]$SyncGuardMaxAgeHours = 12,

    [Parameter()]
    [ValidateRange(1, 10)]
    [int]$KeepLatestCanaryN = 1,

    [Parameter()]
    [switch]$IncludeOpsAutoRemediation,

    [Parameter()]
    [switch]$RunContractTests,

    [Parameter()]
    [switch]$DryRun,

    [Parameter()]
    [switch]$AllowMutatingModes,

    [Parameter()]
    [string]$OutputRoot = 'artifacts/release-control-plane-local',

    [Parameter()]
    [string]$Image = 'ghcr.io/svelderrainruiz/labview-cdev-surface-ops:v1',

    [Parameter()]
    [switch]$BuildLocalImage,

    [Parameter()]
    [string]$LocalTag = 'labview-cdev-surface-ops:local',

    [Parameter()]
    [switch]$HostFallback
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$portableWrapper = Join-Path $PSScriptRoot 'Invoke-PortableOps.ps1'
if (-not (Test-Path -LiteralPath $portableWrapper -PathType Leaf)) {
    throw "portable_wrapper_missing: $portableWrapper"
}

$scriptArgs = @(
    '-Repository', $Repository,
    '-Branch', $Branch,
    '-Mode', $Mode,
    '-SyncGuardMaxAgeHours', [string]$SyncGuardMaxAgeHours,
    '-KeepLatestCanaryN', [string]$KeepLatestCanaryN,
    '-OutputRoot', $OutputRoot
)
if ($IncludeOpsAutoRemediation) {
    $scriptArgs += '-IncludeOpsAutoRemediation'
}
if ($RunContractTests) {
    $scriptArgs += '-RunContractTests'
}
if ($DryRun) {
    $scriptArgs += '-DryRun'
}
if ($AllowMutatingModes) {
    $scriptArgs += '-AllowMutatingModes'
}

& $portableWrapper `
    -ScriptPath 'scripts/Exercise-ReleaseControlPlaneLocal.ps1' `
    -ScriptArguments $scriptArgs `
    -Image $Image `
    -BuildLocalImage:$BuildLocalImage `
    -LocalTag $LocalTag `
    -HostFallback:$HostFallback

exit $LASTEXITCODE
