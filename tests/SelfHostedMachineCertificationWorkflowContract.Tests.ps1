#Requires -Version 7.0
#Requires -Modules Pester

$ErrorActionPreference = 'Stop'

Describe 'Self-hosted machine certification workflow contract' {
    BeforeAll {
        $script:repoRoot = (Resolve-Path -Path (Join-Path $PSScriptRoot '..')).Path
        $script:workflowPath = Join-Path $script:repoRoot '.github/workflows/self-hosted-machine-certification.yml'
        if (-not (Test-Path -LiteralPath $script:workflowPath -PathType Leaf)) {
            throw "Workflow not found: $script:workflowPath"
        }
        $script:workflowContent = Get-Content -LiteralPath $script:workflowPath -Raw
    }

    It 'defines docker context switching input for one-pass setup certification' {
        $script:workflowContent | Should -Match 'switch_docker_context:'
        $script:workflowContent | Should -Match 'Switch Docker Desktop context before machine preflight'
        $script:workflowContent | Should -Match 'start_docker_desktop_if_needed:'
        $script:workflowContent | Should -Match 'Start Docker Desktop automatically when engine is not reachable'
        $script:workflowContent | Should -Match 'allowed_machine_names_csv:'
        $script:workflowContent | Should -Match 'default:\s*true'
    }

    It 'uses setup-aware concurrency and actor-scoped certify locking' {
        $script:workflowContent | Should -Match 'concurrency:'
        $script:workflowContent | Should -Match 'self-hosted-machine-certification-\$\{\{\s*github\.ref\s*\}\}-\$\{\{\s*github\.event\.inputs\.setup_name\s*\|\|\s*''push-matrix''\s*\}\}'
        $script:workflowContent | Should -Match 'cancel-in-progress:\s*false'
        $script:workflowContent | Should -Match 'self-hosted-machine-certify-actor-\$\{\{\s*matrix\.actor_lock_group\s*\|\|\s*matrix\.setup_name\s*\}\}'
    }

    It 'passes switch and strict docker checks into machine preflight' {
        $script:workflowContent | Should -Match 'Assert-InstallerHarnessMachinePreflight\.ps1'
        $script:workflowContent | Should -Match '-DockerCheckSeverity error'
        $script:workflowContent | Should -Match '-StartDockerDesktopIfNeeded:\$\(\[System\.Convert\]::ToBoolean\('
        $script:workflowContent | Should -Match 'matrix\.start_docker_desktop_if_needed'
        $script:workflowContent | Should -Match '-SwitchDockerContext:\$\(\[System\.Convert\]::ToBoolean\('
        $script:workflowContent | Should -Match 'matrix\.switch_docker_context'
    }

    It 'keeps push matrix contexts explicit and switch-enabled' {
        $script:workflowContent | Should -Match 'setup_name:\s*"legacy-2020-desktop-linux"'
        $script:workflowContent | Should -Match 'docker_context:\s*"desktop-linux"'
        $script:workflowContent | Should -Match 'start_docker_desktop_if_needed:\s*"true"'
        $script:workflowContent | Should -Match 'switch_docker_context:\s*"true"'
        $script:workflowContent | Should -Match 'allowed_machine_names_csv:\s*"GHOST,DESKTOP-6Q81H4O"'
        $script:workflowContent | Should -Match 'actor_lock_group:\s*"actor-linux-desktop-shared"'
        $script:workflowContent | Should -Match 'linux-gate-windows-ready'
        $script:workflowContent | Should -Match 'setup_name:\s*"legacy-2020-desktop-windows"'
        $script:workflowContent | Should -Match 'docker_context:\s*"desktop-windows"'
        $script:workflowContent | Should -Match 'setup_name:\s*"legacy-2020-desktop-windows"[\s\S]*?require_secondary_32:\s*"false"'
        $script:workflowContent | Should -Match 'allowed_machine_names_csv:\s*"GHOST"'
        $script:workflowContent | Should -Match 'setup_name:\s*"legacy-2020-desktop-windows"[\s\S]*?actor_lock_group:\s*"actor-ghost-windows"'
        $script:workflowContent | Should -Match 'cdev-surface-windows-gate'
        $script:workflowContent | Should -Match 'setup_name:\s*"legacy-2020-desktop-windows-32"'
        $script:workflowContent | Should -Match 'execution_bitness:\s*"32"'
        $script:workflowContent | Should -Match 'setup_name:\s*"legacy-2020-desktop-windows-32"[\s\S]*?actor_lock_group:\s*"actor-ghost-windows"'
        $script:workflowContent | Should -Match 'setup_name:\s*"host-2025-desktop-windows"'
        $script:workflowContent | Should -Match 'expected_labview_year:\s*"2025"'
        $script:workflowContent | Should -Match 'setup_name:\s*"host-2025-desktop-windows"[\s\S]*?actor_lock_group:\s*"actor-ghost-windows"'
        $script:workflowContent | Should -Match 'cert-setup-host-2025-desktop-windows'
    }

    It 'runs per-bitness MassCompile and VI Analyzer certification with summary fields' {
        $script:workflowContent | Should -Match 'Run MassCompile certification \(64-bit\)'
        $script:workflowContent | Should -Match 'Run MassCompile certification \(32-bit\)'
        $script:workflowContent | Should -Match 'Enforce bitness handoff \(MassCompile 64->32\)'
        $script:workflowContent | Should -Match "if: \$\{\{\s*steps\.execution-contract\.outputs\.has_bitness_64 == 'true'\s*\}\}"
        $script:workflowContent | Should -Match "if: \$\{\{\s*steps\.execution-contract\.outputs\.has_bitness_32 == 'true'\s*\}\}"
        $script:workflowContent | Should -Match 'Invoke-MassCompileCertification\.ps1'
        $script:workflowContent | Should -Match 'Resolve execution LabVIEW bitness for certification'
        $script:workflowContent | Should -Match 'seed-contract\.outputs\.seed_contract_path'
        $script:workflowContent | Should -Match 'PSObject\.Properties\[\$year\]'
        $script:workflowContent | Should -Match '\$orderedBitness \+= ''64'''
        $script:workflowContent | Should -Match '\$orderedBitness \+= ''32'''
        $script:workflowContent | Should -Match 'available_bitness_csv'
        $script:workflowContent | Should -Match 'execution-contract\.outputs\.supported_bitness'
        $script:workflowContent | Should -Match '-TargetRelativePath ''vi\.lib\\LabVIEW Icon API'''
        $script:workflowContent | Should -Match 'masscompile_64_report_path'
        $script:workflowContent | Should -Match 'masscompile_32_report_path'
        $script:workflowContent | Should -Match 'masscompile_status'
        $script:workflowContent | Should -Match 'masscompile_64_status'
        $script:workflowContent | Should -Match 'masscompile_32_status'
        $script:workflowContent | Should -Match 'masscompile_exit_code'
        $script:workflowContent | Should -Match 'Run VI Analyzer certification \(64-bit\)'
        $script:workflowContent | Should -Match 'Run VI Analyzer certification \(32-bit\)'
        $script:workflowContent | Should -Match 'Enforce bitness handoff \(VI Analyzer 64->32\)'
        $script:workflowContent | Should -Match 'Invoke-ViAnalyzerCertification\.ps1'
        $script:workflowContent | Should -Match 'vi_analyzer_64_report_path'
        $script:workflowContent | Should -Match 'vi_analyzer_32_report_path'
        $script:workflowContent | Should -Match 'vi_analyzer_status'
        $script:workflowContent | Should -Match 'vi_analyzer_64_status'
        $script:workflowContent | Should -Match 'vi_analyzer_32_status'
        $script:workflowContent | Should -Match 'Run runner-cli PPL certification \(linux-64\)'
        $script:workflowContent | Should -Match 'Run runner-cli PPL certification \(windows-64\)'
        $script:workflowContent | Should -Match 'Run runner-cli PPL certification \(windows-32\)'
        $script:workflowContent | Should -Match 'Enforce bitness handoff \(runner-cli PPL 64->32\)'
        $script:workflowContent | Should -Match 'Invoke-RunnerCliPplCertification\.ps1'
        $script:workflowContent | Should -Match 'Assert-LabVIEWBitnessHandoff\.ps1'
        $script:workflowContent | Should -Match 'runnercli_ppl_linux_64_report_path'
        $script:workflowContent | Should -Match 'runnercli_ppl_windows_64_report_path'
        $script:workflowContent | Should -Match 'runnercli_ppl_windows_32_report_path'
        $script:workflowContent | Should -Match 'runnercli_ppl_platform'
        $script:workflowContent | Should -Match 'runnercli_ppl_status'
        $script:workflowContent | Should -Match 'runnercli_ppl_output_ppl_size_bytes'
        $script:workflowContent | Should -Match 'runnercli_ppl_64_output_ppl_size_bytes'
        $script:workflowContent | Should -Match 'runnercli_ppl_32_output_ppl_size_bytes'
        $script:workflowContent | Should -Match 'runnercli_ppl_secondary_output_ppl_size_bytes'
        $script:workflowContent | Should -Match 'runner-cli ppl output size bytes'
        $script:workflowContent | Should -Match 'runner-cli ppl 64-bit size bytes'
        $script:workflowContent | Should -Match 'runner-cli ppl 32-bit size bytes'
        $script:workflowContent | Should -Match "matrix\.docker_context == 'desktop-linux'"
        $script:workflowContent | Should -Match "matrix\.docker_context == 'desktop-windows'"
        $script:workflowContent | Should -Match "matrix\.require_secondary_32 == 'true'"
        $script:workflowContent | Should -Match 'runnercli_ppl_secondary_status'
        $script:workflowContent | Should -Match 'runnercli_ppl_secondary_requested'
        $script:workflowContent | Should -Match 'Compare x64 vs x86 LabVIEW file sizes \(manifest \+ summary\)'
        $script:workflowContent | Should -Match 'Export-LabVIEWBitnessFileSizeManifest\.ps1'
        $script:workflowContent | Should -Match 'labview_bitness_filesize_manifest_status'
        $script:workflowContent | Should -Match 'labview_bitness_filesize_manifest_path'
        $script:workflowContent | Should -Match 'labview_bitness_filesize_manifest_summary'
    }

    It 'builds VIP package in a downstream artifact-consuming job with VIPB contract mapping' {
        $script:workflowContent | Should -Match 'Build VI Package From Certification Outputs'
        $script:workflowContent | Should -Match 'package_setups_json'
        $script:workflowContent | Should -Match 'fromJson\(needs\.resolve-setups\.outputs\.package_setups_json\)'
        $script:workflowContent | Should -Match 'PACKAGE_SETUP_TARGET='
        $script:workflowContent | Should -Match 'if \[\[ "\$\{\{\s*github\.event_name\s*\}\}" == "workflow_dispatch" \]\]'
        $script:workflowContent | Should -Match 'actions/download-artifact@v4'
        $script:workflowContent | Should -Match 'self-hosted-machine-certification-\$\{\{\s*matrix\.setup_name\s*\}\}-\$\{\{\s*github\.run_id\s*\}\}'
        $script:workflowContent | Should -Match 'if:\s*\$\{\{\s*matrix\.setup_name == ''legacy-2020-desktop-windows''\s*\}\}'
        $script:workflowContent | Should -Match 'Download secondary 32-bit certification artifact bundle'
        $script:workflowContent | Should -Match 'self-hosted-machine-certification-legacy-2020-desktop-windows-32-\$\{\{\s*github\.run_id\s*\}\}'
        $script:workflowContent | Should -Match 'secondary_certification_summary_path'
        $script:workflowContent | Should -Match 'vipb_destination_missing'
        $script:workflowContent | Should -Match 'vipb_destination_ambiguous'
        $script:workflowContent | Should -Match 'vipb_destination_collision'
        $script:workflowContent | Should -Match 'vipb_required_ppl_missing'
        $script:workflowContent | Should -Match 'ppl_rename_source_empty'
        $script:workflowContent | Should -Match 'ppl_rename_destination_empty'
        $script:workflowContent | Should -Match 'Length -le 0'
        $script:workflowContent | Should -Match "Primary certification x64 PPL size must be greater than zero"
        $script:workflowContent | Should -Match "Secondary certification x86 PPL size must be greater than zero"
        $script:workflowContent | Should -Match 'Assert-LabVIEWBitnessHandoff\.ps1'
        $script:workflowContent | Should -Match 'vipm_prebuild_bitness_handoff_failed'
        $script:workflowContent | Should -Match 'Ensure-LabVIEWCliPortContractAndIni\.ps1'
        $script:workflowContent | Should -Match 'vipm_port_contract_remediation_failed'
        $script:workflowContent | Should -Match 'vipm_port_contract_invalid_expected_port'
        $script:workflowContent | Should -Match "\$executionBitness = '64'"
        $script:workflowContent | Should -Match 'primary certified execution bitness'
        $script:workflowContent | Should -Match 'certified_execution_bitness'
        $script:workflowContent | Should -Match 'labview_process_observation_status'
        $script:workflowContent | Should -Match 'labview_process_observation_message'
        $script:workflowContent | Should -Match 'vipm_labview_process_not_observed'
        $script:workflowContent | Should -Match 'vipm_labview_bitness_mismatch_observed'
        $script:workflowContent | Should -Match 'labview_bitness_mismatch_observed'
        $script:workflowContent | Should -Match 'vipm_log_error_detected'
        $script:workflowContent | Should -Match 'vipm build did not produce a .vip output'
        $script:workflowContent | Should -Match 'vip_output_empty'
        $script:workflowContent | Should -Match 'built_vip_size_bytes'
        $script:workflowContent | Should -Match '\$vipZipPath = Join-Path \$outputRoot'
        $script:workflowContent | Should -Match 'Copy-Item -LiteralPath \$vipOutPath -Destination \$vipZipPath -Force'
        $script:workflowContent | Should -Match 'Expand-Archive -Path \$vipZipPath'
        $script:workflowContent | Should -Not -Match '\[System\.IO\.Path\]::GetRelativePath'
        $script:workflowContent | Should -Match 'vipb_package_labview_version_missing_after_patch'
        $script:workflowContent | Should -Match 'vipb_package_labview_version_not_applied'
        $script:workflowContent | Should -Match 'vipb_package_labview_version_before'
        $script:workflowContent | Should -Match 'vipb_package_labview_version_after'
        $script:workflowContent | Should -Match 'item_type = \$\(if \(\$_\.PSIsContainer\)'
        $script:workflowContent | Should -Match 'size_bytes = \$\(if \(\$_\.PSIsContainer\)'
        $script:workflowContent | Should -Match 'built_vip_contents_manifest_path'
        $script:workflowContent | Should -Match 'built_vip_contents_tree_path'
        $script:workflowContent | Should -Match 'VIP Contents \(ZIP View\)'
        $script:workflowContent | Should -Match 'expected_port'
        $script:workflowContent | Should -Match '<Package_LabVIEW_Version>'
        $script:workflowContent | Should -Match 'self-hosted-machine-certification-vip-\$\{\{\s*matrix\.setup_name\s*\}\}-\$\{\{\s*github\.run_id\s*\}\}'
    }

    It 'requires headless runner enforcement in machine preflight and MassCompile script' {
        $preflightScriptPath = Join-Path $script:repoRoot 'scripts\Assert-InstallerHarnessMachinePreflight.ps1'
        $massCompileScriptPath = Join-Path $script:repoRoot 'scripts\Invoke-MassCompileCertification.ps1'
        $viAnalyzerScriptPath = Join-Path $script:repoRoot 'scripts\Invoke-ViAnalyzerCertification.ps1'
        $runnerCliPplScriptPath = Join-Path $script:repoRoot 'scripts\Invoke-RunnerCliPplCertification.ps1'
        $preflightContent = Get-Content -LiteralPath $preflightScriptPath -Raw
        $massCompileContent = Get-Content -LiteralPath $massCompileScriptPath -Raw
        $viAnalyzerContent = Get-Content -LiteralPath $viAnalyzerScriptPath -Raw
        $runnerCliPplContent = Get-Content -LiteralPath $runnerCliPplScriptPath -Raw

        $preflightContent | Should -Match 'runner:headless_session'
        $preflightContent | Should -Match 'runner_not_headless'
        $massCompileContent | Should -Match 'runner_not_headless'
        $massCompileContent | Should -Match "'-Headless'"
        $viAnalyzerContent | Should -Match 'runner_not_headless'
        $runnerCliPplContent | Should -Match 'runner_not_headless'
    }

    It 'enforces setup-specific machine affinity before preflight execution' {
        $script:workflowContent | Should -Match 'Assert setup machine affinity'
        $script:workflowContent | Should -Match 'allowed_machine_names_csv_empty'
        $script:workflowContent | Should -Match 'runner_machine_not_allowed'
        $script:workflowContent | Should -Match 'machine-affinity'
    }
}
