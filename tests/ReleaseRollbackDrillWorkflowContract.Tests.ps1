#Requires -Version 7.0
#Requires -Modules Pester

$ErrorActionPreference = 'Stop'

Describe 'Release rollback drill workflow contract' {
    BeforeAll {
        $script:repoRoot = (Resolve-Path -Path (Join-Path $PSScriptRoot '..')).Path
        $script:workflowPath = Join-Path $script:repoRoot '.github/workflows/release-rollback-drill.yml'
        $script:runtimePath = Join-Path $script:repoRoot 'scripts/Invoke-ReleaseRollbackDrill.ps1'
        $script:selfHealingPath = Join-Path $script:repoRoot 'scripts/Invoke-RollbackDrillSelfHealing.ps1'

        foreach ($path in @($script:workflowPath, $script:runtimePath, $script:selfHealingPath)) {
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
                throw "Release rollback drill contract file missing: $path"
            }
        }

        $script:workflowContent = Get-Content -LiteralPath $script:workflowPath -Raw
        $script:runtimeContent = Get-Content -LiteralPath $script:runtimePath -Raw
        $script:selfHealingContent = Get-Content -LiteralPath $script:selfHealingPath -Raw
    }

    It 'is scheduled and dispatchable with channel, history, and self-healing controls' {
        $script:workflowContent | Should -Match 'schedule:'
        $script:workflowContent | Should -Match 'workflow_dispatch:'
        $script:workflowContent | Should -Match 'channel:'
        $script:workflowContent | Should -Match 'required_history_count'
        $script:workflowContent | Should -Match 'auto_self_heal'
        $script:workflowContent | Should -Match 'self_heal_max_attempts'
        $script:workflowContent | Should -Match 'self_heal_watch_timeout_minutes'
    }

    It 'runs rollback self-healing runtime, uploads report, and manages incident lifecycle' {
        $script:workflowContent | Should -Match 'Invoke-RollbackDrillSelfHealing\.ps1'
        $script:workflowContent | Should -Match 'release-rollback-drill-report\.json'
        $script:workflowContent | Should -Match 'Invoke-OpsIncidentLifecycle\.ps1'
        $script:workflowContent | Should -Match 'Release Rollback Drill Alert'
        $script:workflowContent | Should -Match '-Mode Fail'
        $script:workflowContent | Should -Match '-Mode Recover'
        $script:workflowContent | Should -Match 'actions:\s*write'
    }

    It 'validates channel-specific release history and required rollback assets' {
        $script:runtimeContent | Should -Match "ValidateSet\('stable', 'prerelease', 'canary'\)"
        $script:runtimeContent | Should -Match 'AllowEmptyCollection'
        $script:runtimeContent | Should -Match 'rollback_candidate_missing'
        $script:runtimeContent | Should -Match 'rollback_assets_missing'
        $script:runtimeContent | Should -Match 'lvie-cdev-workspace-installer\.exe'
        $script:runtimeContent | Should -Match 'release-manifest\.json'
        $script:runtimeContent | Should -Match 'workspace-installer\.spdx\.json'
        $script:runtimeContent | Should -Match 'workspace-installer\.slsa\.json'
        $script:runtimeContent | Should -Match 'reproducibility-report\.json'
    }

    It 'runs bounded rollback self-healing by triggering canary release workflow and re-verifying' {
        $script:selfHealingContent | Should -Match 'Invoke-ReleaseRollbackDrill\.ps1'
        $script:selfHealingContent | Should -Match 'Dispatch-WorkflowAtRemoteHead\.ps1'
        $script:selfHealingContent | Should -Match 'Watch-WorkflowRun\.ps1'
        $script:selfHealingContent | Should -Match 'release-workspace-installer\.yml'
        $script:selfHealingContent | Should -Match 'release_channel=canary'
        $script:selfHealingContent | Should -Match 'allow_existing_tag=false'
        $script:selfHealingContent | Should -Match 'rollback_candidate_missing'
        $script:selfHealingContent | Should -Match 'already_ready'
        $script:selfHealingContent | Should -Match 'remediated'
        $script:selfHealingContent | Should -Match 'no_automatable_action'
        $script:selfHealingContent | Should -Match 'rollback_self_heal_runtime_error'
    }
}
