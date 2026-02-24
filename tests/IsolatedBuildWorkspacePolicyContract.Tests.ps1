#Requires -Version 7.0
#Requires -Modules Pester

$ErrorActionPreference = 'Stop'

Describe 'Isolated build workspace policy contract' {
    BeforeAll {
        $script:repoRoot = (Resolve-Path -Path (Join-Path $PSScriptRoot '..')).Path
        $script:resolveScriptPath = Join-Path $script:repoRoot 'scripts/Resolve-IsolatedBuildWorkspace.ps1'
        $script:prepareScriptPath = Join-Path $script:repoRoot 'scripts/Prepare-IsolatedRepoAtPinnedSha.ps1'
        $script:convertScriptPath = Join-Path $script:repoRoot 'scripts/Convert-ManifestToWorkspace.ps1'
        $script:cleanupScriptPath = Join-Path $script:repoRoot 'scripts/Cleanup-IsolatedBuildWorkspace.ps1'

        foreach ($path in @($script:resolveScriptPath, $script:prepareScriptPath, $script:convertScriptPath, $script:cleanupScriptPath)) {
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
                throw "Isolated workspace helper script missing: $path"
            }
        }

        $script:resolveContent = Get-Content -LiteralPath $script:resolveScriptPath -Raw
        $script:prepareContent = Get-Content -LiteralPath $script:prepareScriptPath -Raw
        $script:convertContent = Get-Content -LiteralPath $script:convertScriptPath -Raw
        $script:cleanupContent = Get-Content -LiteralPath $script:cleanupScriptPath -Raw
    }

    It 'resolves deterministic windows root candidates with D then C fallback' {
        $script:resolveContent | Should -Match "@\('D:\\\\dev', 'C:\\\\dev'\)"
        $script:resolveContent | Should -Match "_lvie-ci\\surface"
        $script:resolveContent | Should -Match 'LVIE_ISOLATED_DRIVE_ROOT'
        $script:resolveContent | Should -Match 'LVIE_ISOLATED_JOB_ROOT'
        $script:resolveContent | Should -Match 'LVIE_ISOLATED_WORKSPACE_ROOT'
        $script:resolveContent | Should -Match 'LVIE_ISOLATED_REPOS_ROOT'
    }

    It 'provisions isolated repos via worktree first with detached-clone fallback' {
        $script:prepareContent | Should -Match 'worktree add --detach'
        $script:prepareContent | Should -Match 'git clone --quiet --no-tags'
        $script:prepareContent | Should -Match "provisionMode = 'detached-clone'"
        $script:prepareContent | Should -Match "provisionMode = 'worktree'"
        $script:prepareContent | Should -Match 'worktree_error'
    }

    It 'rewrites workspace manifest roots for isolated execution' {
        $script:convertContent | Should -Match 'workspace_root'
        $script:convertContent | Should -Match 'managed_repos'
        $script:convertContent | Should -Match 'updated_repo_count'
    }

    It 'supports strict and best-effort cleanup modes' {
        $script:cleanupContent | Should -Match '\[switch\]\$BestEffort'
        $script:cleanupContent | Should -Match '\[switch\]\$RequireExists'
        $script:cleanupContent | Should -Match "status = 'deleted'"
        $script:cleanupContent | Should -Match "status = 'warning'"
    }

    It 'has parse-safe PowerShell syntax for helper scripts' {
        foreach ($content in @($script:resolveContent, $script:prepareContent, $script:convertContent, $script:cleanupContent)) {
            $tokens = $null
            $errors = $null
            [void][System.Management.Automation.Language.Parser]::ParseInput($content, [ref]$tokens, [ref]$errors)
            @($errors).Count | Should -Be 0
        }
    }
}
