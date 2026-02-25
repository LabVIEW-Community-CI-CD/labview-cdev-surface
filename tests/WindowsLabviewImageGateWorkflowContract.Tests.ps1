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

    It 'defines split hard-gate topology with resolve, host, parity, and summary lanes' {
        $script:coreWorkflowContent | Should -Match 'workflow_call:'
        $script:coreWorkflowContent | Should -Match '(?m)^\s*resolve-parity-context:\s*$'
        $script:coreWorkflowContent | Should -Match '(?m)^\s*windows-host-release-gate:\s*$'
        $script:coreWorkflowContent | Should -Match '(?m)^\s*windows-host-linux-prereq-x86:\s*$'
        $script:coreWorkflowContent | Should -Match '(?m)^\s*windows-host-linux-prereq-x64:\s*$'
        $script:coreWorkflowContent | Should -Match '(?m)^\s*windows-container-parity-gate:\s*$'
        $script:coreWorkflowContent | Should -Match '(?m)^\s*gate-summary:\s*$'
        $script:coreWorkflowContent | Should -Match 'needs:\s*\[resolve-parity-context\]'
        $script:coreWorkflowContent | Should -Match 'windows-host-linux-prereq-x86'
        $script:coreWorkflowContent | Should -Match 'windows-host-linux-prereq-x64'
        $script:coreWorkflowContent | Should -Match 'gate_status'
        $script:coreWorkflowContent | Should -Match 'gate_report_artifact_name'
        $script:coreWorkflowContent | Should -Match 'gate_report_path'
        $script:coreWorkflowContent | Should -Match 'linux_prereq_x86_artifact_name'
        $script:coreWorkflowContent | Should -Match 'linux_prereq_x64_artifact_name'
        $script:coreWorkflowContent | Should -Match 'linux_prereq_native_labview_version'
    }

    It 'uses expected runner labels for host release and container parity lanes' {
        $script:coreWorkflowContent | Should -Match '(?s)windows-host-release-gate:\s*.*?runs-on:\s*\[self-hosted,\s*windows,\s*self-hosted-windows-lv,\s*user-session,\s*cdev-surface-windows-gate\]'
        $script:coreWorkflowContent | Should -Not -Match '(?s)windows-host-release-gate:\s*.*?runs-on:\s*\[self-hosted,\s*windows,\s*self-hosted-windows-lv\]'
        $script:coreWorkflowContent | Should -Match 'Windows Host Linux Prereq \(native 2025q3 x86\)'
        $script:coreWorkflowContent | Should -Match 'Windows Host Linux Prereq \(native 2025q3 x64\)'
        $script:coreWorkflowContent | Should -Match '(?s)windows-host-linux-prereq-x86:\s*.*?runs-on:\s*\[self-hosted,\s*windows,\s*self-hosted-windows-lv,\s*user-session,\s*cdev-surface-windows-gate\]'
        $script:coreWorkflowContent | Should -Match '(?s)windows-host-linux-prereq-x64:\s*.*?runs-on:\s*\[self-hosted,\s*windows,\s*self-hosted-windows-lv,\s*user-session,\s*cdev-surface-windows-gate\]'
        $script:coreWorkflowContent | Should -Match 'runs-on:\s*\[self-hosted,\s*windows,\s*self-hosted-windows-lv,\s*windows-containers,\s*user-session,\s*cdev-surface-windows-gate\]'
    }

    It 'resolves parity image from pinned icon-editor .lvcontainer and fails on override mismatch' {
        $script:coreWorkflowContent | Should -Match '\.lvcontainer'
        $script:coreWorkflowContent | Should -Match 'icon_editor_pinned_sha'
        $script:coreWorkflowContent | Should -Match 'icon_editor_source_url'
        $script:coreWorkflowContent | Should -Match '\$\{lvcontainer_raw%-linux\}-windows'
        $script:coreWorkflowContent | Should -Match 'allowed_windows_tags'
        $script:coreWorkflowContent | Should -Match 'LABVIEW_WINDOWS_IMAGE override'
        $script:coreWorkflowContent | Should -Match 'nationalinstruments/labview:\$\{lvcontainer_windows_tag\}'
        $script:coreWorkflowContent | Should -Match 'Windows Container Parity \(\$\{\{\s*needs\.resolve-parity-context\.outputs\.lvcontainer_raw\s*\}\}\s*\|\s*b\$\{\{\s*needs\.resolve-parity-context\.outputs\.selected_ppl_bitness\s*\}\}\s*\|'
    }

    It 'keeps windows powershell-first surface and constrains pwsh use to host bootstrap scripts' {
        $script:coreWorkflowContent | Should -Match 'shell:\s*powershell'
        $script:coreWorkflowContent | Should -Not -Match 'shell:\s*pwsh'
        $script:coreWorkflowContent | Should -Not -Match '&\s*pwsh\s+-NoProfile\s+-File'
        $script:coreWorkflowContent | Should -Match "Get-Command 'pwsh' -ErrorAction SilentlyContinue"
        $script:coreWorkflowContent | Should -Match 'PowerShell 7 \(pwsh\) is required on the host runner for payload bootstrap scripts'
        $script:coreWorkflowContent | Should -Match '& \$pwshExe -NoProfile -ExecutionPolicy RemoteSigned -File "\$env:GITHUB_WORKSPACE/scripts/Build-RunnerCliBundleFromManifest\.ps1"'
        $script:coreWorkflowContent | Should -Match '& \$pwshExe -NoProfile -ExecutionPolicy RemoteSigned -File "\$env:GITHUB_WORKSPACE/scripts/Build-WorkspaceBootstrapInstaller\.ps1"'
        $script:coreWorkflowContent | Should -Match 'LVIE_INSTALLER_EXECUTION_PROFILE = ''host-release'''
        $script:coreWorkflowContent | Should -Match 'LVIE_INSTALLER_EXECUTION_PROFILE = ''container-parity'''
        $script:coreWorkflowContent | Should -Match 'LVIE_WORKTREE_ROOT = ''C:\\dev'''
        $script:coreWorkflowContent | Should -Match 'LVIE_RUNNERCLI_EXECUTION_LABVIEW_YEAR = \[string\]\$env:RELEASE_REQUIRED_YEAR'
        $script:coreWorkflowContent | Should -Match 'RELEASE_REQUIRED_YEAR:\s*\$\{\{\s*needs\.resolve-parity-context\.outputs\.release_required_year\s*\}\}'
    }

    It 'enforces release-vs-parity post-action roles and vi analyzer parity execution' {
        $script:coreWorkflowContent | Should -Match 'vip_package_build_check\.status'
        $script:coreWorkflowContent | Should -Match 'Host release VIP gate did not pass'
        $script:coreWorkflowContent | Should -Match 'must skip VIP build'
        $script:coreWorkflowContent | Should -Match 'LABVIEW_2025Q3_VI_ANALYZER_NIPKG_INSTALL_CMD'
        $script:coreWorkflowContent | Should -Match 'ni-labview-vi-analyzer-toolkit-lic'
        $script:coreWorkflowContent | Should -Match 'call \$viAnalyzerInstallCommand'
        $script:coreWorkflowContent | Should -Match 'resource\\Framework\\Providers\\VI_Analyzer'
        $script:coreWorkflowContent | Should -Match 'vi-analyzer-install\.log'
        $script:coreWorkflowContent | Should -Match 'run-vi-analyzer-windows\.ps1'
        $script:coreWorkflowContent | Should -Match 'vi-analyzer-summary\.parity\.windows\.gate\.json'
        $script:coreWorkflowContent | Should -Match 'PARITY_BUILD_SPEC_MARKER'
        $script:coreWorkflowContent | Should -Match 'git config --global --add safe\.directory'
        $script:coreWorkflowContent | Should -Match 'Failed to configure git safe\.directory entry'
        $script:coreWorkflowContent | Should -Match 'git -C \$repoPath fetch --no-tags --quiet origin \$repoPinnedSha'
    }

    It 'keeps valid feed-add command ordering and container fallback diagnostics contract' {
        $script:coreWorkflowContent | Should -Match 'feed-add https://download\.ni\.com/support/nipkg/products/ni-l/ni-labview-2026-x86/26\.1/released --name=ni-labview-2026-core-x86-en-2026-q1-released'
        $script:coreWorkflowContent | Should -Match 'feed-add https://download\.ni\.com/support/nipkg/products/ni-l/ni-labview-2020-x86/20\.0/released --name=ni-labview-2020-core-x86-en-2020-released'
        $script:coreWorkflowContent | Should -Not -Match 'feed-add\s+ni-labview-[^\s]+\s+https://'
        $script:coreWorkflowContent | Should -Match 'LVIE_LABVIEW_X86_NIPKG_INSTALL_CMD_B64'
        $script:coreWorkflowContent | Should -Match 'FromBase64String'
        $script:coreWorkflowContent | Should -Not -Match 'LVIE_LABVIEW_X86_NIPKG_INSTALL_CMD=\$labviewX86NipkgInstallCmd'
        $script:coreWorkflowContent | Should -Match 'containerCmdEncoded'
        $script:coreWorkflowContent | Should -Match '''powershell'', ''-NoProfile'', ''-EncodedCommand'', \$containerCmdEncoded'
        $script:coreWorkflowContent | Should -Not -Match '''powershell'', ''-NoProfile'', ''-Command'', \$containerCmd'
        $script:coreWorkflowContent | Should -Match '\$requiredCommands = @\(''powershell'', ''pwsh'', ''git'', ''gh'', ''g-cli''\)'
        $script:coreWorkflowContent | Should -Match 'Join-Path \$artifactRoot ''host-mounts'''
        $script:coreWorkflowContent | Should -Match '--env'', "LVIE_RUNNERCLI_EXECUTION_LABVIEW_YEAR=\$parityExecutionYear"'
        $script:coreWorkflowContent | Should -Match '--env'', "PARITY_REQUIRED_YEAR=\$parityExecutionYear"'
        $script:coreWorkflowContent | Should -Match 'LABVIEW_WINDOWS_DOCKER_DNS'
        $script:coreWorkflowContent | Should -Match '''--dns'', \$dnsServer'
        $script:coreWorkflowContent | Should -Match 'type=bind,source=\$hostPwshMountSource,target=C:\\host-tools\\PowerShell7,readonly'
        $script:coreWorkflowContent | Should -Match 'windows-image-gate/parity/host-mounts/\*\*'
        $script:coreWorkflowContent | Should -Match 'type=bind,source=\$hostGitMountSource,target=C:\\host-tools\\Git,readonly'
        $script:coreWorkflowContent | Should -Match 'type=bind,source=\$hostGhMountSource,target=C:\\host-tools\\GitHubCLI,readonly'
        $script:coreWorkflowContent | Should -Match 'type=bind,source=\$hostGCliMountSource,target=C:\\host-tools\\G-CLI,readonly'
        $script:coreWorkflowContent | Should -Not -Match 'target=C:\\Program Files\\National Instruments\\LabVIEW 2020,readonly'
        $script:coreWorkflowContent | Should -Match 'container_boot_failure'
        $script:coreWorkflowContent | Should -Match 'container-fallback-diagnostics\.json'
        $script:coreWorkflowContent | Should -Match 'docker_dns_servers = @\(\$dockerDnsServers\)'
        $script:coreWorkflowContent | Should -Match 'docker manifest inspect --verbose'
        $script:coreWorkflowContent | Should -Match 'automatic engine switching is disabled for non-interactive CI'
    }

    It 'publishes split gate artifacts for troubleshooting' {
        $script:coreWorkflowContent | Should -Match 'windows-labview-image-gate-release-\$\{\{\s*github\.run_id\s*\}\}'
        $script:coreWorkflowContent | Should -Match 'windows-host-linux-prereq-x86-\$\{\{\s*github\.run_id\s*\}\}'
        $script:coreWorkflowContent | Should -Match 'windows-host-linux-prereq-x64-\$\{\{\s*github\.run_id\s*\}\}'
        $script:coreWorkflowContent | Should -Match 'windows-labview-image-gate-parity-\$\{\{\s*github\.run_id\s*\}\}'
        $script:coreWorkflowContent | Should -Match 'upload-artifact'
        $script:coreWorkflowContent | Should -Match 'if-no-files-found:\s*error'
    }
}
