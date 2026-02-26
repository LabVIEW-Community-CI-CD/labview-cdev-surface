#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter()]
    [ValidatePattern('^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$')]
    [string]$SurfaceRepository = 'LabVIEW-Community-CI-CD/labview-cdev-surface-fork',

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string[]]$RequiredRunnerLabels = @(
        'self-hosted',
        'windows',
        'self-hosted-windows-lv',
        'windows-containers',
        'user-session',
        'cdev-surface-windows-gate'
    ),

    [Parameter()]
    [ValidatePattern('^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$')]
    [string]$SyncGuardRepository = 'LabVIEW-Community-CI-CD/labview-cdev-cli',

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$SyncGuardWorkflow = 'fork-upstream-sync-guard',

    [Parameter()]
    [ValidatePattern('^[A-Za-z0-9._/-]+$')]
    [string]$SyncGuardBranch = 'main',

    [Parameter()]
    [ValidateRange(1, 168)]
    [int]$SyncGuardMaxAgeHours = 12,

    [Parameter()]
    [string]$OutputPath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'lib/WorkflowOps.Common.ps1')

function Convert-RunRecord {
    param([Parameter(Mandatory = $true)][object]$Run)

    $runTimestamp = Get-RunTimestampUtc -Run $Run
    return [ordered]@{
        run_id = [string]$Run.databaseId
        status = [string]$Run.status
        conclusion = [string]$Run.conclusion
        event = [string]$Run.event
        head_sha = [string]$Run.headSha
        created_at_utc = if ($runTimestamp -eq [DateTimeOffset]::MinValue) { '' } else { $runTimestamp.ToString('o') }
        url = [string]$Run.url
    }
}

function Add-ReasonCode {
    param(
        [Parameter(Mandatory = $true)][System.Collections.Generic.List[string]]$Target,
        [Parameter(Mandatory = $true)][string]$ReasonCode
    )

    if (-not $Target.Contains($ReasonCode)) {
        [void]$Target.Add($ReasonCode)
    }
}

function Get-RunTimestampUtc {
    param([Parameter(Mandatory = $true)][object]$Run)

    $created = $Run.createdAt
    if ($created -is [DateTimeOffset]) {
        return ([DateTimeOffset]$created).ToUniversalTime()
    }
    if ($created -is [DateTime]) {
        return [DateTimeOffset]::new(([DateTime]$created).ToUniversalTime())
    }

    $createdText = ([string]$created).Trim()
    if ([string]::IsNullOrWhiteSpace($createdText)) {
        return [DateTimeOffset]::MinValue
    }

    $parsed = [DateTimeOffset]::MinValue
    if ([DateTimeOffset]::TryParse(
            $createdText,
            [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::AssumeUniversal,
            [ref]$parsed)) {
        return $parsed.ToUniversalTime()
    }

    if ([DateTimeOffset]::TryParse($createdText, [ref]$parsed)) {
        return $parsed.ToUniversalTime()
    }

    return [DateTimeOffset]::MinValue
}

$reasonCodes = [System.Collections.Generic.List[string]]::new()
$report = [ordered]@{
    schema_version = '1.0'
    timestamp_utc = Get-UtcNowIso
    surface_repository = $SurfaceRepository
    required_runner_labels = @()
    runner_summary = [ordered]@{
        total = 0
        online = 0
        eligible = 0
    }
    eligible_runners = @()
    sync_guard = [ordered]@{
        repository = $SyncGuardRepository
        workflow = $SyncGuardWorkflow
        branch = $SyncGuardBranch
        max_age_hours = $SyncGuardMaxAgeHours
        latest_run = $null
        latest_completed_run = $null
        latest_success_run = $null
        latest_success_age_hours = $null
    }
    status = 'fail'
    reason_codes = @()
    message = ''
}

try {
    $normalizedRequiredLabels = @(
        @($RequiredRunnerLabels | ForEach-Object { ([string]$_).ToLowerInvariant().Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) |
            Sort-Object -Unique
    )
    $report.required_runner_labels = $normalizedRequiredLabels

    $runnerPayload = Invoke-GhJson -Arguments @('api', "repos/$SurfaceRepository/actions/runners?per_page=100")
    $allRunners = @($runnerPayload.runners)
    $onlineRunners = @()
    $eligibleRunners = @()

    foreach ($runner in $allRunners) {
        $labelMap = @{}
        foreach ($label in @($runner.labels)) {
            $name = ([string]$label.name).ToLowerInvariant().Trim()
            if (-not [string]::IsNullOrWhiteSpace($name)) {
                $labelMap[$name] = $true
            }
        }

        $runnerRecord = [ordered]@{
            name = [string]$runner.name
            status = [string]$runner.status
            busy = [bool]$runner.busy
            labels = @($runner.labels | ForEach-Object { [string]$_.name })
            missing_required_labels = @($normalizedRequiredLabels | Where-Object { -not $labelMap.ContainsKey($_) })
        }

        if ([string]$runner.status -eq 'online') {
            $onlineRunners += $runnerRecord
            if (@($runnerRecord.missing_required_labels).Count -eq 0) {
                $eligibleRunners += $runnerRecord
            }
        }
    }

    $report.runner_summary.total = @($allRunners).Count
    $report.runner_summary.online = @($onlineRunners).Count
    $report.runner_summary.eligible = @($eligibleRunners).Count
    $report.eligible_runners = @($eligibleRunners)

    if (@($eligibleRunners).Count -eq 0) {
        Add-ReasonCode -Target $reasonCodes -ReasonCode 'runner_unavailable'
    }

    $syncRunsRaw = @(Invoke-GhJson -Arguments @(
        'run', 'list',
        '-R', $SyncGuardRepository,
        '--workflow', $SyncGuardWorkflow,
        '--branch', $SyncGuardBranch,
        '--limit', '25',
        '--json', 'databaseId,status,conclusion,url,createdAt,headSha,event'
    ))
    $syncRuns = @($syncRunsRaw | Sort-Object { Get-RunTimestampUtc -Run $_ } -Descending)

    $latestRun = $null
    if (@($syncRuns).Count -gt 0) {
        $latestRun = $syncRuns[0]
        $report.sync_guard.latest_run = Convert-RunRecord -Run $latestRun
    }

    $latestCompletedRun = @($syncRuns | Where-Object { [string]$_.status -eq 'completed' } | Select-Object -First 1)
    if (@($latestCompletedRun).Count -eq 1) {
        $report.sync_guard.latest_completed_run = Convert-RunRecord -Run $latestCompletedRun[0]
        if ([string]$latestCompletedRun[0].conclusion -ne 'success') {
            Add-ReasonCode -Target $reasonCodes -ReasonCode 'sync_guard_failed'
        }
    }

    $latestSuccessRun = @($syncRuns | Where-Object { [string]$_.status -eq 'completed' -and [string]$_.conclusion -eq 'success' } | Select-Object -First 1)
    if (@($latestSuccessRun).Count -ne 1) {
        if (@($syncRuns).Count -eq 0) {
            Add-ReasonCode -Target $reasonCodes -ReasonCode 'sync_guard_missing'
        } elseif (@($latestCompletedRun).Count -eq 0) {
            Add-ReasonCode -Target $reasonCodes -ReasonCode 'sync_guard_incomplete'
        } else {
            Add-ReasonCode -Target $reasonCodes -ReasonCode 'sync_guard_failed'
        }
    } else {
        $successRun = $latestSuccessRun[0]
        $report.sync_guard.latest_success_run = Convert-RunRecord -Run $successRun

        $successTimestamp = Get-RunTimestampUtc -Run $successRun
        $ageHours = [Math]::Round((((Get-Date).ToUniversalTime() - $successTimestamp.UtcDateTime).TotalHours), 2)
        $report.sync_guard.latest_success_age_hours = $ageHours

        if ($ageHours -gt $SyncGuardMaxAgeHours) {
            Add-ReasonCode -Target $reasonCodes -ReasonCode 'sync_guard_stale'
        }
    }

    if ($reasonCodes.Count -eq 0) {
        $report.status = 'pass'
        $report.reason_codes = @('ok')
        $report.message = 'Operations monitoring snapshot passed.'
    } else {
        $report.status = 'fail'
        $report.reason_codes = @($reasonCodes)
        $report.message = "Operations monitoring snapshot failed. reason_codes=$([string]::Join(',', @($reasonCodes)))"
    }
}
catch {
    $report.status = 'fail'
    $report.reason_codes = @('ops_monitor_runtime_error')
    $report.message = [string]$_.Exception.Message
}
finally {
    Write-WorkflowOpsReport -Report $report -OutputPath $OutputPath | Out-Null
}

if ([string]$report.status -eq 'pass') {
    exit 0
}

throw ("[ops_monitor_failed] {0}" -f [string]$report.message)
