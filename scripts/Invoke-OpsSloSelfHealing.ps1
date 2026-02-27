#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter()]
    [ValidatePattern('^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$')]
    [string]$SurfaceRepository = 'LabVIEW-Community-CI-CD/labview-cdev-surface-fork',

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
    [bool]$AutoRemediate = $true,

    [Parameter()]
    [ValidatePattern('^[A-Za-z0-9._/-]+$')]
    [string]$RemediationWorkflow = 'ops-autoremediate.yml',

    [Parameter()]
    [ValidatePattern('^[A-Za-z0-9._/-]+$')]
    [string]$RemediationBranch = 'main',

    [Parameter()]
    [ValidateRange(1, 5)]
    [int]$MaxAttempts = 1,

    [Parameter()]
    [ValidateRange(5, 240)]
    [int]$WatchTimeoutMinutes = 45,

    [Parameter()]
    [ValidateRange(0, 100)]
    [double]$WarningMinSuccessRatePct = 99.5,

    [Parameter()]
    [ValidateRange(0, 100)]
    [double]$CriticalMinSuccessRatePct = 99.0,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string[]]$WarningReasonCodes = @(
        'workflow_missing_runs',
        'workflow_success_rate_below_threshold'
    ),

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string[]]$CriticalReasonCodes = @(
        'workflow_failure_detected',
        'sync_guard_missing',
        'sync_guard_stale',
        'slo_gate_runtime_error'
    ),

    [Parameter()]
    [string]$OutputPath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'lib/WorkflowOps.Common.ps1')

$sloGateScript = Join-Path $PSScriptRoot 'Test-OpsSloGate.ps1'
$dispatchWorkflowScript = Join-Path $PSScriptRoot 'Dispatch-WorkflowAtRemoteHead.ps1'
$watchWorkflowScript = Join-Path $PSScriptRoot 'Watch-WorkflowRun.ps1'

foreach ($requiredScript in @($sloGateScript, $dispatchWorkflowScript, $watchWorkflowScript)) {
    if (-not (Test-Path -LiteralPath $requiredScript -PathType Leaf)) {
        throw "required_script_missing: $requiredScript"
    }
}

function ConvertTo-StringArray {
    param([Parameter()][AllowNull()]$Value)

    if ($null -eq $Value) {
        return @()
    }

    if ($Value -is [string]) {
        if ([string]::IsNullOrWhiteSpace([string]$Value)) {
            return @()
        }
        return @([string]$Value)
    }

    $items = [System.Collections.Generic.List[string]]::new()
    foreach ($entry in @($Value)) {
        $text = [string]$entry
        if ([string]::IsNullOrWhiteSpace($text)) {
            continue
        }
        if (-not $items.Contains($text)) {
            [void]$items.Add($text)
        }
    }

    return @($items)
}

function Test-ContainsAnyReasonCode {
    param(
        [Parameter()][string[]]$Source = @(),
        [Parameter()][string[]]$Candidates = @()
    )

    $normalizedSource = ConvertTo-StringArray -Value $Source
    foreach ($reason in @($normalizedSource)) {
        if (@($Candidates) -contains [string]$reason) {
            return $true
        }
    }

    return $false
}

function Get-LowestWorkflowSuccessRate {
    param([Parameter()][AllowNull()]$GateReport)

    if ($null -eq $GateReport) {
        return $null
    }

    $evaluations = @($GateReport.workflow_evaluations)
    if (@($evaluations).Count -eq 0) {
        return $null
    }

    $lowest = $null
    foreach ($evaluation in @($evaluations)) {
        $value = $null
        try {
            $value = [double]$evaluation.success_rate_pct
        } catch {
            $value = $null
        }

        if ($null -eq $value) {
            continue
        }

        if ($null -eq $lowest -or [double]$value -lt [double]$lowest) {
            $lowest = [double]$value
        }
    }

    return $lowest
}

function Resolve-OpsSloAlertSeverity {
    param(
        [Parameter()][string]$OverallStatus = 'fail',
        [Parameter()][AllowNull()]$GateReport = $null,
        [Parameter()][double]$WarningThreshold = 99.5,
        [Parameter()][double]$CriticalThreshold = 99.0,
        [Parameter()][string[]]$WarningCodes = @(),
        [Parameter()][string[]]$CriticalCodes = @()
    )

    if ([string]$OverallStatus -eq 'pass') {
        return 'none'
    }

    $reasonCodes = ConvertTo-StringArray -Value @($GateReport.reason_codes)
    if (Test-ContainsAnyReasonCode -Source @($reasonCodes) -Candidates @($CriticalCodes)) {
        return 'critical'
    }
    if (Test-ContainsAnyReasonCode -Source @($reasonCodes) -Candidates @($WarningCodes)) {
        return 'warning'
    }

    $lowestSuccessRate = Get-LowestWorkflowSuccessRate -GateReport $GateReport
    if ($null -ne $lowestSuccessRate -and [double]$lowestSuccessRate -lt $CriticalThreshold) {
        return 'critical'
    }
    if ($null -ne $lowestSuccessRate -and [double]$lowestSuccessRate -lt $WarningThreshold) {
        return 'warning'
    }

    return 'warning'
}

function Invoke-SloGateAssessment {
    param(
        [Parameter(Mandatory = $true)][string]$ScriptPath,
        [Parameter(Mandatory = $true)][string]$Repository,
        [Parameter(Mandatory = $true)][int]$WindowDays,
        [Parameter(Mandatory = $true)][double]$SuccessThreshold,
        [Parameter(Mandatory = $true)][int]$SyncGuardHours,
        [Parameter(Mandatory = $true)][string]$ReportPath
    )

    $runtimeError = ''
    $exitCode = 1
    try {
        & pwsh -NoProfile -File $ScriptPath `
            -SurfaceRepository $Repository `
            -LookbackDays $WindowDays `
            -MinSuccessRatePct $SuccessThreshold `
            -SyncGuardMaxAgeHours $SyncGuardHours `
            -OutputPath $ReportPath | Out-Null
        $exitCode = if ($null -eq $LASTEXITCODE) { 0 } else { [int]$LASTEXITCODE }
    } catch {
        $runtimeError = [string]$_.Exception.Message
        $exitCode = 1
    }

    $loadedReport = $null
    if (Test-Path -LiteralPath $ReportPath -PathType Leaf) {
        $loadedReport = Get-Content -LiteralPath $ReportPath -Raw | ConvertFrom-Json -ErrorAction Stop
    }

    if ($null -eq $loadedReport) {
        $message = if ([string]::IsNullOrWhiteSpace($runtimeError)) {
            "slo_gate_report_missing: $ReportPath"
        } else {
            $runtimeError
        }
        $loadedReport = [pscustomobject]@{
            status = 'fail'
            reason_codes = @('slo_gate_runtime_error')
            message = $message
        }
    } elseif (-not [string]::IsNullOrWhiteSpace($runtimeError)) {
        $loadedReport.status = 'fail'
        $loadedReport.reason_codes = @('slo_gate_runtime_error')
        $loadedReport.message = $runtimeError
    }

    return [pscustomobject]@{
        exit_code = $exitCode
        report = $loadedReport
    }
}

$scratchRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("ops-slo-self-heal-" + [Guid]::NewGuid().ToString('N'))
New-Item -Path $scratchRoot -ItemType Directory -Force | Out-Null

$report = [ordered]@{
    schema_version = '1.0'
    generated_at_utc = Get-UtcNowIso
    surface_repository = $SurfaceRepository
    lookback_days = $LookbackDays
    min_success_rate_pct = $MinSuccessRatePct
    sync_guard_max_age_hours = $SyncGuardMaxAgeHours
    auto_remediate = [bool]$AutoRemediate
    remediation_workflow = $RemediationWorkflow
    remediation_branch = $RemediationBranch
    max_attempts = $MaxAttempts
    watch_timeout_minutes = $WatchTimeoutMinutes
    alert_thresholds = [ordered]@{
        warning_min_success_rate_pct = $WarningMinSuccessRatePct
        critical_min_success_rate_pct = $CriticalMinSuccessRatePct
        warning_reason_codes = @($WarningReasonCodes)
        critical_reason_codes = @($CriticalReasonCodes)
    }
    alert_severity = 'none'
    status = 'fail'
    reason_code = ''
    message = ''
    initial_report = $null
    remediation_attempts = @()
    final_report = $null
}

try {
    $initialPath = Join-Path $scratchRoot 'initial-slo-gate.json'
    $initialAssessment = Invoke-SloGateAssessment `
        -ScriptPath $sloGateScript `
        -Repository $SurfaceRepository `
        -WindowDays $LookbackDays `
        -SuccessThreshold $MinSuccessRatePct `
        -SyncGuardHours $SyncGuardMaxAgeHours `
        -ReportPath $initialPath
    $initialReport = $initialAssessment.report
    $report.initial_report = $initialReport
    $report.final_report = $initialReport

    if ([string]$initialReport.status -eq 'pass') {
        $report.status = 'pass'
        $report.reason_code = 'already_healthy'
        $report.message = 'SLO gate is already passing. No remediation was required.'
    } elseif (-not $AutoRemediate) {
        $report.status = 'fail'
        $report.reason_code = 'auto_remediation_disabled'
        $report.message = 'SLO gate failed and auto-remediation is disabled.'
    } else {
        $attemptRecords = [System.Collections.Generic.List[object]]::new()
        $recovered = $false
        $hadExecutionFailure = $false
        $lastExecutionError = ''
        $finalReport = $initialReport
        $normalizedMaxAttempts = [Math]::Max(1, [Math]::Min($MaxAttempts, 5))

        for ($attempt = 1; $attempt -le $normalizedMaxAttempts; $attempt++) {
            $attemptRecord = [ordered]@{
                attempt = $attempt
                status = 'pending'
                dispatch = $null
                watch = $null
                verify = $null
                error = ''
            }

            $executionOk = $true
            try {
                $dispatchPath = Join-Path $scratchRoot ("attempt-{0}-dispatch.json" -f $attempt)
                $dispatchInputs = @("sync_guard_max_age_hours=$SyncGuardMaxAgeHours")
                & $dispatchWorkflowScript `
                    -Repository $SurfaceRepository `
                    -WorkflowFile $RemediationWorkflow `
                    -Branch $RemediationBranch `
                    -Inputs $dispatchInputs `
                    -OutputPath $dispatchPath | Out-Null
                $dispatchReport = Get-Content -LiteralPath $dispatchPath -Raw | ConvertFrom-Json -ErrorAction Stop
                $attemptRecord.dispatch = [ordered]@{
                    run_id = [string]$dispatchReport.run_id
                    head_sha = [string]$dispatchReport.head_sha
                    url = [string]$dispatchReport.url
                }

                $watchPath = Join-Path $scratchRoot ("attempt-{0}-watch.json" -f $attempt)
                & pwsh -NoProfile -File $watchWorkflowScript `
                    -Repository $SurfaceRepository `
                    -RunId ([string]$dispatchReport.run_id) `
                    -TimeoutMinutes $WatchTimeoutMinutes `
                    -OutputPath $watchPath | Out-Null
                if ($LASTEXITCODE -ne 0) {
                    throw "slo_remediation_watch_failed: run_id=$([string]$dispatchReport.run_id) exit_code=$LASTEXITCODE"
                }
                $watchReport = Get-Content -LiteralPath $watchPath -Raw | ConvertFrom-Json -ErrorAction Stop
                $attemptRecord.watch = [ordered]@{
                    run_id = [string]$watchReport.run_id
                    conclusion = [string]$watchReport.conclusion
                    url = [string]$watchReport.url
                    classified_reason = [string]$watchReport.classified_reason
                }
            } catch {
                $executionOk = $false
                $hadExecutionFailure = $true
                $lastExecutionError = [string]$_.Exception.Message
                $attemptRecord.error = $lastExecutionError
            }

            $verifyPath = Join-Path $scratchRoot ("attempt-{0}-verify.json" -f $attempt)
            $verifyAssessment = Invoke-SloGateAssessment `
                -ScriptPath $sloGateScript `
                -Repository $SurfaceRepository `
                -WindowDays $LookbackDays `
                -SuccessThreshold $MinSuccessRatePct `
                -SyncGuardHours $SyncGuardMaxAgeHours `
                -ReportPath $verifyPath

            $verifyReport = $verifyAssessment.report
            $finalReport = $verifyReport
            $attemptRecord.verify = [ordered]@{
                status = [string]$verifyReport.status
                reason_codes = @($verifyReport.reason_codes | ForEach-Object { [string]$_ })
                message = [string]$verifyReport.message
            }

            if ($executionOk -and [string]$verifyReport.status -eq 'pass') {
                $attemptRecord.status = 'recovered'
                [void]$attemptRecords.Add($attemptRecord)
                $recovered = $true
                break
            }

            if (-not $executionOk) {
                $attemptRecord.status = 'remediation_execution_failed'
            } else {
                $attemptRecord.status = 'verify_failed'
            }
            [void]$attemptRecords.Add($attemptRecord)
        }

        $report.remediation_attempts = @($attemptRecords)
        $report.final_report = $finalReport

        if ($recovered) {
            $report.status = 'pass'
            $report.reason_code = 'remediated'
            $report.message = 'SLO gate auto-remediation completed and verification passed.'
        } else {
            $report.status = 'fail'
            if ($hadExecutionFailure -and $null -eq $finalReport) {
                $report.reason_code = 'remediation_execution_failed'
                $report.message = $lastExecutionError
            } else {
                $report.reason_code = 'remediation_verify_failed'
                $finalReasons = @()
                if ($null -ne $finalReport) {
                    $finalReasons = @($finalReport.reason_codes | ForEach-Object { [string]$_ })
                }
                $finalReasonText = if ($finalReasons.Count -gt 0) { [string]::Join(',', $finalReasons) } else { 'unknown' }
                $report.message = "SLO gate remains failing after bounded remediation. final_reason_codes=$finalReasonText"
            }
        }
    }

    $severityGateReport = if ($null -ne $report.final_report) { $report.final_report } else { $report.initial_report }
    $report.alert_severity = Resolve-OpsSloAlertSeverity `
        -OverallStatus ([string]$report.status) `
        -GateReport $severityGateReport `
        -WarningThreshold $WarningMinSuccessRatePct `
        -CriticalThreshold $CriticalMinSuccessRatePct `
        -WarningCodes @($WarningReasonCodes) `
        -CriticalCodes @($CriticalReasonCodes)
} catch {
    $report.status = 'fail'
    $report.reason_code = 'slo_self_heal_runtime_error'
    $report.message = [string]$_.Exception.Message
    $severityGateReport = if ($null -ne $report.final_report) { $report.final_report } else { $report.initial_report }
    $report.alert_severity = Resolve-OpsSloAlertSeverity `
        -OverallStatus ([string]$report.status) `
        -GateReport $severityGateReport `
        -WarningThreshold $WarningMinSuccessRatePct `
        -CriticalThreshold $CriticalMinSuccessRatePct `
        -WarningCodes @($WarningReasonCodes) `
        -CriticalCodes @($CriticalReasonCodes)
}
finally {
    Write-WorkflowOpsReport -Report $report -OutputPath $OutputPath | Out-Null
    if (Test-Path -LiteralPath $scratchRoot -PathType Container) {
        Remove-Item -LiteralPath $scratchRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

if ([string]$report.status -eq 'pass') {
    exit 0
}

exit 1
