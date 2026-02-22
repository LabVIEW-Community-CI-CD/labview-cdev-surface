#Requires -Version 7.0
#Requires -Modules Pester

$ErrorActionPreference = 'Stop'

Describe 'Workspace manifest pin refresh script contract' {
    BeforeAll {
        $script:repoRoot = (Resolve-Path -Path (Join-Path $PSScriptRoot '..')).Path
        $script:scriptPath = Join-Path $script:repoRoot 'scripts/Update-WorkspaceManifestPins.ps1'
        if (-not (Test-Path -LiteralPath $script:scriptPath -PathType Leaf)) {
            throw "Required script not found: $script:scriptPath"
        }

        $script:scriptContent = Get-Content -LiteralPath $script:scriptPath -Raw
    }

    It 'defines deterministic script interface' {
        $script:scriptContent | Should -Match '\[switch\]\$WriteChanges'
        $script:scriptContent | Should -Match '\$ManifestPath'
        $script:scriptContent | Should -Match '\$OutputPath'
    }

    It 'supports no-change and update reporting modes' {
        $script:scriptContent | Should -Match '''no_changes'''
        $script:scriptContent | Should -Match '''updated'''
        $script:scriptContent | Should -Match '''drift_detected'''
        $script:scriptContent | Should -Match '\$changes\.Count -gt 0'
        $script:scriptContent | Should -Match 'if \(\$WriteChanges\)'
    }

    It 'uses gh branch-head lookup and emits machine-readable report' {
        $script:scriptContent | Should -Match 'repos/\$repoSlug/commits/\$encodedBranch'
        $script:scriptContent | Should -Match 'ConvertTo-Json -Depth 12'
        $script:scriptContent | Should -Match 'workspace-sha-refresh-report\.json'
        $script:scriptContent | Should -Match 'Initialize-GhToken'
        $script:scriptContent | Should -Match 'token_source'
    }

    It 'has parse-safe PowerShell syntax' {
        $tokens = $null
        $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($script:scriptPath, [ref]$tokens, [ref]$errors)
        @($errors).Count | Should -Be 0
    }
}
