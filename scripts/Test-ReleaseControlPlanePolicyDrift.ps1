#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter()]
    [string]$ManifestPath = 'workspace-governance.json',

    [Parameter()]
    [string]$PayloadManifestPath = 'workspace-governance-payload/workspace-governance/workspace-governance.json',

    [Parameter()]
    [string]$OutputPath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'lib/WorkflowOps.Common.ps1')

function Add-ReasonCode {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][System.Collections.Generic.List[string]]$Target,
        [Parameter(Mandatory = $true)][string]$ReasonCode
    )

    if (-not $Target.Contains($ReasonCode)) {
        [void]$Target.Add($ReasonCode)
    }
}

$report = [ordered]@{
    schema_version = '1.0'
    generated_at_utc = Get-UtcNowIso
    manifest_path = $ManifestPath
    payload_manifest_path = $PayloadManifestPath
    status = 'fail'
    reason_codes = @()
    message = ''
    checks = @()
}

$reasonCodes = [System.Collections.Generic.List[string]]::new()
$checks = [System.Collections.Generic.List[object]]::new()

try {
    $resolvedManifestPath = [System.IO.Path]::GetFullPath($ManifestPath)
    $resolvedPayloadManifestPath = [System.IO.Path]::GetFullPath($PayloadManifestPath)
    $report.manifest_path = $resolvedManifestPath
    $report.payload_manifest_path = $resolvedPayloadManifestPath

    if (-not (Test-Path -LiteralPath $resolvedManifestPath -PathType Leaf)) {
        Add-ReasonCode -Target $reasonCodes -ReasonCode 'manifest_missing'
    }
    if (-not (Test-Path -LiteralPath $resolvedPayloadManifestPath -PathType Leaf)) {
        Add-ReasonCode -Target $reasonCodes -ReasonCode 'payload_manifest_missing'
    }

    if ($reasonCodes.Count -eq 0) {
        $manifest = Get-Content -LiteralPath $resolvedManifestPath -Raw | ConvertFrom-Json -Depth 100
        $payloadManifest = Get-Content -LiteralPath $resolvedPayloadManifestPath -Raw | ConvertFrom-Json -Depth 100

        $releaseClient = $manifest.installer_contract.release_client
        $payloadReleaseClient = $payloadManifest.installer_contract.release_client

        if ($null -eq $releaseClient -or $null -eq $payloadReleaseClient) {
            Add-ReasonCode -Target $reasonCodes -ReasonCode 'release_client_missing'
        } else {
            $releaseClientJson = $releaseClient | ConvertTo-Json -Depth 100
            $payloadReleaseClientJson = $payloadReleaseClient | ConvertTo-Json -Depth 100
            $matches = [string]::Equals($releaseClientJson, $payloadReleaseClientJson, [System.StringComparison]::Ordinal)
            $checks.Add([ordered]@{
                    check = 'release_client_equivalent'
                    passed = $matches
                }) | Out-Null
            if (-not $matches) {
                Add-ReasonCode -Target $reasonCodes -ReasonCode 'release_client_drift'
            }

            $runtimeImagesPresent = ($null -ne $releaseClient.runtime_images)
            $checks.Add([ordered]@{
                    check = 'release_client_runtime_images_present'
                    passed = $runtimeImagesPresent
                }) | Out-Null
            if (-not $runtimeImagesPresent) {
                Add-ReasonCode -Target $reasonCodes -ReasonCode 'runtime_images_missing'
            }

            $opsPolicyPresent = ($null -ne $releaseClient.ops_control_plane_policy)
            $checks.Add([ordered]@{
                    check = 'release_client_ops_control_plane_policy_present'
                    passed = $opsPolicyPresent
                }) | Out-Null
            if (-not $opsPolicyPresent) {
                Add-ReasonCode -Target $reasonCodes -ReasonCode 'ops_control_plane_policy_missing'
            } else {
                $policySchemaVersionValid = ([string]$releaseClient.ops_control_plane_policy.schema_version -eq '2.0')
                $checks.Add([ordered]@{
                        check = 'release_client_ops_control_plane_policy_schema_version_valid'
                        passed = $policySchemaVersionValid
                    }) | Out-Null
                if (-not $policySchemaVersionValid) {
                    Add-ReasonCode -Target $reasonCodes -ReasonCode 'ops_control_plane_schema_version_invalid'
                }

                $stateMachinePresent = ($null -ne $releaseClient.ops_control_plane_policy.state_machine)
                $checks.Add([ordered]@{
                        check = 'release_client_ops_control_plane_policy_state_machine_present'
                        passed = $stateMachinePresent
                    }) | Out-Null
                if (-not $stateMachinePresent) {
                    Add-ReasonCode -Target $reasonCodes -ReasonCode 'ops_control_plane_state_machine_missing'
                } else {
                    $stateMachineVersionPresent = (-not [string]::IsNullOrWhiteSpace([string]$releaseClient.ops_control_plane_policy.state_machine.version))
                    $checks.Add([ordered]@{
                            check = 'release_client_ops_control_plane_policy_state_machine_version_present'
                            passed = $stateMachineVersionPresent
                        }) | Out-Null
                    if (-not $stateMachineVersionPresent) {
                        Add-ReasonCode -Target $reasonCodes -ReasonCode 'ops_control_plane_state_machine_version_missing'
                    }
                }

                $rollbackOrchestrationPresent = ($null -ne $releaseClient.ops_control_plane_policy.rollback_orchestration)
                $checks.Add([ordered]@{
                        check = 'release_client_ops_control_plane_policy_rollback_orchestration_present'
                        passed = $rollbackOrchestrationPresent
                    }) | Out-Null
                if (-not $rollbackOrchestrationPresent) {
                    Add-ReasonCode -Target $reasonCodes -ReasonCode 'ops_control_plane_rollback_orchestration_missing'
                }

                $errorBudgetPresent = ($null -ne $releaseClient.ops_control_plane_policy.error_budget)
                $checks.Add([ordered]@{
                        check = 'release_client_ops_control_plane_policy_error_budget_present'
                        passed = $errorBudgetPresent
                    }) | Out-Null
                if (-not $errorBudgetPresent) {
                    Add-ReasonCode -Target $reasonCodes -ReasonCode 'ops_control_plane_error_budget_missing'
                } else {
                    $errorBudgetWindowValid = ([int]$releaseClient.ops_control_plane_policy.error_budget.window_days -ge 1)
                    $checks.Add([ordered]@{
                            check = 'release_client_ops_control_plane_policy_error_budget_window_days_valid'
                            passed = $errorBudgetWindowValid
                        }) | Out-Null
                    if (-not $errorBudgetWindowValid) {
                        Add-ReasonCode -Target $reasonCodes -ReasonCode 'ops_control_plane_error_budget_window_days_invalid'
                    }
                }

                $sloAlertThresholdsPresent = ($null -ne $releaseClient.ops_control_plane_policy.slo_gate.alert_thresholds)
                $checks.Add([ordered]@{
                        check = 'release_client_ops_control_plane_policy_slo_alert_thresholds_present'
                        passed = $sloAlertThresholdsPresent
                    }) | Out-Null
                if (-not $sloAlertThresholdsPresent) {
                    Add-ReasonCode -Target $reasonCodes -ReasonCode 'ops_control_plane_slo_alert_thresholds_missing'
                }

                $selfHealingPresent = ($null -ne $releaseClient.ops_control_plane_policy.self_healing)
                $checks.Add([ordered]@{
                        check = 'release_client_ops_control_plane_policy_self_healing_present'
                        passed = $selfHealingPresent
                    }) | Out-Null
                if (-not $selfHealingPresent) {
                    Add-ReasonCode -Target $reasonCodes -ReasonCode 'ops_control_plane_self_healing_missing'
                } else {
                    $guardrailsPolicyPresent = ($null -ne $releaseClient.ops_control_plane_policy.self_healing.guardrails)
                    $checks.Add([ordered]@{
                            check = 'release_client_ops_control_plane_policy_self_healing_guardrails_present'
                            passed = $guardrailsPolicyPresent
                        }) | Out-Null
                    if (-not $guardrailsPolicyPresent) {
                        Add-ReasonCode -Target $reasonCodes -ReasonCode 'ops_control_plane_guardrails_missing'
                    }
                }

                $stableWindowPresent = ($null -ne $releaseClient.ops_control_plane_policy.stable_promotion_window)
                $checks.Add([ordered]@{
                        check = 'release_client_ops_control_plane_policy_stable_window_present'
                        passed = $stableWindowPresent
                    }) | Out-Null
                if (-not $stableWindowPresent) {
                    Add-ReasonCode -Target $reasonCodes -ReasonCode 'ops_control_plane_stable_window_missing'
                } else {
                    $stableWindowPatternPresent = (-not [string]::IsNullOrWhiteSpace([string]$releaseClient.ops_control_plane_policy.stable_promotion_window.override_reason_pattern))
                    $checks.Add([ordered]@{
                            check = 'release_client_ops_control_plane_policy_stable_window_reason_pattern_present'
                            passed = $stableWindowPatternPresent
                        }) | Out-Null
                    if (-not $stableWindowPatternPresent) {
                        Add-ReasonCode -Target $reasonCodes -ReasonCode 'ops_control_plane_stable_window_reason_pattern_missing'
                    }

                    $stableWindowReasonExamplePresent = (-not [string]::IsNullOrWhiteSpace([string]$releaseClient.ops_control_plane_policy.stable_promotion_window.override_reason_example))
                    $checks.Add([ordered]@{
                            check = 'release_client_ops_control_plane_policy_stable_window_reason_example_present'
                            passed = $stableWindowReasonExamplePresent
                        }) | Out-Null
                    if (-not $stableWindowReasonExamplePresent) {
                        Add-ReasonCode -Target $reasonCodes -ReasonCode 'ops_control_plane_stable_window_reason_example_missing'
                    }
                }
            }
        }
    }

    $report.checks = @($checks)
    if ($reasonCodes.Count -eq 0) {
        $report.status = 'pass'
        $report.reason_codes = @('ok')
        $report.message = 'Release control-plane policy drift check passed.'
    } else {
        $report.status = 'fail'
        $report.reason_codes = @($reasonCodes)
        $report.message = "Release control-plane policy drift check failed. reason_codes=$([string]::Join(',', @($reasonCodes)))"
    }
}
catch {
    $report.status = 'fail'
    $report.reason_codes = @('policy_drift_runtime_error')
    $report.message = [string]$_.Exception.Message
}
finally {
    Write-WorkflowOpsReport -Report $report -OutputPath $OutputPath | Out-Null
}

if ([string]$report.status -eq 'pass') {
    exit 0
}

exit 1
