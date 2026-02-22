#Requires -Version 7.0
#Requires -Modules Pester

$ErrorActionPreference = 'Stop'

Describe 'Provenance contract' {
    BeforeAll {
        $script:repoRoot = (Resolve-Path -Path (Join-Path $PSScriptRoot '..')).Path
        $script:writeScriptPath = Join-Path $script:repoRoot 'scripts/Write-ReleaseProvenance.ps1'
        $script:testScriptPath = Join-Path $script:repoRoot 'scripts/Test-ProvenanceContracts.ps1'
        foreach ($path in @($script:writeScriptPath, $script:testScriptPath)) {
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
                throw "Required provenance script missing: $path"
            }
        }
        $script:writeContent = Get-Content -LiteralPath $script:writeScriptPath -Raw
        $script:testContent = Get-Content -LiteralPath $script:testScriptPath -Raw
    }

    It 'writes SPDX and SLSA provenance assets with required subjects' {
        $script:writeContent | Should -Match 'workspace-installer\.spdx\.json'
        $script:writeContent | Should -Match 'workspace-installer\.slsa\.json'
        $script:writeContent | Should -Match 'SPDX-2\.3'
        $script:writeContent | Should -Match 'https://slsa\.dev/provenance/v1'
        $script:writeContent | Should -Match '\[string\]\$RunnerCliPath'
        $script:writeContent | Should -Match '\[string\]\$ManifestPath'
        $script:writeContent | Should -Match '\[string\]\$InstallerPath'
    }

    It 'validates schema and hash linkage for provenance subjects' {
        $script:testContent | Should -Match 'spdx_version'
        $script:testContent | Should -Match 'slsa_predicate_type'
        $script:testContent | Should -Match 'spdx_hash_match'
        $script:testContent | Should -Match 'slsa_hash_match'
    }

    It 'has parse-safe PowerShell syntax' {
        $tokens = $null
        $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseInput($script:writeContent, [ref]$tokens, [ref]$errors)
        @($errors).Count | Should -Be 0
        $tokens = $null
        $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseInput($script:testContent, [ref]$tokens, [ref]$errors)
        @($errors).Count | Should -Be 0
    }
}
