#Requires -Version 7.0
#Requires -Modules Pester

$ErrorActionPreference = 'Stop'

Describe 'Installer harness workflow contract' {
    BeforeAll {
        $script:repoRoot = (Resolve-Path -Path (Join-Path $PSScriptRoot '..')).Path
        $script:workflowPath = Join-Path $script:repoRoot '.github/workflows/installer-harness-self-hosted.yml'
        if (-not (Test-Path -LiteralPath $script:workflowPath -PathType Leaf)) {
            throw "Installer harness workflow not found: $script:workflowPath"
        }
        $script:workflowContent = Get-Content -LiteralPath $script:workflowPath -Raw
    }

    It 'triggers on integration branches and workflow dispatch' {
        $script:workflowContent | Should -Match 'name:\s*Installer Harness'
        $script:workflowContent | Should -Match 'push:'
        $script:workflowContent | Should -Match 'integration/\*\*'
        $script:workflowContent | Should -Match 'workflow_dispatch:'
        $script:workflowContent | Should -Match 'ref:'
    }

    It 'uses self-hosted windows LV + installer harness labels with deterministic concurrency' {
        $script:workflowContent | Should -Match 'runs-on:\s*\[self-hosted,\s*windows,\s*self-hosted-windows-lv,\s*installer-harness\]'
        $script:workflowContent | Should -Match 'group:\s*installer-harness-\$\{\{\s*github\.ref\s*\}\}'
        $script:workflowContent | Should -Match 'cancel-in-progress:\s*false'
    }

    It 'executes baseline lock, machine preflight, and installer iteration flow' {
        $script:workflowContent | Should -Match 'Assert-InstallerHarnessRunnerBaseline\.ps1'
        $script:workflowContent | Should -Match '-AllowInteractiveRunner'
        $script:workflowContent | Should -Match 'Assert-InstallerHarnessMachinePreflight\.ps1'
        $script:workflowContent | Should -Match 'Invoke-WorkspaceInstallerIteration\.ps1'
        $script:workflowContent | Should -Match '-Mode full'
        $script:workflowContent | Should -Match 'iteration-summary\.json'
        $script:workflowContent | Should -Match 'exercise-report\.json'
        $script:workflowContent | Should -Match 'workspace-install-latest\.json'
        $script:workflowContent | Should -Match 'ppl_capability_checks'
        $script:workflowContent | Should -Match 'vip_package_build_check'
    }

    It 'uploads harness artifacts for release-readiness evidence' {
        $script:workflowContent | Should -Match 'upload-artifact@v4'
        $script:workflowContent | Should -Match 'installer-harness-\$\{\{\s*github\.run_id\s*\}\}'
        $script:workflowContent | Should -Match 'harness-validation-report\.json'
        $script:workflowContent | Should -Match 'lvie-cdev-workspace-installer-bundle\.zip'
        $script:workflowContent | Should -Match 'lvie-cdev-workspace-installer\.exe\.sha256'
    }
}
