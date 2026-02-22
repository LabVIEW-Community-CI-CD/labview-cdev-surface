#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter()]
    [string]$ExpectedLabviewYear = '2020',

    [Parameter()]
    [string]$DockerContext = 'desktop-linux',

    [Parameter()]
    [string]$NsisPath = 'C:\Program Files (x86)\NSIS\makensis.exe',

    [Parameter()]
    [string]$OutputPath = '',

    [Parameter()]
    [switch]$FailOnWarning
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$checks = @()
$errors = @()
$warnings = @()

function Add-Check {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][bool]$Passed,
        [Parameter(Mandatory = $true)][string]$Detail,
        [Parameter()][ValidateSet('error', 'warning')][string]$Severity = 'error'
    )

    $entry = [ordered]@{
        check = $Name
        passed = $Passed
        severity = $Severity
        detail = $Detail
    }
    $script:checks += [pscustomobject]$entry

    if (-not $Passed) {
        if ($Severity -eq 'warning') {
            $script:warnings += "$Name :: $Detail"
        } else {
            $script:errors += "$Name :: $Detail"
        }
    }
}

foreach ($commandName in @('pwsh', 'git', 'gh', 'g-cli', 'vipm', 'docker')) {
    $command = Get-Command $commandName -ErrorAction SilentlyContinue
    $commandDetail = if ($null -ne $command) { [string]$command.Source } else { 'missing on PATH' }
    Add-Check `
        -Name ("command:{0}" -f $commandName) `
        -Passed ($null -ne $command) `
        -Detail $commandDetail
}

$nsisResolved = $NsisPath
if (-not (Test-Path -LiteralPath $nsisResolved -PathType Leaf)) {
    $makensis = Get-Command makensis -ErrorAction SilentlyContinue
    if ($null -ne $makensis) {
        $nsisResolved = $makensis.Source
    }
}
Add-Check `
    -Name 'command:makensis' `
    -Passed (Test-Path -LiteralPath $nsisResolved -PathType Leaf) `
    -Detail $nsisResolved

$labview64 = "C:\Program Files\National Instruments\LabVIEW $ExpectedLabviewYear"
$labview32 = "C:\Program Files (x86)\National Instruments\LabVIEW $ExpectedLabviewYear"
Add-Check -Name 'labview:x64' -Passed (Test-Path -LiteralPath $labview64 -PathType Container) -Detail $labview64
Add-Check -Name 'labview:x86' -Passed (Test-Path -LiteralPath $labview32 -PathType Container) -Detail $labview32

$dockerContextExists = $false
$dockerContextInspectOutput = ''
if (Get-Command docker -ErrorAction SilentlyContinue) {
    $dockerContextInspectOutput = (& docker context inspect $DockerContext 2>&1 | Out-String)
    if ($LASTEXITCODE -eq 0) {
        $dockerContextExists = $true
    }
}
Add-Check `
    -Name 'docker:context_exists' `
    -Passed $dockerContextExists `
    -Detail ("context={0}" -f $DockerContext)

$dockerContextReachable = $false
$dockerInfoDetail = ''
if ($dockerContextExists) {
    $dockerInfoOutput = (& docker --context $DockerContext info --format '{{.ServerVersion}}|{{.OSType}}' 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -eq 0) {
        $dockerContextReachable = $true
        $dockerInfoDetail = $dockerInfoOutput
    } else {
        $dockerInfoDetail = $dockerInfoOutput
    }
} else {
    $dockerInfoDetail = $dockerContextInspectOutput.Trim()
}
Add-Check `
    -Name 'docker:context_reachable' `
    -Passed $dockerContextReachable `
    -Detail ("context={0}; detail={1}" -f $DockerContext, $dockerInfoDetail)

$status = if ($errors.Count -gt 0) { 'failed' } else { 'succeeded' }
$report = [ordered]@{
    timestamp_utc = (Get-Date).ToUniversalTime().ToString('o')
    expected_labview_year = $ExpectedLabviewYear
    docker_context = $DockerContext
    nsis_path = $nsisResolved
    status = $status
    summary = [ordered]@{
        checks = $checks.Count
        errors = $errors.Count
        warnings = $warnings.Count
    }
    checks = $checks
    errors = $errors
    warnings = $warnings
}

if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
    $resolvedOutput = [System.IO.Path]::GetFullPath($OutputPath)
    $outputDir = Split-Path -Path $resolvedOutput -Parent
    if (-not [string]::IsNullOrWhiteSpace($outputDir) -and -not (Test-Path -LiteralPath $outputDir -PathType Container)) {
        New-Item -Path $outputDir -ItemType Directory -Force | Out-Null
    }
    $report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $resolvedOutput -Encoding utf8
    Write-Host "Machine preflight report: $resolvedOutput"
} else {
    $report | ConvertTo-Json -Depth 8 | Write-Output
}

if ($errors.Count -gt 0) {
    exit 1
}
if ($FailOnWarning -and $warnings.Count -gt 0) {
    exit 1
}

exit 0
