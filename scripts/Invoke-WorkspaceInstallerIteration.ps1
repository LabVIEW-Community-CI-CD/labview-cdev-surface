#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter()]
    [ValidateSet('fast', 'full')]
    [string]$Mode = 'fast',

    [Parameter()]
    [ValidateRange(1, 50)]
    [int]$Iterations = 1,

    [Parameter()]
    [switch]$Watch,

    [Parameter()]
    [ValidateRange(1, 3600)]
    [int]$PollSeconds = 10,

    [Parameter()]
    [ValidateRange(0, 500)]
    [int]$MaxRuns = 0,

    [Parameter()]
    [string]$OutputRoot = (Join-Path (Split-Path -Parent $PSScriptRoot) 'artifacts\release\iteration'),

    [Parameter()]
    [string]$SmokeWorkspaceRoot = 'C:\dev-smoke-lvie',

    [Parameter()]
    [switch]$KeepSmokeWorkspace,

    [Parameter()]
    [string]$NsisRoot = 'C:\Program Files (x86)\NSIS'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Ensure-Directory {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        New-Item -Path $Path -ItemType Directory -Force | Out-Null
    }
}

function Get-WorkspaceFingerprint {
    param([Parameter(Mandatory = $true)][string]$RepoRoot)

    $watchTargets = @(
        'AGENTS.md',
        'README.md',
        'workspace-governance.json',
        'scripts',
        'nsis',
        'tests',
        '.github\workflows'
    )

    $snapshots = @()
    foreach ($target in $watchTargets) {
        $fullTarget = Join-Path $RepoRoot $target
        if (-not (Test-Path -LiteralPath $fullTarget)) {
            continue
        }

        if (Test-Path -LiteralPath $fullTarget -PathType Container) {
            $files = Get-ChildItem -LiteralPath $fullTarget -Recurse -File | Sort-Object FullName
            foreach ($file in $files) {
                $snapshots += ("{0}|{1}|{2}" -f $file.FullName.ToLowerInvariant(), $file.Length, $file.LastWriteTimeUtc.ToString('o'))
            }
        } else {
            $file = Get-Item -LiteralPath $fullTarget
            $snapshots += ("{0}|{1}|{2}" -f $file.FullName.ToLowerInvariant(), $file.Length, $file.LastWriteTimeUtc.ToString('o'))
        }
    }

    $payload = [string]::Join("`n", $snapshots)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($payload)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hashBytes = $sha.ComputeHash($bytes)
    } finally {
        $sha.Dispose()
    }
    return [BitConverter]::ToString($hashBytes).Replace('-', '').ToLowerInvariant()
}

function Invoke-IterationRun {
    param(
        [Parameter(Mandatory = $true)][int]$RunIndex,
        [Parameter(Mandatory = $true)][string]$ResolvedOutputRoot,
        [Parameter(Mandatory = $true)][string]$ModeValue,
        [Parameter(Mandatory = $true)][string]$SmokeRootBase,
        [Parameter(Mandatory = $true)][bool]$KeepSmoke,
        [Parameter(Mandatory = $true)][string]$NsisRootValue,
        [Parameter(Mandatory = $true)][string]$ExerciseScriptPath
    )

    $runName = "run-{0:D3}" -f $RunIndex
    $runOutputRoot = Join-Path $ResolvedOutputRoot $runName
    Ensure-Directory -Path $runOutputRoot

    $runSmokeRoot = if ($RunIndex -eq 1) {
        $SmokeRootBase
    } else {
        Join-Path $SmokeRootBase $runName
    }

    $argList = @(
        '-NoProfile',
        '-File', $ExerciseScriptPath,
        '-OutputRoot', $runOutputRoot,
        '-SmokeWorkspaceRoot', $runSmokeRoot,
        '-NsisRoot', $NsisRootValue
    )
    if ($KeepSmoke) {
        $argList += '-KeepSmokeWorkspace'
    }
    if ($ModeValue -eq 'fast') {
        $argList += '-SkipSmokeBuild'
        $argList += '-SkipSmokeInstall'
    }

    $startUtc = (Get-Date).ToUniversalTime()
    $runExitCode = 0
    $status = 'unknown'

    try {
        & pwsh @argList | Out-Host
        $runExitCode = $LASTEXITCODE
        if ($runExitCode -ne 0) {
            throw "Exercise script exited with code $runExitCode"
        }
        $status = 'succeeded'
    } catch {
        $status = 'failed'
        $runExitCode = if ($runExitCode -ne 0) { $runExitCode } else { 1 }
        throw
    }

    $endUtc = (Get-Date).ToUniversalTime()
    return [pscustomobject]@{
        run = $runName
        mode = $ModeValue
        output_root = $runOutputRoot
        smoke_workspace_root = $runSmokeRoot
        start_utc = $startUtc.ToString('o')
        end_utc = $endUtc.ToString('o')
        exit_code = $runExitCode
        status = $status
    }
}

$repoRoot = (Resolve-Path -Path (Join-Path $PSScriptRoot '..')).Path
$exerciseScript = Join-Path $repoRoot 'scripts\Exercise-WorkspaceInstallerLocal.ps1'
if (-not (Test-Path -LiteralPath $exerciseScript -PathType Leaf)) {
    throw "Exercise script not found: $exerciseScript"
}

$resolvedOutputRoot = [System.IO.Path]::GetFullPath($OutputRoot)
Ensure-Directory -Path $resolvedOutputRoot

$runResults = @()
if (-not $Watch) {
    for ($i = 1; $i -le $Iterations; $i++) {
        $runResults += Invoke-IterationRun -RunIndex $i -ResolvedOutputRoot $resolvedOutputRoot -ModeValue $Mode -SmokeRootBase $SmokeWorkspaceRoot -KeepSmoke ([bool]$KeepSmokeWorkspace) -NsisRootValue $NsisRoot -ExerciseScriptPath $exerciseScript
    }
} else {
    $runIndex = 0
    $fingerprint = Get-WorkspaceFingerprint -RepoRoot $repoRoot
    Write-Host "Watching installer contract files (poll: $PollSeconds sec)."
    Write-Host "Initial fingerprint: $fingerprint"

    while ($true) {
        if ($MaxRuns -gt 0 -and $runIndex -ge $MaxRuns) {
            break
        }

        if ($runIndex -eq 0) {
            $runIndex++
            $runResults += Invoke-IterationRun -RunIndex $runIndex -ResolvedOutputRoot $resolvedOutputRoot -ModeValue $Mode -SmokeRootBase $SmokeWorkspaceRoot -KeepSmoke ([bool]$KeepSmokeWorkspace) -NsisRootValue $NsisRoot -ExerciseScriptPath $exerciseScript
            $fingerprint = Get-WorkspaceFingerprint -RepoRoot $repoRoot
            continue
        }

        Start-Sleep -Seconds $PollSeconds
        $newFingerprint = Get-WorkspaceFingerprint -RepoRoot $repoRoot
        if ($newFingerprint -eq $fingerprint) {
            continue
        }

        Write-Host "Change detected. Re-running installer iteration."
        $fingerprint = $newFingerprint
        $runIndex++
        $runResults += Invoke-IterationRun -RunIndex $runIndex -ResolvedOutputRoot $resolvedOutputRoot -ModeValue $Mode -SmokeRootBase $SmokeWorkspaceRoot -KeepSmoke ([bool]$KeepSmokeWorkspace) -NsisRootValue $NsisRoot -ExerciseScriptPath $exerciseScript
        $fingerprint = Get-WorkspaceFingerprint -RepoRoot $repoRoot
    }
}

$latest = $runResults | Select-Object -Last 1
$summaryPath = Join-Path $resolvedOutputRoot 'iteration-summary.json'
[ordered]@{
    timestamp_utc = (Get-Date).ToUniversalTime().ToString('o')
    mode = $Mode
    watch = [bool]$Watch
    poll_seconds = $PollSeconds
    requested_iterations = $Iterations
    max_runs = $MaxRuns
    executed_runs = @($runResults).Count
    latest = $latest
    runs = $runResults
} | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $summaryPath -Encoding utf8

Write-Host "Iteration summary: $summaryPath"
