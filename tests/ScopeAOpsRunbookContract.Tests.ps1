#Requires -Version 7.0
#Requires -Modules Pester

$ErrorActionPreference = 'Stop'

Describe 'Scope A ops runbook contract' {
    BeforeAll {
        $script:repoRoot = (Resolve-Path -Path (Join-Path $PSScriptRoot '..')).Path
        $script:runbookPath = Join-Path $script:repoRoot 'docs/runbooks/release-ops-incident-response.md'
        $script:readmePath = Join-Path $script:repoRoot 'README.md'
        $script:agentsPath = Join-Path $script:repoRoot 'AGENTS.md'

        foreach ($path in @($script:runbookPath, $script:readmePath, $script:agentsPath)) {
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
                throw "Required ops hardening contract file missing: $path"
            }
        }

        $script:runbookContent = Get-Content -LiteralPath $script:runbookPath -Raw
        $script:readmeContent = Get-Content -LiteralPath $script:readmePath -Raw
        $script:agentsContent = Get-Content -LiteralPath $script:agentsPath -Raw
    }

    It 'documents deterministic incident commands for runner, sync-guard, and canary hygiene' {
        $script:runbookContent | Should -Match 'Get-Service'
        $script:runbookContent | Should -Match 'fork-upstream-sync-guard'
        $script:runbookContent | Should -Match 'Invoke-ControlledForkForceAlign\.ps1'
        $script:runbookContent | Should -Match 'Invoke-CanarySmokeTagHygiene\.ps1'
        $script:runbookContent | Should -Match 'Invoke-OpsIncidentLifecycle\.ps1'
        $script:runbookContent | Should -Match 'ops-slo-gate\.yml'
        $script:runbookContent | Should -Match 'ops-policy-drift-check\.yml'
        $script:runbookContent | Should -Match 'release-rollback-drill\.yml'
        $script:runbookContent | Should -Match 'release-race-hardening-drill\.yml'
        $script:runbookContent | Should -Match 'Invoke-ReleaseRaceHardeningDrill\.ps1'
        $script:runbookContent | Should -Match 'auto_self_heal=false'
        $script:runbookContent | Should -Match '20260226'
        $script:runbookContent | Should -Match 'release_verification_failed'
        $script:runbookContent | Should -Match 'control_plane_collision_not_observed'
        $script:runbookContent | Should -Match 'drill_passed'
        $script:runbookContent | Should -Match 'promotion_lineage_invalid'
        $script:runbookContent | Should -Match 'stable_window_override_invalid'
        $script:runbookContent | Should -Match 'release-manifest\.json'
        $script:runbookContent | Should -Match 'release_dispatch_watch_failed'
        $script:runbookContent | Should -Match 'force_stable_promotion_outside_window=true'
        $script:runbookContent | Should -Match 'CHG-1234'
        $script:runbookContent | Should -Match 'Release Control Plane Stable Override Alert'
        $script:runbookContent | Should -Match 'release-control-plane-override-audit\.json'
    }

    It 'keeps README and AGENTS aligned to Scope A workflows' {
        $script:readmeContent | Should -Match 'ops-monitoring\.yml'
        $script:readmeContent | Should -Match 'canary-smoke-tag-hygiene\.yml'
        $script:readmeContent | Should -Match 'ops-slo-gate\.yml'
        $script:readmeContent | Should -Match 'ops-policy-drift-check\.yml'
        $script:readmeContent | Should -Match 'release-rollback-drill\.yml'
        $script:readmeContent | Should -Match 'release-race-hardening-drill\.yml'
        $script:readmeContent | Should -Match 'Invoke-OpsSloSelfHealing\.ps1'
        $script:readmeContent | Should -Match 'Invoke-RollbackDrillSelfHealing\.ps1'
        $script:readmeContent | Should -Match 'Invoke-ReleaseRaceHardeningDrill\.ps1'
        $script:readmeContent | Should -Match 'release-ops-incident-response\.md'

        $script:agentsContent | Should -Match 'Ops Monitoring Policy'
        $script:agentsContent | Should -Match 'runner_unavailable'
        $script:agentsContent | Should -Match 'sync_guard_failed'
        $script:agentsContent | Should -Match 'canary-smoke-tag-hygiene\.yml'
        $script:agentsContent | Should -Match 'ops-slo-gate\.yml'
        $script:agentsContent | Should -Match 'ops-policy-drift-check\.yml'
        $script:agentsContent | Should -Match 'release-rollback-drill\.yml'
        $script:agentsContent | Should -Match 'release-race-hardening-drill\.yml'
        $script:agentsContent | Should -Match 'Invoke-OpsSloSelfHealing\.ps1'
        $script:agentsContent | Should -Match 'Invoke-RollbackDrillSelfHealing\.ps1'
        $script:agentsContent | Should -Match 'Invoke-ReleaseRaceHardeningDrill\.ps1'
    }
}
