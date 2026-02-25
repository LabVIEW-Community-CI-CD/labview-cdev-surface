#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter()]
    [string]$Repository = 'LabVIEW-Community-CI-CD/labview-cdev-surface',

    [Parameter()]
    [string]$WorkflowFile = 'self-hosted-machine-certification.yml',

    [Parameter()]
    [string]$Ref = 'main',

    [Parameter()]
    [string[]]$SetupName = @(),

    [Parameter()]
    [string]$ProfilesPath = '',

    [Parameter()]
    [switch]$Watch,

    [Parameter()]
    [int]$DispatchPauseSeconds = 4,

    [Parameter()]
    [string]$OutputPath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-ProfilesPath {
    param([string]$InputPath)
    if (-not [string]::IsNullOrWhiteSpace($InputPath)) {
        return [System.IO.Path]::GetFullPath($InputPath)
    }
    $repoRoot = (Resolve-Path -Path (Join-Path $PSScriptRoot '..')).Path
    return (Join-Path $repoRoot 'tools\machine-certification\setup-profiles.json')
}

function Invoke-Gh {
    param([string[]]$Arguments)
    & gh @Arguments
    $exitCode = if ($null -eq $LASTEXITCODE) { 0 } else { [int]$LASTEXITCODE }
    if ($exitCode -ne 0) {
        throw "gh command failed with exit code ${exitCode}: gh $($Arguments -join ' ')"
    }
}

$resolvedProfilesPath = Resolve-ProfilesPath -InputPath $ProfilesPath
if (-not (Test-Path -LiteralPath $resolvedProfilesPath -PathType Leaf)) {
    throw "Setup profiles file not found: $resolvedProfilesPath"
}

$profilesDoc = Get-Content -LiteralPath $resolvedProfilesPath -Raw | ConvertFrom-Json -ErrorAction Stop
$allSetups = @($profilesDoc.setups)
if (@($allSetups).Count -eq 0) {
    throw "No setup profiles found in $resolvedProfilesPath"
}

$selectedSetups = @()
if (@($SetupName).Count -gt 0) {
    foreach ($name in $SetupName) {
        $candidate = @($allSetups | Where-Object { [string]$_.name -eq [string]$name }) | Select-Object -First 1
        if ($null -eq $candidate) {
            throw "Unknown setup profile '$name' in $resolvedProfilesPath"
        }
        $selectedSetups += $candidate
    }
} else {
    $selectedSetups = @($allSetups | Where-Object { $_.active -eq $true })
}

if (@($selectedSetups).Count -eq 0) {
    throw "No active setup profiles selected."
}

$dispatchRecords = @()
$claimedRunIds = @{}
foreach ($setup in $selectedSetups) {
    $setupNameToken = [string]$setup.name
    Write-Host ("Dispatching setup: {0}" -f $setupNameToken)
    $dispatchStartUtc = (Get-Date).ToUniversalTime()

    $dispatchArgs = @(
        'workflow', 'run', $WorkflowFile,
        '-R', $Repository,
        '--ref', $Ref,
        '-f', ("setup_name={0}" -f $setupNameToken),
        '-f', ("runner_labels_json={0}" -f ([string]$setup.runner_labels_json)),
        '-f', ("expected_labview_year={0}" -f ([string]$setup.expected_labview_year)),
        '-f', ("docker_context={0}" -f ([string]$setup.docker_context)),
        '-f', ("skip_host_ini_mutation={0}" -f ([string]$setup.skip_host_ini_mutation).ToLowerInvariant()),
        '-f', ("skip_override_phase={0}" -f ([string]$setup.skip_override_phase).ToLowerInvariant())
    )
    Invoke-Gh -Arguments $dispatchArgs

    Start-Sleep -Seconds $DispatchPauseSeconds

    $runJson = gh run list -R $Repository --workflow $WorkflowFile --branch $Ref --event workflow_dispatch --limit 50 --json databaseId,status,conclusion,url,displayTitle,createdAt
    $runList = @($runJson | ConvertFrom-Json -ErrorAction Stop)
    $candidateRuns = @(
        $runList |
        Where-Object {
            $runId = [string]$_.databaseId
            if ([string]::IsNullOrWhiteSpace($runId)) { return $false }
            if ($claimedRunIds.ContainsKey($runId)) { return $false }
            $createdAt = [DateTimeOffset]::MinValue
            if (-not [DateTimeOffset]::TryParse([string]$_.createdAt, [ref]$createdAt)) { return $false }
            return ($createdAt.UtcDateTime -ge $dispatchStartUtc.AddMinutes(-2))
        } |
        Sort-Object -Property createdAt -Descending
    )
    $run = $candidateRuns | Select-Object -First 1
    if ($null -eq $run -and @($runList).Count -gt 0) {
        $run = @(
            $runList |
            Where-Object { -not $claimedRunIds.ContainsKey([string]$_.databaseId) } |
            Sort-Object -Property createdAt -Descending
        ) | Select-Object -First 1
    }
    if ($null -ne $run -and -not [string]::IsNullOrWhiteSpace([string]$run.databaseId)) {
        $claimedRunIds[[string]$run.databaseId] = $true
    }

    $record = [ordered]@{
        setup_name = $setupNameToken
        run_id = if ($null -ne $run) { [string]$run.databaseId } else { '' }
        run_url = if ($null -ne $run) { [string]$run.url } else { '' }
        run_created_at = if ($null -ne $run) { [string]$run.createdAt } else { '' }
        status = if ($null -ne $run) { [string]$run.status } else { 'unknown' }
        conclusion = if ($null -ne $run) { [string]$run.conclusion } else { '' }
    }
    $dispatchRecords += [pscustomobject]$record

    if ($Watch -and $null -ne $run -and -not [string]::IsNullOrWhiteSpace([string]$run.databaseId)) {
        Invoke-Gh -Arguments @('run', 'watch', [string]$run.databaseId, '-R', $Repository)
    }
}

$report = [ordered]@{
    timestamp_utc = (Get-Date).ToUniversalTime().ToString('o')
    repository = $Repository
    workflow = $WorkflowFile
    ref = $Ref
    profiles_path = $resolvedProfilesPath
    dispatched_setups = @($selectedSetups | ForEach-Object { [string]$_.name })
    runs = @($dispatchRecords)
}

if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
    $resolvedOutputPath = [System.IO.Path]::GetFullPath($OutputPath)
    $parent = Split-Path -Path $resolvedOutputPath -Parent
    if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -Path $parent -ItemType Directory -Force | Out-Null
    }
    $report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $resolvedOutputPath -Encoding utf8
    Write-Host ("Dispatch report written: {0}" -f $resolvedOutputPath)
}

$report | ConvertTo-Json -Depth 8 | Write-Output
