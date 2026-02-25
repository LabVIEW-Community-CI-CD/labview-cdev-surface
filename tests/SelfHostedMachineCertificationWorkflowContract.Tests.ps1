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
        $script:workflowContent | Should -Match 'linux-gate-windows-ready'
        $script:workflowContent | Should -Match 'setup_name:\s*"legacy-2020-desktop-windows"'
        $script:workflowContent | Should -Match 'docker_context:\s*"desktop-windows"'
        $script:workflowContent | Should -Match 'cdev-surface-windows-gate'
    }
}
