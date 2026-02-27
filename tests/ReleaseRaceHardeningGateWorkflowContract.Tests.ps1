#Requires -Version 7.0
#Requires -Modules Pester

$ErrorActionPreference = 'Stop'

Describe 'Release race-hardening gate workflow contract' {
    BeforeAll {
        $script:repoRoot = (Resolve-Path -Path (Join-Path $PSScriptRoot '..')).Path
        $script:workflowPath = Join-Path $script:repoRoot '.github/workflows/release-race-hardening-gate.yml'
        $script:runtimePath = Join-Path $script:repoRoot 'scripts/Test-ReleaseRaceHardeningGate.ps1'

        foreach ($path in @($script:workflowPath, $script:runtimePath)) {
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
                throw "Release race-hardening gate contract file missing: $path"
            }
        }

        $script:workflowContent = Get-Content -LiteralPath $script:workflowPath -Raw
        $script:runtimeContent = Get-Content -LiteralPath $script:runtimePath -Raw
    }

    It 'runs on main and integration PR/push plus manual dispatch' {
        $script:workflowContent | Should -Match 'push:'
        $script:workflowContent | Should -Match 'pull_request:'
        $script:workflowContent | Should -Match 'main'
        $script:workflowContent | Should -Match 'integration/\*\*'
        $script:workflowContent | Should -Match 'workflow_dispatch:'
        $script:workflowContent | Should -Match 'source_branch'
        $script:workflowContent | Should -Match 'max_age_hours'
    }

    It 'exposes required check context and uploads gate report artifact' {
        $script:workflowContent | Should -Match 'name:\s*Release Race Hardening Drill'
        $script:workflowContent | Should -Match 'runs-on:\s*ubuntu-latest'
        $script:workflowContent | Should -Match 'Test-ReleaseRaceHardeningGate\.ps1'
        $script:workflowContent | Should -Match 'release-race-hardening-gate-report\.json'
    }

    It 'validates latest successful drill report reason code and collision evidence' {
        $script:runtimeContent | Should -Match 'Get-GhWorkflowRunsPortable'
        $script:runtimeContent | Should -Match 'drill_run_missing'
        $script:runtimeContent | Should -Match 'drill_run_stale'
        $script:runtimeContent | Should -Match 'drill_report_download_failed'
        $script:runtimeContent | Should -Match 'drill_reason_code_invalid'
        $script:runtimeContent | Should -Match 'drill_collision_evidence_missing'
        $script:runtimeContent | Should -Match 'drill_release_verification_missing'
        $script:runtimeContent | Should -Match 'drill_gate_runtime_error'
        $script:runtimeContent | Should -Match "reason_codes = @\('ok'\)"
        $script:runtimeContent | Should -Match 'drill_passed'
        $script:runtimeContent | Should -Match 'gh run download'
    }
}
