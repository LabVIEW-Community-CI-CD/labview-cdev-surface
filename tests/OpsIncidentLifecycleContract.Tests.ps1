#Requires -Version 7.0
#Requires -Modules Pester

$ErrorActionPreference = 'Stop'

Describe 'Ops incident lifecycle contract' {
    BeforeAll {
        $script:repoRoot = (Resolve-Path -Path (Join-Path $PSScriptRoot '..')).Path
        $script:scriptPath = Join-Path $script:repoRoot 'scripts/Invoke-OpsIncidentLifecycle.ps1'

        if (-not (Test-Path -LiteralPath $script:scriptPath -PathType Leaf)) {
            throw "Ops incident lifecycle script missing: $script:scriptPath"
        }

        $script:scriptContent = Get-Content -LiteralPath $script:scriptPath -Raw
    }

    It 'defines deterministic fail and recover modes' {
        $script:scriptContent | Should -Match "ValidateSet\('Fail', 'Recover'\)"
        $script:scriptContent | Should -Match 'issue_title'
        $script:scriptContent | Should -Match 'mode'
        $script:scriptContent | Should -Match 'action'
    }

    It 'handles create comment reopen close issue transitions' {
        $script:scriptContent | Should -Match "'issue', 'list'"
        $script:scriptContent | Should -Match "'issue', 'create'"
        $script:scriptContent | Should -Match "'issue', 'comment'"
        $script:scriptContent | Should -Match "'issue', 'reopen'"
        $script:scriptContent | Should -Match "'issue', 'close'"
    }

    It 'emits machine-readable report output' {
        $script:scriptContent | Should -Match 'schema_version'
        $script:scriptContent | Should -Match 'Write-WorkflowOpsReport'
        $script:scriptContent | Should -Match 'runtime_error'
    }
}
