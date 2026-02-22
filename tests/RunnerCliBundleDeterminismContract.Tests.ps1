#Requires -Version 7.0
#Requires -Modules Pester

$ErrorActionPreference = 'Stop'

Describe 'Runner CLI bundle determinism contract' {
    BeforeAll {
        $script:repoRoot = (Resolve-Path -Path (Join-Path $PSScriptRoot '..')).Path
        $script:scriptPath = Join-Path $script:repoRoot 'scripts/Test-RunnerCliBundleDeterminism.ps1'
        if (-not (Test-Path -LiteralPath $script:scriptPath -PathType Leaf)) {
            throw "Determinism script missing: $script:scriptPath"
        }
        $script:scriptContent = Get-Content -LiteralPath $script:scriptPath -Raw
    }

    It 'runs two deterministic bundle builds and compares hashes' {
        $script:scriptContent | Should -Match 'foreach \(\$index in 1\.\.2\)'
        $script:scriptContent | Should -Match 'Build-RunnerCliBundleFromManifest\.ps1'
        $script:scriptContent | Should -Match 'Deterministic'
        $script:scriptContent | Should -Match 'sha256'
        $script:scriptContent | Should -Match 'runner-cli-determinism-'
    }

    It 'writes machine-readable reproducibility report' {
        $script:scriptContent | Should -Match 'artifacts\\reproducibility'
        $script:scriptContent | Should -Match 'ConvertTo-Json'
        $script:scriptContent | Should -Match 'status'
    }

    It 'has parse-safe PowerShell syntax' {
        $tokens = $null
        $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseInput($script:scriptContent, [ref]$tokens, [ref]$errors)
        @($errors).Count | Should -Be 0
    }
}
