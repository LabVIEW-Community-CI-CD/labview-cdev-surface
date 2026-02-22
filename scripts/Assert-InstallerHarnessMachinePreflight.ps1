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
    [ValidateSet('error', 'warning')]
    [string]$DockerCheckSeverity = 'error',

    [Parameter()]
    [switch]$FailOnWarning
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$checks = @()
$errors = @()
$warnings = @()
$resolvedTools = @{}

$toolFallbackMap = @{
    'pwsh' = @(
        (Join-Path $PSHOME 'pwsh.exe'),
        'C:\Program Files\PowerShell\7\pwsh.exe'
    )
    'git' = @(
        'C:\Program Files\Git\cmd\git.exe'
    )
    'gh' = @(
        'C:\Program Files\GitHub CLI\gh.exe'
    )
    'g-cli' = @(
        'C:\Program Files\G-CLI\bin\g-cli.exe'
    )
    'vipm' = @(
        'C:\Program Files\JKI\VI Package Manager\support\vipm.exe'
    )
    'docker' = @(
        'C:\Program Files\Docker\Docker\resources\bin\docker.exe'
    )
}

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

function Resolve-Tool {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter()][string[]]$FallbackPaths = @()
    )

    $command = Get-Command $Name -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -ne $command) {
        return [pscustomobject]@{
            found = $true
            path = [string]$command.Source
            source = 'PATH'
        }
    }

    foreach ($fallbackPath in @($FallbackPaths)) {
        if (-not [string]::IsNullOrWhiteSpace($fallbackPath) -and (Test-Path -LiteralPath $fallbackPath -PathType Leaf)) {
            return [pscustomobject]@{
                found = $true
                path = [string]$fallbackPath
                source = 'fallback'
            }
        }
    }

    return [pscustomobject]@{
        found = $false
        path = 'missing'
        source = 'missing'
    }
}

foreach ($commandName in @('pwsh', 'git', 'gh', 'g-cli', 'vipm', 'docker')) {
    $resolved = Resolve-Tool -Name $commandName -FallbackPaths @($toolFallbackMap[$commandName])
    $resolvedTools[$commandName] = $resolved
    $commandDetail = "{0} [{1}]" -f $resolved.path, $resolved.source
    $severity = if ($commandName -eq 'docker') { $DockerCheckSeverity } else { 'error' }
    Add-Check `
        -Name ("command:{0}" -f $commandName) `
        -Passed ([bool]$resolved.found) `
        -Detail $commandDetail `
        -Severity $severity
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
$dockerTool = $resolvedTools['docker']
if ($null -ne $dockerTool -and [bool]$dockerTool.found) {
    $dockerContextInspectOutput = (& $dockerTool.path context inspect $DockerContext 2>&1 | Out-String)
    if ($LASTEXITCODE -eq 0) {
        $dockerContextExists = $true
    }
}
Add-Check `
    -Name 'docker:context_exists' `
    -Passed $dockerContextExists `
    -Detail ("context={0}" -f $DockerContext) `
    -Severity $DockerCheckSeverity

$dockerContextReachable = $false
$dockerInfoDetail = ''
if ($dockerContextExists) {
    $dockerInfoOutput = (& $dockerTool.path --context $DockerContext info --format '{{.ServerVersion}}|{{.OSType}}' 2>&1 | Out-String).Trim()
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
    -Detail ("context={0}; detail={1}" -f $DockerContext, $dockerInfoDetail) `
    -Severity $DockerCheckSeverity

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
