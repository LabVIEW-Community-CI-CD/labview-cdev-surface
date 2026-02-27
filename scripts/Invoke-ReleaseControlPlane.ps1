#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter()]
    [ValidatePattern('^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$')]
    [string]$Repository = 'LabVIEW-Community-CI-CD/labview-cdev-surface-fork',

    [Parameter()]
    [ValidatePattern('^[A-Za-z0-9._/-]+$')]
    [string]$Branch = 'main',

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$ReleaseWorkflowFile = 'release-workspace-installer.yml',

    [Parameter()]
    [ValidateSet('Validate', 'CanaryCycle', 'PromotePrerelease', 'PromoteStable', 'FullCycle')]
    [string]$Mode = 'FullCycle',

    [Parameter()]
    [ValidateRange(1, 168)]
    [int]$SyncGuardMaxAgeHours = 12,

    [Parameter()]
    [ValidateRange(1, 10)]
    [int]$KeepLatestCanaryN = 1,

    [Parameter()]
    [bool]$AutoRemediate = $true,

    [Parameter()]
    [ValidateRange(5, 240)]
    [int]$WatchTimeoutMinutes = 120,

    [Parameter()]
    [switch]$DryRun,

    [Parameter()]
    [bool]$ForceStablePromotionOutsideWindow = $false,

    [Parameter()]
    [string]$ForceStablePromotionReason = '',

    [Parameter()]
    [string]$OverrideAuditOutputPath = '',

    [Parameter()]
    [string]$OutputPath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'lib/WorkflowOps.Common.ps1')

$opsSnapshotScript = Join-Path $PSScriptRoot 'Invoke-OpsMonitoringSnapshot.ps1'
$opsRemediateScript = Join-Path $PSScriptRoot 'Invoke-OpsAutoRemediation.ps1'
$dispatchWorkflowScript = Join-Path $PSScriptRoot 'Dispatch-WorkflowAtRemoteHead.ps1'
$watchWorkflowScript = Join-Path $PSScriptRoot 'Watch-WorkflowRun.ps1'
$canaryHygieneScript = Join-Path $PSScriptRoot 'Invoke-CanarySmokeTagHygiene.ps1'
$rollbackSelfHealingScript = Join-Path $PSScriptRoot 'Invoke-RollbackDrillSelfHealing.ps1'
$releaseRunnerLabels = @('self-hosted', 'windows', 'self-hosted-windows-lv')
$releaseRunnerLabelsCsv = [string]::Join(',', $releaseRunnerLabels)

foreach ($requiredScript in @($opsSnapshotScript, $opsRemediateScript, $dispatchWorkflowScript, $watchWorkflowScript, $canaryHygieneScript, $rollbackSelfHealingScript)) {
    if (-not (Test-Path -LiteralPath $requiredScript -PathType Leaf)) {
        throw "required_script_missing: $requiredScript"
    }
}

function Resolve-SemVerEnforcementPolicy {
    param(
        [Parameter(Mandatory = $true)][string]$ManifestPath,
        [Parameter(Mandatory = $true)][DateTimeOffset]$FallbackEnforceUtc
    )

    $warnings = [System.Collections.Generic.List[string]]::new()
    $policy = [ordered]@{
        semver_only_enforce_utc = $FallbackEnforceUtc
        source = 'default'
        warnings = @()
    }

    if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) {
        [void]$warnings.Add("workspace_governance_missing: path=$ManifestPath")
        $policy.warnings = @($warnings)
        return $policy
    }

    try {
        $manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json -Depth 100
        $candidateValue = $manifest.installer_contract.release_client.ops_control_plane_policy.tag_strategy.semver_only_enforce_utc
        if ($null -eq $candidateValue) {
            [void]$warnings.Add("semver_only_enforce_utc_missing: path=$ManifestPath")
            $policy.warnings = @($warnings)
            return $policy
        }

        if ($candidateValue -is [DateTimeOffset]) {
            $policy.semver_only_enforce_utc = ([DateTimeOffset]$candidateValue).ToUniversalTime()
            $policy.source = 'workspace_governance'
            $policy.warnings = @($warnings)
            return $policy
        }

        if ($candidateValue -is [DateTime]) {
            $candidateDate = [DateTime]$candidateValue
            if ($candidateDate.Kind -eq [DateTimeKind]::Unspecified) {
                $candidateDate = [DateTime]::SpecifyKind($candidateDate, [DateTimeKind]::Utc)
            }
            $policy.semver_only_enforce_utc = ([DateTimeOffset]$candidateDate).ToUniversalTime()
            $policy.source = 'workspace_governance'
            $policy.warnings = @($warnings)
            return $policy
        }

        $candidate = [string]$candidateValue
        if ([string]::IsNullOrWhiteSpace($candidate)) {
            [void]$warnings.Add("semver_only_enforce_utc_missing: path=$ManifestPath")
            $policy.warnings = @($warnings)
            return $policy
        }

        $parsed = [DateTimeOffset]::MinValue
        $parseStyles = [Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal
        if (-not [DateTimeOffset]::TryParse($candidate, [Globalization.CultureInfo]::InvariantCulture, $parseStyles, [ref]$parsed)) {
            [void]$warnings.Add("semver_only_enforce_utc_invalid: value=$candidate")
            $policy.warnings = @($warnings)
            return $policy
        }

        $policy.semver_only_enforce_utc = $parsed
        $policy.source = 'workspace_governance'
    } catch {
        [void]$warnings.Add("semver_policy_load_failed: $([string]$_.Exception.Message)")
    }

    $policy.warnings = @($warnings)
    return $policy
}

function Resolve-StablePromotionWindowPolicy {
    param(
        [Parameter(Mandatory = $true)][string]$ManifestPath
    )

    $warnings = [System.Collections.Generic.List[string]]::new()
    $validWeekdays = @('Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday')
    $policy = [ordered]@{
        full_cycle_allowed_utc_weekdays = @('Monday')
        allow_outside_window_with_override = $true
        override_reason_required = $true
        override_reason_min_length = 12
        override_reason_pattern = '^(?<reference>(?i:(?:CHG|INC|RFC|PR|TASK)-\d{3,}|#\d+))\s*[:\-]\s*(?<summary>.+\S)$'
        override_reason_example = 'CHG-1234: emergency stable promotion after incident remediation'
        source = 'default'
        warnings = @()
    }

    if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) {
        [void]$warnings.Add("workspace_governance_missing: path=$ManifestPath")
        $policy.warnings = @($warnings)
        return $policy
    }

    try {
        $manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json -Depth 100
        $candidateWindow = $manifest.installer_contract.release_client.ops_control_plane_policy.stable_promotion_window
        if ($null -eq $candidateWindow) {
            [void]$warnings.Add("stable_promotion_window_missing: path=$ManifestPath")
            $policy.warnings = @($warnings)
            return $policy
        }

        $policy.source = 'workspace_governance'

        $candidateWeekdays = @($candidateWindow.full_cycle_allowed_utc_weekdays)
        $normalizedWeekdays = [System.Collections.Generic.List[string]]::new()
        foreach ($candidateWeekday in @($candidateWeekdays)) {
            $value = ([string]$candidateWeekday).Trim()
            if ([string]::IsNullOrWhiteSpace($value)) {
                continue
            }

            $canonical = @(
                $validWeekdays |
                    Where-Object { [string]::Equals([string]$_, $value, [System.StringComparison]::OrdinalIgnoreCase) } |
                    Select-Object -First 1
            )
            if (@($canonical).Count -eq 1) {
                $day = [string]$canonical[0]
                if (-not $normalizedWeekdays.Contains($day)) {
                    [void]$normalizedWeekdays.Add($day)
                }
            } else {
                [void]$warnings.Add("stable_promotion_window_invalid_weekday: value=$value")
            }
        }
        if ($normalizedWeekdays.Count -gt 0) {
            $policy.full_cycle_allowed_utc_weekdays = @($normalizedWeekdays)
        } else {
            [void]$warnings.Add('stable_promotion_window_weekdays_missing_or_invalid')
        }

        $allowOverride = $candidateWindow.allow_outside_window_with_override
        if ($allowOverride -is [bool]) {
            $policy.allow_outside_window_with_override = [bool]$allowOverride
        } elseif ($null -ne $allowOverride) {
            $parsedAllowOverride = $false
            $allowOverrideParsed = $false
            try {
                $parsedAllowOverride = [System.Convert]::ToBoolean([string]$allowOverride, [Globalization.CultureInfo]::InvariantCulture)
                $allowOverrideParsed = $true
            } catch {
                $allowOverrideParsed = $false
            }

            if ($allowOverrideParsed) {
                $policy.allow_outside_window_with_override = $parsedAllowOverride
            } else {
                [void]$warnings.Add("stable_promotion_window_allow_override_invalid: value=$allowOverride")
            }
        } else {
            [void]$warnings.Add('stable_promotion_window_allow_override_missing')
        }

        $reasonRequired = $candidateWindow.override_reason_required
        if ($reasonRequired -is [bool]) {
            $policy.override_reason_required = [bool]$reasonRequired
        } elseif ($null -ne $reasonRequired) {
            $parsedReasonRequired = $false
            $reasonRequiredParsed = $false
            try {
                $parsedReasonRequired = [System.Convert]::ToBoolean([string]$reasonRequired, [Globalization.CultureInfo]::InvariantCulture)
                $reasonRequiredParsed = $true
            } catch {
                $reasonRequiredParsed = $false
            }

            if ($reasonRequiredParsed) {
                $policy.override_reason_required = $parsedReasonRequired
            } else {
                [void]$warnings.Add("stable_promotion_window_reason_required_invalid: value=$reasonRequired")
            }
        } else {
            [void]$warnings.Add('stable_promotion_window_reason_required_missing')
        }

        $reasonMinLength = $candidateWindow.override_reason_min_length
        if ($null -ne $reasonMinLength) {
            $parsedMinLength = -1
            if ([int]::TryParse(([string]$reasonMinLength).Trim(), [ref]$parsedMinLength) -and $parsedMinLength -ge 0 -and $parsedMinLength -le 512) {
                $policy.override_reason_min_length = $parsedMinLength
            } else {
                [void]$warnings.Add("stable_promotion_window_reason_min_length_invalid: value=$reasonMinLength")
            }
        } else {
            [void]$warnings.Add('stable_promotion_window_reason_min_length_missing')
        }

        $reasonPattern = [string]$candidateWindow.override_reason_pattern
        if ([string]::IsNullOrWhiteSpace($reasonPattern)) {
            [void]$warnings.Add('stable_promotion_window_reason_pattern_missing')
        } else {
            try {
                [void][regex]::new($reasonPattern)
                $policy.override_reason_pattern = $reasonPattern
            } catch {
                [void]$warnings.Add("stable_promotion_window_reason_pattern_invalid: value=$reasonPattern")
            }
        }

        $reasonExample = [string]$candidateWindow.override_reason_example
        if ([string]::IsNullOrWhiteSpace($reasonExample)) {
            [void]$warnings.Add('stable_promotion_window_reason_example_missing')
        } else {
            $policy.override_reason_example = $reasonExample.Trim()
        }
    } catch {
        [void]$warnings.Add("stable_promotion_window_policy_load_failed: $([string]$_.Exception.Message)")
    }

    $policy.warnings = @($warnings)
    return $policy
}

function Resolve-ControlPlaneGaPolicy {
    param(
        [Parameter(Mandatory = $true)][string]$ManifestPath
    )

    $warnings = [System.Collections.Generic.List[string]]::new()
    $policy = [ordered]@{
        schema_version = '2.0'
        source = 'default'
        warnings = @()
        state_machine = [ordered]@{
            version = '1.0'
            initial_state = 'ops_health_preflight'
            terminal_states = @('completed', 'failed')
        }
        rollback_orchestration = [ordered]@{
            enabled = $true
            run_on_dry_run = $false
            trigger_reason_codes = @(
                'ops_health_gate_failed',
                'ops_unhealthy',
                'release_dispatch_watch_timeout',
                'release_dispatch_watch_failed',
                'release_dispatch_attempts_exhausted',
                'release_verification_failed'
            )
        }
        rollback_drill = [ordered]@{
            channel = 'canary'
            required_history_count = 2
            release_limit = 100
            release_workflow = 'release-workspace-installer.yml'
            release_branch = 'main'
            watch_timeout_minutes = 120
            canary_sequence_min = 1
            canary_sequence_max = 49
            max_attempts = 1
        }
    }

    if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) {
        [void]$warnings.Add("workspace_governance_missing: path=$ManifestPath")
        $policy.warnings = @($warnings)
        return $policy
    }

    try {
        $manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json -Depth 100
        $candidatePolicy = $manifest.installer_contract.release_client.ops_control_plane_policy
        if ($null -eq $candidatePolicy) {
            [void]$warnings.Add("ops_control_plane_policy_missing: path=$ManifestPath")
            $policy.warnings = @($warnings)
            return $policy
        }

        $policy.source = 'workspace_governance'

        $candidateSchema = [string]$candidatePolicy.schema_version
        if (-not [string]::IsNullOrWhiteSpace($candidateSchema)) {
            $policy.schema_version = $candidateSchema.Trim()
        } else {
            [void]$warnings.Add('ops_control_plane_policy_schema_version_missing')
        }

        $candidateStateMachine = $candidatePolicy.state_machine
        if ($null -eq $candidateStateMachine) {
            [void]$warnings.Add('ops_control_plane_policy_state_machine_missing')
        } else {
            $candidateStateMachineVersion = [string]$candidateStateMachine.version
            if (-not [string]::IsNullOrWhiteSpace($candidateStateMachineVersion)) {
                $policy.state_machine.version = $candidateStateMachineVersion.Trim()
            } else {
                [void]$warnings.Add('ops_control_plane_policy_state_machine_version_missing')
            }

            $candidateInitialState = [string]$candidateStateMachine.initial_state
            if (-not [string]::IsNullOrWhiteSpace($candidateInitialState)) {
                $policy.state_machine.initial_state = $candidateInitialState.Trim()
            } else {
                [void]$warnings.Add('ops_control_plane_policy_state_machine_initial_state_missing')
            }

            $candidateTerminalStates = @($candidateStateMachine.terminal_states)
            if (@($candidateTerminalStates).Count -gt 0) {
                $policy.state_machine.terminal_states = @(
                    $candidateTerminalStates |
                        ForEach-Object { ([string]$_).Trim() } |
                        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                        Select-Object -Unique
                )
            } else {
                [void]$warnings.Add('ops_control_plane_policy_state_machine_terminal_states_missing')
            }
        }

        $candidateRollbackOrchestration = $candidatePolicy.rollback_orchestration
        if ($null -eq $candidateRollbackOrchestration) {
            [void]$warnings.Add('ops_control_plane_policy_rollback_orchestration_missing')
        } else {
            if ($candidateRollbackOrchestration.enabled -is [bool]) {
                $policy.rollback_orchestration.enabled = [bool]$candidateRollbackOrchestration.enabled
            }
            if ($candidateRollbackOrchestration.run_on_dry_run -is [bool]) {
                $policy.rollback_orchestration.run_on_dry_run = [bool]$candidateRollbackOrchestration.run_on_dry_run
            }

            $candidateTriggerReasonCodes = @($candidateRollbackOrchestration.trigger_reason_codes)
            if (@($candidateTriggerReasonCodes).Count -gt 0) {
                $policy.rollback_orchestration.trigger_reason_codes = @(
                    $candidateTriggerReasonCodes |
                        ForEach-Object { ([string]$_).Trim() } |
                        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                        Select-Object -Unique
                )
            } else {
                [void]$warnings.Add('ops_control_plane_policy_rollback_orchestration_trigger_reason_codes_missing')
            }
        }

        $candidateRollbackDrill = $candidatePolicy.rollback_drill
        if ($null -ne $candidateRollbackDrill) {
            $candidateRollbackChannel = [string]$candidateRollbackDrill.channel
            if (-not [string]::IsNullOrWhiteSpace($candidateRollbackChannel)) {
                $policy.rollback_drill.channel = $candidateRollbackChannel.Trim()
            }

            $candidateRequiredHistoryCount = 0
            if ([int]::TryParse([string]$candidateRollbackDrill.required_history_count, [ref]$candidateRequiredHistoryCount) -and $candidateRequiredHistoryCount -ge 2 -and $candidateRequiredHistoryCount -le 100) {
                $policy.rollback_drill.required_history_count = $candidateRequiredHistoryCount
            }

            $candidateReleaseLimit = 0
            if ([int]::TryParse([string]$candidateRollbackDrill.release_limit, [ref]$candidateReleaseLimit) -and $candidateReleaseLimit -ge 10 -and $candidateReleaseLimit -le 200) {
                $policy.rollback_drill.release_limit = $candidateReleaseLimit
            }
        }

        $candidateSelfHealing = $candidatePolicy.self_healing
        if ($null -ne $candidateSelfHealing) {
            $candidateMaxAttempts = 0
            if ([int]::TryParse([string]$candidateSelfHealing.max_attempts, [ref]$candidateMaxAttempts) -and $candidateMaxAttempts -ge 1 -and $candidateMaxAttempts -le 5) {
                $policy.rollback_drill.max_attempts = $candidateMaxAttempts
            }

            $candidateSelfHealingRollback = $candidateSelfHealing.rollback_drill
            if ($null -ne $candidateSelfHealingRollback) {
                $candidateReleaseWorkflow = [string]$candidateSelfHealingRollback.release_workflow
                if (-not [string]::IsNullOrWhiteSpace($candidateReleaseWorkflow)) {
                    $policy.rollback_drill.release_workflow = $candidateReleaseWorkflow.Trim()
                }

                $candidateReleaseBranch = [string]$candidateSelfHealingRollback.release_branch
                if (-not [string]::IsNullOrWhiteSpace($candidateReleaseBranch)) {
                    $policy.rollback_drill.release_branch = $candidateReleaseBranch.Trim()
                }

                $candidateWatchTimeout = 0
                if ([int]::TryParse([string]$candidateSelfHealingRollback.watch_timeout_minutes, [ref]$candidateWatchTimeout) -and $candidateWatchTimeout -ge 5 -and $candidateWatchTimeout -le 240) {
                    $policy.rollback_drill.watch_timeout_minutes = $candidateWatchTimeout
                }

                $candidateCanarySequenceMin = 0
                if ([int]::TryParse([string]$candidateSelfHealingRollback.canary_sequence_min, [ref]$candidateCanarySequenceMin) -and $candidateCanarySequenceMin -ge 1 -and $candidateCanarySequenceMin -le 49) {
                    $policy.rollback_drill.canary_sequence_min = $candidateCanarySequenceMin
                }

                $candidateCanarySequenceMax = 0
                if ([int]::TryParse([string]$candidateSelfHealingRollback.canary_sequence_max, [ref]$candidateCanarySequenceMax) -and $candidateCanarySequenceMax -ge $policy.rollback_drill.canary_sequence_min -and $candidateCanarySequenceMax -le 99) {
                    $policy.rollback_drill.canary_sequence_max = $candidateCanarySequenceMax
                }
            }
        }
    } catch {
        [void]$warnings.Add("ops_control_plane_policy_load_failed: $([string]$_.Exception.Message)")
    }

    $policy.warnings = @($warnings)
    return $policy
}

function Add-ControlPlaneStateTransition {
    param(
        [Parameter(Mandatory = $true)]$StateMachine,
        [Parameter(Mandatory = $true)][string]$FromState,
        [Parameter(Mandatory = $true)][string]$Result,
        [Parameter(Mandatory = $true)][string]$ToState,
        [Parameter()][string]$ReasonCode = '',
        [Parameter()][string]$Detail = ''
    )

    if ($null -eq $StateMachine) {
        return
    }

    $transitions = [System.Collections.Generic.List[object]]::new()
    foreach ($existing in @($StateMachine.transitions_executed)) {
        [void]$transitions.Add($existing)
    }

    [void]$transitions.Add([ordered]@{
            timestamp_utc = Get-UtcNowIso
            from_state = $FromState
            result = $Result
            to_state = $ToState
            reason_code = $ReasonCode
            detail = $Detail
        })

    $StateMachine.transitions_executed = @($transitions)
    $StateMachine.current_state = $ToState
}

function Should-AttemptRollbackOrchestration {
    param(
        [Parameter(Mandatory = $true)][string]$ReasonCode,
        [Parameter(Mandatory = $true)]$Policy,
        [Parameter(Mandatory = $true)][bool]$DryRunEnabled,
        [Parameter(Mandatory = $true)][bool]$AutoRemediateEnabled
    )

    if ($null -eq $Policy) {
        return [ordered]@{
            should_attempt = $false
            decision_reason = 'rollback_policy_missing'
        }
    }

    if (-not [bool]$AutoRemediateEnabled) {
        return [ordered]@{
            should_attempt = $false
            decision_reason = 'auto_remediate_disabled'
        }
    }

    if (-not [bool]$Policy.enabled) {
        return [ordered]@{
            should_attempt = $false
            decision_reason = 'rollback_policy_disabled'
        }
    }

    if ([bool]$DryRunEnabled -and -not [bool]$Policy.run_on_dry_run) {
        return [ordered]@{
            should_attempt = $false
            decision_reason = 'rollback_dry_run_blocked'
        }
    }

    if (@($Policy.trigger_reason_codes) -notcontains [string]$ReasonCode) {
        return [ordered]@{
            should_attempt = $false
            decision_reason = 'rollback_reason_not_allowed'
        }
    }

    return [ordered]@{
        should_attempt = $true
        decision_reason = 'rollback_triggered'
    }
}

function Invoke-ControlPlaneRollbackOrchestration {
    param(
        [Parameter(Mandatory = $true)][string]$TargetRepository,
        [Parameter(Mandatory = $true)][string]$TargetBranch,
        [Parameter(Mandatory = $true)]$RollbackPolicy,
        [Parameter(Mandatory = $true)][string]$ScratchRoot
    )

    $rollbackReportPath = Join-Path $ScratchRoot 'rollback-orchestration-report.json'
    $executionError = ''
    $exitCode = 1

    try {
        & pwsh -NoProfile -File $rollbackSelfHealingScript `
            -Repository $TargetRepository `
            -Branch $TargetBranch `
            -Channel ([string]$RollbackPolicy.channel) `
            -RequiredHistoryCount ([int]$RollbackPolicy.required_history_count) `
            -ReleaseLimit ([int]$RollbackPolicy.release_limit) `
            -AutoRemediate:$true `
            -ReleaseWorkflowFile ([string]$RollbackPolicy.release_workflow) `
            -MaxAttempts ([int]$RollbackPolicy.max_attempts) `
            -WatchTimeoutMinutes ([int]$RollbackPolicy.watch_timeout_minutes) `
            -CanarySequenceMin ([int]$RollbackPolicy.canary_sequence_min) `
            -CanarySequenceMax ([int]$RollbackPolicy.canary_sequence_max) `
            -CanaryTagFamily 'semver' `
            -OutputPath $rollbackReportPath | Out-Null
        $exitCode = if ($null -eq $LASTEXITCODE) { 0 } else { [int]$LASTEXITCODE }
    } catch {
        $executionError = [string]$_.Exception.Message
        $exitCode = 1
    }

    $rollbackReport = $null
    if (Test-Path -LiteralPath $rollbackReportPath -PathType Leaf) {
        $rollbackReport = Get-Content -LiteralPath $rollbackReportPath -Raw | ConvertFrom-Json -ErrorAction Stop
    }

    if ($null -eq $rollbackReport) {
        $rollbackReport = [ordered]@{
            status = 'fail'
            reason_code = 'rollback_orchestration_report_missing'
            message = if ([string]::IsNullOrWhiteSpace($executionError)) { 'rollback orchestration report missing.' } else { $executionError }
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($executionError)) {
        $rollbackReport.status = 'fail'
        $rollbackReport.reason_code = 'rollback_orchestration_runtime_error'
        $rollbackReport.message = $executionError
    }

    return [ordered]@{
        status = if ($exitCode -eq 0 -and [string]$rollbackReport.status -eq 'pass') { 'pass' } else { 'fail' }
        exit_code = $exitCode
        report_path = $rollbackReportPath
        report = $rollbackReport
    }
}

$defaultSemverOnlyEnforceUtc = [DateTimeOffset]::Parse('2026-07-01T00:00:00Z')
$workspaceGovernancePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'workspace-governance.json'
$gaPolicy = Resolve-ControlPlaneGaPolicy -ManifestPath $workspaceGovernancePath
$script:opsControlPlanePolicySchemaVersion = [string]$gaPolicy.schema_version
$script:opsControlPlanePolicySource = [string]$gaPolicy.source
$script:controlPlaneStateMachinePolicy = $gaPolicy.state_machine
$script:rollbackOrchestrationPolicy = $gaPolicy.rollback_orchestration
$script:rollbackDrillPolicy = $gaPolicy.rollback_drill
foreach ($warning in @($gaPolicy.warnings)) {
    Write-Warning "[control_plane_policy_warning] $warning"
}

$semverPolicy = Resolve-SemVerEnforcementPolicy -ManifestPath $workspaceGovernancePath -FallbackEnforceUtc $defaultSemverOnlyEnforceUtc
$script:semverOnlyEnforceUtc = [DateTimeOffset]$semverPolicy.semver_only_enforce_utc
$script:semverPolicySource = [string]$semverPolicy.source
$script:semverOnlyEnforced = ([DateTimeOffset]::UtcNow -ge $script:semverOnlyEnforceUtc)
foreach ($warning in @($semverPolicy.warnings)) {
    Write-Warning "[semver_policy_warning] $warning"
}

$stablePromotionWindowPolicy = Resolve-StablePromotionWindowPolicy -ManifestPath $workspaceGovernancePath
$script:stablePromotionWindowPolicySource = [string]$stablePromotionWindowPolicy.source
$script:stablePromotionFullCycleAllowedUtcWeekdays = @($stablePromotionWindowPolicy.full_cycle_allowed_utc_weekdays)
$script:stablePromotionAllowOutsideWindowWithOverride = [bool]$stablePromotionWindowPolicy.allow_outside_window_with_override
$script:stablePromotionOverrideReasonRequired = [bool]$stablePromotionWindowPolicy.override_reason_required
$script:stablePromotionOverrideReasonMinLength = [int]$stablePromotionWindowPolicy.override_reason_min_length
$script:stablePromotionOverrideReasonPattern = [string]$stablePromotionWindowPolicy.override_reason_pattern
$script:stablePromotionOverrideReasonExample = [string]$stablePromotionWindowPolicy.override_reason_example
foreach ($warning in @($stablePromotionWindowPolicy.warnings)) {
    Write-Warning "[stable_promotion_window_policy_warning] $warning"
}

$script:releaseRequiredAssets = @(
    'lvie-cdev-workspace-installer.exe',
    'lvie-cdev-workspace-installer.exe.sha256',
    'reproducibility-report.json',
    'workspace-installer.spdx.json',
    'workspace-installer.slsa.json',
    'release-manifest.json'
)

$script:releaseManifestRequiredProvenanceAssets = @(
    'workspace-installer.spdx.json',
    'workspace-installer.slsa.json',
    'reproducibility-report.json'
)

function Resolve-ControlPlaneFailureReasonCode {
    param([Parameter()][string]$MessageText = '')

    $message = [string]$MessageText
    if ($message -match '^required_script_missing') { return 'required_script_missing' }
    if ($message -match '^ops_health_gate_failed') { return 'ops_health_gate_failed' }
    if ($message -match '^ops_unhealthy') { return 'ops_unhealthy' }
    if ($message -match '^unsupported_mode_config|^unsupported_release_mode') { return 'unsupported_mode' }
    if ($message -match '^semver_only_enforcement_violation') { return 'semver_only_enforcement_violation' }
    if ($message -match '^promotion_source_missing') { return 'promotion_source_missing' }
    if ($message -match '^promotion_source_not_prerelease') { return 'promotion_source_not_prerelease' }
    if ($message -match '^promotion_source_asset_missing') { return 'promotion_source_asset_missing' }
    if ($message -match '^promotion_source_commit_invalid') { return 'promotion_source_commit_invalid' }
    if ($message -match '^promotion_source_not_at_head') { return 'promotion_source_not_at_head' }
    if ($message -match '^promotion_lineage_invalid') { return 'promotion_lineage_invalid' }
    if ($message -match '^stable_window_override_') { return 'stable_window_override_invalid' }
    if ($message -match '^branch_head_unresolved') { return 'branch_head_unresolved' }
    if ($message -match '^semver_prerelease_sequence_exhausted') { return 'semver_prerelease_sequence_exhausted' }
    if ($message -match '^release_tag_collision_retry_exhausted') { return 'release_tag_collision_retry_exhausted' }
    if ($message -match '^release_dispatch_attempts_exhausted') { return 'release_dispatch_attempts_exhausted' }
    if ($message -match '^release_dispatch_report_invalid') { return 'release_dispatch_report_invalid' }
    if ($message -match '^release_watch_timeout') { return 'release_dispatch_watch_timeout' }
    if ($message -match '^release_watch_failed|^release_watch_not_success') { return 'release_dispatch_watch_failed' }
    if ($message -match '^release_verification_') { return 'release_verification_failed' }
    if ($message -match '^canary_hygiene_failed') { return 'canary_hygiene_failed' }
    if ($message -match '^gh_command_failed') { return 'gh_command_failed' }

    return 'control_plane_runtime_error'
}

function Verify-DispatchedRelease {
    param(
        [Parameter(Mandatory = $true)][string]$TargetTag,
        [Parameter(Mandatory = $true)][string]$ExpectedChannel,
        [Parameter(Mandatory = $true)][bool]$ExpectedIsPrerelease,
        [Parameter(Mandatory = $true)][string]$ModeName,
        [Parameter(Mandatory = $true)][string]$ScratchRoot
    )

    $release = Invoke-GhJson -Arguments @(
        'release', 'view',
        $TargetTag,
        '-R', $Repository,
        '--json', 'tagName,isPrerelease,targetCommitish,publishedAt,assets,url'
    )
    if ($null -eq $release) {
        throw "release_verification_release_missing: tag=$TargetTag"
    }

    $actualTag = [string]$release.tagName
    if ([string]::IsNullOrWhiteSpace($actualTag)) {
        throw "release_verification_tag_missing: tag=$TargetTag"
    }
    if ($actualTag -ne $TargetTag) {
        throw "release_verification_tag_mismatch: expected=$TargetTag actual=$actualTag"
    }
    if ([bool]$release.isPrerelease -ne $ExpectedIsPrerelease) {
        throw "release_verification_prerelease_mismatch: tag=$TargetTag expected=$ExpectedIsPrerelease actual=$([bool]$release.isPrerelease)"
    }

    $parsedTagRecord = Convert-ReleaseToRecord -Release $release
    if ($null -eq $parsedTagRecord -or [string]$parsedTagRecord.tag_family -ne 'semver') {
        throw "release_verification_tag_not_semver: tag=$TargetTag"
    }
    if ([string]$parsedTagRecord.channel -ne $ExpectedChannel) {
        throw "release_verification_tag_channel_mismatch: tag=$TargetTag expected=$ExpectedChannel actual=$([string]$parsedTagRecord.channel)"
    }

    $assetNames = @($release.assets | ForEach-Object { [string]$_.name })
    foreach ($requiredAsset in @($script:releaseRequiredAssets)) {
        if ($assetNames -notcontains $requiredAsset) {
            throw "release_verification_asset_missing: tag=$TargetTag asset=$requiredAsset"
        }
    }

    $manifestDownloadRoot = Join-Path $ScratchRoot "release-manifest-$ModeName-$($TargetTag -replace '[^A-Za-z0-9._-]', '_')"
    New-Item -Path $manifestDownloadRoot -ItemType Directory -Force | Out-Null
    & gh release download $TargetTag -R $Repository -p 'release-manifest.json' -D $manifestDownloadRoot
    $downloadExit = if ($null -eq $LASTEXITCODE) { 0 } else { [int]$LASTEXITCODE }
    if ($downloadExit -ne 0) {
        throw "release_verification_manifest_download_failed: tag=$TargetTag exit_code=$downloadExit"
    }

    $manifestPath = Join-Path $manifestDownloadRoot 'release-manifest.json'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        throw "release_verification_manifest_missing: tag=$TargetTag"
    }

    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json -Depth 100
    if ([string]$manifest.schema_version -ne '1.0') {
        throw "release_verification_manifest_schema_invalid: tag=$TargetTag schema=$([string]$manifest.schema_version)"
    }
    if ([string]$manifest.repository -ne $Repository) {
        throw "release_verification_manifest_repository_mismatch: tag=$TargetTag expected=$Repository actual=$([string]$manifest.repository)"
    }
    if ([string]$manifest.release_tag -ne $TargetTag) {
        throw "release_verification_manifest_tag_mismatch: expected=$TargetTag actual=$([string]$manifest.release_tag)"
    }
    if ([string]$manifest.channel -ne $ExpectedChannel) {
        throw "release_verification_manifest_channel_mismatch: tag=$TargetTag expected=$ExpectedChannel actual=$([string]$manifest.channel)"
    }
    if ([string]$manifest.installer.name -ne 'lvie-cdev-workspace-installer.exe') {
        throw "release_verification_manifest_installer_name_mismatch: tag=$TargetTag actual=$([string]$manifest.installer.name)"
    }
    if ([string]::IsNullOrWhiteSpace([string]$manifest.installer.sha256)) {
        throw "release_verification_manifest_installer_sha_missing: tag=$TargetTag"
    }

    $provenanceAssetNames = @($manifest.provenance.assets | ForEach-Object { [string]$_.name })
    foreach ($requiredProvenanceAsset in @($script:releaseManifestRequiredProvenanceAssets)) {
        if ($provenanceAssetNames -notcontains $requiredProvenanceAsset) {
            throw "release_verification_manifest_provenance_missing: tag=$TargetTag asset=$requiredProvenanceAsset"
        }
    }

    return [ordered]@{
        status = 'pass'
        tag = $TargetTag
        channel = $ExpectedChannel
        tag_family = 'semver'
        core = "{0}.{1}.{2}" -f [int]$parsedTagRecord.major, [int]$parsedTagRecord.minor, [int]$parsedTagRecord.patch
        prerelease_sequence = [int]$parsedTagRecord.prerelease_sequence
        prerelease = $ExpectedIsPrerelease
        target_commitish = [string]$release.targetCommitish
        release_url = [string]$release.url
        published_at_utc = [string]$release.publishedAt
        release_assets_checked = @($script:releaseRequiredAssets)
        manifest_path = $manifestPath
        manifest_channel = [string]$manifest.channel
        manifest_release_tag = [string]$manifest.release_tag
        manifest_provenance_assets_checked = @($script:releaseManifestRequiredProvenanceAssets)
    }
}

function Verify-PromotionLineage {
    param(
        [Parameter(Mandatory = $true)][string]$ModeName,
        [Parameter()][AllowNull()]$SourceRelease,
        [Parameter()][AllowNull()]$ReleaseVerification
    )

    if ($ModeName -ne 'PromotePrerelease' -and $ModeName -ne 'PromoteStable') {
        return [ordered]@{
            status = 'skipped'
            mode = $ModeName
            reason_code = 'not_promotion_mode'
        }
    }

    if ($null -eq $SourceRelease) {
        throw "promotion_lineage_invalid: mode=$ModeName reason=source_release_missing"
    }
    if ($null -eq $ReleaseVerification) {
        throw "promotion_lineage_invalid: mode=$ModeName reason=release_verification_missing"
    }

    $sourceCore = ([string]$SourceRelease.core).Trim()
    $targetCore = ([string]$ReleaseVerification.core).Trim()
    if ([string]::IsNullOrWhiteSpace($sourceCore) -or [string]::IsNullOrWhiteSpace($targetCore)) {
        throw "promotion_lineage_invalid: mode=$ModeName reason=core_missing source_core=$sourceCore target_core=$targetCore"
    }
    if ($sourceCore -ne $targetCore) {
        throw "promotion_lineage_invalid: mode=$ModeName reason=core_mismatch source_core=$sourceCore target_core=$targetCore"
    }

    $sourceSha = ([string]$SourceRelease.source_sha).Trim().ToLowerInvariant()
    $targetSha = ([string]$ReleaseVerification.target_commitish).Trim().ToLowerInvariant()
    if ($sourceSha -notmatch '^[0-9a-f]{40}$') {
        throw "promotion_lineage_invalid: mode=$ModeName reason=source_sha_invalid source_sha=$sourceSha"
    }
    if ($targetSha -notmatch '^[0-9a-f]{40}$') {
        throw "promotion_lineage_invalid: mode=$ModeName reason=target_sha_invalid target_sha=$targetSha"
    }
    if ($sourceSha -ne $targetSha) {
        throw "promotion_lineage_invalid: mode=$ModeName reason=sha_mismatch source_sha=$sourceSha target_sha=$targetSha"
    }

    $sourceChannel = [string]$SourceRelease.channel
    $targetChannel = [string]$ReleaseVerification.channel
    $sourcePrereleaseSequence = [int]$SourceRelease.prerelease_sequence
    $targetPrereleaseSequence = [int]$ReleaseVerification.prerelease_sequence
    $targetIsPrerelease = [bool]$ReleaseVerification.prerelease

    if ($ModeName -eq 'PromotePrerelease') {
        if ($sourceChannel -ne 'canary') {
            throw "promotion_lineage_invalid: mode=$ModeName reason=source_channel_invalid source_channel=$sourceChannel"
        }
        if ($targetChannel -ne 'prerelease') {
            throw "promotion_lineage_invalid: mode=$ModeName reason=target_channel_invalid target_channel=$targetChannel"
        }
        if (-not $targetIsPrerelease) {
            throw "promotion_lineage_invalid: mode=$ModeName reason=target_prerelease_false"
        }
        if ($sourcePrereleaseSequence -lt 1) {
            throw "promotion_lineage_invalid: mode=$ModeName reason=source_sequence_invalid source_sequence=$sourcePrereleaseSequence"
        }
        if ($targetPrereleaseSequence -lt 1) {
            throw "promotion_lineage_invalid: mode=$ModeName reason=target_sequence_invalid target_sequence=$targetPrereleaseSequence"
        }
    }

    if ($ModeName -eq 'PromoteStable') {
        if ($sourceChannel -ne 'prerelease') {
            throw "promotion_lineage_invalid: mode=$ModeName reason=source_channel_invalid source_channel=$sourceChannel"
        }
        if ($targetChannel -ne 'stable') {
            throw "promotion_lineage_invalid: mode=$ModeName reason=target_channel_invalid target_channel=$targetChannel"
        }
        if ($targetIsPrerelease) {
            throw "promotion_lineage_invalid: mode=$ModeName reason=target_prerelease_true"
        }
        if ($sourcePrereleaseSequence -lt 1) {
            throw "promotion_lineage_invalid: mode=$ModeName reason=source_sequence_invalid source_sequence=$sourcePrereleaseSequence"
        }
        if ($targetPrereleaseSequence -ne 0) {
            throw "promotion_lineage_invalid: mode=$ModeName reason=target_sequence_invalid target_sequence=$targetPrereleaseSequence"
        }
    }

    return [ordered]@{
        status = 'pass'
        mode = $ModeName
        source_tag = [string]$SourceRelease.tag
        source_channel = $sourceChannel
        source_core = $sourceCore
        source_sha = $sourceSha
        target_tag = [string]$ReleaseVerification.tag
        target_channel = $targetChannel
        target_core = $targetCore
        target_sha = $targetSha
    }
}

function Get-ModeConfig {
    param([Parameter(Mandatory = $true)][string]$ModeName)

    switch ($ModeName) {
        'CanaryCycle' {
            return [ordered]@{
                channel = 'canary'
                prerelease = $true
                source_channel_for_promotion = ''
                enforce_prerelease_source = $false
            }
        }
        'PromotePrerelease' {
            return [ordered]@{
                channel = 'prerelease'
                prerelease = $true
                source_channel_for_promotion = 'canary'
                enforce_prerelease_source = $true
            }
        }
        'PromoteStable' {
            return [ordered]@{
                channel = 'stable'
                prerelease = $false
                source_channel_for_promotion = 'prerelease'
                enforce_prerelease_source = $true
            }
        }
        default {
            throw "unsupported_mode_config: $ModeName"
        }
    }
}

function Get-ReleasePublishedSortValue {
    param([Parameter(Mandatory = $true)][object]$Record)

    $parsed = [DateTimeOffset]::MinValue
    [void][DateTimeOffset]::TryParse([string]$Record.published_at_utc, [ref]$parsed)
    return $parsed
}

function New-CoreVersion {
    param(
        [Parameter(Mandatory = $true)][int]$Major,
        [Parameter(Mandatory = $true)][int]$Minor,
        [Parameter(Mandatory = $true)][int]$Patch
    )

    return [ordered]@{
        major = $Major
        minor = $Minor
        patch = $Patch
    }
}

function Format-CoreVersion {
    param([Parameter(Mandatory = $true)]$Core)
    return "{0}.{1}.{2}" -f [int]$Core.major, [int]$Core.minor, [int]$Core.patch
}

function Compare-CoreVersion {
    param(
        [Parameter(Mandatory = $true)]$Left,
        [Parameter(Mandatory = $true)]$Right
    )

    foreach ($part in @('major', 'minor', 'patch')) {
        $l = [int]$Left.$part
        $r = [int]$Right.$part
        if ($l -gt $r) { return 1 }
        if ($l -lt $r) { return -1 }
    }

    return 0
}

function Get-MaxCoreVersion {
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Records = @())

    $maxCore = $null
    foreach ($record in @($Records)) {
        $candidate = New-CoreVersion -Major ([int]$record.major) -Minor ([int]$record.minor) -Patch ([int]$record.patch)
        if ($null -eq $maxCore) {
            $maxCore = $candidate
            continue
        }

        if ((Compare-CoreVersion -Left $candidate -Right $maxCore) -gt 0) {
            $maxCore = $candidate
        }
    }

    return $maxCore
}

function Test-CoreEquals {
    param(
        [Parameter(Mandatory = $true)]$Left,
        [Parameter(Mandatory = $true)]$Right
    )

    return ((Compare-CoreVersion -Left $Left -Right $Right) -eq 0)
}

function Get-SequenceFromLabel {
    param(
        [Parameter(Mandatory = $true)][string]$Label,
        [Parameter(Mandatory = $true)][string]$Token
    )

    if ([string]::IsNullOrWhiteSpace($Label)) {
        return 0
    }

    $pattern = "(?i)(?:^|[.-]){0}[.-](?<n>\d+)(?:$|[.-])" -f [regex]::Escape($Token)
    $match = [regex]::Match($Label, $pattern)
    if (-not $match.Success) {
        return 0
    }

    $value = 0
    if (-not [int]::TryParse([string]$match.Groups['n'].Value, [ref]$value)) {
        return 0
    }

    return $value
}

function Convert-ReleaseToRecord {
    param([Parameter(Mandatory = $true)][object]$Release)

    $tagName = [string]$Release.tagName
    if ([string]::IsNullOrWhiteSpace($tagName)) {
        return $null
    }

    $isPrerelease = [bool]$Release.isPrerelease
    $publishedAt = [string]$Release.publishedAt
    $url = [string]$Release.url

    $legacyMatch = [regex]::Match($tagName, '^v0\.(?<date>\d{8})\.(?<sequence>\d+)$')
    if ($legacyMatch.Success) {
        $legacySequence = 0
        if (-not [int]::TryParse([string]$legacyMatch.Groups['sequence'].Value, [ref]$legacySequence)) {
            return $null
        }

        $legacyChannel = 'unknown'
        if ($legacySequence -ge 1 -and $legacySequence -le 49 -and $isPrerelease) {
            $legacyChannel = 'canary'
        } elseif ($legacySequence -ge 50 -and $legacySequence -le 79 -and $isPrerelease) {
            $legacyChannel = 'prerelease'
        } elseif ($legacySequence -ge 80 -and $legacySequence -le 99 -and -not $isPrerelease) {
            $legacyChannel = 'stable'
        }

        return [ordered]@{
            tag_name = $tagName
            tag_family = 'legacy_date_window'
            channel = $legacyChannel
            is_prerelease = $isPrerelease
            published_at_utc = $publishedAt
            url = $url
            major = 0
            minor = 0
            patch = 0
            prerelease_label = ''
            prerelease_sequence = 0
            legacy_date = [string]$legacyMatch.Groups['date'].Value
            legacy_sequence = $legacySequence
        }
    }

    $semverMatch = [regex]::Match(
        $tagName,
        '^v(?<major>0|[1-9]\d*)\.(?<minor>0|[1-9]\d*)\.(?<patch>0|[1-9]\d*)(?:-(?<prerelease>[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?(?:\+(?<build>[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?$'
    )
    if (-not $semverMatch.Success) {
        return $null
    }

    $prereleaseLabel = [string]$semverMatch.Groups['prerelease'].Value
    $channel = 'stable'
    $sequence = 0
    if (-not [string]::IsNullOrWhiteSpace($prereleaseLabel)) {
        if ($prereleaseLabel -match '(?i)(^|[.\-])canary([.\-]|$)') {
            $channel = 'canary'
            $sequence = Get-SequenceFromLabel -Label $prereleaseLabel -Token 'canary'
        } else {
            $channel = 'prerelease'
            $sequence = Get-SequenceFromLabel -Label $prereleaseLabel -Token 'rc'
        }
    }

    return [ordered]@{
        tag_name = $tagName
        tag_family = 'semver'
        channel = $channel
        is_prerelease = $isPrerelease
        published_at_utc = $publishedAt
        url = $url
        major = [int]$semverMatch.Groups['major'].Value
        minor = [int]$semverMatch.Groups['minor'].Value
        patch = [int]$semverMatch.Groups['patch'].Value
        prerelease_label = $prereleaseLabel
        prerelease_sequence = $sequence
        legacy_date = ''
        legacy_sequence = 0
    }
}

function Get-LatestSemVerRecordByChannel {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Records = @(),
        [Parameter(Mandatory = $true)][string]$Channel
    )

    return @(
        $Records |
            Where-Object { [string]$_.tag_family -eq 'semver' -and [string]$_.channel -eq $Channel } |
            Sort-Object `
                @{ Expression = { [int]$_.major }; Descending = $true }, `
                @{ Expression = { [int]$_.minor }; Descending = $true }, `
                @{ Expression = { [int]$_.patch }; Descending = $true }, `
                @{ Expression = { [int]$_.prerelease_sequence }; Descending = $true }, `
                @{ Expression = { Get-ReleasePublishedSortValue -Record $_ }; Descending = $true }, `
                @{ Expression = { [string]$_.tag_name }; Descending = $false } |
            Select-Object -First 1
    )
}

function Get-MaxPrereleaseSequenceForCore {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Records = @(),
        [Parameter(Mandatory = $true)]$Core,
        [Parameter(Mandatory = $true)][string]$Channel
    )

    $matched = @(
        $Records |
            Where-Object {
                ([string]$_.tag_family -eq 'semver') -and
                ([string]$_.channel -eq $Channel) -and
                ([int]$_.major -eq [int]$Core.major) -and
                ([int]$_.minor -eq [int]$Core.minor) -and
                ([int]$_.patch -eq [int]$Core.patch)
            } |
            ForEach-Object { [int]$_.prerelease_sequence }
    )
    if (@($matched).Count -eq 0) {
        return 0
    }

    return [int]((@($matched) | Measure-Object -Maximum).Maximum)
}

function Resolve-CanaryTargetSemVer {
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Records = @())

    $semverRecords = @($Records | Where-Object { [string]$_.tag_family -eq 'semver' })
    $stableRecords = @($semverRecords | Where-Object { [string]$_.channel -eq 'stable' })
    $nonStableRecords = @($semverRecords | Where-Object { [string]$_.channel -ne 'stable' })

    $latestStableCore = Get-MaxCoreVersion -Records $stableRecords
    $latestNonStableCore = Get-MaxCoreVersion -Records $nonStableRecords

    $targetCore = $null
    if ($null -ne $latestNonStableCore -and (($null -eq $latestStableCore) -or ((Compare-CoreVersion -Left $latestNonStableCore -Right $latestStableCore) -gt 0))) {
        $targetCore = $latestNonStableCore
    } elseif ($null -ne $latestStableCore) {
        $targetCore = New-CoreVersion -Major ([int]$latestStableCore.major) -Minor ([int]$latestStableCore.minor) -Patch ([int]$latestStableCore.patch + 1)
    } elseif ($null -ne $latestNonStableCore) {
        $targetCore = $latestNonStableCore
    } else {
        $targetCore = New-CoreVersion -Major 0 -Minor 1 -Patch 0
    }

    $maxCanarySequence = Get-MaxPrereleaseSequenceForCore -Records $semverRecords -Core $targetCore -Channel 'canary'
    $nextCanarySequence = $maxCanarySequence + 1
    if ($nextCanarySequence -gt 9999) {
        throw "semver_prerelease_sequence_exhausted: channel=canary core=$(Format-CoreVersion -Core $targetCore) next_sequence=$nextCanarySequence"
    }

    return [ordered]@{
        core = $targetCore
        prerelease_sequence = $nextCanarySequence
        tag = "v$(Format-CoreVersion -Core $targetCore)-canary.$nextCanarySequence"
        skipped = $false
        reason_code = ''
    }
}

function Resolve-PromotedTargetSemVer {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Records = @(),
        [Parameter(Mandatory = $true)][string]$TargetChannel,
        [Parameter(Mandatory = $true)]$SourceCore
    )

    if ([string]$TargetChannel -eq 'prerelease') {
        $maxRcSequence = Get-MaxPrereleaseSequenceForCore -Records $Records -Core $SourceCore -Channel 'prerelease'
        $nextRcSequence = $maxRcSequence + 1
        if ($nextRcSequence -gt 9999) {
            throw "semver_prerelease_sequence_exhausted: channel=prerelease core=$(Format-CoreVersion -Core $SourceCore) next_sequence=$nextRcSequence"
        }

        return [ordered]@{
            core = $SourceCore
            prerelease_sequence = $nextRcSequence
            tag = "v$(Format-CoreVersion -Core $SourceCore)-rc.$nextRcSequence"
            skipped = $false
            reason_code = ''
        }
    }

    if ([string]$TargetChannel -eq 'stable') {
        $stableExists = @(
            $Records |
                Where-Object {
                    ([string]$_.tag_family -eq 'semver') -and
                    ([string]$_.channel -eq 'stable') -and
                    ([int]$_.major -eq [int]$SourceCore.major) -and
                    ([int]$_.minor -eq [int]$SourceCore.minor) -and
                    ([int]$_.patch -eq [int]$SourceCore.patch)
                }
        ).Count -gt 0

        if ($stableExists) {
            return [ordered]@{
                core = $SourceCore
                prerelease_sequence = 0
                tag = "v$(Format-CoreVersion -Core $SourceCore)"
                skipped = $true
                reason_code = 'stable_already_published'
            }
        }

        return [ordered]@{
            core = $SourceCore
            prerelease_sequence = 0
            tag = "v$(Format-CoreVersion -Core $SourceCore)"
            skipped = $false
            reason_code = ''
        }
    }

    throw "unsupported_target_channel: $TargetChannel"
}

function Get-ReleasePlanningState {
    param(
        [Parameter(Mandatory = $true)][string]$Repository
    )

    $releaseList = @(Get-GhReleasesPortable -Repository $Repository -Limit 100 -ExcludeDrafts)
    $allRecords = @(
        $releaseList |
            ForEach-Object { Convert-ReleaseToRecord -Release $_ } |
            Where-Object { $null -ne $_ }
    )
    $legacyRecords = @(
        $allRecords |
            Where-Object { [string]$_.tag_family -eq 'legacy_date_window' -and [string]$_.channel -ne 'unknown' }
    )

    $migrationWarnings = @()
    if (@($legacyRecords).Count -gt 0) {
        if ($script:semverOnlyEnforced) {
            throw "semver_only_enforcement_violation: semver_only_enforce_utc=$($script:semverOnlyEnforceUtc.ToString('yyyy-MM-ddTHH:mm:ssZ')) legacy_tag_count=$(@($legacyRecords).Count)"
        }
        $migrationWarnings += "Legacy date-window release tags remain present in '$Repository'. Control-plane dispatch now targets SemVer channel tags and legacy compatibility ends at $($script:semverOnlyEnforceUtc.ToString('yyyy-MM-ddTHH:mm:ssZ'))."
    }

    return [ordered]@{
        records = @($allRecords)
        migration_warnings = @($migrationWarnings)
    }
}

function Resolve-TargetPlanForMode {
    param(
        [Parameter(Mandatory = $true)][string]$ModeName,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Records = @(),
        [Parameter(Mandatory = $true)]$ModeConfig,
        [Parameter()][AllowNull()]$SourceCore = $null
    )

    if ($ModeName -eq 'CanaryCycle') {
        return Resolve-CanaryTargetSemVer -Records $Records
    }

    if ($ModeName -eq 'PromotePrerelease' -or $ModeName -eq 'PromoteStable') {
        if ($null -eq $SourceCore) {
            throw "promotion_source_missing: channel=$([string]$ModeConfig.source_channel_for_promotion) strategy=semver"
        }
        return Resolve-PromotedTargetSemVer -Records $Records -TargetChannel ([string]$ModeConfig.channel) -SourceCore $SourceCore
    }

    throw "unsupported_release_mode: $ModeName"
}

function Get-ReleaseByTagOrNull {
    param(
        [Parameter(Mandatory = $true)][string]$Repository,
        [Parameter(Mandatory = $true)][string]$Tag
    )

    $viewOutput = & gh release view $Tag -R $Repository --json tagName,publishedAt,url 2>&1
    $exitCode = if ($null -eq $LASTEXITCODE) { 0 } else { [int]$LASTEXITCODE }
    $viewText = if ($viewOutput -is [System.Array]) {
        (($viewOutput | ForEach-Object { [string]$_ }) -join [Environment]::NewLine)
    } else {
        [string]$viewOutput
    }

    if ($exitCode -eq 0) {
        if ([string]::IsNullOrWhiteSpace($viewText)) {
            throw ("gh_command_failed: exit={0} command=gh release view {1} -R {2} --json tagName,publishedAt,url" -f $exitCode, $Tag, $Repository)
        }
        return ($viewText | ConvertFrom-Json -ErrorAction Stop)
    }

    if ($viewText -match '(?i)not found|http 404|release.*not found') {
        return $null
    }

    throw ("gh_command_failed: exit={0} command=gh release view {1} -R {2} --json tagName,publishedAt,url error={3}" -f $exitCode, $Tag, $Repository, ($viewText.Trim()))
}

function Resolve-StablePromotionWindowDecision {
    param(
        [Parameter(Mandatory = $true)][DateTimeOffset]$NowUtc,
        [Parameter(Mandatory = $true)][bool]$OverrideRequested,
        [Parameter()][string]$OverrideReason = ''
    )

    $allowedWeekdays = @($script:stablePromotionFullCycleAllowedUtcWeekdays | ForEach-Object { ([string]$_).Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if (@($allowedWeekdays).Count -eq 0) {
        $allowedWeekdays = @('Monday')
    }

    $currentWeekday = $NowUtc.ToUniversalTime().DayOfWeek.ToString()
    $withinWindow = (@($allowedWeekdays | Where-Object { [string]$_ -eq $currentWeekday }).Count -gt 0)
    $normalizedReason = ([string]$OverrideReason).Trim()

    $decision = [ordered]@{
        status = 'evaluated'
        policy_source = [string]$script:stablePromotionWindowPolicySource
        current_utc = $NowUtc.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        current_utc_weekday = $currentWeekday
        full_cycle_allowed_utc_weekdays = @($allowedWeekdays)
        within_window = [bool]$withinWindow
        override_requested = [bool]$OverrideRequested
        override_applied = $false
        allow_outside_window_with_override = [bool]$script:stablePromotionAllowOutsideWindowWithOverride
        override_reason_required = [bool]$script:stablePromotionOverrideReasonRequired
        override_reason_min_length = [int]$script:stablePromotionOverrideReasonMinLength
        override_reason_pattern = [string]$script:stablePromotionOverrideReasonPattern
        override_reason_example = [string]$script:stablePromotionOverrideReasonExample
        override_reason = $normalizedReason
        override_reference = ''
        override_summary = ''
        structured_reason_valid = $false
        can_promote = $false
        reason_code = ''
    }

    if ($withinWindow) {
        $decision.can_promote = $true
        $decision.reason_code = 'stable_window_open'
        return $decision
    }

    if (-not $OverrideRequested) {
        $decision.can_promote = $false
        $decision.reason_code = 'stable_window_closed'
        return $decision
    }

    if (-not [bool]$script:stablePromotionAllowOutsideWindowWithOverride) {
        throw "stable_window_override_blocked: current_utc_weekday=$currentWeekday"
    }

    if ([bool]$script:stablePromotionOverrideReasonRequired -and [string]::IsNullOrWhiteSpace($normalizedReason)) {
        throw "stable_window_override_reason_required: min_length=$([int]$script:stablePromotionOverrideReasonMinLength)"
    }

    if ([int]$script:stablePromotionOverrideReasonMinLength -gt 0 -and $normalizedReason.Length -lt [int]$script:stablePromotionOverrideReasonMinLength) {
        throw "stable_window_override_reason_too_short: min_length=$([int]$script:stablePromotionOverrideReasonMinLength) actual_length=$($normalizedReason.Length)"
    }

    $reasonPattern = ([string]$script:stablePromotionOverrideReasonPattern).Trim()
    if ([string]::IsNullOrWhiteSpace($reasonPattern)) {
        throw 'stable_window_override_reason_pattern_missing'
    }

    $reasonMatch = $null
    try {
        $reasonMatch = [regex]::Match($normalizedReason, $reasonPattern, [System.Text.RegularExpressions.RegexOptions]::CultureInvariant)
    } catch {
        throw "stable_window_override_reason_pattern_invalid: pattern=$reasonPattern"
    }

    if ($null -eq $reasonMatch -or -not $reasonMatch.Success) {
        throw "stable_window_override_reason_format_invalid: expected_pattern=$reasonPattern"
    }

    $referenceGroup = $reasonMatch.Groups['reference']
    $summaryGroup = $reasonMatch.Groups['summary']
    $overrideReference = if ($null -ne $referenceGroup -and $referenceGroup.Success) { ([string]$referenceGroup.Value).Trim() } else { '' }
    $overrideSummary = if ($null -ne $summaryGroup -and $summaryGroup.Success) { ([string]$summaryGroup.Value).Trim() } else { '' }
    if ([string]::IsNullOrWhiteSpace($overrideReference)) {
        throw 'stable_window_override_reason_reference_missing'
    }
    if ([string]::IsNullOrWhiteSpace($overrideSummary)) {
        throw 'stable_window_override_reason_summary_missing'
    }

    $decision.can_promote = $true
    $decision.override_applied = $true
    $decision.override_reference = $overrideReference
    $decision.override_summary = $overrideSummary
    $decision.structured_reason_valid = $true
    $decision.reason_code = 'stable_window_override_applied'
    return $decision
}

function Write-StableOverrideAuditReport {
    param(
        [Parameter(Mandatory = $true)][object]$ControlPlaneReport,
        [Parameter()][string]$OutputPath = ''
    )

    if ([string]::IsNullOrWhiteSpace([string]$OutputPath)) {
        return
    }

    $window = $ControlPlaneReport.stable_promotion_window
    $decision = $null
    if ($null -ne $window) {
        $decision = $window.decision
    }

    function Get-PropertyValueOrDefault {
        param(
            [Parameter()][AllowNull()]$Object,
            [Parameter(Mandatory = $true)][string]$Name,
            [Parameter()][AllowNull()]$DefaultValue = $null
        )

        if ($null -eq $Object) {
            return $DefaultValue
        }

        if ($Object -is [System.Collections.IDictionary]) {
            if ($Object.Contains($Name)) {
                return $Object[$Name]
            }
            return $DefaultValue
        }

        $prop = $Object.PSObject.Properties[$Name]
        if ($null -eq $prop) {
            return $DefaultValue
        }

        return $prop.Value
    }

    $stableExecution = @(
        @($ControlPlaneReport.executions) |
            Where-Object { [string]$_.mode -eq 'PromoteStable' } |
            Select-Object -First 1
    )

    $stableTargetTag = ''
    $stableDispatchRunId = ''
    $stableReleaseUrl = ''
    if (@($stableExecution).Count -eq 1) {
        if ($null -ne $stableExecution[0].target_release) {
            $stableTargetTag = [string]$stableExecution[0].target_release.tag
        }
        if ($null -ne $stableExecution[0].dispatch) {
            $stableDispatchRunId = [string]$stableExecution[0].dispatch.run_id
        }
        if ($null -ne $stableExecution[0].release_verification) {
            $stableReleaseUrl = [string]$stableExecution[0].release_verification.release_url
        }
    }

    $overrideRequested = $false
    $overrideApplied = $false
    $structuredReasonValid = $false
    $overrideReason = ''
    $overrideReference = ''
    $overrideSummary = ''
    $policySource = ''
    $decisionReason = ''
    $currentUtc = ''
    $currentUtcWeekday = ''
    $allowedWeekdays = @()
    $auditStatus = 'not_applicable'
    $auditReason = 'not_full_cycle_mode'

    if ($null -ne $window) {
        $overrideRequested = [bool](Get-PropertyValueOrDefault -Object $window -Name 'override_requested' -DefaultValue $false)
        $overrideReason = [string](Get-PropertyValueOrDefault -Object $window -Name 'override_reason' -DefaultValue '')
        $policySource = [string](Get-PropertyValueOrDefault -Object $window -Name 'policy_source' -DefaultValue '')
        $allowedWeekdays = @((Get-PropertyValueOrDefault -Object $window -Name 'full_cycle_allowed_utc_weekdays' -DefaultValue @()))
    }

    if ($null -ne $decision) {
        $decisionReason = [string](Get-PropertyValueOrDefault -Object $decision -Name 'reason_code' -DefaultValue '')
        $currentUtc = [string](Get-PropertyValueOrDefault -Object $decision -Name 'current_utc' -DefaultValue '')
        $currentUtcWeekday = [string](Get-PropertyValueOrDefault -Object $decision -Name 'current_utc_weekday' -DefaultValue '')
        $overrideApplied = [bool](Get-PropertyValueOrDefault -Object $decision -Name 'override_applied' -DefaultValue $false)
        $overrideReference = [string](Get-PropertyValueOrDefault -Object $decision -Name 'override_reference' -DefaultValue '')
        $overrideSummary = [string](Get-PropertyValueOrDefault -Object $decision -Name 'override_summary' -DefaultValue '')
        $structuredReasonValid = [bool](Get-PropertyValueOrDefault -Object $decision -Name 'structured_reason_valid' -DefaultValue $false)
    }

    if ([string]$decisionReason -eq 'stable_window_override_applied') {
        $auditStatus = 'override_applied'
        $auditReason = 'stable_window_override_applied'
    } elseif ($overrideRequested) {
        $auditStatus = 'override_requested_not_applied'
        $auditReason = if ([string]::IsNullOrWhiteSpace($decisionReason)) { 'override_requested' } else { $decisionReason }
    } elseif ([string]$ControlPlaneReport.mode -eq 'FullCycle') {
        $auditStatus = 'window_default_path'
        $auditReason = if ([string]::IsNullOrWhiteSpace($decisionReason)) { 'stable_window_not_evaluated' } else { $decisionReason }
    }

    if ([string]$ControlPlaneReport.status -eq 'fail' -and [string]$ControlPlaneReport.reason_code -eq 'stable_window_override_invalid') {
        $auditStatus = 'override_rejected'
        $auditReason = 'stable_window_override_invalid'
    }

    $auditReport = [ordered]@{
        schema_version = '1.0'
        timestamp_utc = Get-UtcNowIso
        repository = [string]$ControlPlaneReport.repository
        branch = [string]$ControlPlaneReport.branch
        mode = [string]$ControlPlaneReport.mode
        run_status = [string]$ControlPlaneReport.status
        run_reason_code = [string]$ControlPlaneReport.reason_code
        status = $auditStatus
        reason_code = $auditReason
        stable_target_tag = $stableTargetTag
        stable_dispatch_run_id = $stableDispatchRunId
        stable_release_url = $stableReleaseUrl
        override_requested = $overrideRequested
        override_applied = $overrideApplied
        override_reason = $overrideReason
        override_reference = $overrideReference
        override_summary = $overrideSummary
        structured_reason_valid = $structuredReasonValid
        policy_source = $policySource
        full_cycle_allowed_utc_weekdays = @($allowedWeekdays)
        current_utc = $currentUtc
        current_utc_weekday = $currentUtcWeekday
        decision_reason_code = $decisionReason
    }

    Write-WorkflowOpsReport -Report $auditReport -OutputPath $OutputPath | Out-Null
}

function Invoke-ReleaseMode {
    param(
        [Parameter(Mandatory = $true)][string]$ModeName,
        [Parameter(Mandatory = $true)][string]$DateKey,
        [Parameter(Mandatory = $true)][string]$ScratchRoot
    )

    $executionReport = [ordered]@{
        mode = $ModeName
        source_release = $null
        target_release = $null
        dispatch = $null
        release_verification = $null
        promotion_lineage = $null
        hygiene = $null
    }

    $modeConfig = Get-ModeConfig -ModeName $ModeName
    $planningState = Get-ReleasePlanningState -Repository $Repository
    $allRecords = @($planningState.records)
    $migrationWarnings = @($planningState.migration_warnings)

    $sourceRecord = $null
    $sourceCore = $null
    if (-not [string]::IsNullOrWhiteSpace([string]$modeConfig.source_channel_for_promotion)) {
        $sourceCandidates = @(Get-LatestSemVerRecordByChannel -Records $allRecords -Channel ([string]$modeConfig.source_channel_for_promotion))
        if (@($sourceCandidates).Count -ne 1) {
            throw "promotion_source_missing: channel=$([string]$modeConfig.source_channel_for_promotion) strategy=semver"
        }

        $sourceRecord = $sourceCandidates[0]
        $sourceTag = [string]$sourceRecord.tag_name
        $sourceCore = New-CoreVersion -Major ([int]$sourceRecord.major) -Minor ([int]$sourceRecord.minor) -Patch ([int]$sourceRecord.patch)
        $sourceRelease = Invoke-GhJson -Arguments @(
            'release', 'view',
            $sourceTag,
            '-R', $Repository,
            '--json', 'tagName,isPrerelease,targetCommitish,publishedAt,assets,url'
        )

        if ($modeConfig.enforce_prerelease_source -and -not [bool]$sourceRelease.isPrerelease) {
            throw "promotion_source_not_prerelease: tag=$sourceTag channel=$([string]$modeConfig.source_channel_for_promotion)"
        }

        $assetNames = @($sourceRelease.assets | ForEach-Object { [string]$_.name })
        foreach ($requiredAsset in @($script:releaseRequiredAssets)) {
            if ($assetNames -notcontains $requiredAsset) {
                throw "promotion_source_asset_missing: tag=$sourceTag asset=$requiredAsset"
            }
        }

        $headSha = (Invoke-GhText -Arguments @('api', "repos/$Repository/branches/$Branch", '--jq', '.commit.sha')).Trim().ToLowerInvariant()
        $sourceCommit = ([string]$sourceRelease.targetCommitish).Trim().ToLowerInvariant()
        if ($headSha -notmatch '^[0-9a-f]{40}$') {
            throw "branch_head_unresolved: repository=$Repository branch=$Branch"
        }
        if ($sourceCommit -notmatch '^[0-9a-f]{40}$') {
            throw "promotion_source_commit_invalid: tag=$sourceTag targetCommitish=$sourceCommit"
        }
        if ($headSha -ne $sourceCommit) {
            throw "promotion_source_not_at_head: tag=$sourceTag source_sha=$sourceCommit head_sha=$headSha"
        }

        $executionReport.source_release = [ordered]@{
            channel = [string]$modeConfig.source_channel_for_promotion
            tag = $sourceTag
            tag_family = 'semver'
            core = Format-CoreVersion -Core $sourceCore
            prerelease_sequence = [int]$sourceRecord.prerelease_sequence
            prerelease = [bool]$sourceRelease.isPrerelease
            source_sha = $sourceCommit
            head_sha = $headSha
            url = [string]$sourceRelease.url
        }
    }

    $targetPlan = Resolve-TargetPlanForMode -ModeName $ModeName -Records $allRecords -ModeConfig $modeConfig -SourceCore $sourceCore

    $targetTag = [string]$targetPlan.tag
    $targetCoreText = Format-CoreVersion -Core $targetPlan.core
    $executionReport.target_release = [ordered]@{
        mode = $ModeName
        channel = [string]$modeConfig.channel
        prerelease = [bool]$modeConfig.prerelease
        tag = $targetTag
        tag_family = 'semver'
        core = $targetCoreText
        prerelease_sequence = [int]$targetPlan.prerelease_sequence
        status = if ([bool]$targetPlan.skipped) { 'skipped' } else { 'planned' }
        reason_code = if ([bool]$targetPlan.skipped) { [string]$targetPlan.reason_code } else { '' }
        migration_warnings = @($migrationWarnings)
        dispatch_retry_max_attempts = 4
        dispatch_attempts = 0
        collision_retries = 0
        dispatch_attempt_history = @()
    }

    if (@($migrationWarnings).Count -gt 0) {
        foreach ($warning in @($migrationWarnings)) {
            Write-Warning "[tag_migration_warning] $warning"
        }
    }

    if ([bool]$targetPlan.skipped) {
        return $executionReport
    }

    if ($DryRun) {
        $executionReport.dispatch = [ordered]@{
            status = 'skipped_dry_run'
            workflow = $ReleaseWorkflowFile
            branch = $Branch
            run_id = ''
            url = ''
            attempts = 0
            collision_retries = 0
        }
        return $executionReport
    }

    $dispatchRetryMaxAttempts = 4
    $dispatchAttempt = 0
    $collisionRetryCount = 0
    $attemptHistory = [System.Collections.Generic.List[object]]::new()
    $dispatchRecord = $null
    $releaseVerification = $null

    while ($dispatchAttempt -lt $dispatchRetryMaxAttempts) {
        $dispatchAttempt++

        if ($dispatchAttempt -gt 1) {
            $planningState = Get-ReleasePlanningState -Repository $Repository
            $allRecords = @($planningState.records)
            $targetPlan = Resolve-TargetPlanForMode -ModeName $ModeName -Records $allRecords -ModeConfig $modeConfig -SourceCore $sourceCore
            $targetTag = [string]$targetPlan.tag
            $targetCoreText = Format-CoreVersion -Core $targetPlan.core

            $executionReport.target_release.tag = $targetTag
            $executionReport.target_release.core = $targetCoreText
            $executionReport.target_release.prerelease_sequence = [int]$targetPlan.prerelease_sequence
            $executionReport.target_release.status = if ([bool]$targetPlan.skipped) { 'skipped' } else { 'planned' }
            $executionReport.target_release.reason_code = if ([bool]$targetPlan.skipped) { [string]$targetPlan.reason_code } else { '' }
            $executionReport.target_release.migration_warnings = @($planningState.migration_warnings)
        }

        if ([bool]$targetPlan.skipped) {
            if ([string]$targetPlan.reason_code -eq 'stable_already_published') {
                $releaseVerification = Verify-DispatchedRelease `
                    -TargetTag $targetTag `
                    -ExpectedChannel ([string]$modeConfig.channel) `
                    -ExpectedIsPrerelease ([bool]$modeConfig.prerelease) `
                    -ModeName $ModeName `
                    -ScratchRoot $ScratchRoot
                $dispatchRecord = [ordered]@{
                    status = 'collision_resolved_existing_stable'
                    workflow = $ReleaseWorkflowFile
                    branch = $Branch
                    run_id = ''
                    url = [string]$releaseVerification.release_url
                    conclusion = 'success'
                    attempts = $dispatchAttempt
                    collision_retries = $collisionRetryCount
                    reason_code = 'stable_already_published'
                }
                [void]$attemptHistory.Add([ordered]@{
                    attempt = $dispatchAttempt
                    tag = $targetTag
                    status = 'stable_already_published'
                    reason_code = 'stable_already_published'
                })
                break
            }

            throw "release_dispatch_attempts_exhausted: mode=$ModeName attempts=$dispatchAttempt tag=$targetTag reason=$([string]$targetPlan.reason_code)"
        }

        $existingBeforeDispatch = Get-ReleaseByTagOrNull -Repository $Repository -Tag $targetTag
        if ($null -ne $existingBeforeDispatch) {
            $collisionRetryCount++
            Write-Warning ("[release_tag_collision] mode={0} attempt={1} tag={2} already exists at {3}. Replanning." -f $ModeName, $dispatchAttempt, $targetTag, [string]$existingBeforeDispatch.url)
            [void]$attemptHistory.Add([ordered]@{
                attempt = $dispatchAttempt
                tag = $targetTag
                status = 'collision_pre_dispatch'
                existing_release_url = [string]$existingBeforeDispatch.url
                existing_release_published_at_utc = [string]$existingBeforeDispatch.publishedAt
            })
            if ($dispatchAttempt -ge $dispatchRetryMaxAttempts) {
                throw "release_tag_collision_retry_exhausted: mode=$ModeName attempts=$dispatchAttempt tag=$targetTag"
            }
            continue
        }

        $dispatchReportPath = Join-Path $ScratchRoot "$ModeName-dispatch-$dispatchAttempt.json"
        $dispatchInputs = @(
            "release_tag=$targetTag",
            'allow_existing_tag=false',
            "prerelease=$(([string]([bool]$modeConfig.prerelease)).ToLowerInvariant())",
            "release_channel=$([string]$modeConfig.channel)"
        )

        try {
            & $dispatchWorkflowScript `
                -Repository $Repository `
                -WorkflowFile $ReleaseWorkflowFile `
                -Branch $Branch `
                -Inputs $dispatchInputs `
                -OutputPath $dispatchReportPath | Out-Null
            $dispatchReport = Get-Content -LiteralPath $dispatchReportPath -Raw | ConvertFrom-Json -ErrorAction Stop
            $dispatchRunId = [string]$dispatchReport.run_id
            if ([string]::IsNullOrWhiteSpace($dispatchRunId)) {
                throw "release_dispatch_report_invalid: mode=$ModeName attempt=$dispatchAttempt field=run_id"
            }

            $watchReportPath = Join-Path $ScratchRoot "$ModeName-watch-$dispatchAttempt.json"
            & pwsh -NoProfile -File $watchWorkflowScript `
                -Repository $Repository `
                -RunId $dispatchRunId `
                -TimeoutMinutes $WatchTimeoutMinutes `
                -OutputPath $watchReportPath | Out-Null
            $watchExitCode = if ($null -eq $LASTEXITCODE) { 0 } else { [int]$LASTEXITCODE }
            if ($watchExitCode -ne 0) {
                $watchFailureStatus = ''
                $watchFailureConclusion = ''
                $watchFailureClassifiedReason = ''
                if (Test-Path -LiteralPath $watchReportPath -PathType Leaf) {
                    try {
                        $watchFailureReport = Get-Content -LiteralPath $watchReportPath -Raw | ConvertFrom-Json -ErrorAction Stop
                        $watchFailureStatus = [string]$watchFailureReport.status
                        $watchFailureConclusion = [string]$watchFailureReport.conclusion
                        $watchFailureClassifiedReason = [string]$watchFailureReport.classified_reason
                    } catch {
                        $watchFailureClassifiedReason = 'watch_report_parse_failed'
                    }
                } else {
                    $watchFailureClassifiedReason = 'watch_report_missing'
                }

                if ([string]::Equals($watchFailureClassifiedReason, 'timeout', [System.StringComparison]::OrdinalIgnoreCase)) {
                    throw "release_watch_timeout: mode=$ModeName run_id=$dispatchRunId timeout_minutes=$WatchTimeoutMinutes status=$watchFailureStatus"
                }

                throw "release_watch_failed: mode=$ModeName run_id=$dispatchRunId exit_code=$watchExitCode classified_reason=$watchFailureClassifiedReason conclusion=$watchFailureConclusion status=$watchFailureStatus"
            }

            $watchReport = Get-Content -LiteralPath $watchReportPath -Raw | ConvertFrom-Json -ErrorAction Stop
            $watchConclusion = [string]$watchReport.conclusion
            $watchClassifiedReason = [string]$watchReport.classified_reason
            if ($watchConclusion -ne 'success') {
                throw "release_watch_not_success: mode=$ModeName run_id=$dispatchRunId conclusion=$watchConclusion classified_reason=$watchClassifiedReason"
            }

            $dispatchRecord = [ordered]@{
                status = 'success'
                workflow = $ReleaseWorkflowFile
                branch = $Branch
                run_id = $dispatchRunId
                url = [string]$watchReport.url
                conclusion = [string]$watchReport.conclusion
                attempts = $dispatchAttempt
                collision_retries = $collisionRetryCount
            }
            [void]$attemptHistory.Add([ordered]@{
                attempt = $dispatchAttempt
                tag = $targetTag
                status = 'success'
                run_id = $dispatchRunId
                run_url = [string]$watchReport.url
            })
            break
        } catch {
            $dispatchError = [string]$_.Exception.Message
            $existingAfterFailure = Get-ReleaseByTagOrNull -Repository $Repository -Tag $targetTag
            if ($null -ne $existingAfterFailure) {
                $collisionRetryCount++
                Write-Warning ("[release_tag_collision] mode={0} attempt={1} tag={2} observed after failure. Verifying existing release." -f $ModeName, $dispatchAttempt, $targetTag)
                [void]$attemptHistory.Add([ordered]@{
                    attempt = $dispatchAttempt
                    tag = $targetTag
                    status = 'collision_post_dispatch'
                    dispatch_error = $dispatchError
                    existing_release_url = [string]$existingAfterFailure.url
                    existing_release_published_at_utc = [string]$existingAfterFailure.publishedAt
                })

                try {
                    $releaseVerification = Verify-DispatchedRelease `
                        -TargetTag $targetTag `
                        -ExpectedChannel ([string]$modeConfig.channel) `
                        -ExpectedIsPrerelease ([bool]$modeConfig.prerelease) `
                        -ModeName $ModeName `
                        -ScratchRoot $ScratchRoot
                    $dispatchRecord = [ordered]@{
                        status = 'collision_resolved_existing_release'
                        workflow = $ReleaseWorkflowFile
                        branch = $Branch
                        run_id = ''
                        url = [string]$releaseVerification.release_url
                        conclusion = 'success'
                        attempts = $dispatchAttempt
                        collision_retries = $collisionRetryCount
                        reason_code = 'tag_already_published_by_peer'
                    }
                    break
                } catch {
                    $verifyError = [string]$_.Exception.Message
                    if ($dispatchAttempt -ge $dispatchRetryMaxAttempts) {
                        throw "release_tag_collision_retry_exhausted: mode=$ModeName attempts=$dispatchAttempt tag=$targetTag last_error=$dispatchError verify_error=$verifyError"
                    }
                    continue
                }
            }

            throw
        }
    }

    if ($null -eq $dispatchRecord) {
        throw "release_dispatch_attempts_exhausted: mode=$ModeName attempts=$dispatchAttempt tag=$targetTag"
    }

    $executionReport.target_release.dispatch_attempts = $dispatchAttempt
    $executionReport.target_release.collision_retries = $collisionRetryCount
    $executionReport.target_release.dispatch_attempt_history = @($attemptHistory)
    $executionReport.dispatch = $dispatchRecord

    if ($null -eq $releaseVerification) {
        $releaseVerification = Verify-DispatchedRelease `
            -TargetTag $targetTag `
            -ExpectedChannel ([string]$modeConfig.channel) `
            -ExpectedIsPrerelease ([bool]$modeConfig.prerelease) `
            -ModeName $ModeName `
            -ScratchRoot $ScratchRoot
    }
    $executionReport.release_verification = $releaseVerification

    $executionReport.promotion_lineage = Verify-PromotionLineage `
        -ModeName $ModeName `
        -SourceRelease $executionReport.source_release `
        -ReleaseVerification $executionReport.release_verification

    if ($ModeName -eq 'CanaryCycle') {
        $hygienePath = Join-Path $ScratchRoot 'canary-hygiene.json'
        & pwsh -NoProfile -File $canaryHygieneScript `
            -Repository $Repository `
            -DateUtc $DateKey `
            -TagFamily semver `
            -KeepLatestN $KeepLatestCanaryN `
            -Delete `
            -OutputPath $hygienePath | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "canary_hygiene_failed: tag_family=semver date=$DateKey exit_code=$LASTEXITCODE"
        }
        $executionReport.hygiene = Get-Content -LiteralPath $hygienePath -Raw | ConvertFrom-Json -ErrorAction Stop
    }

    return $executionReport
}

$scratchRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("release-control-plane-" + [Guid]::NewGuid().ToString('N'))
New-Item -Path $scratchRoot -ItemType Directory -Force | Out-Null

$report = [ordered]@{
    schema_version = '1.0'
    timestamp_utc = Get-UtcNowIso
    repository = $Repository
    branch = $Branch
    mode = $Mode
    dry_run = [bool]$DryRun
    auto_remediate = [bool]$AutoRemediate
    sync_guard_max_age_hours = $SyncGuardMaxAgeHours
    keep_latest_canary_n = $KeepLatestCanaryN
    tag_strategy = 'semver'
    migration_mode = 'dual_mode_publish_semver_control_plane'
    control_plane_policy_schema_version = [string]$script:opsControlPlanePolicySchemaVersion
    control_plane_policy_source = [string]$script:opsControlPlanePolicySource
    state_machine = [ordered]@{
        version = [string]$script:controlPlaneStateMachinePolicy.version
        initial_state = [string]$script:controlPlaneStateMachinePolicy.initial_state
        current_state = [string]$script:controlPlaneStateMachinePolicy.initial_state
        terminal_states = @($script:controlPlaneStateMachinePolicy.terminal_states)
        transitions_executed = @()
    }
    rollback_orchestration = [ordered]@{
        policy_enabled = [bool]$script:rollbackOrchestrationPolicy.enabled
        policy_run_on_dry_run = [bool]$script:rollbackOrchestrationPolicy.run_on_dry_run
        trigger_reason_codes = @($script:rollbackOrchestrationPolicy.trigger_reason_codes)
        attempted = $false
        status = 'not_run'
        reason_code = ''
        message = ''
        report_path = ''
        report = $null
        decision = [ordered]@{
            should_attempt = $false
            decision_reason = 'not_evaluated'
        }
    }
    semver_policy_source = $script:semverPolicySource
    semver_only_enforce_utc = $script:semverOnlyEnforceUtc.ToString('yyyy-MM-ddTHH:mm:ssZ')
    semver_only_enforced = [bool]$script:semverOnlyEnforced
    stable_promotion_window = [ordered]@{
        policy_source = [string]$script:stablePromotionWindowPolicySource
        full_cycle_allowed_utc_weekdays = @($script:stablePromotionFullCycleAllowedUtcWeekdays)
        allow_outside_window_with_override = [bool]$script:stablePromotionAllowOutsideWindowWithOverride
        override_reason_required = [bool]$script:stablePromotionOverrideReasonRequired
        override_reason_min_length = [int]$script:stablePromotionOverrideReasonMinLength
        override_reason_pattern = [string]$script:stablePromotionOverrideReasonPattern
        override_reason_example = [string]$script:stablePromotionOverrideReasonExample
        override_requested = [bool]$ForceStablePromotionOutsideWindow
        override_reason = ([string]$ForceStablePromotionReason).Trim()
        decision = [ordered]@{
            status = 'skipped'
            reason_code = 'not_full_cycle_mode'
        }
    }
    status = 'fail'
    reason_code = ''
    message = ''
    pre_health = $null
    remediation = $null
    post_health = $null
    executions = @()
}

try {
    Add-ControlPlaneStateTransition `
        -StateMachine $report.state_machine `
        -FromState 'start' `
        -Result 'enter' `
        -ToState ([string]$report.state_machine.initial_state) `
        -ReasonCode 'control_plane_start'

    $preHealthPath = Join-Path $scratchRoot 'pre-health.json'
    $healthy = $false
    try {
        & pwsh -NoProfile -File $opsSnapshotScript `
            -SurfaceRepository $Repository `
            -RequiredRunnerLabelsCsv $releaseRunnerLabelsCsv `
            -SyncGuardMaxAgeHours $SyncGuardMaxAgeHours `
            -OutputPath $preHealthPath
        if ($LASTEXITCODE -eq 0) {
            $healthy = $true
        }
    } catch {
        $healthy = $false
    }

    if (Test-Path -LiteralPath $preHealthPath -PathType Leaf) {
        $report.pre_health = Get-Content -LiteralPath $preHealthPath -Raw | ConvertFrom-Json -ErrorAction Stop
    }

    if ($healthy) {
        Add-ControlPlaneStateTransition `
            -StateMachine $report.state_machine `
            -FromState 'ops_health_preflight' `
            -Result 'pass' `
            -ToState 'ops_health_verify' `
            -ReasonCode 'pre_health_pass'
    } else {
        Add-ControlPlaneStateTransition `
            -StateMachine $report.state_machine `
            -FromState 'ops_health_preflight' `
            -Result 'fail' `
            -ToState (if ($AutoRemediate) { 'auto_remediation' } else { 'ops_health_verify' }) `
            -ReasonCode 'pre_health_fail'
    }

    if (-not $healthy -and $AutoRemediate) {
        $remediationPath = Join-Path $scratchRoot 'remediation.json'
        & pwsh -NoProfile -File $opsRemediateScript `
            -SurfaceRepository $Repository `
            -RequiredRunnerLabelsCsv $releaseRunnerLabelsCsv `
            -SyncGuardMaxAgeHours $SyncGuardMaxAgeHours `
            -OutputPath $remediationPath
        if (Test-Path -LiteralPath $remediationPath -PathType Leaf) {
            $report.remediation = Get-Content -LiteralPath $remediationPath -Raw | ConvertFrom-Json -ErrorAction Stop
        }
        Add-ControlPlaneStateTransition `
            -StateMachine $report.state_machine `
            -FromState 'auto_remediation' `
            -Result (if ($null -ne $report.remediation -and [string]$report.remediation.status -eq 'pass') { 'pass' } else { 'fail' }) `
            -ToState 'ops_health_verify' `
            -ReasonCode (if ($null -ne $report.remediation) { [string]$report.remediation.reason_code } else { 'remediation_report_missing' })
    }

    $postHealthPath = Join-Path $scratchRoot 'post-health.json'
    & pwsh -NoProfile -File $opsSnapshotScript `
        -SurfaceRepository $Repository `
        -RequiredRunnerLabelsCsv $releaseRunnerLabelsCsv `
        -SyncGuardMaxAgeHours $SyncGuardMaxAgeHours `
        -OutputPath $postHealthPath
    if ($LASTEXITCODE -ne 0) {
        throw 'ops_health_gate_failed'
    }
    $report.post_health = Get-Content -LiteralPath $postHealthPath -Raw | ConvertFrom-Json -ErrorAction Stop

    if ([string]$report.post_health.status -ne 'pass') {
        throw "ops_unhealthy: reason_codes=$([string]::Join(',', @($report.post_health.reason_codes)))"
    }
    Add-ControlPlaneStateTransition `
        -StateMachine $report.state_machine `
        -FromState 'ops_health_verify' `
        -Result 'pass' `
        -ToState 'release_dispatch' `
        -ReasonCode 'post_health_pass'

    if ($Mode -eq 'Validate') {
        $report.status = 'pass'
        $report.reason_code = if ($DryRun) { 'validate_dry_run' } else { 'validated' }
        $report.message = 'Release control plane validation completed without dispatch.'
        Add-ControlPlaneStateTransition `
            -StateMachine $report.state_machine `
            -FromState ([string]$report.state_machine.current_state) `
            -Result 'pass' `
            -ToState 'completed' `
            -ReasonCode ([string]$report.reason_code)
    } else {
        $dateKey = (Get-Date).ToUniversalTime().ToString('yyyyMMdd')
        $executionList = [System.Collections.Generic.List[object]]::new()

        if ($Mode -eq 'FullCycle') {
            $canaryExec = Invoke-ReleaseMode -ModeName 'CanaryCycle' -DateKey $dateKey -ScratchRoot $scratchRoot
            [void]$executionList.Add($canaryExec)

            $prereleaseExec = Invoke-ReleaseMode -ModeName 'PromotePrerelease' -DateKey $dateKey -ScratchRoot $scratchRoot
            [void]$executionList.Add($prereleaseExec)

            $stableWindowDecision = Resolve-StablePromotionWindowDecision `
                -NowUtc ([DateTimeOffset]::UtcNow) `
                -OverrideRequested ([bool]$ForceStablePromotionOutsideWindow) `
                -OverrideReason ([string]$ForceStablePromotionReason)
            $report.stable_promotion_window.decision = $stableWindowDecision

            $stableExec = [ordered]@{
                target_release = [ordered]@{
                    mode = 'PromoteStable'
                    status = 'skipped'
                    reason_code = [string]$stableWindowDecision.reason_code
                    tag_family = 'semver'
                }
                stable_window_gate = $stableWindowDecision
            }
            if ([bool]$stableWindowDecision.can_promote) {
                $stableExec = Invoke-ReleaseMode -ModeName 'PromoteStable' -DateKey $dateKey -ScratchRoot $scratchRoot
                $stableExec.stable_window_gate = $stableWindowDecision
            }
            [void]$executionList.Add($stableExec)
        } else {
            $singleExec = Invoke-ReleaseMode -ModeName $Mode -DateKey $dateKey -ScratchRoot $scratchRoot
            [void]$executionList.Add($singleExec)
        }

        $report.executions = @($executionList)
        $report.status = 'pass'
        $report.reason_code = if ($DryRun) { 'dry_run' } else { 'completed' }
        $report.message = 'Release control plane completed.'
        Add-ControlPlaneStateTransition `
            -StateMachine $report.state_machine `
            -FromState 'release_dispatch' `
            -Result 'pass' `
            -ToState 'completed' `
            -ReasonCode ([string]$report.reason_code)
    }
}
catch {
    $failureMessage = [string]$_.Exception.Message
    $report.status = 'fail'
    $report.reason_code = Resolve-ControlPlaneFailureReasonCode -MessageText $failureMessage
    $report.message = $failureMessage

    Add-ControlPlaneStateTransition `
        -StateMachine $report.state_machine `
        -FromState ([string]$report.state_machine.current_state) `
        -Result 'fail' `
        -ToState 'rollback_orchestration' `
        -ReasonCode ([string]$report.reason_code) `
        -Detail $failureMessage

    $rollbackDecision = Should-AttemptRollbackOrchestration `
        -ReasonCode ([string]$report.reason_code) `
        -Policy $script:rollbackOrchestrationPolicy `
        -DryRunEnabled ([bool]$DryRun) `
        -AutoRemediateEnabled ([bool]$AutoRemediate)
    $report.rollback_orchestration.decision = $rollbackDecision

    if ([bool]$rollbackDecision.should_attempt) {
        $report.rollback_orchestration.attempted = $true

        try {
            $rollbackResult = Invoke-ControlPlaneRollbackOrchestration `
                -TargetRepository $Repository `
                -TargetBranch ([string]$script:rollbackDrillPolicy.release_branch) `
                -RollbackPolicy $script:rollbackDrillPolicy `
                -ScratchRoot $scratchRoot

            $report.rollback_orchestration.status = [string]$rollbackResult.status
            $report.rollback_orchestration.report_path = [string]$rollbackResult.report_path
            $report.rollback_orchestration.report = $rollbackResult.report
            $report.rollback_orchestration.reason_code = [string]$rollbackResult.report.reason_code
            $report.rollback_orchestration.message = [string]$rollbackResult.report.message

            if ([string]$rollbackResult.status -eq 'pass') {
                Add-ControlPlaneStateTransition `
                    -StateMachine $report.state_machine `
                    -FromState 'rollback_orchestration' `
                    -Result 'pass' `
                    -ToState 'failed_recovered' `
                    -ReasonCode 'rollback_orchestration_recovered'
            } else {
                Add-ControlPlaneStateTransition `
                    -StateMachine $report.state_machine `
                    -FromState 'rollback_orchestration' `
                    -Result 'fail' `
                    -ToState 'failed' `
                    -ReasonCode ([string]$report.rollback_orchestration.reason_code)
            }
        } catch {
            $report.rollback_orchestration.status = 'fail'
            $report.rollback_orchestration.reason_code = 'rollback_orchestration_runtime_error'
            $report.rollback_orchestration.message = [string]$_.Exception.Message
            Add-ControlPlaneStateTransition `
                -StateMachine $report.state_machine `
                -FromState 'rollback_orchestration' `
                -Result 'fail' `
                -ToState 'failed' `
                -ReasonCode 'rollback_orchestration_runtime_error' `
                -Detail ([string]$_.Exception.Message)
        }
    } else {
        $report.rollback_orchestration.attempted = $false
        $report.rollback_orchestration.status = 'skipped'
        $report.rollback_orchestration.reason_code = [string]$rollbackDecision.decision_reason
        $report.rollback_orchestration.message = 'Rollback orchestration skipped by policy decision.'
        Add-ControlPlaneStateTransition `
            -StateMachine $report.state_machine `
            -FromState 'rollback_orchestration' `
            -Result 'fail' `
            -ToState 'failed' `
            -ReasonCode ([string]$rollbackDecision.decision_reason)
    }
}
finally {
    Write-WorkflowOpsReport -Report $report -OutputPath $OutputPath | Out-Null
    try {
        Write-StableOverrideAuditReport -ControlPlaneReport $report -OutputPath $OverrideAuditOutputPath
    } catch {
        Write-Warning ("[stable_override_audit_warning] {0}" -f [string]$_.Exception.Message)
    }
    if (Test-Path -LiteralPath $scratchRoot -PathType Container) {
        Remove-Item -LiteralPath $scratchRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

if ([string]$report.status -eq 'pass') {
    exit 0
}

exit 1
