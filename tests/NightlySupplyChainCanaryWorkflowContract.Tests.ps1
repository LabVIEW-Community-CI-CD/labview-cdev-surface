#Requires -Version 7.0
#Requires -Modules Pester

$ErrorActionPreference = 'Stop'

Describe 'Nightly supply-chain canary workflow contract' {
    BeforeAll {
        $script:repoRoot = (Resolve-Path -Path (Join-Path $PSScriptRoot '..')).Path
        $script:workflowPath = Join-Path $script:repoRoot '.github/workflows/nightly-supplychain-canary.yml'
        if (-not (Test-Path -LiteralPath $script:workflowPath -PathType Leaf)) {
            throw "Canary workflow missing: $script:workflowPath"
        }
        $script:workflowContent = Get-Content -LiteralPath $script:workflowPath -Raw
    }

    It 'is scheduled nightly and runnable on demand' {
        $script:workflowContent | Should -Match 'schedule:'
        $script:workflowContent | Should -Match 'cron:'
        $script:workflowContent | Should -Match 'workflow_dispatch:'
    }

    It 'runs docker linux iteration and determinism checks' {
        $script:workflowContent | Should -Match 'Invoke-DockerDesktopLinuxIteration\.ps1'
        $script:workflowContent | Should -Match 'Test-RunnerCliBundleDeterminism\.ps1'
        $script:workflowContent | Should -Match 'Test-WorkspaceInstallerDeterminism\.ps1'
    }

    It 'records artifacts and opens or updates a tracking issue on failure' {
        $script:workflowContent | Should -Match 'upload-artifact'
        $script:workflowContent | Should -Match 'if:\s*failure\(\)'
        $script:workflowContent | Should -Match 'gh issue'
    }
}
