#Requires -Version 7.0
#Requires -Modules Pester

$ErrorActionPreference = 'Stop'

Describe 'Release rollback drill workflow contract' {
    BeforeAll {
        $script:repoRoot = (Resolve-Path -Path (Join-Path $PSScriptRoot '..')).Path
        $script:workflowPath = Join-Path $script:repoRoot '.github/workflows/release-rollback-drill.yml'
        $script:runtimePath = Join-Path $script:repoRoot 'scripts/Invoke-ReleaseRollbackDrill.ps1'

        foreach ($path in @($script:workflowPath, $script:runtimePath)) {
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
                throw "Release rollback drill contract file missing: $path"
            }
        }

        $script:workflowContent = Get-Content -LiteralPath $script:workflowPath -Raw
        $script:runtimeContent = Get-Content -LiteralPath $script:runtimePath -Raw
    }

    It 'is scheduled and dispatchable with channel and history controls' {
        $script:workflowContent | Should -Match 'schedule:'
        $script:workflowContent | Should -Match 'workflow_dispatch:'
        $script:workflowContent | Should -Match 'channel:'
        $script:workflowContent | Should -Match 'required_history_count'
    }

    It 'runs rollback drill runtime, uploads report, and manages incident lifecycle' {
        $script:workflowContent | Should -Match 'Invoke-ReleaseRollbackDrill\.ps1'
        $script:workflowContent | Should -Match 'release-rollback-drill-report\.json'
        $script:workflowContent | Should -Match 'Invoke-OpsIncidentLifecycle\.ps1'
        $script:workflowContent | Should -Match 'Release Rollback Drill Alert'
        $script:workflowContent | Should -Match '-Mode Fail'
        $script:workflowContent | Should -Match '-Mode Recover'
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
}
