#Requires -Version 7.0
#Requires -Modules Pester

$ErrorActionPreference = 'Stop'

Describe 'Workspace surface contract' {
    BeforeAll {
        $script:repoRoot = (Resolve-Path -Path (Join-Path $PSScriptRoot '..')).Path
        $script:manifestPath = Join-Path $script:repoRoot 'workspace-governance.json'
        $script:agentsPath = Join-Path $script:repoRoot 'AGENTS.md'
        $script:readmePath = Join-Path $script:repoRoot 'README.md'
        $script:assertScriptPath = Join-Path $script:repoRoot 'scripts/Assert-WorkspaceGovernance.ps1'
        $script:policyScriptPath = Join-Path $script:repoRoot 'scripts/Test-PolicyContracts.ps1'
        $script:driftScriptPath = Join-Path $script:repoRoot 'scripts/Test-WorkspaceManifestBranchDrift.ps1'
        $script:pinRefreshScriptPath = Join-Path $script:repoRoot 'scripts/Update-WorkspaceManifestPins.ps1'
        $script:installScriptPath = Join-Path $script:repoRoot 'scripts/Install-WorkspaceFromManifest.ps1'
        $script:buildInstallerScriptPath = Join-Path $script:repoRoot 'scripts/Build-WorkspaceBootstrapInstaller.ps1'
        $script:bundleRunnerCliScriptPath = Join-Path $script:repoRoot 'scripts/Build-RunnerCliBundleFromManifest.ps1'
        $script:resolveIsolatedWorkspaceScriptPath = Join-Path $script:repoRoot 'scripts/Resolve-IsolatedBuildWorkspace.ps1'
        $script:prepareIsolatedRepoScriptPath = Join-Path $script:repoRoot 'scripts/Prepare-IsolatedRepoAtPinnedSha.ps1'
        $script:convertManifestWorkspaceScriptPath = Join-Path $script:repoRoot 'scripts/Convert-ManifestToWorkspace.ps1'
        $script:cleanupIsolatedWorkspaceScriptPath = Join-Path $script:repoRoot 'scripts/Cleanup-IsolatedBuildWorkspace.ps1'
        $script:harnessRunnerBaselineScriptPath = Join-Path $script:repoRoot 'scripts/Assert-InstallerHarnessRunnerBaseline.ps1'
        $script:harnessMachinePreflightScriptPath = Join-Path $script:repoRoot 'scripts/Assert-InstallerHarnessMachinePreflight.ps1'
        $script:runnerCliDeterminismScriptPath = Join-Path $script:repoRoot 'scripts/Test-RunnerCliBundleDeterminism.ps1'
        $script:installerDeterminismScriptPath = Join-Path $script:repoRoot 'scripts/Test-WorkspaceInstallerDeterminism.ps1'
        $script:writeProvenanceScriptPath = Join-Path $script:repoRoot 'scripts/Write-ReleaseProvenance.ps1'
        $script:testProvenanceScriptPath = Join-Path $script:repoRoot 'scripts/Test-ProvenanceContracts.ps1'
        $script:dockerLinuxIterationScriptPath = Join-Path $script:repoRoot 'scripts/Invoke-DockerDesktopLinuxIteration.ps1'
        $script:nsisInstallerPath = Join-Path $script:repoRoot 'nsis/workspace-bootstrap-installer.nsi'
        $script:ciWorkflowPath = Join-Path $script:repoRoot '.github/workflows/ci.yml'
        $script:driftWorkflowPath = Join-Path $script:repoRoot '.github/workflows/workspace-sha-drift-signal.yml'
        $script:shaRefreshWorkflowPath = Join-Path $script:repoRoot '.github/workflows/workspace-sha-refresh-pr.yml'
        $script:releaseWorkflowPath = Join-Path $script:repoRoot '.github/workflows/release-workspace-installer.yml'
        $script:integrationGateWorkflowPath = Join-Path $script:repoRoot '.github/workflows/integration-gate.yml'
        $script:installerHarnessWorkflowPath = Join-Path $script:repoRoot '.github/workflows/installer-harness-self-hosted.yml'
        $script:releaseCoreWorkflowPath = Join-Path $script:repoRoot '.github/workflows/_release-workspace-installer-core.yml'
        $script:releaseWithGateWorkflowPath = Join-Path $script:repoRoot '.github/workflows/release-with-windows-gate.yml'
        $script:canaryWorkflowPath = Join-Path $script:repoRoot '.github/workflows/nightly-supplychain-canary.yml'
        $script:windowsImageGateWorkflowPath = Join-Path $script:repoRoot '.github/workflows/windows-labview-image-gate.yml'
        $script:windowsImageGateCoreWorkflowPath = Join-Path $script:repoRoot '.github/workflows/_windows-labview-image-gate-core.yml'
        $script:linuxImageGateWorkflowPath = Join-Path $script:repoRoot '.github/workflows/linux-labview-image-gate.yml'
        $script:linuxImageGateCoreWorkflowPath = Join-Path $script:repoRoot '.github/workflows/_linux-labview-image-gate-core.yml'
        $script:globalJsonPath = Join-Path $script:repoRoot 'global.json'
        $script:payloadAgentsPath = Join-Path $script:repoRoot 'workspace-governance-payload/workspace-governance/AGENTS.md'
        $script:payloadManifestPath = Join-Path $script:repoRoot 'workspace-governance-payload/workspace-governance/workspace-governance.json'
        $script:payloadAssertScriptPath = Join-Path $script:repoRoot 'workspace-governance-payload/workspace-governance/scripts/Assert-WorkspaceGovernance.ps1'
        $script:payloadPolicyScriptPath = Join-Path $script:repoRoot 'workspace-governance-payload/workspace-governance/scripts/Test-PolicyContracts.ps1'
        $script:payloadCliRoot = Join-Path $script:repoRoot 'workspace-governance-payload/tools/cdev-cli'
        $script:payloadCliWinAssetPath = Join-Path $script:payloadCliRoot 'cdev-cli-win-x64.zip'
        $script:payloadCliWinShaPath = Join-Path $script:payloadCliRoot 'cdev-cli-win-x64.zip.sha256'
        $script:payloadCliLinuxAssetPath = Join-Path $script:payloadCliRoot 'cdev-cli-linux-x64.tar.gz'
        $script:payloadCliLinuxShaPath = Join-Path $script:payloadCliRoot 'cdev-cli-linux-x64.tar.gz.sha256'
        $script:payloadCliContractPath = Join-Path $script:payloadCliRoot 'cli-contract.json'

        $requiredPaths = @(
            $script:manifestPath,
            $script:agentsPath,
            $script:readmePath,
            $script:assertScriptPath,
            $script:policyScriptPath,
            $script:driftScriptPath,
            $script:pinRefreshScriptPath,
            $script:installScriptPath,
            $script:buildInstallerScriptPath,
            $script:bundleRunnerCliScriptPath,
            $script:resolveIsolatedWorkspaceScriptPath,
            $script:prepareIsolatedRepoScriptPath,
            $script:convertManifestWorkspaceScriptPath,
            $script:cleanupIsolatedWorkspaceScriptPath,
            $script:harnessRunnerBaselineScriptPath,
            $script:harnessMachinePreflightScriptPath,
            $script:runnerCliDeterminismScriptPath,
            $script:installerDeterminismScriptPath,
            $script:writeProvenanceScriptPath,
            $script:testProvenanceScriptPath,
            $script:dockerLinuxIterationScriptPath,
            $script:nsisInstallerPath,
            $script:ciWorkflowPath,
            $script:driftWorkflowPath,
            $script:shaRefreshWorkflowPath,
            $script:releaseWorkflowPath,
            $script:integrationGateWorkflowPath,
            $script:installerHarnessWorkflowPath,
            $script:releaseCoreWorkflowPath,
            $script:releaseWithGateWorkflowPath,
            $script:canaryWorkflowPath,
            $script:windowsImageGateWorkflowPath,
            $script:windowsImageGateCoreWorkflowPath,
            $script:linuxImageGateWorkflowPath,
            $script:linuxImageGateCoreWorkflowPath,
            $script:globalJsonPath,
            $script:payloadAgentsPath,
            $script:payloadManifestPath,
            $script:payloadAssertScriptPath,
            $script:payloadPolicyScriptPath,
            $script:payloadCliWinAssetPath,
            $script:payloadCliWinShaPath,
            $script:payloadCliLinuxAssetPath,
            $script:payloadCliLinuxShaPath,
            $script:payloadCliContractPath
        )

        foreach ($path in $requiredPaths) {
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
                throw "Required workspace-surface contract file missing: $path"
            }
        }

        $script:manifest = Get-Content -LiteralPath $script:manifestPath -Raw | ConvertFrom-Json -ErrorAction Stop
        $script:payloadManifest = Get-Content -LiteralPath $script:payloadManifestPath -Raw | ConvertFrom-Json -ErrorAction Stop
        $script:agentsContent = Get-Content -LiteralPath $script:agentsPath -Raw
        $script:readmeContent = Get-Content -LiteralPath $script:readmePath -Raw
        $script:nsisInstallerContent = Get-Content -LiteralPath $script:nsisInstallerPath -Raw
        $script:buildInstallerScriptContent = Get-Content -LiteralPath $script:buildInstallerScriptPath -Raw
        $script:bundleRunnerCliScriptContent = Get-Content -LiteralPath $script:bundleRunnerCliScriptPath -Raw
        $script:ciWorkflowContent = Get-Content -LiteralPath $script:ciWorkflowPath -Raw
        $script:releaseWorkflowContent = Get-Content -LiteralPath $script:releaseWorkflowPath -Raw
        $script:releaseCoreWorkflowContent = Get-Content -LiteralPath $script:releaseCoreWorkflowPath -Raw
        $script:releaseWithGateWorkflowContent = Get-Content -LiteralPath $script:releaseWithGateWorkflowPath -Raw
    }

    It 'tracks a deterministic managed repo set with pinned SHA lock' {
        @($script:manifest.managed_repos).Count | Should -BeGreaterOrEqual 9
        $script:manifest.PSObject.Properties.Name | Should -Contain 'installer_contract'
        $script:manifest.installer_contract.runner_cli_bundle.executable | Should -Be 'runner-cli.exe'
        $script:manifest.installer_contract.labview_gate.required_year | Should -Be '2020'
        ((@($script:manifest.installer_contract.labview_gate.required_ppl_bitnesses) | ForEach-Object { [string]$_ }) -join ',') | Should -Be '32,64'
        $script:manifest.installer_contract.labview_gate.required_vip_bitness | Should -Be '64'
        $script:manifest.installer_contract.release_build_contract.labview_version_source | Should -Be '.lvversion'
        $script:manifest.installer_contract.release_build_contract.required_year | Should -Be '2020'
        ((@($script:manifest.installer_contract.release_build_contract.required_ppl_bitnesses) | ForEach-Object { [string]$_ }) -join ',') | Should -Be '32,64'
        $script:manifest.installer_contract.release_build_contract.required_vip_bitness | Should -Be '64'
        $script:manifest.installer_contract.release_build_contract.required_execution_profile | Should -Be 'host-release'
        $script:manifest.installer_contract.release_build_contract.artifact_root | Should -Be 'artifacts\release'
        $script:manifest.installer_contract.build_workspace_policy.mode | Should -Be 'always-isolated'
        $script:manifest.installer_contract.build_workspace_policy.strategy_primary | Should -Be 'git-worktree'
        $script:manifest.installer_contract.build_workspace_policy.strategy_fallback | Should -Be 'detached-clone'
        ((@($script:manifest.installer_contract.build_workspace_policy.windows_root_candidates) | ForEach-Object { [string]$_ }) -join ',') | Should -Be 'D:\dev,C:\dev'
        $script:manifest.installer_contract.build_workspace_policy.windows_root_selection | Should -Be 'prefer-d-fallback-c'
        $script:manifest.installer_contract.build_workspace_policy.cleanup_policy | Should -Be 'always'
        (@($script:manifest.installer_contract.build_workspace_policy.applies_to) -contains 'windows-host-release-gate') | Should -BeTrue
        (@($script:manifest.installer_contract.build_workspace_policy.applies_to) -contains 'windows-container-parity-gate') | Should -BeTrue
        (@($script:manifest.installer_contract.build_workspace_policy.applies_to) -contains 'linux-gate-windows-prereqs') | Should -BeTrue
        (@($script:manifest.installer_contract.build_workspace_policy.applies_to) -contains 'local-exercise') | Should -BeTrue
        $script:manifest.installer_contract.build_workspace_policy.release_artifact_default_policy | Should -Be 'ci-only-selector'
        $script:manifest.installer_contract.container_parity_contract.lvcontainer_file | Should -Be '.lvcontainer'
        $script:manifest.installer_contract.container_parity_contract.windows_tag_strategy | Should -Be 'derive-from-lvcontainer'
        $script:manifest.installer_contract.container_parity_contract.required_execution_profile | Should -Be 'container-parity'
        $script:manifest.installer_contract.container_parity_contract.artifact_root | Should -Be 'artifacts\parity'
        $script:manifest.installer_contract.container_parity_contract.build_spec_kind | Should -Be 'ppl'
        $script:manifest.installer_contract.container_parity_contract.build_spec_placeholder | Should -Be 'srcdist'
        $script:manifest.installer_contract.container_parity_contract.promote_artifacts | Should -BeFalse
        (@($script:manifest.installer_contract.container_parity_contract.allowed_windows_tags) -contains '2026q1-windows') | Should -BeTrue
        (@($script:manifest.installer_contract.container_parity_contract.allowed_linux_tags) -contains '2025q3-linux') | Should -BeTrue
        (@($script:manifest.installer_contract.container_parity_contract.allowed_linux_tags) -contains '2026q1-linux') | Should -BeTrue
        $script:manifest.installer_contract.container_parity_contract.lock_policy | Should -Be 'derive-tag-then-pin-digest'
        $script:manifest.installer_contract.container_parity_contract.linux_image_locks.'2025q3-linux' | Should -Be 'sha256:9938561c6460841674f9b1871d8562242f51fe9fb72a2c39c66608491edf429c'
        $script:manifest.installer_contract.container_parity_contract.linux_image_locks.'2026q1-linux' | Should -Be 'sha256:597ba99260c0511475e27c04f13dd06f2f57e8ce7d3ee6c1ca289020b1f8c426'
        $script:manifest.installer_contract.container_parity_contract.release_lane_linux_override.'multiarch-2025q3' | Should -Be 'nationalinstruments/labview:2025q3-linux@sha256:9938561c6460841674f9b1871d8562242f51fe9fb72a2c39c66608491edf429c'
        $script:manifest.installer_contract.container_parity_contract.required_check_rollout.mode | Should -Be 'stage_then_required'
        $script:manifest.installer_contract.container_parity_contract.required_check_rollout.promotion_condition | Should -Be 'single_green_run'
        $script:manifest.installer_contract.container_parity_contract.linux_vip_build.enabled | Should -BeTrue
        $script:manifest.installer_contract.container_parity_contract.linux_vip_build.driver | Should -Be 'vipm-api'
        ((@($script:manifest.installer_contract.container_parity_contract.linux_vip_build.required_ppl_bitness) | ForEach-Object { [string]$_ }) -join ',') | Should -Be '32,64'
        $script:manifest.installer_contract.container_parity_contract.linux_vip_build.artifact_role | Should -Be 'signal-only'
        $script:manifest.installer_contract.release_build_contracts.'legacy-2020'.required_year | Should -Be '2020'
        ((@($script:manifest.installer_contract.release_build_contracts.'legacy-2020'.required_ppl_bitnesses) | ForEach-Object { [string]$_ }) -join ',') | Should -Be '32,64'
        $script:manifest.installer_contract.release_build_contracts.'legacy-2020'.required_execution_profile | Should -Be 'host-release'
        $script:manifest.installer_contract.release_build_contracts.'legacy-2020'.artifact_root | Should -Be 'artifacts\release'
        $script:manifest.installer_contract.release_build_contracts.'multiarch-2025q3'.required_year | Should -Be '2025'
        ((@($script:manifest.installer_contract.release_build_contracts.'multiarch-2025q3'.required_ppl_bitnesses) | ForEach-Object { [string]$_ }) -join ',') | Should -Be '32,64'
        $script:manifest.installer_contract.release_build_contracts.'multiarch-2025q3'.required_execution_profile | Should -Be 'host-release'
        $script:manifest.installer_contract.release_build_contracts.'multiarch-2025q3'.artifact_root | Should -Be 'artifacts\release'
        $script:manifest.installer_contract.release_build_contracts.'multiarch-2025q3'.linux_parity_override_image | Should -Be 'nationalinstruments/labview:2025q3-linux@sha256:9938561c6460841674f9b1871d8562242f51fe9fb72a2c39c66608491edf429c'
        $script:manifest.installer_contract.ppl_capability_proof.command | Should -Be 'runner-cli ppl build'
        ((@($script:manifest.installer_contract.ppl_capability_proof.supported_bitnesses) | ForEach-Object { [string]$_ }) -join ',') | Should -Be '32,64'
        $script:manifest.installer_contract.vip_capability_proof.command | Should -Be 'runner-cli vip build'
        $script:manifest.installer_contract.vip_capability_proof.labview_version | Should -Be '2020'
        $script:manifest.installer_contract.vip_capability_proof.supported_bitness | Should -Be '64'
        $script:manifest.installer_contract.reproducibility.required | Should -BeTrue
        $script:manifest.installer_contract.reproducibility.strict_hash_match | Should -BeTrue
        $script:manifest.installer_contract.provenance.schema_version | Should -Be '1.0'
        $script:manifest.installer_contract.canary.docker_context | Should -Be 'desktop-linux'
        $script:manifest.installer_contract.cli_bundle.repo | Should -Be 'LabVIEW-Community-CI-CD/labview-cdev-cli'
        $script:manifest.installer_contract.cli_bundle.asset_win | Should -Be 'cdev-cli-win-x64.zip'
        $script:manifest.installer_contract.cli_bundle.asset_linux | Should -Be 'cdev-cli-linux-x64.tar.gz'
        ([string]$script:manifest.installer_contract.cli_bundle.asset_win_sha256) | Should -Match '^[0-9a-f]{64}$'
        ([string]$script:manifest.installer_contract.cli_bundle.asset_linux_sha256) | Should -Match '^[0-9a-f]{64}$'
        $script:manifest.installer_contract.cli_bundle.entrypoint_win | Should -Be 'tools\cdev-cli\win-x64\cdev-cli\scripts\Invoke-CdevCli.ps1'
        $script:manifest.installer_contract.cli_bundle.entrypoint_linux | Should -Be 'tools/cdev-cli/linux-x64/cdev-cli/scripts/Invoke-CdevCli.ps1'
        $script:manifest.installer_contract.harness.workflow_name | Should -Be 'installer-harness-self-hosted.yml'
        $script:manifest.installer_contract.harness.trigger_mode | Should -Be 'integration_branch_push_and_dispatch'
        (@($script:manifest.installer_contract.harness.runner_labels) -contains 'self-hosted') | Should -BeTrue
        (@($script:manifest.installer_contract.harness.runner_labels) -contains 'windows') | Should -BeTrue
        (@($script:manifest.installer_contract.harness.runner_labels) -contains 'self-hosted-windows-lv') | Should -BeTrue
        (@($script:manifest.installer_contract.harness.runner_labels) -contains 'installer-harness') | Should -BeTrue
        (@($script:manifest.installer_contract.harness.required_reports) -contains 'iteration-summary.json') | Should -BeTrue
        (@($script:manifest.installer_contract.harness.required_reports) -contains 'exercise-report.json') | Should -BeTrue
        (@($script:manifest.installer_contract.harness.required_reports) -contains 'C:\dev-smoke-lvie\artifacts\workspace-install-latest.json') | Should -BeTrue
        (@($script:manifest.installer_contract.harness.required_reports) -contains 'lvie-cdev-workspace-installer-bundle.zip') | Should -BeTrue
        (@($script:manifest.installer_contract.harness.required_reports) -contains 'harness-validation-report.json') | Should -BeTrue
        (@($script:manifest.installer_contract.harness.required_postactions) -contains 'ppl_capability_checks.32') | Should -BeTrue
        (@($script:manifest.installer_contract.harness.required_postactions) -contains 'ppl_capability_checks.64') | Should -BeTrue
        (@($script:manifest.installer_contract.harness.required_postactions) -contains 'vip_package_build_check') | Should -BeTrue
        foreach ($repo in @($script:manifest.managed_repos)) {
            $repo.PSObject.Properties.Name | Should -Contain 'required_gh_repo'
            $repo.PSObject.Properties.Name | Should -Contain 'default_branch'
            $repo.PSObject.Properties.Name | Should -Contain 'pinned_sha'
            ([string]$repo.pinned_sha) | Should -Match '^[0-9a-f]{40}$'
        }
    }

    It 'keeps bundled cdev CLI payload checksums aligned with manifest contract' {
        $winAssetHash = (Get-FileHash -LiteralPath $script:payloadCliWinAssetPath -Algorithm SHA256).Hash.ToLowerInvariant()
        $linuxAssetHash = (Get-FileHash -LiteralPath $script:payloadCliLinuxAssetPath -Algorithm SHA256).Hash.ToLowerInvariant()
        $manifestWinHash = ([string]$script:manifest.installer_contract.cli_bundle.asset_win_sha256).ToLowerInvariant()
        $manifestLinuxHash = ([string]$script:manifest.installer_contract.cli_bundle.asset_linux_sha256).ToLowerInvariant()

        $winAssetHash | Should -Be $manifestWinHash
        $linuxAssetHash | Should -Be $manifestLinuxHash

        ((Get-Content -LiteralPath $script:payloadCliWinShaPath -Raw).Trim()).StartsWith($manifestWinHash) | Should -BeTrue
        ((Get-Content -LiteralPath $script:payloadCliLinuxShaPath -Raw).Trim()).StartsWith($manifestLinuxHash) | Should -BeTrue
    }

    It 'contains codex skills fork and org entries in the manifest' {
        $repoSlugs = @($script:manifest.managed_repos | ForEach-Object { [string]$_.required_gh_repo })
        $repoSlugs | Should -Contain 'svelderrainruiz/labview-icon-editor-codex-skills'
        $repoSlugs | Should -Contain 'LabVIEW-Community-CI-CD/labview-icon-editor-codex-skills'
    }

    It 'pins NSIS launcher to Windows PowerShell executable paths' {
        $script:nsisInstallerContent | Should -Match 'WindowsPowerShell\\v1\.0\\powershell\.exe'
        $script:nsisInstallerContent | Should -Match 'powershell_resolution_error=windows_powershell_not_found'
        $script:nsisInstallerContent | Should -Not -Match 'StrCpy \$1 "powershell"'
    }

    It 'keeps gate bootstrap scripts compatible with Windows PowerShell' {
        $script:buildInstallerScriptContent | Should -Not -Match '^#Requires -Version 7\.0'
        $script:bundleRunnerCliScriptContent | Should -Not -Match '^#Requires -Version 7\.0'
        $script:buildInstallerScriptContent | Should -Match "Get-Command 'Get-FileHash'"
        $script:buildInstallerScriptContent | Should -Match '\[System\.Security\.Cryptography\.SHA256\]::Create\(\)'
        $script:bundleRunnerCliScriptContent | Should -Match "Get-Command 'Get-FileHash'"
        $script:bundleRunnerCliScriptContent | Should -Match '\[System\.Security\.Cryptography\.SHA256\]::Create\(\)'
    }

    It 'keeps canonical payload manifest aligned with repository manifest' {
        @($script:payloadManifest.managed_repos).Count | Should -Be @($script:manifest.managed_repos).Count
        ($script:payloadManifest | ConvertTo-Json -Depth 50) | Should -Be ($script:manifest | ConvertTo-Json -Depth 50)
    }

    It 'documents drift failure as the PR release signal' {
        $script:agentsContent | Should -Match 'Workspace SHA Refresh PR'
        $script:agentsContent | Should -Match 'auto-merge'
        $script:agentsContent | Should -Match 'fallback'
        $script:agentsContent | Should -Match 'Invoke-CdevCli\.ps1'
        $script:agentsContent | Should -Match 'repos doctor'
        $script:agentsContent | Should -Match 'installer exercise'
        $script:agentsContent | Should -Match 'postactions collect'
        $script:agentsContent | Should -Match 'linux deploy-ni'
        $script:agentsContent | Should -Match 'desktop-linux'
        $script:agentsContent | Should -Match 'nationalinstruments/labview:latest-linux'
        $script:agentsContent | Should -Match 'always-isolated'
        $script:agentsContent | Should -Match 'git-worktree'
        $script:agentsContent | Should -Match 'detached-clone'
        $script:agentsContent | Should -Match 'D:\\dev'
        $script:agentsContent | Should -Match 'C:\\dev'
        $script:agentsContent | Should -Match 'ci-only-selector'
        $script:agentsContent | Should -Match 'Installer Harness Execution Contract'
        $script:agentsContent | Should -Match 'integration/\*'
        $script:agentsContent | Should -Match 'self-hosted-windows-lv'
        $script:agentsContent | Should -Match 'installer-harness'
        $script:agentsContent | Should -Match 'C:\\actions-runner-cdev'
        $script:agentsContent | Should -Match 'C:\\actions-runner-cdev-2'
        $script:agentsContent | Should -Match 'C:\\actions-runner-cdev-harness2'
        $script:agentsContent | Should -Match 'iteration-summary\.json'
        $script:agentsContent | Should -Match 'exercise-report\.json'
        $script:agentsContent | Should -Match 'workspace-install-latest\.json'
        $script:readmeContent | Should -Match 'Workspace SHA Refresh PR'
        $script:readmeContent | Should -Match 'automation/sha-refresh'
        $script:readmeContent | Should -Match 'Invoke-CdevCli\.ps1'
        $script:readmeContent | Should -Match 'linux deploy-ni'
        $script:readmeContent | Should -Match 'desktop-linux'
        $script:readmeContent | Should -Match 'nationalinstruments/labview:latest-linux'
        $script:readmeContent | Should -Match 'always-isolated'
        $script:readmeContent | Should -Match 'git-worktree'
        $script:readmeContent | Should -Match 'detached-clone'
        $script:readmeContent | Should -Match 'D:\\dev'
        $script:readmeContent | Should -Match 'C:\\dev'
        $script:readmeContent | Should -Match 'ci-only-selector'
        $script:readmeContent | Should -Match 'Installer Harness'
        $script:readmeContent | Should -Match 'integration/'
        $script:readmeContent | Should -Match 'self-hosted-windows-lv'
        $script:readmeContent | Should -Match 'installer-harness'
    }

    It 'documents Windows feature troubleshooting reporting contract for Docker gating' {
        $script:agentsContent | Should -Match 'LABVIEW_WINDOWS_IMAGE'
        $script:agentsContent | Should -Match 'LABVIEW_WINDOWS_DOCKER_ISOLATION'
        $script:agentsContent | Should -Match 'NoRestart'
        $script:agentsContent | Should -Match 'features_enabled'
        $script:agentsContent | Should -Match 'reboot_pending'
        $script:agentsContent | Should -Match 'docker_daemon_ready'
        $script:readmeContent | Should -Match 'LABVIEW_WINDOWS_IMAGE'
        $script:readmeContent | Should -Match 'LABVIEW_WINDOWS_DOCKER_ISOLATION'
        $script:readmeContent | Should -Match 'features_enabled'
        $script:readmeContent | Should -Match 'reboot_pending'
        $script:readmeContent | Should -Match 'docker_daemon_ready'
    }

    It 'defines CI pipeline workflow' {
        $script:ciWorkflowContent | Should -Match 'name:\s*CI Pipeline'
        $script:ciWorkflowContent | Should -Match 'pull_request:'
        $script:ciWorkflowContent | Should -Match 'workflow_dispatch:'
        $script:ciWorkflowContent | Should -Match 'Invoke-Pester'
        $script:ciWorkflowContent | Should -Match 'Workspace Installer Contract'
        $script:ciWorkflowContent | Should -Match 'Reproducibility Contract'
        $script:ciWorkflowContent | Should -Match 'Provenance Contract'
        $script:ciWorkflowContent | Should -Match 'Build-RunnerCliBundleFromManifest\.ps1'
        $script:ciWorkflowContent | Should -Match 'DockerDesktopLinuxIterationContract\.Tests\.ps1'
        $script:ciWorkflowContent | Should -Match 'RunnerCliBundleDeterminismContract\.Tests\.ps1'
        $script:ciWorkflowContent | Should -Match 'ProvenanceContract\.Tests\.ps1'
        $script:ciWorkflowContent | Should -Match 'IntegrationGateWorkflowContract\.Tests\.ps1'
        $script:ciWorkflowContent | Should -Match 'InstallerHarnessWorkflowContract\.Tests\.ps1'
        $script:ciWorkflowContent | Should -Match 'CiWorkflowReliabilityContract\.Tests\.ps1'
        $script:ciWorkflowContent | Should -Match 'WorkspaceShaRefreshPrContract\.Tests\.ps1'
        $script:ciWorkflowContent | Should -Match 'WorkspaceManifestPinRefreshScript\.Tests\.ps1'
        $script:ciWorkflowContent | Should -Match 'LinuxLabviewImageGateWorkflowContract\.Tests\.ps1'
        $script:ciWorkflowContent | Should -Match 'IsolatedBuildWorkspacePolicyContract\.Tests\.ps1'
        $script:ciWorkflowContent | Should -Match 'ENABLE_SELF_HOSTED_CONTRACTS'
    }

    It 'defines manual installer release workflow contract' {
        $script:releaseWorkflowContent | Should -Match 'workflow_dispatch:'
        $script:releaseWorkflowContent | Should -Match 'release_tag:'
        $script:releaseWorkflowContent | Should -Match 'uses:\s*\./\.github/workflows/_release-workspace-installer-core\.yml'
        $script:releaseCoreWorkflowContent | Should -Match 'lvie-cdev-workspace-installer\.exe'
        $script:releaseCoreWorkflowContent | Should -Match 'Build-RunnerCliBundleFromManifest\.ps1'
        $script:releaseCoreWorkflowContent | Should -Match 'gh release upload'
        $script:releaseCoreWorkflowContent | Should -Match 'workspace-installer\.spdx\.json'
        $script:releaseCoreWorkflowContent | Should -Match 'workspace-installer\.slsa\.json'
        $script:releaseWithGateWorkflowContent | Should -Match 'allow_gate_override:'
        $script:releaseWithGateWorkflowContent | Should -Match 'uses:\s*\./\.github/workflows/_windows-labview-image-gate-core\.yml'
        $script:releaseWithGateWorkflowContent | Should -Match 'uses:\s*\./\.github/workflows/_linux-labview-image-gate-core\.yml'
    }
}
