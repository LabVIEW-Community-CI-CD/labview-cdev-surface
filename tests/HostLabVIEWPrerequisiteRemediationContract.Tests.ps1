#Requires -Version 7.0
#Requires -Modules Pester

$ErrorActionPreference = 'Stop'

Describe 'Host LabVIEW prerequisite remediation contract' {
    BeforeAll {
        $script:repoRoot = (Resolve-Path -Path (Join-Path $PSScriptRoot '..')).Path
        $script:scriptPath = Join-Path $script:repoRoot 'scripts/Ensure-HostLabVIEWPrerequisites.ps1'
        if (-not (Test-Path -LiteralPath $script:scriptPath -PathType Leaf)) {
            throw "Host prerequisite remediation script missing: $script:scriptPath"
        }
        $script:content = Get-Content -LiteralPath $script:scriptPath -Raw
    }

    It 'uses deterministic admin-required signature for VI Analyzer remediation' {
        $script:content | Should -Match 'requires_admin_for_vi_analyzer_install'
        $script:content | Should -Match '\$report\.error_code\s*=\s*''requires_admin_for_vi_analyzer_install'''
        $script:content | Should -Match '\$report\.vi_analyzer\.error_code\s*=\s*''requires_admin_for_vi_analyzer_install'''
        $script:content | Should -Match '\$report\.vi_analyzer\.status\s*=\s*''requires_admin'''
    }

    It 'applies non-admin VI Analyzer guard before feed transactions start' {
        $guardToken = 'Administrative privileges are required to remediate VI Analyzer packages'
        $feedToken = '$feedListCache = Get-NipkgFeedList'

        $guardIndex = $script:content.IndexOf($guardToken, [System.StringComparison]::Ordinal)
        $feedIndex = $script:content.IndexOf($feedToken, [System.StringComparison]::Ordinal)

        $guardIndex | Should -BeGreaterThan -1
        $feedIndex | Should -BeGreaterThan -1
        $guardIndex | Should -BeLessThan $feedIndex
    }

    It 'backfills deterministic error code in catch on prefixed failures' {
        $script:content | Should -Match '\.StartsWith\(''requires_admin_for_vi_analyzer_install''\)'
    }
}
