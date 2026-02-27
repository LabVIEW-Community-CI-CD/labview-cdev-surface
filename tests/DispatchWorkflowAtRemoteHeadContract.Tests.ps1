#Requires -Version 7.0
#Requires -Modules Pester

$ErrorActionPreference = 'Stop'

Describe 'Dispatch workflow at remote head contract' {
    BeforeAll {
        $script:repoRoot = (Resolve-Path -Path (Join-Path $PSScriptRoot '..')).Path
        $script:path = Join-Path $script:repoRoot 'scripts/Dispatch-WorkflowAtRemoteHead.ps1'
        if (-not (Test-Path -LiteralPath $script:path -PathType Leaf)) {
            throw "Script missing: $script:path"
        }
        $script:content = Get-Content -LiteralPath $script:path -Raw
    }

    It 'verifies run head SHA against remote branch head' {
        $script:content | Should -Match 'expectedHeadSha'
        $script:content | Should -Match 'dispatch_head_sha_mismatch'
    }

    It 'uses explicit inputs parameter with backward-compatible alias' {
        $script:content | Should -Match "\[Alias\('Input'\)\]"
        $script:content | Should -Match '\[string\[\]\]\$Inputs'
        $script:content | Should -Match 'Convert-InputPairsToGhArgs -Inputs \$Inputs'
    }

    It 'supports stale-run cancellation before dispatch' {
        $script:content | Should -Match 'Cancel-StaleWorkflowRuns\.ps1'
        $script:content | Should -Match '-TargetHeadSha \$expectedHeadSha'
    }

    It 'emits deterministic dispatch report fields' {
        $script:content | Should -Match 'timestamp_utc'
        $script:content | Should -Match 'repository = \$Repository'
        $script:content | Should -Match 'workflow = \$WorkflowFile'
        $script:content | Should -Match 'branch = \$Branch'
    }
}
