#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$SpdxPath,

    [Parameter(Mandatory = $true)]
    [string]$SlsaPath,

    [Parameter(Mandatory = $true)]
    [string]$InstallerPath,

    [Parameter(Mandatory = $true)]
    [string]$RunnerCliPath,

    [Parameter(Mandatory = $true)]
    [string]$ManifestPath,

    [Parameter()]
    [string]$OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-SubjectHash {
    param([Parameter(Mandatory = $true)][string]$Path)
    $resolved = [System.IO.Path]::GetFullPath($Path)
    if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
        throw "Subject file not found: $resolved"
    }
    return (Get-FileHash -LiteralPath $resolved -Algorithm SHA256).Hash.ToLowerInvariant()
}

$resolvedSpdxPath = [System.IO.Path]::GetFullPath($SpdxPath)
$resolvedSlsaPath = [System.IO.Path]::GetFullPath($SlsaPath)
$resolvedInstallerPath = [System.IO.Path]::GetFullPath($InstallerPath)
$resolvedRunnerCliPath = [System.IO.Path]::GetFullPath($RunnerCliPath)
$resolvedManifestPath = [System.IO.Path]::GetFullPath($ManifestPath)

foreach ($path in @($resolvedSpdxPath, $resolvedSlsaPath, $resolvedInstallerPath, $resolvedRunnerCliPath, $resolvedManifestPath)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Required file not found: $path"
    }
}

$spdx = Get-Content -LiteralPath $resolvedSpdxPath -Raw | ConvertFrom-Json -ErrorAction Stop
$slsa = Get-Content -LiteralPath $resolvedSlsaPath -Raw | ConvertFrom-Json -ErrorAction Stop

$requiredSubjects = @(
    [pscustomobject]@{ name = (Split-Path -Path $resolvedInstallerPath -Leaf); path = $resolvedInstallerPath; sha256 = (Resolve-SubjectHash -Path $resolvedInstallerPath) },
    [pscustomobject]@{ name = (Split-Path -Path $resolvedRunnerCliPath -Leaf); path = $resolvedRunnerCliPath; sha256 = (Resolve-SubjectHash -Path $resolvedRunnerCliPath) },
    [pscustomobject]@{ name = (Split-Path -Path $resolvedManifestPath -Leaf); path = $resolvedManifestPath; sha256 = (Resolve-SubjectHash -Path $resolvedManifestPath) }
)

$failures = @()
$checks = @()

function Add-Check {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][bool]$Passed,
        [Parameter()][string]$Detail = ''
    )
    $script:checks += [pscustomobject]@{
        check = $Name
        passed = $Passed
        detail = $Detail
    }
    if (-not $Passed) {
        $script:failures += ("{0} :: {1}" -f $Name, $Detail)
    }
}

Add-Check -Name 'spdx_version' -Passed ([string]$spdx.spdxVersion -eq 'SPDX-2.3') -Detail ([string]$spdx.spdxVersion)
Add-Check -Name 'slsa_predicate_type' -Passed ([string]$slsa.predicateType -eq 'https://slsa.dev/provenance/v1') -Detail ([string]$slsa.predicateType)

$spdxFiles = @($spdx.files)
$slsaSubjects = @($slsa.subject)

foreach ($subject in $requiredSubjects) {
    $spdxMatch = $spdxFiles | Where-Object { [string]$_.fileName -eq $subject.path }
    Add-Check -Name ("spdx_contains_subject:{0}" -f $subject.name) -Passed ($null -ne $spdxMatch) -Detail $subject.path
    if ($null -ne $spdxMatch) {
        $spdxChecksum = @($spdxMatch.checksums | Where-Object { [string]$_.algorithm -eq 'SHA256' } | Select-Object -First 1).checksumValue
        Add-Check -Name ("spdx_hash_match:{0}" -f $subject.name) -Passed ([string]$spdxChecksum -eq $subject.sha256) -Detail ("expected={0};actual={1}" -f $subject.sha256, [string]$spdxChecksum)
    }

    $slsaMatch = $slsaSubjects | Where-Object { [string]$_.name -eq $subject.name }
    Add-Check -Name ("slsa_contains_subject:{0}" -f $subject.name) -Passed ($null -ne $slsaMatch) -Detail $subject.name
    if ($null -ne $slsaMatch) {
        $slsaHash = [string]$slsaMatch.digest.sha256
        Add-Check -Name ("slsa_hash_match:{0}" -f $subject.name) -Passed ($slsaHash -eq $subject.sha256) -Detail ("expected={0};actual={1}" -f $subject.sha256, $slsaHash)
    }
}

$status = if ($failures.Count -eq 0) { 'pass' } else { 'fail' }
$report = [ordered]@{
    timestamp_utc = (Get-Date).ToUniversalTime().ToString('o')
    status = $status
    spdx_path = $resolvedSpdxPath
    slsa_path = $resolvedSlsaPath
    checks = $checks
    failures = $failures
}

if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
    $resolvedOutputPath = [System.IO.Path]::GetFullPath($OutputPath)
    $reportDir = Split-Path -Path $resolvedOutputPath -Parent
    if (-not [string]::IsNullOrWhiteSpace($reportDir) -and -not (Test-Path -LiteralPath $reportDir -PathType Container)) {
        New-Item -Path $reportDir -ItemType Directory -Force | Out-Null
    }
    $report | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $resolvedOutputPath -Encoding utf8
    Write-Host "Provenance contract report: $resolvedOutputPath"
} else {
    $report | ConvertTo-Json -Depth 10 | Write-Output
}

if ($status -ne 'pass') {
    exit 1
}

exit 0
