#Requires -Version 7.0
#Requires -Modules Pester

$ErrorActionPreference = 'Stop'

Describe 'Release client runtime contract' {
    BeforeAll {
        $script:repoRoot = (Resolve-Path -Path (Join-Path $PSScriptRoot '..')).Path
        $script:scriptPath = Join-Path $script:repoRoot 'scripts/Install-WorkspaceInstallerFromRelease.ps1'
        if (-not (Test-Path -LiteralPath $script:scriptPath -PathType Leaf)) {
            throw "Release client runtime script missing: $script:scriptPath"
        }
        $script:scriptContent = Get-Content -LiteralPath $script:scriptPath -Raw
    }

    It 'defines additive install/upgrade/rollback/status/policy modes' {
        $script:scriptContent | Should -Match "ValidateSet\('Install', 'Upgrade', 'Rollback', 'Status', 'ValidatePolicy'\)"
        $script:scriptContent | Should -Match "ValidateSet\('stable', 'prerelease', 'canary'\)"
        $script:scriptContent | Should -Match '\$AllowMajor'
        $script:scriptContent | Should -Match '\$RollbackTo'
        $script:scriptContent | Should -Match '\$PolicyPath'
    }

    It 'enforces release source allowlist, signatures, provenance, and installer report checks' {
        $script:scriptContent | Should -Match 'allowed_repositories'
        $script:scriptContent | Should -Match 'release-manifest\.json'
        $script:scriptContent | Should -Match 'Get-AuthenticodeSignature'
        $script:scriptContent | Should -Match '\.spdx\.json'
        $script:scriptContent | Should -Match '\.slsa\.json'
        $script:scriptContent | Should -Match 'workspace-install-latest\.json'
        $script:scriptContent | Should -Match 'workspace-release-state\.json'
        $script:scriptContent | Should -Match 'workspace-release-client-latest\.json'
    }

    It 'defines deterministic failure reason codes' {
        foreach ($reason in @('source_blocked', 'asset_missing', 'hash_mismatch', 'signature_missing', 'signature_invalid', 'provenance_invalid', 'installer_exit_nonzero', 'install_report_missing')) {
            $script:scriptContent | Should -Match $reason
        }
    }

    It 'has parse-safe PowerShell syntax' {
        $tokens = $null
        $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseInput($script:scriptContent, [ref]$tokens, [ref]$errors)
        @($errors).Count | Should -Be 0
    }
}
