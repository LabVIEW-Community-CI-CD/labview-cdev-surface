#Requires -Version 7.0
#Requires -Modules Pester

$ErrorActionPreference = 'Stop'

Describe 'Ops SLO gate workflow contract' {
    BeforeAll {
        $script:repoRoot = (Resolve-Path -Path (Join-Path $PSScriptRoot '..')).Path
        $script:workflowPath = Join-Path $script:repoRoot '.github/workflows/ops-slo-gate.yml'
        $script:runtimePath = Join-Path $script:repoRoot 'scripts/Test-OpsSloGate.ps1'
        $script:selfHealingPath = Join-Path $script:repoRoot 'scripts/Invoke-OpsSloSelfHealing.ps1'

        foreach ($path in @($script:workflowPath, $script:runtimePath, $script:selfHealingPath)) {
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
                throw "Ops SLO gate contract file missing: $path"
            }
        }

        $script:workflowContent = Get-Content -LiteralPath $script:workflowPath -Raw
        $script:runtimeContent = Get-Content -LiteralPath $script:runtimePath -Raw
        $script:selfHealingContent = Get-Content -LiteralPath $script:selfHealingPath -Raw
    }

    It 'is scheduled and dispatchable with deterministic SLO inputs' {
        $script:workflowContent | Should -Match 'schedule:'
        $script:workflowContent | Should -Match 'workflow_dispatch:'
        $script:workflowContent | Should -Match 'lookback_days'
        $script:workflowContent | Should -Match 'min_success_rate_pct'
        $script:workflowContent | Should -Match 'sync_guard_max_age_hours'
        $script:workflowContent | Should -Match 'auto_self_heal'
        $script:workflowContent | Should -Match 'self_heal_max_attempts'
        $script:workflowContent | Should -Match 'self_heal_watch_timeout_minutes'
        $script:workflowContent | Should -Match 'warning_min_success_rate_pct'
        $script:workflowContent | Should -Match 'critical_min_success_rate_pct'
    }

    It 'runs self-healing SLO runtime, uploads report, and manages incident lifecycle' {
        $script:workflowContent | Should -Match 'Invoke-OpsSloSelfHealing\.ps1'
        $script:workflowContent | Should -Match 'ops-slo-gate-report\.json'
        $script:workflowContent | Should -Match 'Invoke-OpsIncidentLifecycle\.ps1'
        $script:workflowContent | Should -Match 'Ops SLO Gate Alert'
        $script:workflowContent | Should -Match '-Mode Fail'
        $script:workflowContent | Should -Match '-Mode Recover'
        $script:workflowContent | Should -Match 'actions:\s*write'
    }

    It 'evaluates workflow and sync-guard SLO conditions with deterministic reason codes' {
        $script:runtimeContent | Should -Match 'Write-OpsSloReport\.ps1'
        $script:runtimeContent | Should -Match 'AllowEmptyCollection'
        $script:runtimeContent | Should -Match 'ops-monitoring'
        $script:runtimeContent | Should -Match 'ops-autoremediate'
        $script:runtimeContent | Should -Match 'release-control-plane'
        $script:runtimeContent | Should -Match 'workflow_missing_runs'
        $script:runtimeContent | Should -Match 'workflow_failure_detected'
        $script:runtimeContent | Should -Match 'workflow_success_rate_below_threshold'
        $script:runtimeContent | Should -Match 'sync_guard_stale'
        $script:runtimeContent | Should -Match 'sync_guard_missing'
    }

    It 'runs bounded SLO self-healing playbook with deterministic outcomes' {
        $script:selfHealingContent | Should -Match 'Dispatch-WorkflowAtRemoteHead\.ps1'
        $script:selfHealingContent | Should -Match 'Watch-WorkflowRun\.ps1'
        $script:selfHealingContent | Should -Match 'ops-autoremediate\.yml'
        $script:selfHealingContent | Should -Match '\$dispatchInputs = @\('
        $script:selfHealingContent | Should -Match '-Inputs \$dispatchInputs'
        $script:selfHealingContent | Should -Match 'sync_guard_max_age_hours'
        $script:selfHealingContent | Should -Match 'warning_min_success_rate_pct'
        $script:selfHealingContent | Should -Match 'critical_min_success_rate_pct'
        $script:selfHealingContent | Should -Match 'alert_severity'
        $script:selfHealingContent | Should -Match 'critical_reason_codes'
        $script:selfHealingContent | Should -Match 'warning_reason_codes'
        $script:selfHealingContent | Should -Match 'already_healthy'
        $script:selfHealingContent | Should -Match 'remediated'
        $script:selfHealingContent | Should -Match 'auto_remediation_disabled'
        $script:selfHealingContent | Should -Match 'remediation_verify_failed'
        $script:selfHealingContent | Should -Match 'slo_self_heal_runtime_error'
    }
}
