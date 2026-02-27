#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter()]
    [ValidatePattern('^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$')]
    [string]$SurfaceRepository = 'LabVIEW-Community-CI-CD/labview-cdev-surface-fork',

    [Parameter()]
    [ValidatePattern('^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$')]
    [string]$SyncGuardRepository = 'LabVIEW-Community-CI-CD/labview-cdev-cli',

    [Parameter()]
    [ValidatePattern('^[A-Za-z0-9._/-]+$')]
    [string]$SyncGuardWorkflow = 'fork-upstream-sync-guard',

    [Parameter()]
    [ValidatePattern('^[A-Za-z0-9._/-]+$')]
    [string]$SyncGuardBranch = 'main',

    [Parameter()]
    [ValidateRange(1, 168)]
    [int]$SyncGuardMaxAgeHours = 12,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string[]]$RequiredRunnerLabels = @(
        'self-hosted',
        'windows',
        'self-hosted-windows-lv'
    ),

    [Parameter()]
    [ValidateRange(5, 180)]
    [int]$WatchTimeoutMinutes = 45,

    [Parameter()]
    [string]$OutputPath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'lib/WorkflowOps.Common.ps1')

$opsSnapshotScript = Join-Path $PSScriptRoot 'Invoke-OpsMonitoringSnapshot.ps1'
$dispatchWorkflowScript = Join-Path $PSScriptRoot 'Dispatch-WorkflowAtRemoteHead.ps1'
$watchWorkflowScript = Join-Path $PSScriptRoot 'Watch-WorkflowRun.ps1'

foreach ($requiredScript in @($opsSnapshotScript, $dispatchWorkflowScript, $watchWorkflowScript)) {
    if (-not (Test-Path -LiteralPath $requiredScript -PathType Leaf)) {
        throw "required_script_missing: $requiredScript"
    }
}

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("ops-auto-remediate-" + [Guid]::NewGuid().ToString('N'))
New-Item -Path $tempRoot -ItemType Directory -Force | Out-Null

$report = [ordered]@{
    schema_version = '1.0'
    timestamp_utc = Get-UtcNowIso
    surface_repository = $SurfaceRepository
    sync_guard_repository = $SyncGuardRepository
    sync_guard_workflow = $SyncGuardWorkflow
    sync_guard_branch = $SyncGuardBranch
    sync_guard_max_age_hours = $SyncGuardMaxAgeHours
    status = 'fail'
    reason_code = ''
    message = ''
    pre_health = $null
    post_health = $null
    actions = @()
}

try {
    $preHealthPath = Join-Path $tempRoot 'pre-health.json'
    & pwsh -NoProfile -File $opsSnapshotScript `
        -SurfaceRepository $SurfaceRepository `
        -RequiredRunnerLabels $RequiredRunnerLabels `
        -SyncGuardRepository $SyncGuardRepository `
        -SyncGuardWorkflow $SyncGuardWorkflow `
        -SyncGuardBranch $SyncGuardBranch `
        -SyncGuardMaxAgeHours $SyncGuardMaxAgeHours `
        -OutputPath $preHealthPath
    if ($LASTEXITCODE -ne 0) {
        throw "ops_snapshot_failed_pre: exit_code=$LASTEXITCODE"
    }
    $report.pre_health = Get-Content -LiteralPath $preHealthPath -Raw | ConvertFrom-Json -ErrorAction Stop

    if ([string]$report.pre_health.status -eq 'pass') {
        $report.status = 'pass'
        $report.reason_code = 'already_healthy'
        $report.message = 'Ops health is already green. No remediation required.'
    } else {
        $preReasons = @($report.pre_health.reason_codes | ForEach-Object { [string]$_ })
        $syncGuardReasons = @('sync_guard_failed', 'sync_guard_stale', 'sync_guard_missing', 'sync_guard_incomplete')
        $hasAutomatableSyncGuardDrift = @($preReasons | Where-Object { $syncGuardReasons -contains $_ }).Count -gt 0

        if ($hasAutomatableSyncGuardDrift) {
            $dispatchReportPath = Join-Path $tempRoot 'sync-guard-dispatch.json'
            & pwsh -NoProfile -File $dispatchWorkflowScript `
                -Repository $SyncGuardRepository `
                -WorkflowFile $SyncGuardWorkflow `
                -Branch $SyncGuardBranch `
                -OutputPath $dispatchReportPath
            if ($LASTEXITCODE -ne 0) {
                throw "sync_guard_dispatch_failed: exit_code=$LASTEXITCODE"
            }
            $dispatchReport = Get-Content -LiteralPath $dispatchReportPath -Raw | ConvertFrom-Json -ErrorAction Stop

            $watchReportPath = Join-Path $tempRoot 'sync-guard-watch.json'
            & pwsh -NoProfile -File $watchWorkflowScript `
                -Repository $SyncGuardRepository `
                -RunId ([string]$dispatchReport.run_id) `
                -TimeoutMinutes $WatchTimeoutMinutes `
                -OutputPath $watchReportPath
            if ($LASTEXITCODE -ne 0) {
                throw "sync_guard_watch_failed: exit_code=$LASTEXITCODE"
            }
            $watchReport = Get-Content -LiteralPath $watchReportPath -Raw | ConvertFrom-Json -ErrorAction Stop

            $report.actions = @(
                [ordered]@{
                    action = 'dispatch_sync_guard'
                    status = 'success'
                    run_id = [string]$dispatchReport.run_id
                    run_url = [string]$dispatchReport.url
                },
                [ordered]@{
                    action = 'watch_sync_guard'
                    status = [string]$watchReport.conclusion
                    run_id = [string]$watchReport.run_id
                    run_url = [string]$watchReport.url
                }
            )
        } else {
            $report.actions = @(
                [ordered]@{
                    action = 'no_automatable_action'
                    status = 'skipped'
                    detail = "reason_codes=$([string]::Join(',', $preReasons))"
                }
            )
        }

        $postHealthPath = Join-Path $tempRoot 'post-health.json'
        $postSucceeded = $false
        try {
            & pwsh -NoProfile -File $opsSnapshotScript `
                -SurfaceRepository $SurfaceRepository `
                -RequiredRunnerLabels $RequiredRunnerLabels `
                -SyncGuardRepository $SyncGuardRepository `
                -SyncGuardWorkflow $SyncGuardWorkflow `
                -SyncGuardBranch $SyncGuardBranch `
                -SyncGuardMaxAgeHours $SyncGuardMaxAgeHours `
                -OutputPath $postHealthPath
            if ($LASTEXITCODE -eq 0) {
                $postSucceeded = $true
            }
        } catch {
            $postSucceeded = $false
        }

        if (Test-Path -LiteralPath $postHealthPath -PathType Leaf) {
            $report.post_health = Get-Content -LiteralPath $postHealthPath -Raw | ConvertFrom-Json -ErrorAction Stop
        }

        if ($postSucceeded -and $null -ne $report.post_health -and [string]$report.post_health.status -eq 'pass') {
            $report.status = 'pass'
            $report.reason_code = 'remediated'
            $report.message = 'Auto-remediation recovered ops health to pass.'
        } else {
            $postReasons = @()
            if ($null -ne $report.post_health) {
                $postReasons = @($report.post_health.reason_codes | ForEach-Object { [string]$_ })
            }
            $manualRequired = (@($postReasons | Where-Object { $_ -eq 'runner_unavailable' }).Count -gt 0) -or
                (@($preReasons | Where-Object { $_ -eq 'runner_unavailable' }).Count -gt 0)
            if ($manualRequired) {
                $report.status = 'fail'
                $report.reason_code = 'manual_intervention_required'
                $report.message = "Runner availability requires manual intervention. reason_codes=$([string]::Join(',', @($postReasons)))"
            } elseif ($hasAutomatableSyncGuardDrift) {
                $report.status = 'fail'
                $report.reason_code = 'remediation_incomplete'
                $report.message = "Auto-remediation attempted but health is still failing. reason_codes=$([string]::Join(',', @($postReasons)))"
            } else {
                $report.status = 'fail'
                $report.reason_code = 'no_automatable_action'
                $report.message = "No automatable action for current ops failure. reason_codes=$([string]::Join(',', @($preReasons)))"
            }
        }
    }
}
catch {
    $report.status = 'fail'
    $report.reason_code = 'remediation_failed'
    $report.message = [string]$_.Exception.Message
}
finally {
    Write-WorkflowOpsReport -Report $report -OutputPath $OutputPath | Out-Null
    if (Test-Path -LiteralPath $tempRoot -PathType Container) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

if ([string]$report.status -eq 'pass') {
    exit 0
}

exit 1
