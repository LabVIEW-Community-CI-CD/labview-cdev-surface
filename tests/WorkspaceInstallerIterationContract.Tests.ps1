#Requires -Version 7.0
#Requires -Modules Pester

$ErrorActionPreference = 'Stop'

Describe 'Workspace installer iteration runner contract' {
    BeforeAll {
        $script:repoRoot = (Resolve-Path -Path (Join-Path $PSScriptRoot '..')).Path
        $script:scriptPath = Join-Path $script:repoRoot 'scripts/Invoke-WorkspaceInstallerIteration.ps1'
        if (-not (Test-Path -LiteralPath $script:scriptPath -PathType Leaf)) {
            throw "Iteration script missing: $script:scriptPath"
        }
        $script:scriptContent = Get-Content -LiteralPath $script:scriptPath -Raw
    }

    It 'supports fast and full modes with watch-based rerun capability' {
        $script:scriptContent | Should -Match '\[ValidateSet\(''fast'', ''full''\)\]'
        $script:scriptContent | Should -Match '\[switch\]\$Watch'
        $script:scriptContent | Should -Match '\[int\]\$PollSeconds'
        $script:scriptContent | Should -Match '\[int\]\$MaxRuns'
        $script:scriptContent | Should -Match 'Get-WorkspaceFingerprint'
    }

    It 'delegates execution to local exercise script and writes summary output' {
        $script:scriptContent | Should -Match 'Exercise-WorkspaceInstallerLocal\.ps1'
        $script:scriptContent | Should -Match '-SkipSmokeBuild'
        $script:scriptContent | Should -Match '-SkipSmokeInstall'
        $script:scriptContent | Should -Match 'iteration-summary\.json'
    }

    It 'has parse-safe PowerShell syntax' {
        $tokens = $null
        $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseInput($script:scriptContent, [ref]$tokens, [ref]$errors)
        @($errors).Count | Should -Be 0
    }
}
