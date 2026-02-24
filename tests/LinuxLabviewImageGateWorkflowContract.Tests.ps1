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

    It 'defines resolve, windows prerequisites, linux parity, linux vip, and summary lanes' {
        $script:coreWorkflowContent | Should -Match '(?m)^\s*resolve-parity-context:\s*$'
        $script:coreWorkflowContent | Should -Match '(?m)^\s*windows-host-ppl-32:\s*$'
        $script:coreWorkflowContent | Should -Match '(?m)^\s*windows-host-ppl-64:\s*$'
        $script:coreWorkflowContent | Should -Match '(?m)^\s*linux-parity-projectspec-via-container:\s*$'
        $script:coreWorkflowContent | Should -Match '(?m)^\s*linux-parity-vip:\s*$'
        $script:coreWorkflowContent | Should -Match '(?m)^\s*gate-summary:\s*$'
        $script:coreWorkflowContent | Should -Match 'needs:\s*\[resolve-parity-context\]'
        $script:coreWorkflowContent | Should -Match 'needs:\s*\[resolve-parity-context,\s*windows-host-ppl-32,\s*windows-host-ppl-64,\s*linux-parity-projectspec-via-container\]'
    }

    It 'enforces isolated windows prerequisite workspaces with deterministic cleanup' {
        $script:coreWorkflowContent | Should -Match 'Resolve-IsolatedBuildWorkspace\.ps1'
        $script:coreWorkflowContent | Should -Match 'Prepare-IsolatedRepoAtPinnedSha\.ps1'
        $script:coreWorkflowContent | Should -Match 'Cleanup-IsolatedBuildWorkspace\.ps1'
        $script:coreWorkflowContent | Should -Match 'LVIE_ISOLATED_JOB_ROOT_LINUX_PPL32'
        $script:coreWorkflowContent | Should -Match 'LVIE_ISOLATED_JOB_ROOT_LINUX_PPL64'
        $script:coreWorkflowContent | Should -Match 'isolated-workspace-resolution\.json'
        $script:coreWorkflowContent | Should -Match 'repo-provisioning\.labview-icon-editor\.json'
        $script:coreWorkflowContent | Should -Match 'if:\s*always\(\)'
    }

    It 'derives Linux image from lvcontainer with derive-then-lock policy and lane override support' {
        $script:coreWorkflowContent | Should -Match '\.lvcontainer'
        $script:coreWorkflowContent | Should -Match 'allowed_linux_tags'
        $script:coreWorkflowContent | Should -Match 'linux_image_locks'
        $script:coreWorkflowContent | Should -Match 'release_lane_linux_override'
        $script:coreWorkflowContent | Should -Match "lock_policy must be 'derive-tag-then-pin-digest'"
        $script:coreWorkflowContent | Should -Match 'LVIE_RELEASE_BUILD_LANE'
        $script:coreWorkflowContent | Should -Match 'nationalinstruments/labview:'
        $script:coreWorkflowContent | Should -Match '@sha256:'
    }

    It 'enforces Linux VIP parity contract and prerequisite guards' {
        $script:coreWorkflowContent | Should -Match 'linux_vip_build\.driver'
        $script:coreWorkflowContent | Should -Match 'linux_vip_build\.required_ppl_bitness'
        $script:coreWorkflowContent | Should -Match 'vipm_api_unavailable'
        $script:coreWorkflowContent | Should -Match 'missing_required_ppl_prerequisite'
        $script:coreWorkflowContent | Should -Match 'vipm_api_command_failed'
        $script:coreWorkflowContent | Should -Match 'artifact_role'
        $script:coreWorkflowContent | Should -Match 'signal-only'
        $script:coreWorkflowContent | Should -Not -Match '\bg-cli\b'
    }

    It 'adds anti-stall signatures and parity observability bundles' {
        $script:coreWorkflowContent | Should -Match 'container_script_non_exit'
        $script:coreWorkflowContent | Should -Match 'phase-checkpoints\.log'
        $script:coreWorkflowContent | Should -Match 'linux-parity-projectspec-classification\.json'
        $script:coreWorkflowContent | Should -Match 'linux-parity-vip-report\.json'
        $script:coreWorkflowContent | Should -Match 'Linux Gate Summary'
    }
}
