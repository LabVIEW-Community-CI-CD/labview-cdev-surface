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
        $releaseClient.ops_control_plane_policy.schema_version | Should -Be '2.0'
        $releaseClient.ops_control_plane_policy.slo_gate.lookback_days | Should -Be 7
        $releaseClient.ops_control_plane_policy.slo_gate.min_success_rate_pct | Should -Be 100
        $releaseClient.ops_control_plane_policy.slo_gate.max_sync_guard_age_hours | Should -Be 12
        $releaseClient.ops_control_plane_policy.slo_gate.alert_thresholds.warning_min_success_rate_pct | Should -Be 99.5
        $releaseClient.ops_control_plane_policy.slo_gate.alert_thresholds.critical_min_success_rate_pct | Should -Be 99
        @($releaseClient.ops_control_plane_policy.slo_gate.alert_thresholds.warning_reason_codes) | Should -Contain 'workflow_missing_runs'
        @($releaseClient.ops_control_plane_policy.slo_gate.alert_thresholds.warning_reason_codes) | Should -Contain 'workflow_success_rate_below_threshold'
        @($releaseClient.ops_control_plane_policy.slo_gate.alert_thresholds.critical_reason_codes) | Should -Contain 'workflow_failure_detected'
        @($releaseClient.ops_control_plane_policy.slo_gate.alert_thresholds.critical_reason_codes) | Should -Contain 'sync_guard_missing'
        @($releaseClient.ops_control_plane_policy.slo_gate.alert_thresholds.critical_reason_codes) | Should -Contain 'sync_guard_stale'
        @($releaseClient.ops_control_plane_policy.slo_gate.alert_thresholds.critical_reason_codes) | Should -Contain 'slo_gate_runtime_error'
        $releaseClient.ops_control_plane_policy.error_budget.window_days | Should -Be 7
        $releaseClient.ops_control_plane_policy.error_budget.max_failed_runs | Should -Be 0
        $releaseClient.ops_control_plane_policy.error_budget.max_failure_rate_pct | Should -Be 0
        $releaseClient.ops_control_plane_policy.error_budget.critical_burn_rate_pct | Should -Be 100
        $releaseClient.ops_control_plane_policy.state_machine.version | Should -Be '1.0'
        $releaseClient.ops_control_plane_policy.state_machine.initial_state | Should -Be 'ops_health_preflight'
        @($releaseClient.ops_control_plane_policy.state_machine.terminal_states) | Should -Contain 'completed'
        @($releaseClient.ops_control_plane_policy.state_machine.terminal_states) | Should -Contain 'failed'
        $releaseClient.ops_control_plane_policy.state_machine.transitions.ops_health_preflight.on_pass | Should -Be 'release_dispatch'
        $releaseClient.ops_control_plane_policy.state_machine.transitions.ops_health_preflight.on_fail | Should -Be 'auto_remediation'
        $releaseClient.ops_control_plane_policy.rollback_orchestration.enabled | Should -BeTrue
        @($releaseClient.ops_control_plane_policy.rollback_orchestration.trigger_reason_codes) | Should -Contain 'release_dispatch_watch_timeout'
        @($releaseClient.ops_control_plane_policy.rollback_orchestration.trigger_reason_codes) | Should -Contain 'release_verification_failed'
        @($releaseClient.ops_control_plane_policy.slo_gate.required_workflows) | Should -Contain 'ops-monitoring'
        @($releaseClient.ops_control_plane_policy.slo_gate.required_workflows) | Should -Contain 'ops-autoremediate'
        @($releaseClient.ops_control_plane_policy.slo_gate.required_workflows) | Should -Contain 'release-control-plane'
        $releaseClient.ops_control_plane_policy.incident_lifecycle.auto_close_on_recovery | Should -BeTrue
        $releaseClient.ops_control_plane_policy.incident_lifecycle.reopen_on_regression | Should -BeTrue
        $releaseClient.ops_control_plane_policy.tag_strategy.mode | Should -Be 'dual-mode-semver-preferred'
        $releaseClient.ops_control_plane_policy.tag_strategy.legacy_tag_family | Should -Be 'legacy_date_window'
        ([DateTime]$releaseClient.ops_control_plane_policy.tag_strategy.semver_only_enforce_utc).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') | Should -Be '2026-07-01T00:00:00Z'
        ([DateTime]$releaseClient.ops_control_plane_policy.tag_strategy.semver_only_enforce_utc).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') | Should -Be (([DateTime]$releaseClient.signature_policy.grace_end_utc).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'))
        @($releaseClient.ops_control_plane_policy.stable_promotion_window.full_cycle_allowed_utc_weekdays) | Should -Contain 'Monday'
        $releaseClient.ops_control_plane_policy.stable_promotion_window.allow_outside_window_with_override | Should -BeTrue
        $releaseClient.ops_control_plane_policy.stable_promotion_window.override_reason_required | Should -BeTrue
        $releaseClient.ops_control_plane_policy.stable_promotion_window.override_reason_min_length | Should -Be 12
        ([string]$releaseClient.ops_control_plane_policy.stable_promotion_window.override_reason_pattern) | Should -Match '\?<reference>'
        ([string]$releaseClient.ops_control_plane_policy.stable_promotion_window.override_reason_pattern) | Should -Match '\?<summary>'
        ([string]$releaseClient.ops_control_plane_policy.stable_promotion_window.override_reason_example) | Should -Match '^CHG-'
        @($releaseClient.ops_control_plane_policy.incident_lifecycle.titles) | Should -Contain 'Ops SLO Gate Alert'
        @($releaseClient.ops_control_plane_policy.incident_lifecycle.titles) | Should -Contain 'Ops Policy Drift Alert'
        @($releaseClient.ops_control_plane_policy.incident_lifecycle.titles) | Should -Contain 'Release Guardrails Auto-Remediation Alert'
        @($releaseClient.ops_control_plane_policy.incident_lifecycle.titles) | Should -Contain 'Release Rollback Drill Alert'
        @($releaseClient.ops_control_plane_policy.incident_lifecycle.titles) | Should -Contain 'Workflow Bot Token Health Alert'
        $releaseClient.ops_control_plane_policy.self_healing.enabled | Should -BeTrue
        $releaseClient.ops_control_plane_policy.self_healing.max_attempts | Should -Be 1
        $releaseClient.ops_control_plane_policy.self_healing.slo_gate.remediation_workflow | Should -Be 'ops-autoremediate.yml'
        $releaseClient.ops_control_plane_policy.self_healing.slo_gate.watch_timeout_minutes | Should -Be 45
        $releaseClient.ops_control_plane_policy.self_healing.slo_gate.verify_after_remediation | Should -BeTrue
        $releaseClient.ops_control_plane_policy.self_healing.guardrails.remediation_workflow | Should -Be 'release-guardrails-autoremediate.yml'
        $releaseClient.ops_control_plane_policy.self_healing.guardrails.race_drill_workflow | Should -Be 'release-race-hardening-drill.yml'
        $releaseClient.ops_control_plane_policy.self_healing.guardrails.watch_timeout_minutes | Should -Be 120
        $releaseClient.ops_control_plane_policy.self_healing.guardrails.verify_after_remediation | Should -BeTrue
        $releaseClient.ops_control_plane_policy.self_healing.guardrails.race_gate_max_age_hours | Should -Be 168
        $releaseClient.ops_control_plane_policy.self_healing.rollback_drill.release_workflow | Should -Be 'release-workspace-installer.yml'
        $releaseClient.ops_control_plane_policy.self_healing.rollback_drill.release_branch | Should -Be 'main'
        $releaseClient.ops_control_plane_policy.self_healing.rollback_drill.watch_timeout_minutes | Should -Be 120
        $releaseClient.ops_control_plane_policy.self_healing.rollback_drill.verify_after_remediation | Should -BeTrue
        $releaseClient.ops_control_plane_policy.self_healing.rollback_drill.canary_sequence_min | Should -Be 1
        $releaseClient.ops_control_plane_policy.self_healing.rollback_drill.canary_sequence_max | Should -Be 49
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
        $script:policyScriptContent | Should -Match 'ops_policy_schema_version'
        $script:policyScriptContent | Should -Match 'ops_policy_slo_min_success_rate_pct'
        $script:policyScriptContent | Should -Match 'ops_policy_slo_alert_thresholds_warning_min_success_rate_pct'
        $script:policyScriptContent | Should -Match 'ops_policy_slo_alert_thresholds_critical_reason_slo_gate_runtime_error'
        $script:policyScriptContent | Should -Match 'ops_policy_error_budget_window_days'
        $script:policyScriptContent | Should -Match 'ops_policy_state_machine_version'
        $script:policyScriptContent | Should -Match 'ops_policy_rollback_orchestration_enabled'
        $script:policyScriptContent | Should -Match 'ops_policy_tag_strategy_semver_only_enforce'
        $script:policyScriptContent | Should -Match 'ops_policy_stable_window_full_cycle_weekday_monday'
        $script:policyScriptContent | Should -Match 'ops_policy_stable_window_reason_pattern_exists'
        $script:policyScriptContent | Should -Match 'ops_policy_stable_window_reason_example'
        $script:policyScriptContent | Should -Match 'ops_policy_self_healing_enabled'
        $script:policyScriptContent | Should -Match 'ops_policy_self_healing_guardrails_workflow'
        $script:policyScriptContent | Should -Match 'ops_policy_self_healing_rollback_workflow'
        $script:policyScriptContent | Should -Match 'ops_policy_rollback_release_limit'
    }

    It 'has parse-safe PowerShell syntax' {
        $tokens = $null
        $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseInput($script:policyScriptContent, [ref]$tokens, [ref]$errors)
        @($errors).Count | Should -Be 0
    }
}
