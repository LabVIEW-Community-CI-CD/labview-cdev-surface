#Requires -Version 7.0
#Requires -Modules Pester

$ErrorActionPreference = 'Stop'

Describe 'Ops policy drift workflow contract' {
    BeforeAll {
        $script:repoRoot = (Resolve-Path -Path (Join-Path $PSScriptRoot '..')).Path
        $script:workflowPath = Join-Path $script:repoRoot '.github/workflows/ops-policy-drift-check.yml'
        $script:runtimePath = Join-Path $script:repoRoot 'scripts/Test-ReleaseControlPlanePolicyDrift.ps1'

        foreach ($path in @($script:workflowPath, $script:runtimePath)) {
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
                throw "Ops policy drift contract file missing: $path"
            }
        }

        $script:workflowContent = Get-Content -LiteralPath $script:workflowPath -Raw
        $script:runtimeContent = Get-Content -LiteralPath $script:runtimePath -Raw
    }

    It 'is scheduled and dispatchable' {
        $script:workflowContent | Should -Match 'schedule:'
        $script:workflowContent | Should -Match 'workflow_dispatch:'
    }

    It 'runs policy drift validation and incident lifecycle handling' {
        $script:workflowContent | Should -Match 'Test-ReleaseControlPlanePolicyDrift\.ps1'
        $script:workflowContent | Should -Match 'ops-policy-drift-report\.json'
        $script:workflowContent | Should -Match 'Invoke-OpsIncidentLifecycle\.ps1'
        $script:workflowContent | Should -Match 'Ops Policy Drift Alert'
        $script:workflowContent | Should -Match '-Mode Fail'
        $script:workflowContent | Should -Match '-Mode Recover'
    }

    It 'verifies release-client policy equivalence and required ops metadata' {
        $script:runtimeContent | Should -Match 'AllowEmptyCollection'
        $script:runtimeContent | Should -Match 'release_client_equivalent'
        $script:runtimeContent | Should -Match 'release_client_drift'
        $script:runtimeContent | Should -Match 'runtime_images_missing'
        $script:runtimeContent | Should -Match 'ops_control_plane_policy_missing'
        $script:runtimeContent | Should -Match 'ops_control_plane_slo_alert_thresholds_missing'
        $script:runtimeContent | Should -Match 'ops_control_plane_self_healing_missing'
        $script:runtimeContent | Should -Match 'ops_control_plane_guardrails_missing'
        $script:runtimeContent | Should -Match 'ops_control_plane_stable_window_missing'
        $script:runtimeContent | Should -Match 'ops_control_plane_stable_window_reason_pattern_missing'
        $script:runtimeContent | Should -Match 'ops_control_plane_stable_window_reason_example_missing'
    }
}
