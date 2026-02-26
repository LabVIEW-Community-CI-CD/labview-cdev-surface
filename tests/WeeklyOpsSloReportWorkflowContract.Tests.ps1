#Requires -Version 7.0
#Requires -Modules Pester

$ErrorActionPreference = 'Stop'

Describe 'Weekly ops SLO workflow contract' {
    BeforeAll {
        $script:repoRoot = (Resolve-Path -Path (Join-Path $PSScriptRoot '..')).Path
        $script:workflowPath = Join-Path $script:repoRoot '.github/workflows/weekly-ops-slo-report.yml'
        $script:runtimePath = Join-Path $script:repoRoot 'scripts/Write-OpsSloReport.ps1'

        if (-not (Test-Path -LiteralPath $script:workflowPath -PathType Leaf)) {
            throw "Weekly ops SLO workflow missing: $script:workflowPath"
        }
        if (-not (Test-Path -LiteralPath $script:runtimePath -PathType Leaf)) {
            throw "Weekly ops SLO runtime missing: $script:runtimePath"
        }

        $script:workflowContent = Get-Content -LiteralPath $script:workflowPath -Raw
        $script:runtimeContent = Get-Content -LiteralPath $script:runtimePath -Raw
    }

    It 'is scheduled weekly and dispatchable with lookback input' {
        $script:workflowContent | Should -Match 'schedule:'
        $script:workflowContent | Should -Match 'workflow_dispatch:'
        $script:workflowContent | Should -Match 'lookback_days'
        $script:workflowContent | Should -Match 'weekly-ops-slo-report'
    }

    It 'generates and uploads machine-readable SLO report artifact' {
        $script:workflowContent | Should -Match 'Write-OpsSloReport\.ps1'
        $script:workflowContent | Should -Match 'weekly-ops-slo-report\.json'
        $script:workflowContent | Should -Match 'upload-artifact'
    }

    It 'calculates workflow and sync-guard SLO summaries' {
        $script:runtimeContent | Should -Match 'Get-WorkflowSloSummary'
        $script:runtimeContent | Should -Match 'ops-monitoring'
        $script:runtimeContent | Should -Match 'ops-autoremediate'
        $script:runtimeContent | Should -Match 'release-control-plane'
        $script:runtimeContent | Should -Match 'fork-upstream-sync-guard'
        $script:runtimeContent | Should -Match 'success_rate_pct'
    }
}
