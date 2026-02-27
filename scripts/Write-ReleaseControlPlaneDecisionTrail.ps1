#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ReportPath,

    [Parameter()]
    [string]$Repository = '',

    [Parameter()]
    [string]$Workflow = 'release-control-plane.yml',

    [Parameter()]
    [string]$RunId = '',

    [Parameter()]
    [string]$RunUrl = '',

    [Parameter()]
    [string]$Branch = '',

    [Parameter()]
    [string]$HeadSha = '',

    [Parameter()]
    [string]$OutputPath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'lib/WorkflowOps.Common.ps1')

function Get-Sha256HexFromText {
    param(
        [Parameter(Mandatory = $true)][string]$Text
    )

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
        $hash = $sha.ComputeHash($bytes)
        return [string]::Join('', ($hash | ForEach-Object { $_.ToString('x2') }))
    } finally {
        $sha.Dispose()
    }
}

if (-not (Test-Path -LiteralPath $ReportPath -PathType Leaf)) {
    throw "control_plane_report_missing: $ReportPath"
}

$resolvedReportPath = [System.IO.Path]::GetFullPath($ReportPath)
$report = Get-Content -LiteralPath $resolvedReportPath -Raw | ConvertFrom-Json -Depth 100
$reportSha256 = (Get-FileHash -LiteralPath $resolvedReportPath -Algorithm SHA256).Hash.ToLowerInvariant()

$stateMachine = $null
if ($null -ne $report.state_machine) {
    $stateMachine = [ordered]@{
        version = [string]$report.state_machine.version
        initial_state = [string]$report.state_machine.initial_state
        current_state = [string]$report.state_machine.current_state
        terminal_states = @($report.state_machine.terminal_states | ForEach-Object { [string]$_ })
        transitions_executed = @(
            $report.state_machine.transitions_executed |
                ForEach-Object {
                    [ordered]@{
                        timestamp_utc = [string]$_.timestamp_utc
                        from_state = [string]$_.from_state
                        result = [string]$_.result
                        to_state = [string]$_.to_state
                        reason_code = [string]$_.reason_code
                        detail = [string]$_.detail
                    }
                }
        )
    }
}

$rollbackOrchestration = $null
if ($null -ne $report.rollback_orchestration) {
    $rollbackOrchestration = [ordered]@{
        policy_enabled = [bool]$report.rollback_orchestration.policy_enabled
        policy_run_on_dry_run = [bool]$report.rollback_orchestration.policy_run_on_dry_run
        trigger_reason_codes = @($report.rollback_orchestration.trigger_reason_codes | ForEach-Object { [string]$_ })
        attempted = [bool]$report.rollback_orchestration.attempted
        status = [string]$report.rollback_orchestration.status
        reason_code = [string]$report.rollback_orchestration.reason_code
        message = [string]$report.rollback_orchestration.message
        decision = [ordered]@{
            should_attempt = [bool]$report.rollback_orchestration.decision.should_attempt
            decision_reason = [string]$report.rollback_orchestration.decision.decision_reason
        }
    }
}

$executionSummaries = @(
    $report.executions |
        ForEach-Object {
            [ordered]@{
                mode = [string]$_.target_release.mode
                status = [string]$_.target_release.status
                reason_code = [string]$_.target_release.reason_code
                tag = [string]$_.target_release.tag
            }
        }
)

$decisionTrail = [ordered]@{
    schema_version = '1.0'
    generated_at_utc = Get-UtcNowIso
    run_context = [ordered]@{
        repository = if (-not [string]::IsNullOrWhiteSpace($Repository)) { $Repository } else { [string]$report.repository }
        workflow = [string]$Workflow
        run_id = [string]$RunId
        run_url = [string]$RunUrl
        branch = if (-not [string]::IsNullOrWhiteSpace($Branch)) { $Branch } else { [string]$report.branch }
        head_sha = [string]$HeadSha
    }
    report = [ordered]@{
        path = $resolvedReportPath
        sha256 = $reportSha256
        status = [string]$report.status
        reason_code = [string]$report.reason_code
        message = [string]$report.message
        mode = [string]$report.mode
        dry_run = [bool]$report.dry_run
        control_plane_policy_schema_version = [string]$report.control_plane_policy_schema_version
        control_plane_policy_source = [string]$report.control_plane_policy_source
    }
    decision_evidence = [ordered]@{
        state_machine = $stateMachine
        rollback_orchestration = $rollbackOrchestration
        stable_window_decision = [ordered]@{
            status = [string]$report.stable_promotion_window.decision.status
            reason_code = [string]$report.stable_promotion_window.decision.reason_code
            can_promote = [bool]$report.stable_promotion_window.decision.can_promote
            current_utc_weekday = [string]$report.stable_promotion_window.decision.current_utc_weekday
        }
        executions = @($executionSummaries)
    }
}

$fingerprintPayload = [ordered]@{
    report_sha256 = [string]$decisionTrail.report.sha256
    report_status = [string]$decisionTrail.report.status
    report_reason_code = [string]$decisionTrail.report.reason_code
    mode = [string]$decisionTrail.report.mode
    state_machine_current_state = if ($null -eq $decisionTrail.decision_evidence.state_machine) { '' } else { [string]$decisionTrail.decision_evidence.state_machine.current_state }
    rollback_status = if ($null -eq $decisionTrail.decision_evidence.rollback_orchestration) { '' } else { [string]$decisionTrail.decision_evidence.rollback_orchestration.status }
    rollback_reason_code = if ($null -eq $decisionTrail.decision_evidence.rollback_orchestration) { '' } else { [string]$decisionTrail.decision_evidence.rollback_orchestration.reason_code }
}

$decisionTrail.signature = [ordered]@{
    algorithm = 'sha256'
    payload = $fingerprintPayload
    fingerprint = Get-Sha256HexFromText -Text ($fingerprintPayload | ConvertTo-Json -Depth 20 -Compress)
}

Write-WorkflowOpsReport -Report $decisionTrail -OutputPath $OutputPath | Out-Null
