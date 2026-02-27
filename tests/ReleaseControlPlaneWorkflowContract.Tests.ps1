#Requires -Version 7.0
#Requires -Modules Pester

$ErrorActionPreference = 'Stop'

Describe 'Release control plane workflow contract' {
    BeforeAll {
        $script:repoRoot = (Resolve-Path -Path (Join-Path $PSScriptRoot '..')).Path
        $script:workflowPath = Join-Path $script:repoRoot '.github/workflows/release-control-plane.yml'
        $script:runtimePath = Join-Path $script:repoRoot 'scripts/Invoke-ReleaseControlPlane.ps1'

        if (-not (Test-Path -LiteralPath $script:workflowPath -PathType Leaf)) {
            throw "Release control plane workflow missing: $script:workflowPath"
        }
        if (-not (Test-Path -LiteralPath $script:runtimePath -PathType Leaf)) {
            throw "Release control plane runtime missing: $script:runtimePath"
        }

        $script:workflowContent = Get-Content -LiteralPath $script:workflowPath -Raw
        $script:runtimeContent = Get-Content -LiteralPath $script:runtimePath -Raw
    }

    It 'is scheduled and dispatchable with control inputs' {
        $script:workflowContent | Should -Match 'schedule:'
        $script:workflowContent | Should -Match 'workflow_dispatch:'
        $script:workflowContent | Should -Match 'mode:'
        $script:workflowContent | Should -Match 'FullCycle'
        $script:workflowContent | Should -Match 'auto_remediate'
        $script:workflowContent | Should -Match 'keep_latest_canary_n'
        $script:workflowContent | Should -Match 'watch_timeout_minutes'
        $script:workflowContent | Should -Match 'force_stable_promotion_outside_window'
        $script:workflowContent | Should -Match 'force_stable_promotion_reason'
        $script:workflowContent | Should -Match 'dry_run'
    }

    It 'runs autonomous control-plane runtime and uploads report' {
        $script:workflowContent | Should -Match 'runs-on:\s*ubuntu-latest'
        $script:workflowContent | Should -Match 'concurrency:'
        $script:workflowContent | Should -Match 'group:\s*release-control-plane-\$\{\{\s*github\.repository\s*\}\}-\$\{\{\s*github\.ref_name\s*\}\}'
        $script:workflowContent | Should -Match 'cancel-in-progress:\s*false'
        $script:workflowContent | Should -Match 'Enforce hosted-runner lock'
        $script:workflowContent | Should -Match 'RUNNER_ENVIRONMENT'
        $script:workflowContent | Should -Match 'hosted_runner_required'
        $script:workflowContent | Should -Match 'Invoke-ReleaseControlPlane\.ps1'
        $script:workflowContent | Should -Match 'Invoke-OpsIncidentLifecycle\.ps1'
        $script:workflowContent | Should -Match 'release-control-plane-report\.json'
        $script:workflowContent | Should -Match 'release-control-plane-override-audit\.json'
        $script:workflowContent | Should -Match 'Release Control Plane Stable Override Alert'
        $script:workflowContent | Should -Match 'Release Control Plane Alert'
        $script:workflowContent | Should -Match '-Mode Fail'
        $script:workflowContent | Should -Match '-Mode Recover'
        $script:workflowContent | Should -Match 'actions:\s*write'
        $script:workflowContent | Should -Match 'contents:\s*write'
    }

    It 'implements mode sequencing, semver promotion guards, and semver tag planning' {
        $script:runtimeContent | Should -Match "ValidateSet\('Validate', 'CanaryCycle', 'PromotePrerelease', 'PromoteStable', 'FullCycle'\)"
        $script:runtimeContent | Should -Match 'Resolve-CanaryTargetSemVer'
        $script:runtimeContent | Should -Match 'Resolve-PromotedTargetSemVer'
        $script:runtimeContent | Should -Match 'Get-ReleasePlanningState'
        $script:runtimeContent | Should -Match 'Resolve-TargetPlanForMode'
        $script:runtimeContent | Should -Match 'Get-ReleaseByTagOrNull'
        $script:runtimeContent | Should -Match 'Resolve-SemVerEnforcementPolicy'
        $script:runtimeContent | Should -Match 'Resolve-StablePromotionWindowPolicy'
        $script:runtimeContent | Should -Match 'Resolve-StablePromotionWindowDecision'
        $script:runtimeContent | Should -Match 'Write-StableOverrideAuditReport'
        $script:runtimeContent | Should -Match 'Resolve-ControlPlaneFailureReasonCode'
        $script:runtimeContent | Should -Match 'Verify-DispatchedRelease'
        $script:runtimeContent | Should -Match 'Verify-PromotionLineage'
        $script:runtimeContent | Should -Match 'AllowEmptyCollection'
        $script:runtimeContent | Should -Match 'tag_strategy = ''semver'''
        $script:runtimeContent | Should -Match 'semver_only_enforce_utc'
        $script:runtimeContent | Should -Match 'semver_only_enforcement_violation'
        $script:runtimeContent | Should -Match 'semver_prerelease_sequence_exhausted'
        $script:runtimeContent | Should -Match 'release_tag_collision_retry_exhausted'
        $script:runtimeContent | Should -Match 'release_dispatch_attempts_exhausted'
        $script:runtimeContent | Should -Match 'release_dispatch_report_invalid'
        $script:runtimeContent | Should -Match 'release_watch_timeout'
        $script:runtimeContent | Should -Match 'release_dispatch_watch_timeout'
        $script:runtimeContent | Should -Match '\[release_tag_collision\]'
        $script:runtimeContent | Should -Match 'release_watch_not_success'
        $script:runtimeContent | Should -Match 'release_verification_asset_missing'
        $script:runtimeContent | Should -Match 'release_verification_manifest_channel_mismatch'
        $script:runtimeContent | Should -Match 'release_verification_failed'
        $script:runtimeContent | Should -Match 'promotion_lineage_invalid'
        $script:runtimeContent | Should -Match 'promotion_source_missing'
        $script:runtimeContent | Should -Match 'promotion_source_asset_missing'
        $script:runtimeContent | Should -Match 'promotion_source_not_at_head'
        $script:runtimeContent | Should -Match 'stable_window_closed'
        $script:runtimeContent | Should -Match 'stable_window_override_applied'
        $script:runtimeContent | Should -Match 'stable_window_override_invalid'
        $script:runtimeContent | Should -Match 'stable_window_override_reason_format_invalid'
        $script:runtimeContent | Should -Match 'stable_already_published'
        $script:runtimeContent | Should -Match '\[tag_migration_warning\]'
        $script:runtimeContent | Should -Match "tag_family = 'semver'"
        $script:runtimeContent | Should -Match '-TagFamily semver'
        $script:runtimeContent | Should -Match 'Invoke-CanarySmokeTagHygiene\.ps1'
        $script:runtimeContent | Should -Match '\$dispatchInputs = @\('
        $script:runtimeContent | Should -Match '-Inputs \$dispatchInputs'
        $script:workflowContent | Should -Match '-WatchTimeoutMinutes \$watchTimeoutMinutes'
    }

    It 'decouples control-plane runner health gate to release-runner labels' {
        $script:runtimeContent | Should -Match 'RequiredRunnerLabelsCsv \$releaseRunnerLabelsCsv'
        $script:runtimeContent | Should -Match "self-hosted', 'windows', 'self-hosted-windows-lv"
        $script:runtimeContent | Should -Not -Match 'windows-containers'
        $script:runtimeContent | Should -Not -Match 'user-session'
        $script:runtimeContent | Should -Not -Match 'cdev-surface-windows-gate'
    }
}
