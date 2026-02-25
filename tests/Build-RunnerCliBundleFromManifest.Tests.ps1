#Requires -Version 7.0
#Requires -Modules Pester

$ErrorActionPreference = 'Stop'

Describe 'Build runner-cli bundle from manifest contract' {
    BeforeAll {
        $script:repoRoot = (Resolve-Path -Path (Join-Path $PSScriptRoot '..')).Path
        $script:scriptPath = Join-Path $script:repoRoot 'scripts/Build-RunnerCliBundleFromManifest.ps1'
        if (-not (Test-Path -LiteralPath $script:scriptPath -PathType Leaf)) {
            throw "Runner CLI bundle script missing: $script:scriptPath"
        }
        $script:scriptContent = Get-Content -LiteralPath $script:scriptPath -Raw
    }

    It 'defines manifest-driven deterministic bundle parameters' {
        $script:scriptContent | Should -Match '\[string\]\$ManifestPath'
        $script:scriptContent | Should -Match '\[Parameter\(Mandatory = \$true\)\]\s*\[string\]\$OutputRoot'
        $script:scriptContent | Should -Match '\[string\]\$RepoName = ''labview-icon-editor'''
        $script:scriptContent | Should -Match '\[string\]\$Runtime = ''win-x64'''
        $script:scriptContent | Should -Match '\[bool\]\$Deterministic = \$true'
        $script:scriptContent | Should -Match '\[long\]\$SourceDateEpoch'
        $script:scriptContent | Should -Match 'pinned_sha'
        $script:scriptContent | Should -Match 'global\.json'
    }

    It 'uses runner temp with fallback and isolated temp roots' {
        $script:scriptContent | Should -Match '\$env:RUNNER_TEMP'
        $script:scriptContent | Should -Match '\$env:TEMP'
        $script:scriptContent | Should -Match 'Get-IsolationToken'
        $script:scriptContent | Should -Match 'lvie-runner-cli-bundle-'
        $script:scriptContent | Should -Match 'Write-Warning'
    }

    It 'builds and writes runner-cli executable, hash, and metadata' {
        $script:scriptContent | Should -Match 'dotnet publish'
        $script:scriptContent | Should -Match 'runner-cli\.exe'
        $script:scriptContent | Should -Match 'runner-cli\.dll'
        $script:scriptContent | Should -Match 'runner-cli\.runtimeconfig\.json'
        $script:scriptContent | Should -Match 'runner-cli\.deps\.json'
        $script:scriptContent | Should -Match 'runner-cli\.exe\.sha256'
        $script:scriptContent | Should -Match 'runner-cli\.metadata\.json'
        $script:scriptContent | Should -Match 'launcher_fallback_command'
        $script:scriptContent | Should -Match 'dotnet runner-cli\.dll'
        $script:scriptContent | Should -Match 'source_commit'
        $script:scriptContent | Should -Match 'build_epoch_utc'
        $script:scriptContent | Should -Match 'Deterministic=true'
    }

    It 'has parse-safe PowerShell syntax' {
        $tokens = $null
        $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseInput($script:scriptContent, [ref]$tokens, [ref]$errors)
        @($errors).Count | Should -Be 0
    }
}
