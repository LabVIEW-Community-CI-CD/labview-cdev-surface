#Requires -Version 7.0
#Requires -Modules Pester

$ErrorActionPreference = 'Stop'

Describe 'Canary smoke tag hygiene workflow contract' {
    BeforeAll {
        $script:repoRoot = (Resolve-Path -Path (Join-Path $PSScriptRoot '..')).Path
        $script:workflowPath = Join-Path $script:repoRoot '.github/workflows/canary-smoke-tag-hygiene.yml'
        $script:scriptPath = Join-Path $script:repoRoot 'scripts/Invoke-CanarySmokeTagHygiene.ps1'

        if (-not (Test-Path -LiteralPath $script:workflowPath -PathType Leaf)) {
            throw "Canary smoke tag hygiene workflow missing: $script:workflowPath"
        }
        if (-not (Test-Path -LiteralPath $script:scriptPath -PathType Leaf)) {
            throw "Canary smoke tag hygiene script missing: $script:scriptPath"
        }

        $script:workflowContent = Get-Content -LiteralPath $script:workflowPath -Raw
        $script:scriptContent = Get-Content -LiteralPath $script:scriptPath -Raw
    }

    It 'is scheduled and dispatchable with apply-controls inputs' {
        $script:workflowContent | Should -Match 'schedule:'
        $script:workflowContent | Should -Match 'workflow_dispatch:'
        $script:workflowContent | Should -Match 'target_date_utc'
        $script:workflowContent | Should -Match 'keep_latest_n'
        $script:workflowContent | Should -Match 'apply_changes'
        $script:workflowContent | Should -Match 'type:\s*boolean'
    }

    It 'runs hygiene script and uploads deterministic report artifact' {
        $script:workflowContent | Should -Match 'Invoke-CanarySmokeTagHygiene\.ps1'
        $script:workflowContent | Should -Match 'canary-smoke-tag-hygiene-report\.json'
        $script:workflowContent | Should -Match 'upload-artifact'
    }

    It 'enforces keep-latest canary tag cleanup behavior' {
        $script:scriptContent | Should -Match 'Get-GhReleasesPortable'
        $script:scriptContent | Should -Match 'release''\s*,\s*''delete'''
        $script:scriptContent | Should -Match '--cleanup-tag'
        $script:scriptContent | Should -Match 'KeepLatestN'
        $script:scriptContent | Should -Match '\(\?<date>\\d\{8\}\)'
        $script:scriptContent | Should -Match '\(\?<sequence>\\d\+\)'
        $script:scriptContent | Should -Match 'delete_count_exceeds_guard'
    }
}
