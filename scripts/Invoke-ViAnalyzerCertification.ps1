#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$RepoPath,

    [Parameter(Mandatory = $true)]
    [string]$ExecutionLabviewYear,

    [Parameter()]
    [ValidateSet('32', '64')]
    [string]$SupportedBitness = '64',

    [Parameter(Mandatory = $true)]
    [string]$ArtifactRoot,

    [Parameter()]
    [string]$LabVIEWPath = '',

    [Parameter()]
    [int]$TimeoutSeconds = 900,

    [Parameter()]
    [string]$OutputPath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Ensure-Directory {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        New-Item -Path $Path -ItemType Directory -Force | Out-Null
    }
}

function Get-HeadlessState {
    $sessionName = [string]$env:SESSIONNAME
    if ([string]::IsNullOrWhiteSpace($sessionName)) {
        $sessionName = 'unknown'
    }

    $sessionId = -1
    try {
        $sessionId = [System.Diagnostics.Process]::GetCurrentProcess().SessionId
    } catch {
        $sessionId = -1
    }

    $isInteractive = [System.Environment]::UserInteractive
    $sessionSignalsHeadless = ($sessionId -eq 0) -or ($sessionName -match '^(Services|Service)$')
    $isHeadless = (-not $isInteractive) -and $sessionSignalsHeadless

    return [pscustomobject]@{
        is_headless = $isHeadless
        session_name = $sessionName
        session_id = $sessionId
        interactive = $isInteractive
    }
}

function Resolve-LabVIEWPath {
    param(
        [Parameter(Mandatory = $true)][string]$Year,
        [Parameter(Mandatory = $true)][string]$Bitness,
        [Parameter()][string]$PreferredPath = ''
    )

    if (-not [string]::IsNullOrWhiteSpace($PreferredPath)) {
        return [System.IO.Path]::GetFullPath($PreferredPath)
    }

    if ($Bitness -eq '32') {
        return "C:\Program Files (x86)\National Instruments\LabVIEW $Year\LabVIEW.exe"
    }
    return "C:\Program Files\National Instruments\LabVIEW $Year\LabVIEW.exe"
}

$resolvedRepoPath = [System.IO.Path]::GetFullPath($RepoPath)
$resolvedArtifactRoot = [System.IO.Path]::GetFullPath($ArtifactRoot)
Ensure-Directory -Path $resolvedArtifactRoot

$reportPath = if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    Join-Path $resolvedArtifactRoot 'vi-analyzer-certification-report.json'
} else {
    [System.IO.Path]::GetFullPath($OutputPath)
}
Ensure-Directory -Path (Split-Path -Path $reportPath -Parent)

$headlessState = Get-HeadlessState
if (-not [bool]$headlessState.is_headless) {
    $headlessMessage = ("runner_not_headless: VI Analyzer certification requires headless runner session. session='{0}' session_id={1} interactive={2}" -f [string]$headlessState.session_name, [int]$headlessState.session_id, [bool]$headlessState.interactive)
    throw $headlessMessage
}

if (-not (Test-Path -LiteralPath $resolvedRepoPath -PathType Container)) {
    throw "Repo path not found: $resolvedRepoPath"
}

$viAnalyzerScript = Join-Path $resolvedRepoPath 'Tooling\container-parity\run-vi-analyzer-windows.ps1'
if (-not (Test-Path -LiteralPath $viAnalyzerScript -PathType Leaf)) {
    throw "VI Analyzer script not found: $viAnalyzerScript"
}

$resolvedLabVIEWPath = Resolve-LabVIEWPath -Year $ExecutionLabviewYear -Bitness $SupportedBitness -PreferredPath $LabVIEWPath
if (-not (Test-Path -LiteralPath $resolvedLabVIEWPath -PathType Leaf)) {
    throw "LabVIEW executable not found for VI Analyzer certification: $resolvedLabVIEWPath"
}

$statusPath = Join-Path $resolvedArtifactRoot 'vi-analyzer-status.json'
$reportsRoot = Join-Path $resolvedArtifactRoot 'reports'
$sourceSyncManifestPath = Join-Path $resolvedArtifactRoot 'source-sync-manifest.json'
Ensure-Directory -Path $reportsRoot

$processArgs = @(
    '-NoLogo',
    '-NoProfile',
    '-NonInteractive',
    '-ExecutionPolicy', 'Bypass',
    '-File', $viAnalyzerScript,
    '-WorkspaceRoot', $resolvedRepoPath,
    '-LabVIEWPath', $resolvedLabVIEWPath,
    '-LabVIEWVersion', $ExecutionLabviewYear,
    '-LabVIEWBitness', $SupportedBitness,
    '-ReportsRoot', $reportsRoot,
    '-StatusPath', $statusPath,
    '-SourceSyncManifestPath', $sourceSyncManifestPath
)

$process = $null
$timedOut = $false
$exitCode = 1
$processId = -1
$status = 'failed'

try {
    $process = Start-Process -FilePath 'powershell' -ArgumentList $processArgs -PassThru
    $processId = [int]$process.Id
    $waitMilliseconds = [Math]::Max(1, [int]$TimeoutSeconds) * 1000
    $exited = $process.WaitForExit($waitMilliseconds)
    if (-not $exited) {
        $timedOut = $true
        try {
            $process.Kill()
        } catch {
            # best effort
        }
        $exitCode = 124
    } else {
        $exitCode = [int]$process.ExitCode
    }

    if ($exitCode -eq 0 -and -not $timedOut) {
        $status = 'succeeded'
    }
} finally {
    $statusPayload = $null
    if (Test-Path -LiteralPath $statusPath -PathType Leaf) {
        try {
            $statusPayload = Get-Content -LiteralPath $statusPath -Raw | ConvertFrom-Json -ErrorAction Stop
            if ($null -eq $statusPayload.overall_success -or -not [bool]$statusPayload.overall_success) {
                $status = 'failed'
            }
        } catch {
            $status = 'failed'
        }
    } else {
        $status = 'failed'
    }

    $report = [ordered]@{
        timestamp_utc = (Get-Date).ToUniversalTime().ToString('o')
        status = $status
        repository_root = $resolvedRepoPath
        execution_labview_year = $ExecutionLabviewYear
        supported_bitness = $SupportedBitness
        headless_session = [ordered]@{
            is_headless = [bool]$headlessState.is_headless
            session_name = [string]$headlessState.session_name
            session_id = [int]$headlessState.session_id
            interactive = [bool]$headlessState.interactive
        }
        labview_path = $resolvedLabVIEWPath
        vi_analyzer_script = $viAnalyzerScript
        reports_root = $reportsRoot
        status_path = $statusPath
        source_sync_manifest_path = $sourceSyncManifestPath
        timeout_seconds = $TimeoutSeconds
        timed_out = [bool]$timedOut
        exit_code = [int]$exitCode
        process_id = [int]$processId
        overall_success = if ($null -ne $statusPayload -and $statusPayload.PSObject.Properties.Name -contains 'overall_success') { [bool]$statusPayload.overall_success } else { $false }
        task_count = if ($null -ne $statusPayload -and $statusPayload.PSObject.Properties.Name -contains 'task_count') { [int]$statusPayload.task_count } else { 0 }
    }

    $report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $reportPath -Encoding utf8
}

Write-Host ("VI Analyzer certification report: {0}" -f $reportPath)
Write-Host ("VI Analyzer certification status: {0}" -f $status)

if ($status -ne 'succeeded') {
    throw ("VI Analyzer certification failed (exit={0}, timed_out={1}). See report: {2}" -f [int]$exitCode, [bool]$timedOut, $reportPath)
}

Get-Content -LiteralPath $reportPath -Raw | Write-Output
