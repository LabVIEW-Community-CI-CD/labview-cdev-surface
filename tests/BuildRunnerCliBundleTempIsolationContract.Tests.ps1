#Requires -Version 7.0
#Requires -Modules Pester

$ErrorActionPreference = 'Stop'

Describe 'Build runner-cli temp isolation contract' {
    BeforeAll {
        $script:repoRoot = (Resolve-Path -Path (Join-Path $PSScriptRoot '..')).Path
        $script:scriptPath = Join-Path $script:repoRoot 'scripts/Build-RunnerCliBundleFromManifest.ps1'
        if (-not (Test-Path -LiteralPath $script:scriptPath -PathType Leaf)) {
            throw "Runner CLI bundle script missing: $script:scriptPath"
        }

        $script:scriptContent = Get-Content -LiteralPath $script:scriptPath -Raw
    }

    It 'prefers RUNNER_TEMP and falls back to TEMP' {
        $script:scriptContent | Should -Match 'function Get-TempBasePath'
        $script:scriptContent | Should -Match '\$env:RUNNER_TEMP'
        $script:scriptContent | Should -Match '\$env:TEMP'
        $script:scriptContent | Should -Match 'Neither RUNNER_TEMP nor TEMP is set'
    }

    It 'builds per-invocation isolated temp roots' {
        $script:scriptContent | Should -Match 'function Get-IsolationToken'
        $script:scriptContent | Should -Match '\$env:GITHUB_RUN_ID'
        $script:scriptContent | Should -Match '\$env:GITHUB_RUN_ATTEMPT'
        $script:scriptContent | Should -Match '\$env:GITHUB_JOB'
        $script:scriptContent | Should -Match '\$env:RUNNER_NAME'
        $script:scriptContent | Should -Match "\$seedParts = @\('local'\)"
        $script:scriptContent | Should -Match 'lvie-runner-cli-bundle-'
    }

    It 'uses best-effort cleanup in finally' {
        $script:scriptContent | Should -Match 'function Remove-Directory'
        $script:scriptContent | Should -Match '\[switch\]\$BestEffort'
        $script:scriptContent | Should -Match 'Write-Warning'
        $script:scriptContent | Should -Match 'Remove-Directory -Path \$tempRoot -BestEffort'
    }

    It 'has parse-safe PowerShell syntax' {
        $tokens = $null
        $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseInput($script:scriptContent, [ref]$tokens, [ref]$errors)
        @($errors).Count | Should -Be 0
    }
}
