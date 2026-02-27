#Requires -Version 7.0
#Requires -Modules Pester

$ErrorActionPreference = 'Stop'

Describe 'Release manifest contract' {
    BeforeAll {
        $script:repoRoot = (Resolve-Path -Path (Join-Path $PSScriptRoot '..')).Path
        $script:scriptPath = Join-Path $script:repoRoot 'scripts/Write-ReleaseManifest.ps1'
        $script:workflowPath = Join-Path $script:repoRoot '.github/workflows/_release-workspace-installer-core.yml'

        if (-not (Test-Path -LiteralPath $script:scriptPath -PathType Leaf)) {
            throw "Release manifest script missing: $script:scriptPath"
        }
        if (-not (Test-Path -LiteralPath $script:workflowPath -PathType Leaf)) {
            throw "Release core workflow missing: $script:workflowPath"
        }

        $script:scriptContent = Get-Content -LiteralPath $script:scriptPath -Raw
        $script:workflowContent = Get-Content -LiteralPath $script:workflowPath -Raw
    }

    It 'defines required release-manifest fields and signature metadata' {
        $script:scriptContent | Should -Match 'schema_version'
        $script:scriptContent | Should -Match 'repository'
        $script:scriptContent | Should -Match 'release_tag'
        $script:scriptContent | Should -Match 'channel'
        $script:scriptContent | Should -Match 'published_at_utc'
        $script:scriptContent | Should -Match 'installer'
        $script:scriptContent | Should -Match 'sha256'
        $script:scriptContent | Should -Match 'signature'
        $script:scriptContent | Should -Match 'provenance'
        $script:scriptContent | Should -Match 'install_command'
        $script:scriptContent | Should -Match 'compatibility'
        $script:scriptContent | Should -Match 'rollback'
        $script:scriptContent | Should -Match 'authenticode'
    }

    It 'is generated and published by release workflow' {
        $script:workflowContent | Should -Match 'Write-ReleaseManifest\.ps1'
        $script:workflowContent | Should -Match 'release-manifest\.json'
        $script:workflowContent | Should -Match 'gh release upload'
    }

    It 'has parse-safe PowerShell syntax' {
        $tokens = $null
        $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseInput($script:scriptContent, [ref]$tokens, [ref]$errors)
        @($errors).Count | Should -Be 0
    }
}
