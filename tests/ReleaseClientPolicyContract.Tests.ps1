#Requires -Version 7.0
#Requires -Modules Pester

$ErrorActionPreference = 'Stop'

Describe 'Release client policy contract' {
    BeforeAll {
        $script:repoRoot = (Resolve-Path -Path (Join-Path $PSScriptRoot '..')).Path
        $script:manifestPath = Join-Path $script:repoRoot 'workspace-governance.json'
        $script:payloadManifestPath = Join-Path $script:repoRoot 'workspace-governance-payload/workspace-governance/workspace-governance.json'
        $script:policyScriptPath = Join-Path $script:repoRoot 'scripts/Test-ReleaseClientContracts.ps1'

        if (-not (Test-Path -LiteralPath $script:manifestPath -PathType Leaf)) {
            throw "Manifest missing: $script:manifestPath"
        }
        if (-not (Test-Path -LiteralPath $script:payloadManifestPath -PathType Leaf)) {
            throw "Payload manifest missing: $script:payloadManifestPath"
        }
        if (-not (Test-Path -LiteralPath $script:policyScriptPath -PathType Leaf)) {
            throw "Release client policy script missing: $script:policyScriptPath"
        }

        $script:manifest = Get-Content -LiteralPath $script:manifestPath -Raw | ConvertFrom-Json -Depth 100
        $script:payloadManifest = Get-Content -LiteralPath $script:payloadManifestPath -Raw | ConvertFrom-Json -Depth 100
        $script:policyScriptContent = Get-Content -LiteralPath $script:policyScriptPath -Raw
    }

    It 'defines release_client policy defaults in manifest and payload manifest' {
        $releaseClient = $script:manifest.installer_contract.release_client
        $releaseClient | Should -Not -BeNullOrEmpty
        $releaseClient.schema_version | Should -Be '1.0'
        @($releaseClient.allowed_repositories) | Should -Contain 'LabVIEW-Community-CI-CD/labview-cdev-surface'
        @($releaseClient.allowed_repositories) | Should -Contain 'svelderrainruiz/labview-cdev-surface'
        @($releaseClient.channel_rules.allowed_channels) | Should -Contain 'stable'
        @($releaseClient.channel_rules.allowed_channels) | Should -Contain 'prerelease'
        @($releaseClient.channel_rules.allowed_channels) | Should -Contain 'canary'
        $releaseClient.signature_policy.provider | Should -Be 'authenticode'
        $releaseClient.signature_policy.mode | Should -Be 'dual-mode-transition'
        ([DateTime]$releaseClient.signature_policy.dual_mode_start_utc).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') | Should -Be '2026-03-15T00:00:00Z'
        ([DateTime]$releaseClient.signature_policy.canary_enforce_utc).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') | Should -Be '2026-05-15T00:00:00Z'
        ([DateTime]$releaseClient.signature_policy.grace_end_utc).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') | Should -Be '2026-07-01T00:00:00Z'
        $releaseClient.policy_path | Should -Be 'C:\dev\workspace-governance\release-policy.json'
        $releaseClient.state_path | Should -Be 'C:\dev\artifacts\workspace-release-state.json'
        $releaseClient.latest_report_path | Should -Be 'C:\dev\artifacts\workspace-release-client-latest.json'
        $releaseClient.cdev_cli_sync.primary_repo | Should -Be 'svelderrainruiz/labview-cdev-cli'
        $releaseClient.cdev_cli_sync.mirror_repo | Should -Be 'LabVIEW-Community-CI-CD/labview-cdev-cli'
        $releaseClient.cdev_cli_sync.strategy | Should -Be 'fork-and-upstream-full-sync'
        $releaseClient.runtime_images.cdev_cli_runtime.canonical_repository | Should -Be 'ghcr.io/labview-community-ci-cd/labview-cdev-cli-runtime'
        $releaseClient.runtime_images.cdev_cli_runtime.source_repo | Should -Be 'LabVIEW-Community-CI-CD/labview-cdev-cli'
        $releaseClient.runtime_images.cdev_cli_runtime.source_commit | Should -Be '8fef6f9192d81a14add28636c1100c109ae5e977'
        $releaseClient.runtime_images.cdev_cli_runtime.digest | Should -Be 'sha256:0506e8789680ce1c941ca9f005b75d804150aed6ad36a5ac59458b802d358423'
        $releaseClient.runtime_images.ops_runtime.repository | Should -Be 'ghcr.io/labview-community-ci-cd/labview-cdev-surface-ops'
        $releaseClient.runtime_images.ops_runtime.base_repository | Should -Be 'ghcr.io/labview-community-ci-cd/labview-cdev-cli-runtime'
        $releaseClient.runtime_images.ops_runtime.base_digest | Should -Be 'sha256:0506e8789680ce1c941ca9f005b75d804150aed6ad36a5ac59458b802d358423'
        $releaseClient.ops_control_plane_policy.slo_gate.lookback_days | Should -Be 7
        $releaseClient.ops_control_plane_policy.slo_gate.min_success_rate_pct | Should -Be 100
        $releaseClient.ops_control_plane_policy.slo_gate.max_sync_guard_age_hours | Should -Be 12
        @($releaseClient.ops_control_plane_policy.slo_gate.required_workflows) | Should -Contain 'ops-monitoring'
        @($releaseClient.ops_control_plane_policy.slo_gate.required_workflows) | Should -Contain 'ops-autoremediate'
        @($releaseClient.ops_control_plane_policy.slo_gate.required_workflows) | Should -Contain 'release-control-plane'
        $releaseClient.ops_control_plane_policy.incident_lifecycle.auto_close_on_recovery | Should -BeTrue
        $releaseClient.ops_control_plane_policy.incident_lifecycle.reopen_on_regression | Should -BeTrue
        @($releaseClient.ops_control_plane_policy.incident_lifecycle.titles) | Should -Contain 'Ops SLO Gate Alert'
        @($releaseClient.ops_control_plane_policy.incident_lifecycle.titles) | Should -Contain 'Ops Policy Drift Alert'
        @($releaseClient.ops_control_plane_policy.incident_lifecycle.titles) | Should -Contain 'Release Rollback Drill Alert'
        $releaseClient.ops_control_plane_policy.rollback_drill.channel | Should -Be 'canary'
        $releaseClient.ops_control_plane_policy.rollback_drill.required_history_count | Should -Be 2
        $releaseClient.ops_control_plane_policy.rollback_drill.release_limit | Should -Be 100

        ($script:payloadManifest | ConvertTo-Json -Depth 100) | Should -Be ($script:manifest | ConvertTo-Json -Depth 100)
    }

    It 'includes release-client policy validation script content' {
        $script:policyScriptContent | Should -Match 'release_client_exists'
        $script:policyScriptContent | Should -Match 'allowed_repository:'
        $script:policyScriptContent | Should -Match 'LabVIEW-Community-CI-CD/labview-cdev-surface'
        $script:policyScriptContent | Should -Match 'svelderrainruiz/labview-cdev-surface'
        $script:policyScriptContent | Should -Match 'cdev_cli_sync_primary_repo'
        $script:policyScriptContent | Should -Match 'cdev_cli_sync_mirror_repo'
        $script:policyScriptContent | Should -Match 'runtime_images_exists'
        $script:policyScriptContent | Should -Match 'runtime_images_cdev_cli_runtime_canonical_repository'
        $script:policyScriptContent | Should -Match 'runtime_images_ops_runtime_base_digest'
        $script:policyScriptContent | Should -Match 'ops_control_plane_policy_exists'
        $script:policyScriptContent | Should -Match 'ops_policy_slo_min_success_rate_pct'
        $script:policyScriptContent | Should -Match 'ops_policy_rollback_release_limit'
    }

    It 'has parse-safe PowerShell syntax' {
        $tokens = $null
        $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseInput($script:policyScriptContent, [ref]$tokens, [ref]$errors)
        @($errors).Count | Should -Be 0
    }
}
