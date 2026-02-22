#Requires -Version 7.0
#Requires -Modules Pester

$ErrorActionPreference = 'Stop'

Describe 'Workspace SHA refresh PR workflow contract' {
    BeforeAll {
        $script:repoRoot = (Resolve-Path -Path (Join-Path $PSScriptRoot '..')).Path
        $script:workflowPath = Join-Path $script:repoRoot '.github/workflows/workspace-sha-refresh-pr.yml'
        if (-not (Test-Path -LiteralPath $script:workflowPath -PathType Leaf)) {
            throw "Required workflow file missing: $script:workflowPath"
        }

        $script:workflowContent = Get-Content -LiteralPath $script:workflowPath -Raw
    }

    It 'is schedule and dispatch driven with write permissions' {
        $script:workflowContent | Should -Match 'schedule:'
        $script:workflowContent | Should -Match 'workflow_dispatch:'
        $script:workflowContent | Should -Match 'actions:\s*write'
        $script:workflowContent | Should -Match 'contents:\s*write'
        $script:workflowContent | Should -Match 'pull-requests:\s*write'
    }

    It 'uses deterministic single-branch refresh PR flow' {
        $script:workflowContent | Should -Match 'automation/sha-refresh'
        $script:workflowContent | Should -Match 'peter-evans/create-pull-request@v6'
        $script:workflowContent | Should -Match 'workspace-governance\.json'
        $script:workflowContent | Should -Match 'workspace-governance-payload/workspace-governance/workspace-governance\.json'
    }

    It 'requires WORKFLOW_BOT_TOKEN for mutation operations' {
        $script:workflowContent | Should -Match 'WORKFLOW_BOT_TOKEN'
        $script:workflowContent | Should -Match 'Required secret WORKFLOW_BOT_TOKEN is not configured'
        $script:workflowContent | Should -Match 'token:\s*\${{\s*secrets\.WORKFLOW_BOT_TOKEN\s*}}'
        $script:workflowContent | Should -Not -Match 'token:\s*\${{\s*github\.token\s*}}'
    }

    It 'enables squash auto-merge for refresh PRs' {
        $script:workflowContent | Should -Match 'gh pr merge'
        $script:workflowContent | Should -Match '--auto'
        $script:workflowContent | Should -Match '--squash'
    }

    It 'dispatches CI Pipeline for automation branch' {
        $script:workflowContent | Should -Match 'gh workflow run ci\.yml'
        $script:workflowContent | Should -Match '--ref automation/sha-refresh'
    }
}
