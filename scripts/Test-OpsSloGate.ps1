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
    [ValidateRange(1, 90)]
    [int]$LookbackDays = 7,

    [Parameter()]
    [ValidateRange(0, 100)]
    [double]$MinSuccessRatePct = 100,

    [Parameter()]
    [ValidateRange(1, 168)]
    [int]$SyncGuardMaxAgeHours = 12,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string[]]$RequiredWorkflows = @(
        'ops-monitoring',
        'ops-autoremediate',
        'release-control-plane'
    ),

    [Parameter()]
    [string]$OutputPath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'lib/WorkflowOps.Common.ps1')

function Add-ReasonCode {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][System.Collections.Generic.List[string]]$Target,
        [Parameter(Mandatory = $true)][string]$ReasonCode
    )

    if (-not $Target.Contains($ReasonCode)) {
        [void]$Target.Add($ReasonCode)
    }
}

$report = [ordered]@{
    schema_version = '1.0'
    generated_at_utc = Get-UtcNowIso
    surface_repository = $SurfaceRepository
    sync_guard_repository = $SyncGuardRepository
    lookback_days = $LookbackDays
    min_success_rate_pct = $MinSuccessRatePct
    sync_guard_max_age_hours = $SyncGuardMaxAgeHours
    required_workflows = @($RequiredWorkflows)
    status = 'fail'
    reason_codes = @()
    message = ''
    workflow_evaluations = @()
    sync_guard_evaluation = [ordered]@{}
    source_slo_report = $null
}

$reasonCodes = [System.Collections.Generic.List[string]]::new()

try {
    $sloScript = Join-Path $PSScriptRoot 'Write-OpsSloReport.ps1'
    if (-not (Test-Path -LiteralPath $sloScript -PathType Leaf)) {
        throw "required_script_missing: $sloScript"
    }

    $scratchRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("ops-slo-gate-" + [Guid]::NewGuid().ToString('N'))
    New-Item -Path $scratchRoot -ItemType Directory -Force | Out-Null

    try {
        $sloPath = Join-Path $scratchRoot 'weekly-ops-slo-report.json'
        & pwsh -NoProfile -File $sloScript `
            -SurfaceRepository $SurfaceRepository `
            -SyncGuardRepository $SyncGuardRepository `
            -LookbackDays $LookbackDays `
            -OutputPath $sloPath
        if ($LASTEXITCODE -ne 0) {
            throw "slo_report_generation_failed: exit_code=$LASTEXITCODE"
        }

        $sloReport = Get-Content -LiteralPath $sloPath -Raw | ConvertFrom-Json -ErrorAction Stop
        $report.source_slo_report = $sloReport

        $workflowEvaluations = [System.Collections.Generic.List[object]]::new()
        foreach ($workflowName in @($RequiredWorkflows)) {
            $candidate = @($sloReport.workflows | Where-Object { [string]$_.workflow -eq [string]$workflowName } | Select-Object -First 1)
            if (@($candidate).Count -ne 1) {
                Add-ReasonCode -Target $reasonCodes -ReasonCode 'workflow_missing_runs'
                [void]$workflowEvaluations.Add([ordered]@{
                        workflow = $workflowName
                        status = 'fail'
                        reason = 'missing'
                        detail = 'No SLO record found for required workflow.'
                    })
                continue
            }

            $record = $candidate[0]
            $workflowStatus = 'pass'
            $workflowReasons = [System.Collections.Generic.List[string]]::new()
            if ([int]$record.total_runs -lt 1) {
                Add-ReasonCode -Target $reasonCodes -ReasonCode 'workflow_missing_runs'
                [void]$workflowReasons.Add('missing_runs')
            }
            if ([int]$record.failure_runs -gt 0) {
                Add-ReasonCode -Target $reasonCodes -ReasonCode 'workflow_failure_detected'
                [void]$workflowReasons.Add('failure_runs_present')
            }
            if ([double]$record.success_rate_pct -lt $MinSuccessRatePct) {
                Add-ReasonCode -Target $reasonCodes -ReasonCode 'workflow_success_rate_below_threshold'
                [void]$workflowReasons.Add('success_rate_below_threshold')
            }
            if (@($workflowReasons).Count -gt 0) {
                $workflowStatus = 'fail'
            }

            [void]$workflowEvaluations.Add([ordered]@{
                    workflow = [string]$record.workflow
                    status = $workflowStatus
                    reason_codes = @($workflowReasons)
                    total_runs = [int]$record.total_runs
                    completed_runs = [int]$record.completed_runs
                    success_runs = [int]$record.success_runs
                    failure_runs = [int]$record.failure_runs
                    success_rate_pct = [double]$record.success_rate_pct
                })
        }
        $report.workflow_evaluations = @($workflowEvaluations)

        $syncGuardEvaluation = [ordered]@{
            status = 'pass'
            reason_codes = @()
            latest_success_age_hours = $sloReport.sync_guard.latest_success_age_hours
            total_runs = $sloReport.sync_guard.total_runs
        }
        $syncGuardReasons = [System.Collections.Generic.List[string]]::new()
        if ($null -eq $sloReport.sync_guard.latest_success_run) {
            Add-ReasonCode -Target $reasonCodes -ReasonCode 'sync_guard_missing'
            [void]$syncGuardReasons.Add('latest_success_missing')
        } elseif ($null -ne $sloReport.sync_guard.latest_success_age_hours -and [double]$sloReport.sync_guard.latest_success_age_hours -gt $SyncGuardMaxAgeHours) {
            Add-ReasonCode -Target $reasonCodes -ReasonCode 'sync_guard_stale'
            [void]$syncGuardReasons.Add('latest_success_stale')
        }

        if (@($syncGuardReasons).Count -gt 0) {
            $syncGuardEvaluation.status = 'fail'
            $syncGuardEvaluation.reason_codes = @($syncGuardReasons)
        }
        $report.sync_guard_evaluation = $syncGuardEvaluation

        if ($reasonCodes.Count -eq 0) {
            $report.status = 'pass'
            $report.reason_codes = @('ok')
            $report.message = 'Ops SLO gate passed.'
        } else {
            $report.status = 'fail'
            $report.reason_codes = @($reasonCodes)
            $report.message = "Ops SLO gate failed. reason_codes=$([string]::Join(',', @($reasonCodes)))"
        }
    }
    finally {
        if (Test-Path -LiteralPath $scratchRoot -PathType Container) {
            Remove-Item -LiteralPath $scratchRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
catch {
    $report.status = 'fail'
    $report.reason_codes = @('slo_gate_runtime_error')
    $report.message = [string]$_.Exception.Message
}
finally {
    Write-WorkflowOpsReport -Report $report -OutputPath $OutputPath | Out-Null
}

if ([string]$report.status -eq 'pass') {
    exit 0
}

exit 1
