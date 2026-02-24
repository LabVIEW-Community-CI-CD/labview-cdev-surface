#Requires -Version 7.0
#Requires -Modules Pester

$ErrorActionPreference = 'Stop'

Describe 'Linux LabVIEW image gate workflow contract' {
    BeforeAll {
        $script:repoRoot = (Resolve-Path -Path (Join-Path $PSScriptRoot '..')).Path
        $script:wrapperWorkflowPath = Join-Path $script:repoRoot '.github/workflows/linux-labview-image-gate.yml'
        $script:coreWorkflowPath = Join-Path $script:repoRoot '.github/workflows/_linux-labview-image-gate-core.yml'
        if (-not (Test-Path -LiteralPath $script:wrapperWorkflowPath -PathType Leaf)) {
            throw "Linux image gate wrapper workflow missing: $script:wrapperWorkflowPath"
        }
        if (-not (Test-Path -LiteralPath $script:coreWorkflowPath -PathType Leaf)) {
            throw "Linux image gate core workflow missing: $script:coreWorkflowPath"
        }
        $script:wrapperWorkflowContent = Get-Content -LiteralPath $script:wrapperWorkflowPath -Raw
        $script:coreWorkflowContent = Get-Content -LiteralPath $script:coreWorkflowPath -Raw
    }

    It 'keeps dispatch-only wrapper and forwards to reusable core' {
        $script:wrapperWorkflowContent | Should -Match 'workflow_dispatch:'
        $script:wrapperWorkflowContent | Should -Not -Match '(?m)^\s*push:'
        $script:wrapperWorkflowContent | Should -Not -Match '(?m)^\s*pull_request:'
        $script:wrapperWorkflowContent | Should -Match 'uses:\s*\./\.github/workflows/_linux-labview-image-gate-core\.yml'
    }

    It 'resolves linux image tags deterministically and enforces locked image pinning' {
        $script:coreWorkflowContent | Should -Match 'workflow_call:'
        $script:coreWorkflowContent | Should -Match 'installer_contract\.container_parity_contract'
        $script:coreWorkflowContent | Should -Match 'linux_tag_strategy'
        $script:coreWorkflowContent | Should -Match 'allowed_linux_tags'
        $script:coreWorkflowContent | Should -Match 'locked_linux_image'
        $script:coreWorkflowContent | Should -Match 'windows_host_execution_mode'
        $script:coreWorkflowContent | Should -Match 'windows_host_native_labview_version'
        $script:coreWorkflowContent | Should -Match 'sibling-windows-to-linux'
        $script:coreWorkflowContent | Should -Match '\.lvcontainer'
        $script:coreWorkflowContent | Should -Match '2025q3-linux@sha256:9938561c6460841674f9b1871d8562242f51fe9fb72a2c39c66608491edf429c'
        $script:coreWorkflowContent | Should -Match '2025q3'
        $script:coreWorkflowContent | Should -Match 'resolved_linux_tag'
        $script:coreWorkflowContent | Should -Match 'linux-image-resolution\.json'
    }

    It 'defines required linux parity jobs and VIP preflight contract' {
        $script:coreWorkflowContent | Should -Match 'linux-parity-ppl-64:'
        $script:coreWorkflowContent | Should -Match 'windows-host-ppl-32:'
        $script:coreWorkflowContent | Should -Match 'windows-host-ppl-64:'
        $script:coreWorkflowContent | Should -Match 'linux-parity-vip:'
        $script:coreWorkflowContent | Should -Match 'lv_icon_x86\.lvlibp'
        $script:coreWorkflowContent | Should -Match 'lv_icon_x64\.lvlibp'
        $script:coreWorkflowContent | Should -Match 'vipm_api_unavailable'
        $script:coreWorkflowContent | Should -Match "driver = 'vipm-api'"
        $script:coreWorkflowContent | Should -Match 'artifact_role = ''signal-only'''
        $script:coreWorkflowContent | Should -Match 'artifacts/parity/linux/vip/\*'
        $script:coreWorkflowContent | Should -Match 'artifacts/release/\*'
        $script:coreWorkflowContent | Should -Not -Match '\bg-cli\b'
    }

    It 'publishes linux parity artifacts and exposes reusable outputs' {
        $script:coreWorkflowContent | Should -Match 'gate_status:'
        $script:coreWorkflowContent | Should -Match 'gate_report_artifact_name:'
        $script:coreWorkflowContent | Should -Match 'gate_report_path:'
        $script:coreWorkflowContent | Should -Match 'capture-gate-metadata'
        $script:coreWorkflowContent | Should -Match 'upload-artifact'
        $script:coreWorkflowContent | Should -Match 'if-no-files-found:'
    }
}
