#Requires -Version 7.0
#Requires -Modules Pester

$ErrorActionPreference = 'Stop'

Describe 'Release race-hardening drill workflow contract' {
    BeforeAll {
        $script:repoRoot = (Resolve-Path -Path (Join-Path $PSScriptRoot '..')).Path
        $script:workflowPath = Join-Path $script:repoRoot '.github/workflows/release-race-hardening-drill.yml'
        $script:runtimePath = Join-Path $script:repoRoot 'scripts/Invoke-ReleaseRaceHardeningDrill.ps1'

        foreach ($path in @($script:workflowPath, $script:runtimePath)) {
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
                throw "Release race-hardening contract file missing: $path"
            }
        }

        $script:workflowContent = Get-Content -LiteralPath $script:workflowPath -Raw
        $script:runtimeContent = Get-Content -LiteralPath $script:runtimePath -Raw
    }

    It 'is scheduled and dispatchable with bounded drill controls' {
        $script:workflowContent | Should -Match 'schedule:'
        $script:workflowContent | Should -Match 'workflow_dispatch:'
        $script:workflowContent | Should -Match 'auto_remediate'
        $script:workflowContent | Should -Match 'keep_latest_canary_n'
        $script:workflowContent | Should -Match 'watch_timeout_minutes'
    }

    It 'runs on hosted runner, executes drill runtime, and uploads drill + weekly summary artifacts' {
        $script:workflowContent | Should -Match 'runs-on:\s*ubuntu-latest'
        $script:workflowContent | Should -Match 'Enforce hosted-runner lock'
        $script:workflowContent | Should -Match 'RUNNER_ENVIRONMENT'
        $script:workflowContent | Should -Match 'hosted_runner_required'
        $script:workflowContent | Should -Match 'Invoke-ReleaseRaceHardeningDrill\.ps1'
        $script:workflowContent | Should -Match 'release-race-hardening-drill-report\.json'
        $script:workflowContent | Should -Match 'release-race-hardening-weekly-summary\.json'
        $script:workflowContent | Should -Match 'Upload release race-hardening weekly summary'
        $script:workflowContent | Should -Match 'actions:\s*write'
    }

    It 'dispatches contender and control-plane workflows then verifies collision evidence from control-plane report artifact' {
        $script:runtimeContent | Should -Match 'Dispatch-WorkflowAtRemoteHead\.ps1'
        $script:runtimeContent | Should -Match 'Watch-WorkflowRun\.ps1'
        $script:runtimeContent | Should -Match 'release-workspace-installer\.yml'
        $script:runtimeContent | Should -Match 'release-control-plane\.yml'
        $script:runtimeContent | Should -Match 'mode=CanaryCycle'
        $script:runtimeContent | Should -Match 'release-control-plane-report-'
        $script:runtimeContent | Should -Match 'gh run download'
        $script:runtimeContent | Should -Match 'control_plane_collision_not_observed'
        $script:runtimeContent | Should -Match 'collision_retries'
        $script:runtimeContent | Should -Match 'contender_dispatch_report_invalid'
        $script:runtimeContent | Should -Match 'control_plane_dispatch_report_invalid'
        $script:runtimeContent | Should -Match 'control_plane_watch_timeout'
        $script:runtimeContent | Should -Match 'contender_run_id'
        $script:runtimeContent | Should -Match 'control_plane_run_id'
        $script:runtimeContent | Should -Match 'tag_already_published_by_peer'
        $script:runtimeContent | Should -Match 'reproducibility-report\.json'
        $script:runtimeContent | Should -Match 'drill_passed'
    }

    It 'computes semver canary target tags deterministically' {
        $script:runtimeContent | Should -Match 'Get-NextSemVerCanaryTag'
        $script:runtimeContent | Should -Match "tag_family = 'semver'"
        $script:runtimeContent | Should -Match '-canary\.'
        $script:runtimeContent | Should -Match 'semver_prerelease_sequence_exhausted'
    }

    It 'manages incident lifecycle for drill failures and recoveries' {
        $script:workflowContent | Should -Match 'Release Race Hardening Drill Alert'
        $script:workflowContent | Should -Match 'Invoke-OpsIncidentLifecycle\.ps1'
        $script:workflowContent | Should -Match '-Mode Fail'
        $script:workflowContent | Should -Match '-Mode Recover'
        $script:workflowContent | Should -Match 'issues:\s*write'
    }
}
