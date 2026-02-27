#Requires -Version 7.0
#Requires -Modules Pester

$ErrorActionPreference = 'Stop'

Describe 'WorkflowOps.Common input conversion contract' {
    BeforeAll {
        $script:repoRoot = (Resolve-Path -Path (Join-Path $PSScriptRoot '..')).Path
        $script:commonPath = Join-Path $script:repoRoot 'scripts/lib/WorkflowOps.Common.ps1'
        if (-not (Test-Path -LiteralPath $script:commonPath -PathType Leaf)) {
            throw "Common script missing: $script:commonPath"
        }

        . $script:commonPath
    }

    It 'returns flattened gh args for multiple key=value inputs' {
        $result = Convert-InputPairsToGhArgs -Inputs @(
            'release_tag=v0.20260227.1',
            'allow_existing_tag=false'
        )

        $result.Count | Should -Be 4
        $result[0] | Should -Be '-f'
        $result[1] | Should -Be 'release_tag=v0.20260227.1'
        $result[2] | Should -Be '-f'
        $result[3] | Should -Be 'allow_existing_tag=false'
        (@($result | Where-Object { $_ -is [System.Array] })).Count | Should -Be 0
    }

    It 'keeps backward-compatible Input alias behavior' {
        $result = Convert-InputPairsToGhArgs -Input @('sync_guard_max_age_hours=12')

        $result.Count | Should -Be 2
        $result[0] | Should -Be '-f'
        $result[1] | Should -Be 'sync_guard_max_age_hours=12'
    }

    It 'fails malformed input pairs deterministically' {
        { Convert-InputPairsToGhArgs -Inputs @('release_tag') } | Should -Throw '*input_pair_invalid*'
    }
}
