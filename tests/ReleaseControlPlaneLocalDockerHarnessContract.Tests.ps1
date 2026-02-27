#Requires -Version 7.0
#Requires -Modules Pester

$ErrorActionPreference = 'Stop'

Describe 'Release control plane local Docker harness contract' {
    BeforeAll {
        $script:repoRoot = (Resolve-Path -Path (Join-Path $PSScriptRoot '..')).Path
        $script:wrapperPath = Join-Path $script:repoRoot 'scripts/Invoke-ReleaseControlPlaneLocalDocker.ps1'
        $script:harnessPath = Join-Path $script:repoRoot 'scripts/Exercise-ReleaseControlPlaneLocal.ps1'

        if (-not (Test-Path -LiteralPath $script:wrapperPath -PathType Leaf)) {
            throw "Local Docker wrapper missing: $script:wrapperPath"
        }
        if (-not (Test-Path -LiteralPath $script:harnessPath -PathType Leaf)) {
            throw "Local Docker harness runtime missing: $script:harnessPath"
        }

        $script:wrapperContent = Get-Content -LiteralPath $script:wrapperPath -Raw
        $script:harnessContent = Get-Content -LiteralPath $script:harnessPath -Raw
    }

    It 'wraps release control plane local harness through portable container runtime' {
        $script:wrapperContent | Should -Match 'Invoke-PortableOps\.ps1'
        $script:wrapperContent | Should -Match 'Exercise-ReleaseControlPlaneLocal\.ps1'
        $script:wrapperContent | Should -Match 'ghcr\.io/labview-community-ci-cd/labview-cdev-surface-ops:v1'
        $script:wrapperContent | Should -Match 'BuildLocalImage'
        $script:wrapperContent | Should -Match 'HostFallback'
    }

    It 'executes deterministic control-plane local steps and writes summary report' {
        $script:harnessContent | Should -Match 'Invoke-OpsMonitoringSnapshot\.ps1'
        $script:harnessContent | Should -Match 'Invoke-OpsAutoRemediation\.ps1'
        $script:harnessContent | Should -Match 'Invoke-ReleaseControlPlane\.ps1'
        $script:harnessContent | Should -Match 'Write-OpsSloReport\.ps1'
        $script:harnessContent | Should -Match 'RequiredRunnerLabelsCsv \$releaseRunnerLabelsCsv'
        $script:harnessContent | Should -Match "self-hosted', 'windows', 'self-hosted-windows-lv"
        $script:harnessContent | Should -Match 'release-control-plane-local-summary\.json'
        $script:harnessContent | Should -Match 'release-control-plane-override-audit\.json'
    }

    It 'guards mutating modes unless explicitly allowed' {
        $script:harnessContent | Should -Match 'mutating_mode_blocked'
        $script:harnessContent | Should -Match 'AllowMutatingModes'
        $script:harnessContent | Should -Match 'DryRun'
    }
}
