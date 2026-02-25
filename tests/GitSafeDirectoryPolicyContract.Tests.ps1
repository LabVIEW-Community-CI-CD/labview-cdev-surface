#Requires -Version 7.0
#Requires -Modules Pester

$ErrorActionPreference = 'Stop'

Describe 'Git safe-directory policy contract' {
    BeforeAll {
        $script:repoRoot = (Resolve-Path -Path (Join-Path $PSScriptRoot '..')).Path
        $script:scriptPath = Join-Path $script:repoRoot 'scripts/Ensure-GitSafeDirectories.ps1'
        if (-not (Test-Path -LiteralPath $script:scriptPath -PathType Leaf)) {
            throw "Git safe-directory policy script missing: $script:scriptPath"
        }
        $script:scriptContent = Get-Content -LiteralPath $script:scriptPath -Raw
    }

    It 'uses global safe.directory bootstrap and supports idempotent discovery' {
        $script:scriptContent | Should -Match 'git config --global --get-all safe\.directory'
        $script:scriptContent | Should -Match 'git config --global --add safe\.directory'
        $script:scriptContent | Should -Match 'ConvertTo-NormalizedPathOrRaw'
        $script:scriptContent | Should -Match "Preserve non-path safe\.directory values"
        $script:scriptContent | Should -Match 'include_git_worktrees'
        $script:scriptContent | Should -Match 'validate_git_status'
    }

    It 'supports worktree expansion and optional git status validation' {
        $script:scriptContent | Should -Match 'worktree list --porcelain'
        $script:scriptContent | Should -Match 'status --porcelain --untracked-files=no'
        $script:scriptContent | Should -Match 'detected_dubious_ownership'
    }

    It 'bootstraps repo root as safe before worktree probing' {
        $bootstrapToken = "if (-not `$existingSet.Contains(`$path)) {"
        $worktreeToken = 'Get-GitWorktreePaths -RepoPath $path'

        $bootstrapIndex = $script:scriptContent.IndexOf($bootstrapToken, [System.StringComparison]::Ordinal)
        $worktreeIndex = $script:scriptContent.IndexOf($worktreeToken, [System.StringComparison]::Ordinal)

        $bootstrapIndex | Should -BeGreaterThan -1
        $worktreeIndex | Should -BeGreaterThan -1
        $bootstrapIndex | Should -BeLessThan $worktreeIndex
    }

    It 'produces deterministic JSON evidence fields' {
        $script:scriptContent | Should -Match 'added_count'
        $script:scriptContent | Should -Match 'target_path_count'
        $script:scriptContent | Should -Match 'timestamp_utc'
        $script:scriptContent | Should -Match 'machine_name'
        $script:scriptContent | Should -Match 'user_name'
    }

    It 'has parse-safe PowerShell syntax' {
        $tokens = $null
        $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseInput($script:scriptContent, [ref]$tokens, [ref]$errors)
        @($errors).Count | Should -Be 0
    }
}
