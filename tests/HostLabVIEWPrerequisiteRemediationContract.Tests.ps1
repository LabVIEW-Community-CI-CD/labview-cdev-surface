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
        $installedProbeToken = 'Test-NipkgPackageInstalled -NipkgPath $nipkgPath -PackageName $packageName'

        $guardIndex = $script:content.IndexOf($guardToken, [System.StringComparison]::Ordinal)
        $feedIndex = $script:content.IndexOf($feedToken, [System.StringComparison]::Ordinal)
        $installedProbeIndex = $script:content.IndexOf($installedProbeToken, [System.StringComparison]::Ordinal)

        $guardIndex | Should -BeGreaterThan -1
        $feedIndex | Should -BeGreaterThan -1
        $installedProbeIndex | Should -BeGreaterThan -1
        $installedProbeIndex | Should -BeLessThan $feedIndex
        $guardIndex | Should -BeLessThan $feedIndex
    }

    It 'backfills deterministic error code in catch on prefixed failures' {
        $script:content | Should -Match '\.StartsWith\(''requires_admin_for_vi_analyzer_install''\)'
    }

    It 'allows non-admin pass-through when VI Analyzer packages are already installed' {
        $script:content | Should -Match '\$report\.vi_analyzer\.installed_after\s*=\s*\$installedBefore'
        $script:content | Should -Match '\$report\.vi_analyzer\.status\s*=\s*''pass'''
        $script:content | Should -Match 'if \(\@\(\$viAnalyzerMissingPackages\)\.Count -gt 0\)'
    }

    It 'probes NIPM package install state with non-terminating stderr handling' {
        $script:content | Should -Match 'function Test-NipkgPackageInstalled'
        $script:content | Should -Match '\$previousErrorActionPreference\s*=\s*\$ErrorActionPreference'
        $script:content | Should -Match '\$ErrorActionPreference\s*=\s*''Continue'''
        $script:content | Should -Match '\$output\s*=\s*&\s*\$NipkgPath\s+list-installed\s+\$PackageName\s+2>&1'
        $script:content | Should -Match '\$ErrorActionPreference\s*=\s*\$previousErrorActionPreference'
    }

    It 'maps non-admin package probe failures into deterministic admin-required classification' {
        $script:content | Should -Match 'action\s*=\s*''vi-analyzer-check'''
        $script:content | Should -Match 'status\s*=\s*''check_failed'''
        $script:content | Should -Match '\$viAnalyzerMissingPackages \+= \$packageName'
    }
}
