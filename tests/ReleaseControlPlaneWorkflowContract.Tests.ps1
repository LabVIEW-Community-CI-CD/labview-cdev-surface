#Requires -Version 7.0
#Requires -Modules Pester

$ErrorActionPreference = 'Stop'

Describe 'Release control plane workflow contract' {
    BeforeAll {
        $script:repoRoot = (Resolve-Path -Path (Join-Path $PSScriptRoot '..')).Path
        $script:workflowPath = Join-Path $script:repoRoot '.github/workflows/release-control-plane.yml'
        $script:runtimePath = Join-Path $script:repoRoot 'scripts/Invoke-ReleaseControlPlane.ps1'

        if (-not (Test-Path -LiteralPath $script:workflowPath -PathType Leaf)) {
            throw "Release control plane workflow missing: $script:workflowPath"
        }
        if (-not (Test-Path -LiteralPath $script:runtimePath -PathType Leaf)) {
            throw "Release control plane runtime missing: $script:runtimePath"
        }

        $script:workflowContent = Get-Content -LiteralPath $script:workflowPath -Raw
        $script:runtimeContent = Get-Content -LiteralPath $script:runtimePath -Raw
    }

    It 'is scheduled and dispatchable with control inputs' {
        $script:workflowContent | Should -Match 'schedule:'
        $script:workflowContent | Should -Match 'workflow_dispatch:'
        $script:workflowContent | Should -Match 'mode:'
        $script:workflowContent | Should -Match 'FullCycle'
        $script:workflowContent | Should -Match 'auto_remediate'
        $script:workflowContent | Should -Match 'keep_latest_canary_n'
        $script:workflowContent | Should -Match 'dry_run'
    }

    It 'runs autonomous control-plane runtime and uploads report' {
        $script:workflowContent | Should -Match 'runs-on:\s*ubuntu-latest'
        $script:workflowContent | Should -Match 'Enforce hosted-runner lock'
        $script:workflowContent | Should -Match 'RUNNER_ENVIRONMENT'
        $script:workflowContent | Should -Match 'hosted_runner_required'
        $script:workflowContent | Should -Match 'Invoke-ReleaseControlPlane\.ps1'
        $script:workflowContent | Should -Match 'release-control-plane-report\.json'
        $script:workflowContent | Should -Match 'Release Control Plane Alert'
        $script:workflowContent | Should -Match 'actions:\s*write'
        $script:workflowContent | Should -Match 'contents:\s*write'
    }

    It 'implements mode sequencing, promotion guards, and deterministic tag ranges' {
        $script:runtimeContent | Should -Match "ValidateSet\('Validate', 'CanaryCycle', 'PromotePrerelease', 'PromoteStable', 'FullCycle'\)"
        $script:runtimeContent | Should -Match 'range_min = 1'
        $script:runtimeContent | Should -Match 'range_max = 49'
        $script:runtimeContent | Should -Match 'range_min = 50'
        $script:runtimeContent | Should -Match 'range_max = 79'
        $script:runtimeContent | Should -Match 'range_min = 80'
        $script:runtimeContent | Should -Match 'range_max = 99'
        $script:runtimeContent | Should -Match 'promotion_source_missing'
        $script:runtimeContent | Should -Match 'promotion_source_asset_missing'
        $script:runtimeContent | Should -Match 'promotion_source_not_at_head'
        $script:runtimeContent | Should -Match 'release_tag_range_exhausted'
        $script:runtimeContent | Should -Match 'Invoke-CanarySmokeTagHygiene\.ps1'
    }

    It 'decouples control-plane runner health gate to release-runner labels' {
        $script:runtimeContent | Should -Match 'RequiredRunnerLabels \$releaseRunnerLabels'
        $script:runtimeContent | Should -Match "self-hosted', 'windows', 'self-hosted-windows-lv"
        $script:runtimeContent | Should -Not -Match 'windows-containers'
        $script:runtimeContent | Should -Not -Match 'user-session'
        $script:runtimeContent | Should -Not -Match 'cdev-surface-windows-gate'
    }
}
