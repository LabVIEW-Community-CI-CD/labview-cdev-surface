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
        $script:wrapperWorkflowContent | Should -Match 'windows-labview-image-gate-prereq:'
        $script:wrapperWorkflowContent | Should -Match 'uses:\s*\./\.github/workflows/_windows-labview-image-gate-core\.yml'
        $script:wrapperWorkflowContent | Should -Match 'linux_prereq_only:\s*true'
        $script:wrapperWorkflowContent | Should -Match 'needs:\s*\[windows-labview-image-gate-prereq\]'
        $script:wrapperWorkflowContent | Should -Match 'uses:\s*\./\.github/workflows/_linux-labview-image-gate-core\.yml'
        $script:wrapperWorkflowContent | Should -Match 'windows_prereq_x86_artifact_name:'
        $script:wrapperWorkflowContent | Should -Match 'windows_prereq_x64_artifact_name:'
        $script:wrapperWorkflowContent | Should -Match 'windows_prereq_native_labview_version:'
    }

    It 'resolves linux image tags deterministically and enforces locked image pinning' {
        $script:coreWorkflowContent | Should -Match 'workflow_call:'
        $script:coreWorkflowContent | Should -Match 'inputs:'
        $script:coreWorkflowContent | Should -Match 'windows_prereq_x86_artifact_name:'
        $script:coreWorkflowContent | Should -Match 'windows_prereq_x64_artifact_name:'
        $script:coreWorkflowContent | Should -Match 'windows_prereq_native_labview_version:'
        $script:coreWorkflowContent | Should -Match 'installer_contract\.container_parity_contract'
        $script:coreWorkflowContent | Should -Match 'linux_tag_strategy'
        $script:coreWorkflowContent | Should -Match 'allowed_linux_tags'
        $script:coreWorkflowContent | Should -Match 'locked_linux_image'
        $script:coreWorkflowContent | Should -Match 'windows_host_execution_mode'
        $script:coreWorkflowContent | Should -Match 'windows_host_native_labview_version'
        $script:coreWorkflowContent | Should -Match 'linux_labview_path'
        $script:coreWorkflowContent | Should -Match 'linux_cli_operation'
        $script:coreWorkflowContent | Should -Match 'linux_headless_required'
        $script:coreWorkflowContent | Should -Match 'linux_enable_cicd_features'
        $script:coreWorkflowContent | Should -Match 'sibling-windows-to-linux'
        $script:coreWorkflowContent | Should -Match '\.lvcontainer'
        $script:coreWorkflowContent | Should -Match '2025q3-linux@sha256:9938561c6460841674f9b1871d8562242f51fe9fb72a2c39c66608491edf429c'
        $script:coreWorkflowContent | Should -Match '2025q3'
        $script:coreWorkflowContent | Should -Match 'resolved_linux_tag'
        $script:coreWorkflowContent | Should -Match 'derived_linux_tag'
        $script:coreWorkflowContent | Should -Match 'resolved_tag_was_allowed'
        $script:coreWorkflowContent | Should -Match 'fallback_to_locked_image'
        $script:coreWorkflowContent | Should -Match 'fallback_reason'
        $script:coreWorkflowContent | Should -Match 'Using locked_linux_image tag'
        $script:coreWorkflowContent | Should -Not -Match 'does not match resolved_linux_tag'
        $script:coreWorkflowContent | Should -Match 'linux-image-resolution\.json'
    }

    It 'defines required linux parity jobs and consumes real windows-host artifacts for VIP preflight' {
        $script:coreWorkflowContent | Should -Match 'linux-parity-ppl-64:'
        $script:coreWorkflowContent | Should -Match 'linux-parity-vip:'
        $script:coreWorkflowContent | Should -Match 'resolve-prereq-artifacts'
        $script:coreWorkflowContent | Should -Not -Match 'windows-host-ppl-32:'
        $script:coreWorkflowContent | Should -Not -Match 'windows-host-ppl-64:'
        $script:coreWorkflowContent | Should -Match 'windows-host-linux-prereq-x86-'
        $script:coreWorkflowContent | Should -Match 'windows-host-linux-prereq-x64-'
        $script:coreWorkflowContent | Should -Match 'windows-host-prereq-x86'
        $script:coreWorkflowContent | Should -Match 'windows-host-prereq-x64'
        $script:coreWorkflowContent | Should -Match 'lv_icon_x86\.lvlibp'
        $script:coreWorkflowContent | Should -Match 'lv_icon_x64\.lvlibp'
        $script:coreWorkflowContent | Should -Match 'EnableCICDFeaturesForLabVIEW=TRUE'
        $script:coreWorkflowContent | Should -Match 'LabVIEWCLI -OperationName'
        $script:coreWorkflowContent | Should -Match "driver = 'labviewcli-smoke'"
        $script:coreWorkflowContent | Should -Not -Match 'command -v vipm'
        $script:coreWorkflowContent | Should -Match 'windows_prereq_artifacts'
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
