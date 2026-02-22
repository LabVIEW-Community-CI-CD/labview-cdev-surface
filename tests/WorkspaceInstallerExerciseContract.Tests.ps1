#Requires -Version 7.0
#Requires -Modules Pester

$ErrorActionPreference = 'Stop'

Describe 'Workspace installer local exercise contract' {
    BeforeAll {
        $script:repoRoot = (Resolve-Path -Path (Join-Path $PSScriptRoot '..')).Path
        $script:scriptPath = Join-Path $script:repoRoot 'scripts/Exercise-WorkspaceInstallerLocal.ps1'
        if (-not (Test-Path -LiteralPath $script:scriptPath -PathType Leaf)) {
            throw "Exercise script missing: $script:scriptPath"
        }
        $script:scriptContent = Get-Content -LiteralPath $script:scriptPath -Raw
    }

    It 'supports fast local refinement switches' {
        $script:scriptContent | Should -Match '\[switch\]\$SkipSmokeInstall'
        $script:scriptContent | Should -Match '\[switch\]\$SkipSmokeBuild'
        $script:scriptContent | Should -Match '\[switch\]\$KeepSmokeWorkspace'
        $script:scriptContent | Should -Match 'Build-RunnerCliBundleFromManifest\.ps1'
        $script:scriptContent | Should -Match 'lvie-cdev-workspace-installer\.exe'
        $script:scriptContent | Should -Match 'lvie-cdev-workspace-installer-bundle\.zip'
    }

    It 'includes isolated smoke manifest remap and transfer bundle outputs' {
        $script:scriptContent | Should -Match 'Convert-ManifestToWorkspace'
        $script:scriptContent | Should -Match 'Verify-And-Install\.ps1'
        $script:scriptContent | Should -Match 'runner-cli\.exe'
        $script:scriptContent | Should -Match '''g-cli'''
        $script:scriptContent | Should -Match 'exercise-report\.json'
        $script:scriptContent | Should -Match 'workspace-install-latest\.json'
    }

    It 'has parse-safe PowerShell syntax' {
        $tokens = $null
        $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseInput($script:scriptContent, [ref]$tokens, [ref]$errors)
        @($errors).Count | Should -Be 0
    }
}
