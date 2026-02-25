#Requires -Version 7.0
#Requires -Modules Pester

$ErrorActionPreference = 'Stop'

Describe 'Workspace install runtime contract' {
    BeforeAll {
        $script:repoRoot = (Resolve-Path -Path (Join-Path $PSScriptRoot '..')).Path
        $script:scriptPath = Join-Path $script:repoRoot 'scripts/Install-WorkspaceFromManifest.ps1'
        if (-not (Test-Path -LiteralPath $script:scriptPath -PathType Leaf)) {
            throw "Workspace installer runtime script missing: $script:scriptPath"
        }
        $script:scriptContent = Get-Content -LiteralPath $script:scriptPath -Raw
    }

    It 'defines required parameters and install verify modes' {
        $script:scriptContent | Should -Match '\[string\]\$WorkspaceRoot = ''C:\\dev'''
        $script:scriptContent | Should -Match '\[Parameter\(Mandatory = \$true\)\]\s*\[string\]\$ManifestPath'
        $script:scriptContent | Should -Match '\[ValidateSet\(''Install'', ''Verify''\)\]'
        $script:scriptContent | Should -Match '\$InstallerExecutionContext = '''''
        $script:scriptContent | Should -Match '\[Parameter\(Mandatory = \$true\)\]\s*\[string\]\$OutputPath'
    }

    It 'fails fast on missing dependencies and enforces deterministic pinned_sha checks' {
        $script:scriptContent | Should -Match "Get-Command 'powershell'"
        $script:scriptContent | Should -Match "Get-Command 'pwsh'"
        $script:scriptContent | Should -Match "Required command 'powershell' \(or fallback 'pwsh'\)"
        $script:scriptContent | Should -Match 'foreach \(\$commandName in @\(''git'', ''gh'', ''g-cli''\)\)'
        $script:scriptContent | Should -Match 'invalid pinned_sha'
        $script:scriptContent | Should -Match 'head_sha_mismatch'
        $script:scriptContent | Should -Match 'remote_mismatch_'
        $script:scriptContent | Should -Match 'branch_identity_mismatch'
        $script:scriptContent | Should -Match 'LVIE_OFFLINE_GIT_MODE'
        $script:scriptContent | Should -Match 'Repository path missing in offline git mode'
    }

    It 'copies governance payload to workspace root, validates runner-cli bundle, and runs governance audit' {
        $script:scriptContent | Should -Match 'workspace-governance\.json'
        $script:scriptContent | Should -Match 'AGENTS\.md'
        $script:scriptContent | Should -Match 'Assert-WorkspaceGovernance\.ps1'
        $script:scriptContent | Should -Match 'runner-cli\.exe'
        $script:scriptContent | Should -Match 'runner-cli\.metadata\.json'
        $script:scriptContent | Should -Match 'cli_bundle'
        $script:scriptContent | Should -Match 'cdev-cli-win-x64\.zip'
        $script:scriptContent | Should -Match 'cdev-cli-linux-x64\.tar\.gz'
        $script:scriptContent | Should -Match 'Expand-CdevCliWindowsBundle'
        $script:scriptContent | Should -Match 'function Get-Sha256Hex'
        $script:scriptContent | Should -Match "Get-Command 'Get-FileHash'"
        $script:scriptContent | Should -Match '\[System\.Security\.Cryptography\.SHA256\]::Create\(\)'
        $script:scriptContent | Should -Match 'Get-Sha256Hex -Path \$runnerCliExePath'
        $script:scriptContent | Should -Match 'Get-Sha256Hex -Path \$cliBundle\.asset_win_path'
        $script:scriptContent | Should -Match 'Get-Sha256Hex -Path \$cliBundle\.asset_linux_path'
        $script:scriptContent | Should -Match 'cli-bundle'
        $script:scriptContent | Should -Match 'release_build_contract'
        $script:scriptContent | Should -Match 'container_parity_contract'
        $script:scriptContent | Should -Match 'LVIE_INSTALLER_EXECUTION_PROFILE'
        $script:scriptContent | Should -Match 'host-release'
        $script:scriptContent | Should -Match 'container-parity'
        $script:scriptContent | Should -Match 'required_ppl_bitnesses'
        $script:scriptContent | Should -Match 'required_vip_bitness'
        $script:scriptContent | Should -Match '-InstallerExecutionContext NsisInstall'
        $script:scriptContent | Should -Match 'Container parity profile requires LVIE_GATE_SINGLE_PPL_BITNESS'
        $script:scriptContent | Should -Match 'Invoke-RunnerCliPplCapabilityCheck'
        $script:scriptContent | Should -Match 'Test-PplBuildLabVIEWVersionAlignment'
        $script:scriptContent | Should -Match 'labviewcli-executebuildspec-\*\.log'
        $script:scriptContent | Should -Match 'Illegal combination: PPL build executed with LabVIEW'
        $script:scriptContent | Should -Match 'failed on first attempt; retrying once after additional LabVIEW cleanup'
        $script:scriptContent | Should -Match 'Invoke-RunnerCliVipPackageHarnessCheck'
        $script:scriptContent | Should -Match 'VIP harness is skipped for execution profile ''\$executionProfile''\.'
        $script:scriptContent | Should -Match 'Invoke-VipcApplyWithVipmCli'
        $script:scriptContent | Should -Match 'Get-VipcMismatchAssessment'
        $script:scriptContent | Should -Match 'Invoke-PreVipLabVIEWCloseBestEffort'
        $script:scriptContent | Should -Match 'Pre-VIP LabVIEW close \(best-effort\)'
        $script:scriptContent | Should -Match 'Executing native VIPM CLI apply'
        $script:scriptContent | Should -Match 'vipm_best_effort'
        $script:scriptContent | Should -Match 'Non-blocking VIPC apply attempt failed; continuing to post-action gates'
        $script:scriptContent | Should -Match 'VIPC assert still reports non-blocking mismatch roots after remediation'
        $script:scriptContent | Should -Match 'sas_workshops_lib_lunit_for_g_cli'
        $script:scriptContent | Should -Not -Match '''vipc'', ''apply'''
        $script:scriptContent | Should -Match 'Invoke-VipBuild\.ps1'
        $script:scriptContent | Should -Match '''-ExecutionLabVIEWYear'', \$RequiredLabviewYear'
        $script:scriptContent | Should -Match 'vipc assert'
        $script:scriptContent | Should -Match 'vip build'
        $script:scriptContent | Should -Match 'Write-InstallerFeedback'
        $script:scriptContent | Should -Match 'execution_profile = \$executionProfile'
        $script:scriptContent | Should -Match 'contract_split = \$contractSplit'
        $script:scriptContent | Should -Match 'ppl_capability_checks'
        $script:scriptContent | Should -Match 'post_action_sequence'
        $script:scriptContent | Should -Match 'governance-audit'
        $script:scriptContent | Should -Match 'branch_protection_'
        $script:scriptContent | Should -Match 'branch_only_failure'
    }

    It 'preserves explicit LVIE_WORKTREE_ROOT and defaults to workspace root when unset' {
        $script:scriptContent | Should -Match '\$originalWorktreeRoot = \$env:LVIE_WORKTREE_ROOT'
        $script:scriptContent | Should -Match '\$effectiveWorktreeRoot = if \(\[string\]::IsNullOrWhiteSpace\(\$originalWorktreeRoot\)\) \{ \$resolvedWorkspaceRoot \} else \{ \$originalWorktreeRoot \}'
        $script:scriptContent | Should -Match '\$env:LVIE_WORKTREE_ROOT = \$effectiveWorktreeRoot'
        $script:scriptContent | Should -Match 'Setting LVIE_WORKTREE_ROOT to workspace root for post-actions'
        $script:scriptContent | Should -Match 'Using existing LVIE_WORKTREE_ROOT for post-actions'
    }

    It 'has parse-safe PowerShell syntax' {
        $tokens = $null
        $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseInput($script:scriptContent, [ref]$tokens, [ref]$errors)
        @($errors).Count | Should -Be 0
    }
}
