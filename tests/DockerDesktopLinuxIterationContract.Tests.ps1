#Requires -Version 7.0
#Requires -Modules Pester

$ErrorActionPreference = 'Stop'

Describe 'Docker Desktop Linux iteration contract' {
    BeforeAll {
        $script:repoRoot = (Resolve-Path -Path (Join-Path $PSScriptRoot '..')).Path
        $script:scriptPath = Join-Path $script:repoRoot 'scripts/Invoke-DockerDesktopLinuxIteration.ps1'
        if (-not (Test-Path -LiteralPath $script:scriptPath -PathType Leaf)) {
            throw "Docker Linux iteration script missing: $script:scriptPath"
        }
        $script:scriptContent = Get-Content -LiteralPath $script:scriptPath -Raw
    }

    It 'uses docker and manifest-pinned runner-cli bundle for linux iteration' {
        $script:scriptContent | Should -Match 'Build-RunnerCliBundleFromManifest\.ps1'
        $script:scriptContent | Should -Match '\[string\]\$Runtime\s*=\s*''linux-x64'''
        $script:scriptContent | Should -Match '\[string\]\$DockerContext\s*=\s*''desktop-linux'''
        $script:scriptContent | Should -Match 'runner-cli\.exe'
        $script:scriptContent | Should -Match 'docker run'
        $script:scriptContent | Should -Match '--context'
        $script:scriptContent | Should -Match 'Get-WindowsOptionalFeature'
        $script:scriptContent | Should -Match 'Microsoft-Hyper-V-All'
    }

    It 'runs runner-cli command surface checks in container' {
        $script:scriptContent | Should -Match 'runner-cli --help'
        $script:scriptContent | Should -Match 'runner-cli ppl --help'
        $script:scriptContent | Should -Match 'container-report\.json'
    }

    It 'supports optional pester execution in container' {
        $script:scriptContent | Should -Match '\[switch\]\$SkipPester'
        $script:scriptContent | Should -Match 'Install-Module -Name Pester'
        $script:scriptContent | Should -Match 'Invoke-Pester'
    }

    It 'has parse-safe PowerShell syntax' {
        $tokens = $null
        $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseInput($script:scriptContent, [ref]$tokens, [ref]$errors)
        @($errors).Count | Should -Be 0
    }
}
