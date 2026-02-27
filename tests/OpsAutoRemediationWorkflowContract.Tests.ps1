#Requires -Version 7.0
#Requires -Modules Pester

$ErrorActionPreference = 'Stop'

Describe 'Ops auto-remediation workflow contract' {
    BeforeAll {
        $script:repoRoot = (Resolve-Path -Path (Join-Path $PSScriptRoot '..')).Path
        $script:workflowPath = Join-Path $script:repoRoot '.github/workflows/ops-autoremediate.yml'
        $script:runtimePath = Join-Path $script:repoRoot 'scripts/Invoke-OpsAutoRemediation.ps1'

        if (-not (Test-Path -LiteralPath $script:workflowPath -PathType Leaf)) {
            throw "Ops auto-remediation workflow missing: $script:workflowPath"
        }
        if (-not (Test-Path -LiteralPath $script:runtimePath -PathType Leaf)) {
            throw "Ops auto-remediation runtime missing: $script:runtimePath"
        }

        $script:workflowContent = Get-Content -LiteralPath $script:workflowPath -Raw
        $script:runtimeContent = Get-Content -LiteralPath $script:runtimePath -Raw
    }

    It 'is scheduled and dispatchable' {
        $script:workflowContent | Should -Match 'schedule:'
        $script:workflowContent | Should -Match 'workflow_dispatch:'
        $script:workflowContent | Should -Match 'sync_guard_max_age_hours'
        $script:workflowContent | Should -Match 'actions:\s*write'
    }

    It 'executes deterministic remediation and reports incidents' {
        $script:workflowContent | Should -Match 'Invoke-OpsAutoRemediation\.ps1'
        $script:workflowContent | Should -Match 'Invoke-OpsIncidentLifecycle\.ps1'
        $script:workflowContent | Should -Match 'ops-autoremediate-report\.json'
        $script:workflowContent | Should -Match 'Ops Auto-Remediation Alert'
        $script:workflowContent | Should -Match '-Mode Fail'
        $script:workflowContent | Should -Match '-Mode Recover'
    }

    It 'targets sync-guard drift and classifies manual runner intervention' {
        $script:runtimeContent | Should -Match 'Invoke-OpsMonitoringSnapshot\.ps1'
        $script:runtimeContent | Should -Match 'Dispatch-WorkflowAtRemoteHead\.ps1'
        $script:runtimeContent | Should -Match 'Watch-WorkflowRun\.ps1'
        $script:runtimeContent | Should -Match 'manual_intervention_required'
        $script:runtimeContent | Should -Match 'remediated'
        $script:runtimeContent | Should -Match 'no_automatable_action'
        $script:runtimeContent | Should -Match 'remediation_failed'
    }

    It 'uses release-runner labels for control-plane remediation health checks' {
        $script:runtimeContent | Should -Match "self-hosted',\s*'windows',\s*'self-hosted-windows-lv"
        $script:runtimeContent | Should -Match 'RequiredRunnerLabelsCsv \$requiredRunnerLabelsCsv'
        $script:runtimeContent | Should -Not -Match 'windows-containers'
        $script:runtimeContent | Should -Not -Match 'user-session'
        $script:runtimeContent | Should -Not -Match 'cdev-surface-windows-gate'
    }
}
