#Requires -Version 7.0
#Requires -Modules Pester

$ErrorActionPreference = 'Stop'

Describe 'Windows LabVIEW image gate workflow contract' {
    BeforeAll {
        $script:repoRoot = (Resolve-Path -Path (Join-Path $PSScriptRoot '..')).Path
        $script:wrapperWorkflowPath = Join-Path $script:repoRoot '.github/workflows/windows-labview-image-gate.yml'
        $script:coreWorkflowPath = Join-Path $script:repoRoot '.github/workflows/_windows-labview-image-gate-core.yml'
        if (-not (Test-Path -LiteralPath $script:wrapperWorkflowPath -PathType Leaf)) {
            throw "Windows image gate wrapper workflow missing: $script:wrapperWorkflowPath"
        }
        if (-not (Test-Path -LiteralPath $script:coreWorkflowPath -PathType Leaf)) {
            throw "Windows image gate core workflow missing: $script:coreWorkflowPath"
        }
        $script:wrapperWorkflowContent = Get-Content -LiteralPath $script:wrapperWorkflowPath -Raw
        $script:coreWorkflowContent = Get-Content -LiteralPath $script:coreWorkflowPath -Raw
    }

    It 'keeps dispatch-only wrapper and forwards to reusable core' {
        $script:wrapperWorkflowContent | Should -Match 'workflow_dispatch:'
        $script:wrapperWorkflowContent | Should -Not -Match '(?m)^\s*push:'
        $script:wrapperWorkflowContent | Should -Not -Match '(?m)^\s*pull_request:'
        $script:wrapperWorkflowContent | Should -Match 'uses:\s*\./\.github/workflows/_windows-labview-image-gate-core\.yml'
    }

    It 'targets windows containers with installer-post-action report checks in core workflow' {
        $script:coreWorkflowContent | Should -Match 'workflow_call:'
        $script:coreWorkflowContent | Should -Match 'runs-on:\s*\[self-hosted,\s*windows,\s*self-hosted-windows-lv,\s*windows-containers,\s*user-session,\s*cdev-surface-windows-gate\]'
        $script:coreWorkflowContent | Should -Match 'nationalinstruments/labview:2026q1-windows'
        $script:coreWorkflowContent | Should -Match 'LABVIEW_WINDOWS_IMAGE'
        $script:coreWorkflowContent | Should -Match 'LABVIEW_WINDOWS_DOCKER_ISOLATION'
        $script:coreWorkflowContent | Should -Match "docker version --format '\{\{\.Server\.Os\}\}'"
        $script:coreWorkflowContent | Should -Match 'docker manifest inspect --verbose'
        $script:coreWorkflowContent | Should -Match 'Windows container compatibility mismatch'
        $script:coreWorkflowContent | Should -Match 'Falling back to Hyper-V isolation'
        $script:coreWorkflowContent | Should -Match '--isolation=\$dockerIsolation'
        $script:coreWorkflowContent | Should -Match 'automatic engine switching is disabled for non-interactive CI'
        $script:coreWorkflowContent | Should -Match 'Get-Command pwsh'
        $script:coreWorkflowContent | Should -Match 'Install-WorkspaceFromManifest\.ps1'
        $script:coreWorkflowContent | Should -Match 'workspace-install-latest\.json'
        $script:coreWorkflowContent | Should -Match "ppl_capability_checks\.'32'\.status"
        $script:coreWorkflowContent | Should -Match "ppl_capability_checks\.'64'\.status"
        $script:coreWorkflowContent | Should -Match 'vip_package_build_check\.status'
        $script:coreWorkflowContent | Should -Match 'gate_status'
        $script:coreWorkflowContent | Should -Match 'gate_report_artifact_name'
        $script:coreWorkflowContent | Should -Match 'gate_report_path'
    }

    It 'publishes gate artifacts for troubleshooting from reusable core' {
        $script:coreWorkflowContent | Should -Match 'upload-artifact'
        $script:coreWorkflowContent | Should -Match 'if-no-files-found:'
    }
}
