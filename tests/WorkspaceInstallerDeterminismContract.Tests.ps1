#Requires -Version 7.0
#Requires -Modules Pester

$ErrorActionPreference = 'Stop'

Describe 'Workspace installer determinism contract' {
    BeforeAll {
        $script:repoRoot = (Resolve-Path -Path (Join-Path $PSScriptRoot '..')).Path
        $script:scriptPath = Join-Path $script:repoRoot 'scripts/Test-WorkspaceInstallerDeterminism.ps1'
        if (-not (Test-Path -LiteralPath $script:scriptPath -PathType Leaf)) {
            throw "Determinism script missing: $script:scriptPath"
        }
        $script:scriptContent = Get-Content -LiteralPath $script:scriptPath -Raw
    }

    It 'invokes deterministic installer build compare mode' {
        $script:scriptContent | Should -Match 'Build-WorkspaceBootstrapInstaller\.ps1'
        $script:scriptContent | Should -Match '-VerifyDeterminism'
        $script:scriptContent | Should -Match '-Deterministic'
        $script:scriptContent | Should -Match 'workspace-installer-determinism\.json'
    }

    It 'emits reproducibility summary report' {
        $script:scriptContent | Should -Match 'workspace-installer-determinism-summary\.json'
        $script:scriptContent | Should -Match 'artifacts\\reproducibility'
        $script:scriptContent | Should -Match 'output_sha256'
    }

    It 'has parse-safe PowerShell syntax' {
        $tokens = $null
        $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseInput($script:scriptContent, [ref]$tokens, [ref]$errors)
        @($errors).Count | Should -Be 0
    }
}
