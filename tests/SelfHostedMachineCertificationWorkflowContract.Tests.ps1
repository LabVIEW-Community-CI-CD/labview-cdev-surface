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

    It 'uses setup-aware concurrency to avoid workflow-dispatch run cancellation' {
        $script:workflowContent | Should -Match 'concurrency:'
        $script:workflowContent | Should -Match 'self-hosted-machine-certification-\$\{\{\s*github\.ref\s*\}\}-\$\{\{\s*github\.event\.inputs\.setup_name\s*\|\|\s*''push-matrix''\s*\}\}'
        $script:workflowContent | Should -Match 'cancel-in-progress:\s*false'
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
        $script:workflowContent | Should -Match 'linux-gate-windows-ready'
        $script:workflowContent | Should -Match 'setup_name:\s*"legacy-2020-desktop-windows"'
        $script:workflowContent | Should -Match 'docker_context:\s*"desktop-windows"'
        $script:workflowContent | Should -Match 'allowed_machine_names_csv:\s*"GHOST"'
        $script:workflowContent | Should -Match 'cdev-surface-windows-gate'
    }

    It 'runs MassCompile, VI Analyze, and runner-cli PPL certification with summary fields' {
        $script:workflowContent | Should -Match 'Run MassCompile certification'
        $script:workflowContent | Should -Match 'Invoke-MassCompileCertification\.ps1'
        $script:workflowContent | Should -Match '-TargetRelativePath ''vi\.lib\\LabVIEW Icon API'''
        $script:workflowContent | Should -Match 'masscompile_report_path'
        $script:workflowContent | Should -Match 'masscompile_status'
        $script:workflowContent | Should -Match 'masscompile_exit_code'
        $script:workflowContent | Should -Match 'Run VI Analyze certification'
        $script:workflowContent | Should -Match 'Invoke-ViAnalyzerCertification\.ps1'
        $script:workflowContent | Should -Match 'vi_analyzer_report_path'
        $script:workflowContent | Should -Match 'vi_analyzer_status'
        $script:workflowContent | Should -Match 'Run runner-cli PPL certification'
        $script:workflowContent | Should -Match 'Invoke-RunnerCliPplCertification\.ps1'
        $script:workflowContent | Should -Match 'runnercli_ppl_report_path'
        $script:workflowContent | Should -Match 'runnercli_ppl_status'
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
