#Requires -Version 7.0
#Requires -Modules Pester

$ErrorActionPreference = 'Stop'

Describe 'Linux container NSIS parity contract' {
    BeforeAll {
        $script:repoRoot = (Resolve-Path -Path (Join-Path $PSScriptRoot '..')).Path
        $script:parityScriptPath = Join-Path $script:repoRoot 'scripts/Invoke-LinuxContainerNsisParity.ps1'
        $script:dockerfilePath = Join-Path $script:repoRoot 'tools/nsis-selftest-linux/Dockerfile'

        if (-not (Test-Path -LiteralPath $script:parityScriptPath -PathType Leaf)) {
            throw "Linux NSIS parity script missing: $script:parityScriptPath"
        }
        if (-not (Test-Path -LiteralPath $script:dockerfilePath -PathType Leaf)) {
            throw "Linux NSIS parity Dockerfile missing: $script:dockerfilePath"
        }

        $script:parityScriptContent = Get-Content -LiteralPath $script:parityScriptPath -Raw
        $script:dockerfileContent = Get-Content -LiteralPath $script:dockerfilePath -Raw
    }

    It 'runs a Linux parity container flow against desktop-linux context' {
        $script:parityScriptContent | Should -Match '\[string\]\$DockerContext\s*=\s*''desktop-linux'''
        $script:parityScriptContent | Should -Match 'docker run'
        $script:parityScriptContent | Should -Match 'container-report\.json'
        $script:parityScriptContent | Should -Match 'linux-container-nsis-parity-report\.json'
        $script:parityScriptContent | Should -Match 'labviewcli'
        $script:parityScriptContent | Should -Match 'LabVIEWCLI'
        $script:parityScriptContent | Should -Match 'makensis'
        $script:parityScriptContent | Should -Match 'windows_installer_not_executable_on_linux'
    }

    It 'defines deterministic linux parity image dependencies' {
        $script:dockerfileContent | Should -Match 'FROM nationalinstruments/labview:2026q1-linux'
        $script:dockerfileContent | Should -Match 'apt-get install -y --no-install-recommends'
        $script:dockerfileContent | Should -Match 'packages\.microsoft\.com/ubuntu/22\.04/prod'
        $script:dockerfileContent | Should -Match 'dotnet-sdk-8\.0'
        $script:dockerfileContent | Should -Match 'powershell'
        $script:dockerfileContent | Should -Match 'nsis'
        $script:dockerfileContent | Should -Match 'git'
        $script:dockerfileContent | Should -Match 'jq'
        $script:dockerfileContent | Should -Match 'gtk-update-icon-cache'
        $script:dockerfileContent | Should -Match 'desktop-file-utils'
    }

    It 'has parse-safe PowerShell syntax' {
        $tokens = $null
        $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseInput($script:parityScriptContent, [ref]$tokens, [ref]$errors)
        @($errors).Count | Should -Be 0
    }
}
