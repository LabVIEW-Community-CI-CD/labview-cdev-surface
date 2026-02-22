#Requires -Version 7.0
#Requires -Modules Pester

$ErrorActionPreference = 'Stop'

Describe 'Workspace SHA drift signal contract' {
    BeforeAll {
        $script:repoRoot = (Resolve-Path -Path (Join-Path $PSScriptRoot '..')).Path
        $script:workflowPath = Join-Path $script:repoRoot '.github/workflows/workspace-sha-drift-signal.yml'
        $script:scriptPath = Join-Path $script:repoRoot 'scripts/Test-WorkspaceManifestBranchDrift.ps1'

        foreach ($path in @($script:workflowPath, $script:scriptPath)) {
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
                throw "Required drift-signal contract file missing: $path"
            }
        }

        $script:workflowContent = Get-Content -LiteralPath $script:workflowPath -Raw
        $script:scriptContent = Get-Content -LiteralPath $script:scriptPath -Raw
    }

    It 'runs on schedule and on demand' {
        $script:workflowContent | Should -Match 'schedule:'
        $script:workflowContent | Should -Match 'workflow_dispatch:'
        $script:workflowContent | Should -Match 'Workspace SHA Drift Signal'
    }

    It 'uses root manifest path and fails when drift is detected' {
        $script:workflowContent | Should -Match '-ManifestPath ./workspace-governance\.json'
        $script:scriptContent | Should -Match 'pinned_sha'
        $script:scriptContent | Should -Match '\$drifts\.Count -gt 0'
        $script:scriptContent | Should -Match 'exit 1'
    }

    It 'uses gh api default branch head lookup' {
        $script:scriptContent | Should -Match 'repos/\$repoSlug/commits/\$encodedBranch'
        $script:scriptContent | Should -Match '--jq ''\.sha'''
    }

    It 'uses workflow bot token strategy for cross-repo drift lookup' {
        $script:workflowContent | Should -Match 'WORKFLOW_BOT_TOKEN:\s*\$\{\{\s*secrets\.WORKFLOW_BOT_TOKEN\s*\}\}'
        $script:workflowContent | Should -Match 'GH_TOKEN:\s*\$\{\{\s*secrets\.WORKFLOW_BOT_TOKEN\s*\}\}'
        $script:scriptContent | Should -Match 'Initialize-GhToken'
    }

    It 'uploads drift report artifacts' {
        $script:workflowContent | Should -Match 'workspace-sha-drift-report-\$\{\{\s*github\.run_id\s*\}\}'
        $script:workflowContent | Should -Match 'Upload drift report'
    }

    It 'has parse-safe PowerShell syntax' {
        $tokens = $null
        $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($script:scriptPath, [ref]$tokens, [ref]$errors)
        @($errors).Count | Should -Be 0
    }
}
