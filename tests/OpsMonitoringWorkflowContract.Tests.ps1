#Requires -Version 7.0
#Requires -Modules Pester

$ErrorActionPreference = 'Stop'

Describe 'Ops monitoring workflow contract' {
    BeforeAll {
        $script:repoRoot = (Resolve-Path -Path (Join-Path $PSScriptRoot '..')).Path
        $script:workflowPath = Join-Path $script:repoRoot '.github/workflows/ops-monitoring.yml'
        $script:scriptPath = Join-Path $script:repoRoot 'scripts/Invoke-OpsMonitoringSnapshot.ps1'

        if (-not (Test-Path -LiteralPath $script:workflowPath -PathType Leaf)) {
            throw "Ops monitoring workflow missing: $script:workflowPath"
        }
        if (-not (Test-Path -LiteralPath $script:scriptPath -PathType Leaf)) {
            throw "Ops monitoring script missing: $script:scriptPath"
        }

        $script:workflowContent = Get-Content -LiteralPath $script:workflowPath -Raw
        $script:scriptContent = Get-Content -LiteralPath $script:scriptPath -Raw
    }

    It 'is scheduled and dispatchable' {
        $script:workflowContent | Should -Match 'schedule:'
        $script:workflowContent | Should -Match 'workflow_dispatch:'
        $script:workflowContent | Should -Match 'cron:'
    }

    It 'runs snapshot script and uploads deterministic report artifact' {
        $script:workflowContent | Should -Match 'Invoke-OpsMonitoringSnapshot\.ps1'
        $script:workflowContent | Should -Match 'ops-monitoring-report\.json'
        $script:workflowContent | Should -Match 'upload-artifact'
        $script:workflowContent | Should -Match 'Ops Monitoring Alert'
    }

    It 'checks runner and sync-guard health with deterministic reason codes' {
        $script:scriptContent | Should -Match 'repos/\$SurfaceRepository/actions/runners\?per_page=100'
        $script:scriptContent | Should -Match 'Get-GhWorkflowRunsPortable'
        $script:scriptContent | Should -Match 'runner_unavailable'
        $script:scriptContent | Should -Match 'runner_visibility_unavailable'
        $script:scriptContent | Should -Match 'sync_guard_failed'
        $script:scriptContent | Should -Match 'sync_guard_stale'
        $script:scriptContent | Should -Match 'sync_guard_missing'
        $script:scriptContent | Should -Match 'sync_guard_incomplete'
    }
}
