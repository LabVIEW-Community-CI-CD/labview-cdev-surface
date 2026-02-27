#Requires -Version 7.0
#Requires -Modules Pester

$ErrorActionPreference = 'Stop'

Describe 'Ops SLO gate workflow contract' {
    BeforeAll {
        $script:repoRoot = (Resolve-Path -Path (Join-Path $PSScriptRoot '..')).Path
        $script:workflowPath = Join-Path $script:repoRoot '.github/workflows/ops-slo-gate.yml'
        $script:runtimePath = Join-Path $script:repoRoot 'scripts/Test-OpsSloGate.ps1'

        foreach ($path in @($script:workflowPath, $script:runtimePath)) {
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
                throw "Ops SLO gate contract file missing: $path"
            }
        }

        $script:workflowContent = Get-Content -LiteralPath $script:workflowPath -Raw
        $script:runtimeContent = Get-Content -LiteralPath $script:runtimePath -Raw
    }

    It 'is scheduled and dispatchable with deterministic SLO inputs' {
        $script:workflowContent | Should -Match 'schedule:'
        $script:workflowContent | Should -Match 'workflow_dispatch:'
        $script:workflowContent | Should -Match 'lookback_days'
        $script:workflowContent | Should -Match 'min_success_rate_pct'
        $script:workflowContent | Should -Match 'sync_guard_max_age_hours'
    }

    It 'runs SLO gate runtime, uploads report, and manages incident lifecycle' {
        $script:workflowContent | Should -Match 'Test-OpsSloGate\.ps1'
        $script:workflowContent | Should -Match 'ops-slo-gate-report\.json'
        $script:workflowContent | Should -Match 'Invoke-OpsIncidentLifecycle\.ps1'
        $script:workflowContent | Should -Match 'Ops SLO Gate Alert'
        $script:workflowContent | Should -Match '-Mode Fail'
        $script:workflowContent | Should -Match '-Mode Recover'
    }

    It 'evaluates workflow and sync-guard SLO conditions with deterministic reason codes' {
        $script:runtimeContent | Should -Match 'Write-OpsSloReport\.ps1'
        $script:runtimeContent | Should -Match 'ops-monitoring'
        $script:runtimeContent | Should -Match 'ops-autoremediate'
        $script:runtimeContent | Should -Match 'release-control-plane'
        $script:runtimeContent | Should -Match 'workflow_missing_runs'
        $script:runtimeContent | Should -Match 'workflow_failure_detected'
        $script:runtimeContent | Should -Match 'workflow_success_rate_below_threshold'
        $script:runtimeContent | Should -Match 'sync_guard_stale'
        $script:runtimeContent | Should -Match 'sync_guard_missing'
    }
}
