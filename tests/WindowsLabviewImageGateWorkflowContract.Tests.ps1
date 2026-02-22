#Requires -Version 7.0
#Requires -Modules Pester

$ErrorActionPreference = 'Stop'

Describe 'Windows LabVIEW image gate workflow contract' {
    BeforeAll {
        $script:repoRoot = (Resolve-Path -Path (Join-Path $PSScriptRoot '..')).Path
        $script:workflowPath = Join-Path $script:repoRoot '.github/workflows/windows-labview-image-gate.yml'
        if (-not (Test-Path -LiteralPath $script:workflowPath -PathType Leaf)) {
            throw "Windows image gate workflow missing: $script:workflowPath"
        }
        $script:workflowContent = Get-Content -LiteralPath $script:workflowPath -Raw
    }

    It 'is manual-dispatch only for phase-1 rollout' {
        $script:workflowContent | Should -Match 'workflow_dispatch:'
        $script:workflowContent | Should -Not -Match '(?m)^\s*push:'
        $script:workflowContent | Should -Not -Match '(?m)^\s*pull_request:'
    }

    It 'targets windows containers with installer-post-action report checks' {
        $script:workflowContent | Should -Match 'nationalinstruments/labview:latest-windows'
        $script:workflowContent | Should -Match 'DockerCli\.exe.*-SwitchWindowsEngine'
        $script:workflowContent | Should -Match 'Install-WorkspaceFromManifest\.ps1'
        $script:workflowContent | Should -Match 'workspace-install-latest\.json'
        $script:workflowContent | Should -Match "ppl_capability_checks\.'32'\.status"
        $script:workflowContent | Should -Match "ppl_capability_checks\.'64'\.status"
        $script:workflowContent | Should -Match 'vip_package_build_check\.status'
    }

    It 'publishes gate artifacts for troubleshooting' {
        $script:workflowContent | Should -Match 'upload-artifact'
        $script:workflowContent | Should -Match 'if-no-files-found:'
    }
}
