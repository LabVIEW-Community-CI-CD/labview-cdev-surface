#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter()]
    [string]$WorkspaceRoot = 'C:\dev',

    [Parameter()]
    [switch]$FailOnWarning
)

$ErrorActionPreference = 'Stop'

$manifestPath = Join-Path $WorkspaceRoot 'workspace-governance.json'
$policyPath = Join-Path $WorkspaceRoot 'workspace-governance\release-policy.json'

if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    throw "Manifest not found: $manifestPath"
}

$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json -Depth 100
$checks = @()
$failures = @()
$warnings = @()

function Add-Check {
    param(
        [string]$Name,
        [bool]$Passed,
        [string]$Detail,
        [ValidateSet('error', 'warning')]
        [string]$Severity = 'error'
    )

    $entry = [ordered]@{
        name = $Name
        passed = $Passed
        detail = $Detail
        severity = $Severity
    }
    $script:checks += [pscustomobject]$entry

    if (-not $Passed) {
        if ($Severity -eq 'warning') {
            $script:warnings += "$Name :: $Detail"
        } else {
            $script:failures += "$Name :: $Detail"
        }
    }
}

$releaseClient = $null
if ($null -ne $manifest.installer_contract) {
    $releaseClient = $manifest.installer_contract.release_client
}

Add-Check -Name 'release_client_exists' -Passed ($null -ne $releaseClient) -Detail 'installer_contract.release_client'

if ($null -ne $releaseClient) {
    Add-Check -Name 'schema_version' -Passed ([string]$releaseClient.schema_version -eq '1.0') -Detail ([string]$releaseClient.schema_version)

    foreach ($repo in @('LabVIEW-Community-CI-CD/labview-cdev-surface', 'svelderrainruiz/labview-cdev-surface')) {
        Add-Check -Name "allowed_repository:$repo" -Passed ((@($releaseClient.allowed_repositories) -contains $repo)) -Detail ([string]::Join(',', @($releaseClient.allowed_repositories)))
    }

    foreach ($channel in @('stable', 'prerelease', 'canary')) {
        Add-Check -Name "allowed_channel:$channel" -Passed ((@($releaseClient.channel_rules.allowed_channels) -contains $channel)) -Detail ([string]::Join(',', @($releaseClient.channel_rules.allowed_channels)))
    }

    Add-Check -Name 'default_channel_stable' -Passed ([string]$releaseClient.channel_rules.default_channel -eq 'stable') -Detail ([string]$releaseClient.channel_rules.default_channel)
    Add-Check -Name 'signature_provider_authenticode' -Passed ([string]$releaseClient.signature_policy.provider -eq 'authenticode') -Detail ([string]$releaseClient.signature_policy.provider)
    Add-Check -Name 'signature_mode_dual_mode' -Passed ([string]$releaseClient.signature_policy.mode -eq 'dual-mode-transition') -Detail ([string]$releaseClient.signature_policy.mode)
    Add-Check -Name 'signature_grace_end' -Passed (([DateTime]$releaseClient.signature_policy.grace_end_utc).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') -eq '2026-07-01T00:00:00Z') -Detail ([string]$releaseClient.signature_policy.grace_end_utc)
    Add-Check -Name 'signature_canary_enforce' -Passed (([DateTime]$releaseClient.signature_policy.canary_enforce_utc).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') -eq '2026-05-15T00:00:00Z') -Detail ([string]$releaseClient.signature_policy.canary_enforce_utc)
    Add-Check -Name 'signature_dual_mode_start' -Passed (([DateTime]$releaseClient.signature_policy.dual_mode_start_utc).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') -eq '2026-03-15T00:00:00Z') -Detail ([string]$releaseClient.signature_policy.dual_mode_start_utc)
    Add-Check -Name 'provenance_required_true' -Passed ([bool]$releaseClient.provenance_required) -Detail ([string]$releaseClient.provenance_required)
    Add-Check -Name 'default_install_root' -Passed ([string]$releaseClient.default_install_root -eq 'C:\dev') -Detail ([string]$releaseClient.default_install_root)
    Add-Check -Name 'upgrade_allow_major_false' -Passed (-not [bool]$releaseClient.upgrade_policy.allow_major_upgrade) -Detail ([string]$releaseClient.upgrade_policy.allow_major_upgrade)
    Add-Check -Name 'upgrade_allow_downgrade_false' -Passed (-not [bool]$releaseClient.upgrade_policy.allow_downgrade) -Detail ([string]$releaseClient.upgrade_policy.allow_downgrade)
    Add-Check -Name 'state_path' -Passed ([string]$releaseClient.state_path -eq 'C:\dev\artifacts\workspace-release-state.json') -Detail ([string]$releaseClient.state_path)
    Add-Check -Name 'latest_report_path' -Passed ([string]$releaseClient.latest_report_path -eq 'C:\dev\artifacts\workspace-release-client-latest.json') -Detail ([string]$releaseClient.latest_report_path)
    Add-Check -Name 'policy_path' -Passed ([string]$releaseClient.policy_path -eq 'C:\dev\workspace-governance\release-policy.json') -Detail ([string]$releaseClient.policy_path)

    Add-Check -Name 'cdev_cli_sync_primary_repo' -Passed ([string]$releaseClient.cdev_cli_sync.primary_repo -eq 'svelderrainruiz/labview-cdev-cli') -Detail ([string]$releaseClient.cdev_cli_sync.primary_repo)
    Add-Check -Name 'cdev_cli_sync_mirror_repo' -Passed ([string]$releaseClient.cdev_cli_sync.mirror_repo -eq 'LabVIEW-Community-CI-CD/labview-cdev-cli') -Detail ([string]$releaseClient.cdev_cli_sync.mirror_repo)
    Add-Check -Name 'cdev_cli_sync_strategy' -Passed ([string]$releaseClient.cdev_cli_sync.strategy -eq 'fork-and-upstream-full-sync') -Detail ([string]$releaseClient.cdev_cli_sync.strategy)
    Add-Check -Name 'runtime_images_exists' -Passed ($null -ne $releaseClient.runtime_images) -Detail 'installer_contract.release_client.runtime_images'
    Add-Check -Name 'runtime_images_cdev_cli_runtime_canonical_repository' -Passed ([string]$releaseClient.runtime_images.cdev_cli_runtime.canonical_repository -eq 'ghcr.io/labview-community-ci-cd/labview-cdev-cli-runtime') -Detail ([string]$releaseClient.runtime_images.cdev_cli_runtime.canonical_repository)
    Add-Check -Name 'runtime_images_cdev_cli_runtime_source_repo' -Passed ([string]$releaseClient.runtime_images.cdev_cli_runtime.source_repo -eq 'LabVIEW-Community-CI-CD/labview-cdev-cli') -Detail ([string]$releaseClient.runtime_images.cdev_cli_runtime.source_repo)
    Add-Check -Name 'runtime_images_cdev_cli_runtime_source_commit' -Passed ([string]$releaseClient.runtime_images.cdev_cli_runtime.source_commit -eq '8fef6f9192d81a14add28636c1100c109ae5e977') -Detail ([string]$releaseClient.runtime_images.cdev_cli_runtime.source_commit)
    Add-Check -Name 'runtime_images_cdev_cli_runtime_digest' -Passed ([string]$releaseClient.runtime_images.cdev_cli_runtime.digest -eq 'sha256:0506e8789680ce1c941ca9f005b75d804150aed6ad36a5ac59458b802d358423') -Detail ([string]$releaseClient.runtime_images.cdev_cli_runtime.digest)
    Add-Check -Name 'runtime_images_ops_runtime_repository' -Passed ([string]$releaseClient.runtime_images.ops_runtime.repository -eq 'ghcr.io/labview-community-ci-cd/labview-cdev-surface-ops') -Detail ([string]$releaseClient.runtime_images.ops_runtime.repository)
    Add-Check -Name 'runtime_images_ops_runtime_base_repository' -Passed ([string]$releaseClient.runtime_images.ops_runtime.base_repository -eq 'ghcr.io/labview-community-ci-cd/labview-cdev-cli-runtime') -Detail ([string]$releaseClient.runtime_images.ops_runtime.base_repository)
    Add-Check -Name 'runtime_images_ops_runtime_base_digest' -Passed ([string]$releaseClient.runtime_images.ops_runtime.base_digest -eq 'sha256:0506e8789680ce1c941ca9f005b75d804150aed6ad36a5ac59458b802d358423') -Detail ([string]$releaseClient.runtime_images.ops_runtime.base_digest)
    Add-Check -Name 'ops_control_plane_policy_exists' -Passed ($null -ne $releaseClient.ops_control_plane_policy) -Detail 'installer_contract.release_client.ops_control_plane_policy'
    Add-Check -Name 'ops_policy_slo_lookback_days' -Passed ([int]$releaseClient.ops_control_plane_policy.slo_gate.lookback_days -eq 7) -Detail ([string]$releaseClient.ops_control_plane_policy.slo_gate.lookback_days)
    Add-Check -Name 'ops_policy_slo_min_success_rate_pct' -Passed ([double]$releaseClient.ops_control_plane_policy.slo_gate.min_success_rate_pct -eq 100) -Detail ([string]$releaseClient.ops_control_plane_policy.slo_gate.min_success_rate_pct)
    Add-Check -Name 'ops_policy_slo_max_sync_guard_age_hours' -Passed ([int]$releaseClient.ops_control_plane_policy.slo_gate.max_sync_guard_age_hours -eq 12) -Detail ([string]$releaseClient.ops_control_plane_policy.slo_gate.max_sync_guard_age_hours)
    Add-Check -Name 'ops_policy_slo_required_workflow_ops_monitoring' -Passed (@($releaseClient.ops_control_plane_policy.slo_gate.required_workflows) -contains 'ops-monitoring') -Detail ([string]::Join(',', @($releaseClient.ops_control_plane_policy.slo_gate.required_workflows)))
    Add-Check -Name 'ops_policy_slo_required_workflow_ops_autoremediate' -Passed (@($releaseClient.ops_control_plane_policy.slo_gate.required_workflows) -contains 'ops-autoremediate') -Detail ([string]::Join(',', @($releaseClient.ops_control_plane_policy.slo_gate.required_workflows)))
    Add-Check -Name 'ops_policy_slo_required_workflow_release_control_plane' -Passed (@($releaseClient.ops_control_plane_policy.slo_gate.required_workflows) -contains 'release-control-plane') -Detail ([string]::Join(',', @($releaseClient.ops_control_plane_policy.slo_gate.required_workflows)))
    Add-Check -Name 'ops_policy_incident_auto_close_on_recovery' -Passed ([bool]$releaseClient.ops_control_plane_policy.incident_lifecycle.auto_close_on_recovery) -Detail ([string]$releaseClient.ops_control_plane_policy.incident_lifecycle.auto_close_on_recovery)
    Add-Check -Name 'ops_policy_incident_reopen_on_regression' -Passed ([bool]$releaseClient.ops_control_plane_policy.incident_lifecycle.reopen_on_regression) -Detail ([string]$releaseClient.ops_control_plane_policy.incident_lifecycle.reopen_on_regression)
    Add-Check -Name 'ops_policy_incident_title_release_control_plane' -Passed (@($releaseClient.ops_control_plane_policy.incident_lifecycle.titles) -contains 'Release Control Plane Alert') -Detail ([string]::Join(',', @($releaseClient.ops_control_plane_policy.incident_lifecycle.titles)))
    Add-Check -Name 'ops_policy_tag_strategy_mode' -Passed ([string]$releaseClient.ops_control_plane_policy.tag_strategy.mode -eq 'dual-mode-semver-preferred') -Detail ([string]$releaseClient.ops_control_plane_policy.tag_strategy.mode)
    Add-Check -Name 'ops_policy_tag_strategy_legacy_tag_family' -Passed ([string]$releaseClient.ops_control_plane_policy.tag_strategy.legacy_tag_family -eq 'legacy_date_window') -Detail ([string]$releaseClient.ops_control_plane_policy.tag_strategy.legacy_tag_family)
    Add-Check -Name 'ops_policy_tag_strategy_semver_only_enforce' -Passed (([DateTime]$releaseClient.ops_control_plane_policy.tag_strategy.semver_only_enforce_utc).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') -eq '2026-07-01T00:00:00Z') -Detail ([string]$releaseClient.ops_control_plane_policy.tag_strategy.semver_only_enforce_utc)
    Add-Check -Name 'ops_policy_tag_strategy_matches_signature_grace_end' -Passed (([DateTime]$releaseClient.ops_control_plane_policy.tag_strategy.semver_only_enforce_utc).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') -eq ([DateTime]$releaseClient.signature_policy.grace_end_utc).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')) -Detail ("semver_only_enforce_utc={0}; signature_grace_end_utc={1}" -f [string]$releaseClient.ops_control_plane_policy.tag_strategy.semver_only_enforce_utc, [string]$releaseClient.signature_policy.grace_end_utc)
    Add-Check -Name 'ops_policy_stable_window_full_cycle_weekday_monday' -Passed (@($releaseClient.ops_control_plane_policy.stable_promotion_window.full_cycle_allowed_utc_weekdays) -contains 'Monday') -Detail ([string]::Join(',', @($releaseClient.ops_control_plane_policy.stable_promotion_window.full_cycle_allowed_utc_weekdays)))
    Add-Check -Name 'ops_policy_stable_window_allow_override' -Passed ([bool]$releaseClient.ops_control_plane_policy.stable_promotion_window.allow_outside_window_with_override) -Detail ([string]$releaseClient.ops_control_plane_policy.stable_promotion_window.allow_outside_window_with_override)
    Add-Check -Name 'ops_policy_stable_window_reason_required' -Passed ([bool]$releaseClient.ops_control_plane_policy.stable_promotion_window.override_reason_required) -Detail ([string]$releaseClient.ops_control_plane_policy.stable_promotion_window.override_reason_required)
    Add-Check -Name 'ops_policy_stable_window_reason_min_length' -Passed ([int]$releaseClient.ops_control_plane_policy.stable_promotion_window.override_reason_min_length -eq 12) -Detail ([string]$releaseClient.ops_control_plane_policy.stable_promotion_window.override_reason_min_length)
    Add-Check -Name 'ops_policy_self_healing_enabled' -Passed ([bool]$releaseClient.ops_control_plane_policy.self_healing.enabled) -Detail ([string]$releaseClient.ops_control_plane_policy.self_healing.enabled)
    Add-Check -Name 'ops_policy_self_healing_max_attempts' -Passed ([int]$releaseClient.ops_control_plane_policy.self_healing.max_attempts -eq 1) -Detail ([string]$releaseClient.ops_control_plane_policy.self_healing.max_attempts)
    Add-Check -Name 'ops_policy_self_healing_slo_workflow' -Passed ([string]$releaseClient.ops_control_plane_policy.self_healing.slo_gate.remediation_workflow -eq 'ops-autoremediate.yml') -Detail ([string]$releaseClient.ops_control_plane_policy.self_healing.slo_gate.remediation_workflow)
    Add-Check -Name 'ops_policy_self_healing_slo_watch_timeout' -Passed ([int]$releaseClient.ops_control_plane_policy.self_healing.slo_gate.watch_timeout_minutes -eq 45) -Detail ([string]$releaseClient.ops_control_plane_policy.self_healing.slo_gate.watch_timeout_minutes)
    Add-Check -Name 'ops_policy_self_healing_slo_verify' -Passed ([bool]$releaseClient.ops_control_plane_policy.self_healing.slo_gate.verify_after_remediation) -Detail ([string]$releaseClient.ops_control_plane_policy.self_healing.slo_gate.verify_after_remediation)
    Add-Check -Name 'ops_policy_self_healing_rollback_workflow' -Passed ([string]$releaseClient.ops_control_plane_policy.self_healing.rollback_drill.release_workflow -eq 'release-workspace-installer.yml') -Detail ([string]$releaseClient.ops_control_plane_policy.self_healing.rollback_drill.release_workflow)
    Add-Check -Name 'ops_policy_self_healing_rollback_branch' -Passed ([string]$releaseClient.ops_control_plane_policy.self_healing.rollback_drill.release_branch -eq 'main') -Detail ([string]$releaseClient.ops_control_plane_policy.self_healing.rollback_drill.release_branch)
    Add-Check -Name 'ops_policy_self_healing_rollback_watch_timeout' -Passed ([int]$releaseClient.ops_control_plane_policy.self_healing.rollback_drill.watch_timeout_minutes -eq 120) -Detail ([string]$releaseClient.ops_control_plane_policy.self_healing.rollback_drill.watch_timeout_minutes)
    Add-Check -Name 'ops_policy_self_healing_rollback_verify' -Passed ([bool]$releaseClient.ops_control_plane_policy.self_healing.rollback_drill.verify_after_remediation) -Detail ([string]$releaseClient.ops_control_plane_policy.self_healing.rollback_drill.verify_after_remediation)
    Add-Check -Name 'ops_policy_self_healing_rollback_canary_min' -Passed ([int]$releaseClient.ops_control_plane_policy.self_healing.rollback_drill.canary_sequence_min -eq 1) -Detail ([string]$releaseClient.ops_control_plane_policy.self_healing.rollback_drill.canary_sequence_min)
    Add-Check -Name 'ops_policy_self_healing_rollback_canary_max' -Passed ([int]$releaseClient.ops_control_plane_policy.self_healing.rollback_drill.canary_sequence_max -eq 49) -Detail ([string]$releaseClient.ops_control_plane_policy.self_healing.rollback_drill.canary_sequence_max)
    Add-Check -Name 'ops_policy_rollback_channel' -Passed ([string]$releaseClient.ops_control_plane_policy.rollback_drill.channel -eq 'canary') -Detail ([string]$releaseClient.ops_control_plane_policy.rollback_drill.channel)
    Add-Check -Name 'ops_policy_rollback_required_history_count' -Passed ([int]$releaseClient.ops_control_plane_policy.rollback_drill.required_history_count -eq 2) -Detail ([string]$releaseClient.ops_control_plane_policy.rollback_drill.required_history_count)
    Add-Check -Name 'ops_policy_rollback_release_limit' -Passed ([int]$releaseClient.ops_control_plane_policy.rollback_drill.release_limit -eq 100) -Detail ([string]$releaseClient.ops_control_plane_policy.rollback_drill.release_limit)

    if ([DateTime]::Parse([string]$releaseClient.signature_policy.dual_mode_start_utc) -gt [DateTime]::Parse([string]$releaseClient.signature_policy.canary_enforce_utc)) {
        Add-Check -Name 'signature_date_order_dual_before_canary' -Passed $false -Detail 'dual_mode_start_utc must be <= canary_enforce_utc'
    } else {
        Add-Check -Name 'signature_date_order_dual_before_canary' -Passed $true -Detail 'ok'
    }

    if ([DateTime]::Parse([string]$releaseClient.signature_policy.canary_enforce_utc) -gt [DateTime]::Parse([string]$releaseClient.signature_policy.grace_end_utc)) {
        Add-Check -Name 'signature_date_order_canary_before_grace_end' -Passed $false -Detail 'canary_enforce_utc must be <= grace_end_utc'
    } else {
        Add-Check -Name 'signature_date_order_canary_before_grace_end' -Passed $true -Detail 'ok'
    }
}

if (-not (Test-Path -LiteralPath $policyPath -PathType Leaf)) {
    Add-Check -Name 'policy_file_exists' -Passed $false -Detail $policyPath -Severity 'warning'
} else {
    Add-Check -Name 'policy_file_exists' -Passed $true -Detail $policyPath
}

$report = [ordered]@{
    timestamp_utc = (Get-Date).ToUniversalTime().ToString('o')
    workspace_root = $WorkspaceRoot
    summary = [ordered]@{
        checks = $checks.Count
        failures = $failures.Count
        warnings = $warnings.Count
    }
    checks = $checks
    failures = $failures
    warnings = $warnings
}

$report | ConvertTo-Json -Depth 20 | Write-Output

if ($failures.Count -gt 0) {
    exit 1
}
if ($FailOnWarning -and $warnings.Count -gt 0) {
    exit 1
}

exit 0
