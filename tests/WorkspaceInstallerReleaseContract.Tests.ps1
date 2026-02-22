#Requires -Version 7.0
#Requires -Modules Pester

$ErrorActionPreference = 'Stop'

Describe 'Workspace installer release workflow contract' {
    BeforeAll {
        $script:repoRoot = (Resolve-Path -Path (Join-Path $PSScriptRoot '..')).Path
        $script:workflowPath = Join-Path $script:repoRoot '.github/workflows/release-workspace-installer.yml'
        if (-not (Test-Path -LiteralPath $script:workflowPath -PathType Leaf)) {
            throw "Release workflow not found: $script:workflowPath"
        }
        $script:workflowContent = Get-Content -LiteralPath $script:workflowPath -Raw
    }

    It 'is dispatch-only and requires release inputs' {
        $script:workflowContent | Should -Match 'workflow_dispatch:'
        $script:workflowContent | Should -Not -Match '(?m)^\s*push:'
        $script:workflowContent | Should -Not -Match '(?m)^\s*pull_request:'
        $script:workflowContent | Should -Not -Match '(?m)^\s*schedule:'
        $script:workflowContent | Should -Match 'release_tag:'
        $script:workflowContent | Should -Match 'required:\s*true'
        $script:workflowContent | Should -Match 'type:\s*string'
        $script:workflowContent | Should -Match 'prerelease:'
        $script:workflowContent | Should -Match 'type:\s*boolean'
    }

    It 'defines package and publish jobs with release asset upload' {
        $script:workflowContent | Should -Match 'name:\s*Package Workspace Installer'
        $script:workflowContent | Should -Match 'name:\s*Publish GitHub Release Asset'
        $script:workflowContent | Should -Match 'Build-RunnerCliBundleFromManifest\.ps1'
        $script:workflowContent | Should -Match 'Test-RunnerCliBundleDeterminism\.ps1'
        $script:workflowContent | Should -Match 'Test-WorkspaceInstallerDeterminism\.ps1'
        $script:workflowContent | Should -Match 'Write-ReleaseProvenance\.ps1'
        $script:workflowContent | Should -Match 'Test-ProvenanceContracts\.ps1'
        $script:workflowContent | Should -Match 'workspace-installer-release-\$\{\{\s*github\.run_id\s*\}\}'
        $script:workflowContent | Should -Match '(gh release create|''release'',\s*''create'')'
        $script:workflowContent | Should -Match 'gh release upload'
        $script:workflowContent | Should -Match '--clobber'
    }

    It 'enforces release notes and tag validation' {
        $script:workflowContent | Should -Match '\^v\[0-9\]\+\\\.\[0-9\]\+\\\.\[0-9\]\+\$'
        $script:workflowContent | Should -Match 'SHA256'
        $script:workflowContent | Should -Match 'lvie-cdev-workspace-installer\.exe /S'
        $script:workflowContent | Should -Match 'workspace-installer\.spdx\.json'
        $script:workflowContent | Should -Match 'workspace-installer\.slsa\.json'
        $script:workflowContent | Should -Match 'reproducibility-report\.json'
    }
}
