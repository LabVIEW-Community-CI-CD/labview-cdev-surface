#Requires -Version 7.0
#Requires -Modules Pester

$ErrorActionPreference = 'Stop'

Describe 'Windows LabVIEW image gate workflow contract' {
    BeforeAll {
        $script:repoRoot = (Resolve-Path -Path (Join-Path $PSScriptRoot '..')).Path
        $script:wrapperWorkflowPath = Join-Path $script:repoRoot '.github/workflows/windows-labview-image-gate.yml'
        $script:coreWorkflowPath = Join-Path $script:repoRoot '.github/workflows/_windows-labview-image-gate-core.yml'
        if (-not (Test-Path -LiteralPath $script:wrapperWorkflowPath -PathType Leaf)) {
            throw "Windows image gate wrapper workflow missing: $script:wrapperWorkflowPath"
        }
        if (-not (Test-Path -LiteralPath $script:coreWorkflowPath -PathType Leaf)) {
            throw "Windows image gate core workflow missing: $script:coreWorkflowPath"
        }
        $script:wrapperWorkflowContent = Get-Content -LiteralPath $script:wrapperWorkflowPath -Raw
        $script:coreWorkflowContent = Get-Content -LiteralPath $script:coreWorkflowPath -Raw
    }

    It 'keeps dispatch-only wrapper and forwards to reusable core' {
        $script:wrapperWorkflowContent | Should -Match 'workflow_dispatch:'
        $script:wrapperWorkflowContent | Should -Not -Match '(?m)^\s*push:'
        $script:wrapperWorkflowContent | Should -Not -Match '(?m)^\s*pull_request:'
        $script:wrapperWorkflowContent | Should -Match 'uses:\s*\./\.github/workflows/_windows-labview-image-gate-core\.yml'
    }

    It 'targets windows containers with installer-post-action report checks in core workflow' {
        $script:coreWorkflowContent | Should -Match 'workflow_call:'
        $script:coreWorkflowContent | Should -Match 'runs-on:\s*\[self-hosted,\s*windows,\s*self-hosted-windows-lv,\s*windows-containers,\s*user-session,\s*cdev-surface-windows-gate\]'
        $script:coreWorkflowContent | Should -Match 'shell:\s*powershell'
        $script:coreWorkflowContent | Should -Not -Match 'shell:\s*pwsh'
        $script:coreWorkflowContent | Should -Not -Match '&\s*pwsh\s+-NoProfile\s+-File'
        $script:coreWorkflowContent | Should -Match 'nationalinstruments/labview:2026q1-windows'
        $script:coreWorkflowContent | Should -Match 'LABVIEW_WINDOWS_IMAGE'
        $script:coreWorkflowContent | Should -Match 'LABVIEW_WINDOWS_DOCKER_ISOLATION'
        $script:coreWorkflowContent | Should -Match "docker version --format '\{\{\.Server\.Os\}\}'"
        $script:coreWorkflowContent | Should -Match 'docker manifest inspect --verbose'
        $script:coreWorkflowContent | Should -Match 'Windows container compatibility mismatch'
        $script:coreWorkflowContent | Should -Match 'Falling back to Hyper-V isolation'
        $script:coreWorkflowContent | Should -Match '--isolation=\$dockerIsolation'
        $script:coreWorkflowContent | Should -Match 'automatic engine switching is disabled for non-interactive CI'
        $script:coreWorkflowContent | Should -Match "\$requiredCommands = @\('powershell', 'git', 'gh'\)"
        $script:coreWorkflowContent | Should -Match 'Container runtime missing required commands after host-tool mount'
        $script:coreWorkflowContent | Should -Match "VIPM_COMMUNITY_EDITION = 'true'"
        $script:coreWorkflowContent | Should -Match '--env "VIPM_COMMUNITY_EDITION=true"'
        $script:coreWorkflowContent | Should -Match 'LVIE_OFFLINE_GIT_MODE'
        $script:coreWorkflowContent | Should -Match '--env "LVIE_OFFLINE_GIT_MODE=true"'
        $script:coreWorkflowContent | Should -Match '-RequiredLabviewYear \$requiredLabviewYear'
        $script:coreWorkflowContent | Should -Match 'LVIE_LABVIEW_X86_NIPKG_INSTALL_CMD'
        $script:coreWorkflowContent | Should -Match 'LVIE_GATE_REQUIRED_LABVIEW_YEAR'
        $script:coreWorkflowContent | Should -Match 'LVIE_GATE_SINGLE_PPL_BITNESS'
        $script:coreWorkflowContent | Should -Match '--env "LVIE_GATE_REQUIRED_LABVIEW_YEAR=\$gateRequiredLabviewYear"'
        $script:coreWorkflowContent | Should -Match '--env "LVIE_GATE_SINGLE_PPL_BITNESS=\$singlePplBitness"'
        $script:coreWorkflowContent | Should -Match '--env "LVIE_LABVIEW_X86_NIPKG_INSTALL_CMD=\$labviewX86NipkgInstallCmd"'
        $script:coreWorkflowContent | Should -Match 'feed-add https://download\.ni\.com/support/nipkg/products/ni-l/ni-labview-2026-x86/26\.1/released --name=ni-labview-2026-core-x86-en-2026-q1-released'
        $script:coreWorkflowContent | Should -Match 'feed-add https://download\.ni\.com/support/nipkg/products/ni-l/ni-labview-2020-x86/20\.0/released --name=ni-labview-2020-core-x86-en-2020-released'
        $script:coreWorkflowContent | Should -Not -Match 'feed-add\s+ni-labview-[^\s]+\s+https://'
        $script:coreWorkflowContent | Should -Match "\$hostDevRoot = 'C:\\dev'"
        $script:coreWorkflowContent | Should -Match "\$hostLabview2020x64Root = 'C:\\Program Files\\National Instruments\\LabVIEW 2020'"
        $script:coreWorkflowContent | Should -Match "\$hostLabview2020x86Root = 'C:\\Program Files \(x86\)\\National Instruments\\LabVIEW 2020'"
        $script:coreWorkflowContent | Should -Not -Match 'hostPwshRoot'
        $script:coreWorkflowContent | Should -Match '--mount "type=bind,source=\$hostDevRoot,target=C:\\dev"'
        $script:coreWorkflowContent | Should -Match '--mount "type=bind,source=\$hostLabview2020x64Root,target=C:\\Program Files\\National Instruments\\LabVIEW 2020,readonly"'
        $script:coreWorkflowContent | Should -Match '--mount "type=bind,source=\$hostLabview2020x86Root,target=C:\\Program Files \(x86\)\\National Instruments\\LabVIEW 2020,readonly"'
        $script:coreWorkflowContent | Should -Match '--mount "type=bind,source=\$hostGitRoot,target=C:\\host-tools\\Git,readonly"'
        $script:coreWorkflowContent | Should -Match '--mount "type=bind,source=\$hostGhRoot,target=C:\\host-tools\\GitHubCLI,readonly"'
        $script:coreWorkflowContent | Should -Match '--mount "type=bind,source=\$hostGCliRoot,target=C:\\host-tools\\G-CLI,readonly"'
        $script:coreWorkflowContent | Should -Match 'Install-WorkspaceFromManifest\.ps1'
        $script:coreWorkflowContent | Should -Match '-Deterministic 1'
        $script:coreWorkflowContent | Should -Not -Match '-Deterministic \$true'
        $script:coreWorkflowContent | Should -Not -Match '-Deterministic:\$true'
        $script:coreWorkflowContent | Should -Match 'workspace-install-latest\.json'
        $script:coreWorkflowContent | Should -Match "ppl_capability_checks\.'32'\.status"
        $script:coreWorkflowContent | Should -Match "ppl_capability_checks\.'64'\.status"
        $script:coreWorkflowContent | Should -Match 'selected_ppl_bitness'
        $script:coreWorkflowContent | Should -Match 'selected_ppl_status'
        $script:coreWorkflowContent | Should -Match 'vip_package_build_check\.status'
        $script:coreWorkflowContent | Should -Match 'gate_status'
        $script:coreWorkflowContent | Should -Match 'gate_report_artifact_name'
        $script:coreWorkflowContent | Should -Match 'gate_report_path'
    }

    It 'publishes gate artifacts for troubleshooting from reusable core' {
        $script:coreWorkflowContent | Should -Match 'upload-artifact'
        $script:coreWorkflowContent | Should -Match 'if-no-files-found:'
    }
}
