#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter()]
    [string]$WorkspaceRoot = 'C:\dev',

    [Parameter()]
    [switch]$FailOnWarning
)

$ErrorActionPreference = 'Stop'

function Resolve-FirstExistingPath {
    param(
        [string[]]$Candidates
    )

    foreach ($candidate in @($Candidates)) {
        if (-not [string]::IsNullOrWhiteSpace($candidate) -and (Test-Path -Path $candidate)) {
            return $candidate
        }
    }

    if (@($Candidates).Count -gt 0) {
        return $Candidates[0]
    }
    return $null
}

$manifestPath = Join-Path $WorkspaceRoot 'workspace-governance.json'
$parentAgentsPath = Join-Path $WorkspaceRoot 'AGENTS.md'
$iconEditorRepoCandidates = @(
    'C:\Users\Sergio Velderrain\repos\labview-icon-editor',
    (Join-Path $WorkspaceRoot 'labview-icon-editor')
)
$repoAgentsPath = Resolve-FirstExistingPath -Candidates @(
    (Join-Path $iconEditorRepoCandidates[0] 'AGENTS.md'),
    (Join-Path $iconEditorRepoCandidates[1] 'AGENTS.md')
)
$containersForkAgentsPath = Join-Path $WorkspaceRoot 'labview-for-containers-org\AGENTS.md'

$repoWrapperPath = Resolve-FirstExistingPath -Candidates @(
    (Join-Path $iconEditorRepoCandidates[0] '.github\scripts\Invoke-GovernanceContract.ps1'),
    (Join-Path $iconEditorRepoCandidates[1] '.github\scripts\Invoke-GovernanceContract.ps1')
)
$repoWorkflowPath = Resolve-FirstExistingPath -Candidates @(
    (Join-Path $iconEditorRepoCandidates[0] '.github\workflows\governance-contract.yml'),
    (Join-Path $iconEditorRepoCandidates[1] '.github\workflows\governance-contract.yml')
)
$containersWrapperPath = Join-Path $WorkspaceRoot 'labview-for-containers-org\.github\scripts\Invoke-GovernanceContract.ps1'
$containersWorkflowPath = Join-Path $WorkspaceRoot 'labview-for-containers-org\.github\workflows\governance-contract.yml'

$failures = @()
$warnings = @()
$checks = @()

function Add-Check {
    param(
        [string]$Scope,
        [string]$Name,
        [bool]$Passed,
        [string]$Detail,
        [ValidateSet('error', 'warning')]
        [string]$Severity = 'error'
    )

    $entry = [ordered]@{
        scope = $Scope
        check = $Name
        passed = $Passed
        severity = $Severity
        detail = $Detail
    }
    $script:checks += [pscustomobject]$entry

    if (-not $Passed) {
        if ($Severity -eq 'warning') {
            $script:warnings += "$Scope :: $Name :: $Detail"
        } else {
            $script:failures += "$Scope :: $Name :: $Detail"
        }
    }
}

if (-not (Test-Path -Path $manifestPath)) {
    throw "Manifest not found: $manifestPath"
}

$manifest = Get-Content -Path $manifestPath -Raw | ConvertFrom-Json
Add-Check -Scope 'manifest' -Name 'managed_repo_count' -Passed ($manifest.managed_repos.Count -ge 9) -Detail "managed_repos=$($manifest.managed_repos.Count)"

$installerContractProperty = $manifest.PSObject.Properties['installer_contract']
$installerContract = if ($null -ne $installerContractProperty) { $manifest.installer_contract } else { $null }
$installerContractMembers = if ($null -ne $installerContract) { @($installerContract.PSObject.Properties.Name) } else { @() }

Add-Check -Scope 'manifest' -Name 'has_installer_contract_reproducibility' -Passed ($installerContractMembers -contains 'reproducibility') -Detail 'installer_contract.reproducibility'
Add-Check -Scope 'manifest' -Name 'has_installer_contract_provenance' -Passed ($installerContractMembers -contains 'provenance') -Detail 'installer_contract.provenance'
Add-Check -Scope 'manifest' -Name 'has_installer_contract_canary' -Passed ($installerContractMembers -contains 'canary') -Detail 'installer_contract.canary'
Add-Check -Scope 'manifest' -Name 'has_installer_contract_cli_bundle' -Passed ($installerContractMembers -contains 'cli_bundle') -Detail 'installer_contract.cli_bundle'
Add-Check -Scope 'manifest' -Name 'has_installer_contract_harness' -Passed ($installerContractMembers -contains 'harness') -Detail 'installer_contract.harness'
Add-Check -Scope 'manifest' -Name 'has_installer_contract_release_client' -Passed ($installerContractMembers -contains 'release_client') -Detail 'installer_contract.release_client'
if ($installerContractMembers -contains 'reproducibility') {
    Add-Check -Scope 'manifest' -Name 'reproducibility_required_true' -Passed ([bool]$manifest.installer_contract.reproducibility.required) -Detail "required=$($manifest.installer_contract.reproducibility.required)"
    Add-Check -Scope 'manifest' -Name 'reproducibility_strict_hash_match_true' -Passed ([bool]$manifest.installer_contract.reproducibility.strict_hash_match) -Detail "strict_hash_match=$($manifest.installer_contract.reproducibility.strict_hash_match)"
}
if ($installerContractMembers -contains 'provenance') {
    $formats = @($manifest.installer_contract.provenance.formats)
    Add-Check -Scope 'manifest' -Name 'provenance_formats_include_spdx' -Passed ($formats -contains 'SPDX-2.3-JSON') -Detail ([string]::Join(',', $formats))
    Add-Check -Scope 'manifest' -Name 'provenance_formats_include_slsa' -Passed ($formats -contains 'SLSA-v1-JSON') -Detail ([string]::Join(',', $formats))
}
if ($installerContractMembers -contains 'canary') {
    Add-Check -Scope 'manifest' -Name 'canary_has_schedule' -Passed (-not [string]::IsNullOrWhiteSpace([string]$manifest.installer_contract.canary.schedule_cron_utc)) -Detail ([string]$manifest.installer_contract.canary.schedule_cron_utc)
    Add-Check -Scope 'manifest' -Name 'canary_linux_context' -Passed ([string]$manifest.installer_contract.canary.docker_context -eq 'desktop-linux') -Detail ([string]$manifest.installer_contract.canary.docker_context)
}
if ($installerContractMembers -contains 'cli_bundle') {
    $cliBundle = $manifest.installer_contract.cli_bundle
    Add-Check -Scope 'manifest' -Name 'cli_bundle_repo' -Passed ([string]$cliBundle.repo -eq 'LabVIEW-Community-CI-CD/labview-cdev-cli') -Detail ([string]$cliBundle.repo)
    Add-Check -Scope 'manifest' -Name 'cli_bundle_asset_win' -Passed ([string]$cliBundle.asset_win -eq 'cdev-cli-win-x64.zip') -Detail ([string]$cliBundle.asset_win)
    Add-Check -Scope 'manifest' -Name 'cli_bundle_asset_linux' -Passed ([string]$cliBundle.asset_linux -eq 'cdev-cli-linux-x64.tar.gz') -Detail ([string]$cliBundle.asset_linux)
    Add-Check -Scope 'manifest' -Name 'cli_bundle_asset_win_sha256' -Passed ([regex]::IsMatch(([string]$cliBundle.asset_win_sha256).ToLowerInvariant(), '^[0-9a-f]{64}$')) -Detail ([string]$cliBundle.asset_win_sha256)
    Add-Check -Scope 'manifest' -Name 'cli_bundle_asset_linux_sha256' -Passed ([regex]::IsMatch(([string]$cliBundle.asset_linux_sha256).ToLowerInvariant(), '^[0-9a-f]{64}$')) -Detail ([string]$cliBundle.asset_linux_sha256)
    Add-Check -Scope 'manifest' -Name 'cli_bundle_entrypoint_win' -Passed ([string]$cliBundle.entrypoint_win -eq 'tools\cdev-cli\win-x64\cdev-cli\scripts\Invoke-CdevCli.ps1') -Detail ([string]$cliBundle.entrypoint_win)
    Add-Check -Scope 'manifest' -Name 'cli_bundle_entrypoint_linux' -Passed ([string]$cliBundle.entrypoint_linux -eq 'tools/cdev-cli/linux-x64/cdev-cli/scripts/Invoke-CdevCli.ps1') -Detail ([string]$cliBundle.entrypoint_linux)
}
if ($installerContractMembers -contains 'harness') {
    $harness = $manifest.installer_contract.harness
    Add-Check -Scope 'manifest' -Name 'harness_workflow_name' -Passed ([string]$harness.workflow_name -eq 'installer-harness-self-hosted.yml') -Detail ([string]$harness.workflow_name)
    Add-Check -Scope 'manifest' -Name 'harness_trigger_mode' -Passed ([string]$harness.trigger_mode -eq 'integration_branch_push_and_dispatch') -Detail ([string]$harness.trigger_mode)
    foreach ($label in @('self-hosted', 'windows', 'self-hosted-windows-lv')) {
        Add-Check -Scope 'manifest' -Name "harness_runner_label:$label" -Passed (@($harness.runner_labels) -contains $label) -Detail ([string]::Join(',', @($harness.runner_labels)))
    }
    foreach ($requiredReport in @('iteration-summary.json', 'exercise-report.json', 'C:\dev-smoke-lvie\artifacts\workspace-install-latest.json', 'lvie-cdev-workspace-installer-bundle.zip', 'harness-validation-report.json')) {
        Add-Check -Scope 'manifest' -Name "harness_required_report:$requiredReport" -Passed (@($harness.required_reports) -contains $requiredReport) -Detail ([string]::Join(',', @($harness.required_reports)))
    }
    foreach ($requiredPostaction in @('ppl_capability_checks.32', 'ppl_capability_checks.64', 'vip_package_build_check')) {
        Add-Check -Scope 'manifest' -Name "harness_required_postaction:$requiredPostaction" -Passed (@($harness.required_postactions) -contains $requiredPostaction) -Detail ([string]::Join(',', @($harness.required_postactions)))
    }
}
if ($installerContractMembers -contains 'release_client') {
    $releaseClient = $manifest.installer_contract.release_client
    Add-Check -Scope 'manifest' -Name 'release_client_schema_version' -Passed ([string]$releaseClient.schema_version -eq '1.0') -Detail ([string]$releaseClient.schema_version)
    Add-Check -Scope 'manifest' -Name 'release_client_default_install_root' -Passed ([string]$releaseClient.default_install_root -eq 'C:\dev') -Detail ([string]$releaseClient.default_install_root)
    Add-Check -Scope 'manifest' -Name 'release_client_policy_path' -Passed ([string]$releaseClient.policy_path -eq 'C:\dev\workspace-governance\release-policy.json') -Detail ([string]$releaseClient.policy_path)
    Add-Check -Scope 'manifest' -Name 'release_client_state_path' -Passed ([string]$releaseClient.state_path -eq 'C:\dev\artifacts\workspace-release-state.json') -Detail ([string]$releaseClient.state_path)
    Add-Check -Scope 'manifest' -Name 'release_client_latest_report_path' -Passed ([string]$releaseClient.latest_report_path -eq 'C:\dev\artifacts\workspace-release-client-latest.json') -Detail ([string]$releaseClient.latest_report_path)
    Add-Check -Scope 'manifest' -Name 'release_client_provenance_required' -Passed ([bool]$releaseClient.provenance_required) -Detail ([string]$releaseClient.provenance_required)
    Add-Check -Scope 'manifest' -Name 'release_client_allowed_repo_upstream' -Passed (@($releaseClient.allowed_repositories) -contains 'LabVIEW-Community-CI-CD/labview-cdev-surface') -Detail ([string]::Join(',', @($releaseClient.allowed_repositories)))
    Add-Check -Scope 'manifest' -Name 'release_client_allowed_repo_fork' -Passed (@($releaseClient.allowed_repositories) -contains 'svelderrainruiz/labview-cdev-surface') -Detail ([string]::Join(',', @($releaseClient.allowed_repositories)))
    Add-Check -Scope 'manifest' -Name 'release_client_allowed_channel_stable' -Passed (@($releaseClient.channel_rules.allowed_channels) -contains 'stable') -Detail ([string]::Join(',', @($releaseClient.channel_rules.allowed_channels)))
    Add-Check -Scope 'manifest' -Name 'release_client_allowed_channel_prerelease' -Passed (@($releaseClient.channel_rules.allowed_channels) -contains 'prerelease') -Detail ([string]::Join(',', @($releaseClient.channel_rules.allowed_channels)))
    Add-Check -Scope 'manifest' -Name 'release_client_allowed_channel_canary' -Passed (@($releaseClient.channel_rules.allowed_channels) -contains 'canary') -Detail ([string]::Join(',', @($releaseClient.channel_rules.allowed_channels)))
    Add-Check -Scope 'manifest' -Name 'release_client_default_channel' -Passed ([string]$releaseClient.channel_rules.default_channel -eq 'stable') -Detail ([string]$releaseClient.channel_rules.default_channel)
    Add-Check -Scope 'manifest' -Name 'release_client_signature_provider' -Passed ([string]$releaseClient.signature_policy.provider -eq 'authenticode') -Detail ([string]$releaseClient.signature_policy.provider)
    Add-Check -Scope 'manifest' -Name 'release_client_signature_mode' -Passed ([string]$releaseClient.signature_policy.mode -eq 'dual-mode-transition') -Detail ([string]$releaseClient.signature_policy.mode)
    Add-Check -Scope 'manifest' -Name 'release_client_signature_dual_mode_start' -Passed (([DateTime]$releaseClient.signature_policy.dual_mode_start_utc).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') -eq '2026-03-15T00:00:00Z') -Detail ([string]$releaseClient.signature_policy.dual_mode_start_utc)
    Add-Check -Scope 'manifest' -Name 'release_client_signature_canary_enforce' -Passed (([DateTime]$releaseClient.signature_policy.canary_enforce_utc).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') -eq '2026-05-15T00:00:00Z') -Detail ([string]$releaseClient.signature_policy.canary_enforce_utc)
    Add-Check -Scope 'manifest' -Name 'release_client_signature_grace_end' -Passed (([DateTime]$releaseClient.signature_policy.grace_end_utc).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') -eq '2026-07-01T00:00:00Z') -Detail ([string]$releaseClient.signature_policy.grace_end_utc)
    Add-Check -Scope 'manifest' -Name 'release_client_upgrade_allow_major' -Passed (-not [bool]$releaseClient.upgrade_policy.allow_major_upgrade) -Detail ([string]$releaseClient.upgrade_policy.allow_major_upgrade)
    Add-Check -Scope 'manifest' -Name 'release_client_upgrade_allow_downgrade' -Passed (-not [bool]$releaseClient.upgrade_policy.allow_downgrade) -Detail ([string]$releaseClient.upgrade_policy.allow_downgrade)
    Add-Check -Scope 'manifest' -Name 'release_client_cli_sync_primary' -Passed ([string]$releaseClient.cdev_cli_sync.primary_repo -eq 'svelderrainruiz/labview-cdev-cli') -Detail ([string]$releaseClient.cdev_cli_sync.primary_repo)
    Add-Check -Scope 'manifest' -Name 'release_client_cli_sync_mirror' -Passed ([string]$releaseClient.cdev_cli_sync.mirror_repo -eq 'LabVIEW-Community-CI-CD/labview-cdev-cli') -Detail ([string]$releaseClient.cdev_cli_sync.mirror_repo)
    Add-Check -Scope 'manifest' -Name 'release_client_cli_sync_strategy' -Passed ([string]$releaseClient.cdev_cli_sync.strategy -eq 'fork-and-upstream-full-sync') -Detail ([string]$releaseClient.cdev_cli_sync.strategy)
    Add-Check -Scope 'manifest' -Name 'release_client_runtime_images_exists' -Passed ($null -ne $releaseClient.runtime_images) -Detail 'installer_contract.release_client.runtime_images'
    Add-Check -Scope 'manifest' -Name 'release_client_runtime_images_cdev_cli_runtime_repository' -Passed ([string]$releaseClient.runtime_images.cdev_cli_runtime.canonical_repository -eq 'ghcr.io/labview-community-ci-cd/labview-cdev-cli-runtime') -Detail ([string]$releaseClient.runtime_images.cdev_cli_runtime.canonical_repository)
    Add-Check -Scope 'manifest' -Name 'release_client_runtime_images_cdev_cli_runtime_source_repo' -Passed ([string]$releaseClient.runtime_images.cdev_cli_runtime.source_repo -eq 'LabVIEW-Community-CI-CD/labview-cdev-cli') -Detail ([string]$releaseClient.runtime_images.cdev_cli_runtime.source_repo)
    Add-Check -Scope 'manifest' -Name 'release_client_runtime_images_cdev_cli_runtime_source_commit' -Passed ([string]$releaseClient.runtime_images.cdev_cli_runtime.source_commit -eq '8fef6f9192d81a14add28636c1100c109ae5e977') -Detail ([string]$releaseClient.runtime_images.cdev_cli_runtime.source_commit)
    Add-Check -Scope 'manifest' -Name 'release_client_runtime_images_cdev_cli_runtime_digest' -Passed ([string]$releaseClient.runtime_images.cdev_cli_runtime.digest -eq 'sha256:0506e8789680ce1c941ca9f005b75d804150aed6ad36a5ac59458b802d358423') -Detail ([string]$releaseClient.runtime_images.cdev_cli_runtime.digest)
    Add-Check -Scope 'manifest' -Name 'release_client_runtime_images_ops_repository' -Passed ([string]$releaseClient.runtime_images.ops_runtime.repository -eq 'ghcr.io/labview-community-ci-cd/labview-cdev-surface-ops') -Detail ([string]$releaseClient.runtime_images.ops_runtime.repository)
    Add-Check -Scope 'manifest' -Name 'release_client_runtime_images_ops_base_repository' -Passed ([string]$releaseClient.runtime_images.ops_runtime.base_repository -eq 'ghcr.io/labview-community-ci-cd/labview-cdev-cli-runtime') -Detail ([string]$releaseClient.runtime_images.ops_runtime.base_repository)
    Add-Check -Scope 'manifest' -Name 'release_client_runtime_images_ops_base_digest' -Passed ([string]$releaseClient.runtime_images.ops_runtime.base_digest -eq 'sha256:0506e8789680ce1c941ca9f005b75d804150aed6ad36a5ac59458b802d358423') -Detail ([string]$releaseClient.runtime_images.ops_runtime.base_digest)
    Add-Check -Scope 'manifest' -Name 'release_client_ops_policy_exists' -Passed ($null -ne $releaseClient.ops_control_plane_policy) -Detail 'installer_contract.release_client.ops_control_plane_policy'
    Add-Check -Scope 'manifest' -Name 'release_client_ops_policy_slo_lookback_days' -Passed ([int]$releaseClient.ops_control_plane_policy.slo_gate.lookback_days -eq 7) -Detail ([string]$releaseClient.ops_control_plane_policy.slo_gate.lookback_days)
    Add-Check -Scope 'manifest' -Name 'release_client_ops_policy_slo_min_success_rate_pct' -Passed ([double]$releaseClient.ops_control_plane_policy.slo_gate.min_success_rate_pct -eq 100) -Detail ([string]$releaseClient.ops_control_plane_policy.slo_gate.min_success_rate_pct)
    Add-Check -Scope 'manifest' -Name 'release_client_ops_policy_slo_max_sync_guard_age_hours' -Passed ([int]$releaseClient.ops_control_plane_policy.slo_gate.max_sync_guard_age_hours -eq 12) -Detail ([string]$releaseClient.ops_control_plane_policy.slo_gate.max_sync_guard_age_hours)
    Add-Check -Scope 'manifest' -Name 'release_client_ops_policy_slo_required_workflow_ops_monitoring' -Passed (@($releaseClient.ops_control_plane_policy.slo_gate.required_workflows) -contains 'ops-monitoring') -Detail ([string]::Join(',', @($releaseClient.ops_control_plane_policy.slo_gate.required_workflows)))
    Add-Check -Scope 'manifest' -Name 'release_client_ops_policy_slo_required_workflow_ops_autoremediate' -Passed (@($releaseClient.ops_control_plane_policy.slo_gate.required_workflows) -contains 'ops-autoremediate') -Detail ([string]::Join(',', @($releaseClient.ops_control_plane_policy.slo_gate.required_workflows)))
    Add-Check -Scope 'manifest' -Name 'release_client_ops_policy_slo_required_workflow_release_control_plane' -Passed (@($releaseClient.ops_control_plane_policy.slo_gate.required_workflows) -contains 'release-control-plane') -Detail ([string]::Join(',', @($releaseClient.ops_control_plane_policy.slo_gate.required_workflows)))
    Add-Check -Scope 'manifest' -Name 'release_client_ops_policy_incident_auto_close' -Passed ([bool]$releaseClient.ops_control_plane_policy.incident_lifecycle.auto_close_on_recovery) -Detail ([string]$releaseClient.ops_control_plane_policy.incident_lifecycle.auto_close_on_recovery)
    Add-Check -Scope 'manifest' -Name 'release_client_ops_policy_incident_reopen' -Passed ([bool]$releaseClient.ops_control_plane_policy.incident_lifecycle.reopen_on_regression) -Detail ([string]$releaseClient.ops_control_plane_policy.incident_lifecycle.reopen_on_regression)
    Add-Check -Scope 'manifest' -Name 'release_client_ops_policy_incident_title_release_guardrails' -Passed (@($releaseClient.ops_control_plane_policy.incident_lifecycle.titles) -contains 'Release Guardrails Auto-Remediation Alert') -Detail ([string]::Join(',', @($releaseClient.ops_control_plane_policy.incident_lifecycle.titles)))
    Add-Check -Scope 'manifest' -Name 'release_client_ops_policy_tag_strategy_mode' -Passed ([string]$releaseClient.ops_control_plane_policy.tag_strategy.mode -eq 'dual-mode-semver-preferred') -Detail ([string]$releaseClient.ops_control_plane_policy.tag_strategy.mode)
    Add-Check -Scope 'manifest' -Name 'release_client_ops_policy_tag_strategy_legacy_tag_family' -Passed ([string]$releaseClient.ops_control_plane_policy.tag_strategy.legacy_tag_family -eq 'legacy_date_window') -Detail ([string]$releaseClient.ops_control_plane_policy.tag_strategy.legacy_tag_family)
    Add-Check -Scope 'manifest' -Name 'release_client_ops_policy_tag_strategy_semver_only_enforce' -Passed (([DateTime]$releaseClient.ops_control_plane_policy.tag_strategy.semver_only_enforce_utc).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') -eq '2026-07-01T00:00:00Z') -Detail ([string]$releaseClient.ops_control_plane_policy.tag_strategy.semver_only_enforce_utc)
    Add-Check -Scope 'manifest' -Name 'release_client_ops_policy_tag_strategy_matches_signature_grace_end' -Passed (([DateTime]$releaseClient.ops_control_plane_policy.tag_strategy.semver_only_enforce_utc).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') -eq ([DateTime]$releaseClient.signature_policy.grace_end_utc).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')) -Detail ("semver_only_enforce_utc={0}; signature_grace_end_utc={1}" -f [string]$releaseClient.ops_control_plane_policy.tag_strategy.semver_only_enforce_utc, [string]$releaseClient.signature_policy.grace_end_utc)
    Add-Check -Scope 'manifest' -Name 'release_client_ops_policy_stable_window_weekday_monday' -Passed (@($releaseClient.ops_control_plane_policy.stable_promotion_window.full_cycle_allowed_utc_weekdays) -contains 'Monday') -Detail ([string]::Join(',', @($releaseClient.ops_control_plane_policy.stable_promotion_window.full_cycle_allowed_utc_weekdays)))
    Add-Check -Scope 'manifest' -Name 'release_client_ops_policy_stable_window_allow_override' -Passed ([bool]$releaseClient.ops_control_plane_policy.stable_promotion_window.allow_outside_window_with_override) -Detail ([string]$releaseClient.ops_control_plane_policy.stable_promotion_window.allow_outside_window_with_override)
    Add-Check -Scope 'manifest' -Name 'release_client_ops_policy_stable_window_reason_required' -Passed ([bool]$releaseClient.ops_control_plane_policy.stable_promotion_window.override_reason_required) -Detail ([string]$releaseClient.ops_control_plane_policy.stable_promotion_window.override_reason_required)
    Add-Check -Scope 'manifest' -Name 'release_client_ops_policy_stable_window_reason_min_length' -Passed ([int]$releaseClient.ops_control_plane_policy.stable_promotion_window.override_reason_min_length -eq 12) -Detail ([string]$releaseClient.ops_control_plane_policy.stable_promotion_window.override_reason_min_length)
    Add-Check -Scope 'manifest' -Name 'release_client_ops_policy_stable_window_reason_pattern_exists' -Passed (-not [string]::IsNullOrWhiteSpace([string]$releaseClient.ops_control_plane_policy.stable_promotion_window.override_reason_pattern)) -Detail ([string]$releaseClient.ops_control_plane_policy.stable_promotion_window.override_reason_pattern)
    Add-Check -Scope 'manifest' -Name 'release_client_ops_policy_stable_window_reason_pattern_has_reference_group' -Passed ([string]$releaseClient.ops_control_plane_policy.stable_promotion_window.override_reason_pattern -match '\?<reference>') -Detail ([string]$releaseClient.ops_control_plane_policy.stable_promotion_window.override_reason_pattern)
    Add-Check -Scope 'manifest' -Name 'release_client_ops_policy_stable_window_reason_pattern_has_summary_group' -Passed ([string]$releaseClient.ops_control_plane_policy.stable_promotion_window.override_reason_pattern -match '\?<summary>') -Detail ([string]$releaseClient.ops_control_plane_policy.stable_promotion_window.override_reason_pattern)
    Add-Check -Scope 'manifest' -Name 'release_client_ops_policy_stable_window_reason_example' -Passed (-not [string]::IsNullOrWhiteSpace([string]$releaseClient.ops_control_plane_policy.stable_promotion_window.override_reason_example)) -Detail ([string]$releaseClient.ops_control_plane_policy.stable_promotion_window.override_reason_example)
    Add-Check -Scope 'manifest' -Name 'release_client_ops_policy_self_healing_enabled' -Passed ([bool]$releaseClient.ops_control_plane_policy.self_healing.enabled) -Detail ([string]$releaseClient.ops_control_plane_policy.self_healing.enabled)
    Add-Check -Scope 'manifest' -Name 'release_client_ops_policy_self_healing_max_attempts' -Passed ([int]$releaseClient.ops_control_plane_policy.self_healing.max_attempts -eq 1) -Detail ([string]$releaseClient.ops_control_plane_policy.self_healing.max_attempts)
    Add-Check -Scope 'manifest' -Name 'release_client_ops_policy_self_healing_slo_workflow' -Passed ([string]$releaseClient.ops_control_plane_policy.self_healing.slo_gate.remediation_workflow -eq 'ops-autoremediate.yml') -Detail ([string]$releaseClient.ops_control_plane_policy.self_healing.slo_gate.remediation_workflow)
    Add-Check -Scope 'manifest' -Name 'release_client_ops_policy_self_healing_slo_watch_timeout' -Passed ([int]$releaseClient.ops_control_plane_policy.self_healing.slo_gate.watch_timeout_minutes -eq 45) -Detail ([string]$releaseClient.ops_control_plane_policy.self_healing.slo_gate.watch_timeout_minutes)
    Add-Check -Scope 'manifest' -Name 'release_client_ops_policy_self_healing_slo_verify' -Passed ([bool]$releaseClient.ops_control_plane_policy.self_healing.slo_gate.verify_after_remediation) -Detail ([string]$releaseClient.ops_control_plane_policy.self_healing.slo_gate.verify_after_remediation)
    Add-Check -Scope 'manifest' -Name 'release_client_ops_policy_self_healing_guardrails_workflow' -Passed ([string]$releaseClient.ops_control_plane_policy.self_healing.guardrails.remediation_workflow -eq 'release-guardrails-autoremediate.yml') -Detail ([string]$releaseClient.ops_control_plane_policy.self_healing.guardrails.remediation_workflow)
    Add-Check -Scope 'manifest' -Name 'release_client_ops_policy_self_healing_guardrails_race_drill_workflow' -Passed ([string]$releaseClient.ops_control_plane_policy.self_healing.guardrails.race_drill_workflow -eq 'release-race-hardening-drill.yml') -Detail ([string]$releaseClient.ops_control_plane_policy.self_healing.guardrails.race_drill_workflow)
    Add-Check -Scope 'manifest' -Name 'release_client_ops_policy_self_healing_guardrails_watch_timeout' -Passed ([int]$releaseClient.ops_control_plane_policy.self_healing.guardrails.watch_timeout_minutes -eq 120) -Detail ([string]$releaseClient.ops_control_plane_policy.self_healing.guardrails.watch_timeout_minutes)
    Add-Check -Scope 'manifest' -Name 'release_client_ops_policy_self_healing_guardrails_verify' -Passed ([bool]$releaseClient.ops_control_plane_policy.self_healing.guardrails.verify_after_remediation) -Detail ([string]$releaseClient.ops_control_plane_policy.self_healing.guardrails.verify_after_remediation)
    Add-Check -Scope 'manifest' -Name 'release_client_ops_policy_self_healing_guardrails_race_gate_max_age_hours' -Passed ([int]$releaseClient.ops_control_plane_policy.self_healing.guardrails.race_gate_max_age_hours -eq 168) -Detail ([string]$releaseClient.ops_control_plane_policy.self_healing.guardrails.race_gate_max_age_hours)
    Add-Check -Scope 'manifest' -Name 'release_client_ops_policy_self_healing_rollback_workflow' -Passed ([string]$releaseClient.ops_control_plane_policy.self_healing.rollback_drill.release_workflow -eq 'release-workspace-installer.yml') -Detail ([string]$releaseClient.ops_control_plane_policy.self_healing.rollback_drill.release_workflow)
    Add-Check -Scope 'manifest' -Name 'release_client_ops_policy_self_healing_rollback_branch' -Passed ([string]$releaseClient.ops_control_plane_policy.self_healing.rollback_drill.release_branch -eq 'main') -Detail ([string]$releaseClient.ops_control_plane_policy.self_healing.rollback_drill.release_branch)
    Add-Check -Scope 'manifest' -Name 'release_client_ops_policy_self_healing_rollback_watch_timeout' -Passed ([int]$releaseClient.ops_control_plane_policy.self_healing.rollback_drill.watch_timeout_minutes -eq 120) -Detail ([string]$releaseClient.ops_control_plane_policy.self_healing.rollback_drill.watch_timeout_minutes)
    Add-Check -Scope 'manifest' -Name 'release_client_ops_policy_self_healing_rollback_verify' -Passed ([bool]$releaseClient.ops_control_plane_policy.self_healing.rollback_drill.verify_after_remediation) -Detail ([string]$releaseClient.ops_control_plane_policy.self_healing.rollback_drill.verify_after_remediation)
    Add-Check -Scope 'manifest' -Name 'release_client_ops_policy_self_healing_rollback_canary_min' -Passed ([int]$releaseClient.ops_control_plane_policy.self_healing.rollback_drill.canary_sequence_min -eq 1) -Detail ([string]$releaseClient.ops_control_plane_policy.self_healing.rollback_drill.canary_sequence_min)
    Add-Check -Scope 'manifest' -Name 'release_client_ops_policy_self_healing_rollback_canary_max' -Passed ([int]$releaseClient.ops_control_plane_policy.self_healing.rollback_drill.canary_sequence_max -eq 49) -Detail ([string]$releaseClient.ops_control_plane_policy.self_healing.rollback_drill.canary_sequence_max)
    Add-Check -Scope 'manifest' -Name 'release_client_ops_policy_rollback_channel' -Passed ([string]$releaseClient.ops_control_plane_policy.rollback_drill.channel -eq 'canary') -Detail ([string]$releaseClient.ops_control_plane_policy.rollback_drill.channel)
    Add-Check -Scope 'manifest' -Name 'release_client_ops_policy_rollback_history_count' -Passed ([int]$releaseClient.ops_control_plane_policy.rollback_drill.required_history_count -eq 2) -Detail ([string]$releaseClient.ops_control_plane_policy.rollback_drill.required_history_count)
    Add-Check -Scope 'manifest' -Name 'release_client_ops_policy_rollback_release_limit' -Passed ([int]$releaseClient.ops_control_plane_policy.rollback_drill.release_limit -eq 100) -Detail ([string]$releaseClient.ops_control_plane_policy.rollback_drill.release_limit)
}

$requiredSchemaFields = @(
    'path',
    'repo_name',
    'mode',
    'required_remotes',
    'allowed_mutation_remotes',
    'required_gh_repo',
    'forbidden_targets',
    'default_branch',
    'branch_protection_required',
    'default_branch_mutation_policy',
    'required_status_checks',
    'strict_status_checks',
    'required_review_policy',
    'forbid_force_push',
    'forbid_deletion',
    'pinned_sha'
)

foreach ($repo in $manifest.managed_repos) {
    $scope = "manifest:$($repo.repo_name)"
    foreach ($field in $requiredSchemaFields) {
        $present = $null -ne $repo.PSObject.Properties[$field]
        Add-Check -Scope $scope -Name "has_field:$field" -Passed $present -Detail $field
    }

    if ($null -ne $repo.PSObject.Properties['required_status_checks']) {
        Add-Check -Scope $scope -Name 'required_status_checks_nonempty' -Passed (@($repo.required_status_checks).Count -gt 0) -Detail "count=$(@($repo.required_status_checks).Count)"
    }

    if ($null -ne $repo.PSObject.Properties['required_review_policy']) {
        $policy = $repo.required_review_policy
        Add-Check -Scope $scope -Name 'review_policy_has_required_pull_request_reviews' -Passed ($null -ne $policy.PSObject.Properties['required_pull_request_reviews']) -Detail 'required_pull_request_reviews'
        Add-Check -Scope $scope -Name 'review_policy_has_required_approving_review_count' -Passed ($null -ne $policy.PSObject.Properties['required_approving_review_count']) -Detail 'required_approving_review_count'
    }

    if ($null -ne $repo.PSObject.Properties['pinned_sha']) {
        $sha = [string]$repo.pinned_sha
        Add-Check -Scope $scope -Name 'pinned_sha_is_40_hex' -Passed ([regex]::IsMatch($sha, '^[0-9a-f]{40}$')) -Detail $sha
    }
}

if (-not (Test-Path -Path $parentAgentsPath)) {
    Add-Check -Scope 'parent-agents' -Name 'file_exists' -Passed $false -Detail "Missing: $parentAgentsPath"
} else {
    $parentText = Get-Content -Path $parentAgentsPath -Raw
    $parentRequired = @(
        'workspace-governance.json',
        '## Branch Protection Gate',
        'Default-branch mutation is blocked',
        'svelderrainruiz/labview-icon-editor-org:develop',
        'LabVIEW-Community-CI-CD/labview-icon-editor:develop',
        'svelderrainruiz/labview-for-containers-org:main',
        'LabVIEW-Community-CI-CD/labview-for-containers:main',
        'svelderrainruiz/labview-icon-editor-codex-skills:main',
        'LabVIEW-Community-CI-CD/labview-icon-editor-codex-skills:main',
        'svelderrainruiz/labview-cdev-surface:main',
        'LabVIEW-Community-CI-CD/labview-cdev-surface:main',
        'C:\dev\labview-icon-editor-codex-skills',
        'C:\dev\labview-icon-editor-codex-skills-upstream',
        'C:\dev\labview-cdev-surface',
        'C:\dev\labview-cdev-surface-upstream',
        '-R svelderrainruiz/labview-cdev-surface',
        '-R LabVIEW-Community-CI-CD/labview-cdev-surface',
        'Pipeline Contract',
        'Governance Contract',
        'stabilization-2026-certification-gate',
        'Workspace Installer Contract',
        'pinned_sha'
    )
    foreach ($token in $parentRequired) {
        Add-Check -Scope 'parent-agents' -Name "contains:$token" -Passed ($parentText.Contains($token)) -Detail $token
    }

    $staleIconFork = [regex]::IsMatch($parentText, 'svelderrainruiz/labview-icon-editor(?!-(org|codex-skills))')
    Add-Check -Scope 'parent-agents' -Name 'no_stale_icon_fork_target' -Passed (-not $staleIconFork) -Detail 'Must not reference old icon-editor fork target.'

    $unsafeCdevForkMutation = [regex]::IsMatch(
        $parentText,
        '\| `C:\\dev\\labview-cdev-surface` \|[^\r\n]*\(`LabVIEW-Community-CI-CD/labview-cdev-surface`\)'
    )
    Add-Check -Scope 'parent-agents' -Name 'no_unsafe_cdev_fork_mutation_target' -Passed (-not $unsafeCdevForkMutation) -Detail 'Fork cdev-surface path must not allow org mutation target.'
}

if (-not (Test-Path -Path $repoAgentsPath)) {
    Add-Check -Scope 'repo-agents' -Name 'file_exists' -Passed $false -Detail "Missing: $repoAgentsPath"
} else {
    $repoText = Get-Content -Path $repoAgentsPath -Raw
    $repoRequired = @(
        'C:\dev\AGENTS.md',
        'C:\dev\workspace-governance.json',
        'Branch-protection readiness gate',
        'feature-branch mutation + PR flow',
        'svelderrainruiz/labview-icon-editor-org',
        'LabVIEW-Community-CI-CD/labview-icon-editor',
        '-R svelderrainruiz/labview-icon-editor-org'
    )
    foreach ($token in $repoRequired) {
        Add-Check -Scope 'repo-agents' -Name "contains:$token" -Passed ($repoText.Contains($token)) -Detail $token
    }

    $staleIconForkRepo = [regex]::IsMatch($repoText, 'svelderrainruiz/labview-icon-editor(?!-(org|codex-skills))')
    Add-Check -Scope 'repo-agents' -Name 'no_stale_icon_fork_target' -Passed (-not $staleIconForkRepo) -Detail 'Must not reference old icon-editor fork target.'
}

if (-not (Test-Path -Path $containersForkAgentsPath)) {
    Add-Check -Scope 'containers-fork-agents' -Name 'file_exists' -Passed $false -Detail "Missing: $containersForkAgentsPath"
} else {
    $containersText = Get-Content -Path $containersForkAgentsPath -Raw
    $containersRequired = @(
        'C:\dev\AGENTS.md',
        'C:\dev\workspace-governance.json',
        '## Branch Protection Gate',
        'svelderrainruiz/labview-for-containers-org:main',
        'Governance Contract',
        '-R svelderrainruiz/labview-for-containers-org'
    )
    foreach ($token in $containersRequired) {
        Add-Check -Scope 'containers-fork-agents' -Name "contains:$token" -Passed ($containersText.Contains($token)) -Detail $token
    }

    $staleContainersFork = [regex]::IsMatch($containersText, 'svelderrainruiz/labview-for-containers(?!-org)')
    Add-Check -Scope 'containers-fork-agents' -Name 'no_stale_containers_fork_target' -Passed (-not $staleContainersFork) -Detail 'Must not reference old containers fork target.'
}

Add-Check -Scope 'ci-contract' -Name 'repo_wrapper_exists' -Passed (Test-Path -Path $repoWrapperPath) -Detail $repoWrapperPath
Add-Check -Scope 'ci-contract' -Name 'repo_workflow_exists' -Passed (Test-Path -Path $repoWorkflowPath) -Detail $repoWorkflowPath
Add-Check -Scope 'ci-contract' -Name 'containers_wrapper_exists' -Passed (Test-Path -Path $containersWrapperPath) -Detail $containersWrapperPath
Add-Check -Scope 'ci-contract' -Name 'containers_workflow_exists' -Passed (Test-Path -Path $containersWorkflowPath) -Detail $containersWorkflowPath

if (Test-Path -Path $repoWrapperPath) {
    $repoWrapperText = Get-Content -Path $repoWrapperPath -Raw
    Add-Check -Scope 'ci-contract' -Name 'repo_wrapper_checks_branch_protection_api' -Passed ($repoWrapperText.Contains('/protection')) -Detail '/protection'
    Add-Check -Scope 'ci-contract' -Name 'repo_wrapper_checks_required_context_pipeline_contract' -Passed ($repoWrapperText.Contains('Pipeline Contract')) -Detail 'Pipeline Contract'
    Add-Check -Scope 'ci-contract' -Name 'repo_wrapper_checks_required_context_governance_contract' -Passed ($repoWrapperText.Contains('Governance Contract')) -Detail 'Governance Contract'
}

if (Test-Path -Path $containersWrapperPath) {
    $containersWrapperText = Get-Content -Path $containersWrapperPath -Raw
    Add-Check -Scope 'ci-contract' -Name 'containers_wrapper_checks_branch_protection_api' -Passed ($containersWrapperText.Contains('/protection')) -Detail '/protection'
    Add-Check -Scope 'ci-contract' -Name 'containers_wrapper_checks_required_context_linux' -Passed ($containersWrapperText.Contains('run-labview-cli')) -Detail 'run-labview-cli'
    Add-Check -Scope 'ci-contract' -Name 'containers_wrapper_checks_required_context_windows' -Passed ($containersWrapperText.Contains('run-labview-cli-windows')) -Detail 'run-labview-cli-windows'
    Add-Check -Scope 'ci-contract' -Name 'containers_wrapper_checks_required_context_governance' -Passed ($containersWrapperText.Contains('Governance Contract')) -Detail 'Governance Contract'
}

if (Test-Path -Path $repoWorkflowPath) {
    $repoWorkflowText = Get-Content -Path $repoWorkflowPath -Raw
    Add-Check -Scope 'ci-contract' -Name 'repo_workflow_passes_gh_token' -Passed ($repoWorkflowText.Contains('GH_TOKEN: ${{ github.token }}')) -Detail 'GH_TOKEN env'
}

if (Test-Path -Path $containersWorkflowPath) {
    $containersWorkflowText = Get-Content -Path $containersWorkflowPath -Raw
    Add-Check -Scope 'ci-contract' -Name 'containers_workflow_passes_gh_token' -Passed ($containersWorkflowText.Contains('GH_TOKEN: ${{ github.token }}')) -Detail 'GH_TOKEN env'
}

$report = [ordered]@{
    timestamp_utc = (Get-Date).ToUniversalTime().ToString('o')
    workspace_root = $WorkspaceRoot
    fail_on_warning = [bool]$FailOnWarning
    summary = [ordered]@{
        checks = $checks.Count
        failures = $failures.Count
        warnings = $warnings.Count
    }
    checks = $checks
    failures = $failures
    warnings = $warnings
}

$report | ConvertTo-Json -Depth 12 | Write-Output

if ($failures.Count -gt 0) {
    exit 1
}
if ($FailOnWarning -and $warnings.Count -gt 0) {
    exit 1
}

exit 0
