#Requires -Version 7.0
#Requires -Modules Pester

$ErrorActionPreference = 'Stop'

Describe 'Workspace surface contract' {
    BeforeAll {
        $script:repoRoot = (Resolve-Path -Path (Join-Path $PSScriptRoot '..')).Path
        $script:manifestPath = Join-Path $script:repoRoot 'workspace-governance.json'
        $script:agentsPath = Join-Path $script:repoRoot 'AGENTS.md'
        $script:readmePath = Join-Path $script:repoRoot 'README.md'
        $script:assertScriptPath = Join-Path $script:repoRoot 'scripts/Assert-WorkspaceGovernance.ps1'
        $script:policyScriptPath = Join-Path $script:repoRoot 'scripts/Test-PolicyContracts.ps1'
        $script:driftScriptPath = Join-Path $script:repoRoot 'scripts/Test-WorkspaceManifestBranchDrift.ps1'
        $script:ciWorkflowPath = Join-Path $script:repoRoot '.github/workflows/ci.yml'
        $script:driftWorkflowPath = Join-Path $script:repoRoot '.github/workflows/workspace-sha-drift-signal.yml'

        $requiredPaths = @(
            $script:manifestPath,
            $script:agentsPath,
            $script:readmePath,
            $script:assertScriptPath,
            $script:policyScriptPath,
            $script:driftScriptPath,
            $script:ciWorkflowPath,
            $script:driftWorkflowPath
        )

        foreach ($path in $requiredPaths) {
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
                throw "Required workspace-surface contract file missing: $path"
            }
        }

        $script:manifest = Get-Content -LiteralPath $script:manifestPath -Raw | ConvertFrom-Json -ErrorAction Stop
        $script:agentsContent = Get-Content -LiteralPath $script:agentsPath -Raw
        $script:readmeContent = Get-Content -LiteralPath $script:readmePath -Raw
        $script:ciWorkflowContent = Get-Content -LiteralPath $script:ciWorkflowPath -Raw
    }

    It 'tracks a deterministic managed repo set with pinned SHA lock' {
        @($script:manifest.managed_repos).Count | Should -BeGreaterOrEqual 7
        foreach ($repo in @($script:manifest.managed_repos)) {
            $repo.PSObject.Properties.Name | Should -Contain 'required_gh_repo'
            $repo.PSObject.Properties.Name | Should -Contain 'default_branch'
            $repo.PSObject.Properties.Name | Should -Contain 'pinned_sha'
            ([string]$repo.pinned_sha) | Should -Match '^[0-9a-f]{40}$'
        }
    }

    It 'contains codex skills fork and org entries in the manifest' {
        $repoSlugs = @($script:manifest.managed_repos | ForEach-Object { [string]$_.required_gh_repo })
        $repoSlugs | Should -Contain 'svelderrainruiz/labview-icon-editor-codex-skills'
        $repoSlugs | Should -Contain 'LabVIEW-Community-CI-CD/labview-icon-editor-codex-skills'
    }

    It 'documents drift failure as the PR release signal' {
        $script:agentsContent | Should -Match 'Workspace SHA Drift Signal'
        $script:agentsContent | Should -Match 'fails'
        $script:agentsContent | Should -Match 'create a PR'
        $script:readmeContent | Should -Match 'signal to open a PR'
    }

    It 'defines CI pipeline workflow' {
        $script:ciWorkflowContent | Should -Match 'name:\s*CI Pipeline'
        $script:ciWorkflowContent | Should -Match 'pull_request:'
        $script:ciWorkflowContent | Should -Match 'workflow_dispatch:'
        $script:ciWorkflowContent | Should -Match 'Invoke-Pester'
    }
}
