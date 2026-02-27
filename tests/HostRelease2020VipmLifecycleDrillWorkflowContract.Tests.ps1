#Requires -Version 7.0
#Requires -Modules Pester

$ErrorActionPreference = 'Stop'

Describe 'Host release 2020 VIPM lifecycle drill workflow contract' {
    BeforeAll {
        $script:repoRoot = (Resolve-Path -Path (Join-Path $PSScriptRoot '..')).Path
        $script:workflowPath = Join-Path $script:repoRoot '.github/workflows/host-release-2020-vipm-lifecycle-drill.yml'
        $script:drillRuntimePath = Join-Path $script:repoRoot 'scripts/Invoke-HostRelease2020VipmLifecycleDrill.ps1'
        $script:vipmRuntimePath = Join-Path $script:repoRoot 'scripts/Invoke-VipmInstallUninstallCheck.ps1'

        foreach ($path in @($script:workflowPath, $script:drillRuntimePath, $script:vipmRuntimePath)) {
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
                throw "Host release 2020 VIPM lifecycle contract file missing: $path"
            }
        }

        $script:workflowContent = Get-Content -LiteralPath $script:workflowPath -Raw
        $script:drillRuntimeContent = Get-Content -LiteralPath $script:drillRuntimePath -Raw
        $script:vipmRuntimeContent = Get-Content -LiteralPath $script:vipmRuntimePath -Raw
    }

    It 'is dispatchable with ref, bitness, workspace retention, and NSIS override inputs' {
        $script:workflowContent | Should -Match 'workflow_dispatch:'
        $script:workflowContent | Should -Match 'ref:'
        $script:workflowContent | Should -Match 'selected_ppl_bitness:'
        $script:workflowContent | Should -Match 'keep_smoke_workspace:'
        $script:workflowContent | Should -Match 'allow_system_account:'
        $script:workflowContent | Should -Match 'nsis_root:'
    }

    It 'runs on installer-harness self-hosted windows labels and publishes deterministic artifacts' {
        $script:workflowContent | Should -Match 'runs-on:\s*\[self-hosted,\s*windows,\s*self-hosted-windows-lv,\s*installer-harness\]'
        $script:workflowContent | Should -Match 'Assert-InstallerHarnessMachinePreflight\.ps1'
        $script:workflowContent | Should -Match 'allow_system_account must be boolean'
        $script:workflowContent | Should -Match 'ExpectedLabviewYear'
        $script:workflowContent | Should -Match '-RequireNonSystemAccount'
        $script:workflowContent | Should -Match 'Invoke-HostRelease2020VipmLifecycleDrill\.ps1'
        $script:workflowContent | Should -Match "TargetLabviewYear', '2020'"
        $script:workflowContent | Should -Match 'host-release-2020-vipm-lifecycle-drill-report-\$\{\{\s*github\.run_id\s*\}\}'
        $script:workflowContent | Should -Match 'host-release-2020-vipm-lifecycle-drill-report\.json'
    }

    It 'orchestrates host-release installer iteration and deterministic VIPM lifecycle checks' {
        foreach ($token in @(
                'reasonCodeTaxonomy',
                'LVIE_INSTALLER_EXECUTION_PROFILE',
                'host-release',
                'LVIE_RUNNERCLI_EXECUTION_LABVIEW_YEAR',
                'Invoke-WorkspaceInstallerIteration\.ps1',
                'Invoke-VipmInstallUninstallCheck\.ps1',
                'vipm_lifecycle_failed',
                'vip_lifecycle_drill_passed'
            )) {
            $script:drillRuntimeContent | Should -Match $token
        }
    }

    It 'implements deterministic VIPM install/uninstall reason codes and command flows' {
        foreach ($token in @(
                'vip_path_missing',
                'target_labview_missing',
                'vipm_cli_missing',
                'vipm_activate_failed',
                'vipm_list_before_failed',
                'vipm_install_failed',
                'vipm_list_after_install_failed',
                'uninstall_target_resolution_failed',
                'vipm_uninstall_failed',
                'vipm_list_after_uninstall_failed',
                'vipm_uninstall_verification_failed',
                'vip_lifecycle_passed',
                'vipm_lifecycle_runtime_error',
                'vipm activate',
                '--labview-version',
                '--labview-bitness',
                '--labview',
                '--bitness',
                '''install'',',
                '''uninstall'','
            )) {
            $script:vipmRuntimeContent | Should -Match $token
        }
    }

    It 'has parse-safe PowerShell syntax for new runtimes' {
        foreach ($content in @($script:drillRuntimeContent, $script:vipmRuntimeContent)) {
            $tokens = $null
            $errors = $null
            [void][System.Management.Automation.Language.Parser]::ParseInput($content, [ref]$tokens, [ref]$errors)
            @($errors).Count | Should -Be 0
        }
    }
}
