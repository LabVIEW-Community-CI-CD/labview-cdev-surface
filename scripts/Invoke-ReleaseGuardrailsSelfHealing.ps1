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
    [ValidatePattern('^[A-Za-z0-9._/-]+$')]
    [string]$DrillWorkflow = 'release-race-hardening-drill.yml',

    [Parameter()]
    [ValidateRange(1, 720)]
    [int]$RaceGateMaxAgeHours = 168,

    [Parameter()]
    [bool]$AutoSelfHeal = $true,

    [Parameter()]
    [ValidateRange(1, 5)]
    [int]$MaxAttempts = 1,

    [Parameter()]
    [ValidateRange(5, 240)]
    [int]$DrillWatchTimeoutMinutes = 120,

    [Parameter()]
    [string]$OutputPath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'lib/WorkflowOps.Common.ps1')

$branchPolicyScript = Join-Path $PSScriptRoot 'Test-ReleaseBranchProtectionPolicy.ps1'
$setBranchPolicyScript = Join-Path $PSScriptRoot 'Set-ReleaseBranchProtectionPolicy.ps1'
$raceGateScript = Join-Path $PSScriptRoot 'Test-ReleaseRaceHardeningGate.ps1'
$dispatchWorkflowScript = Join-Path $PSScriptRoot 'Dispatch-WorkflowAtRemoteHead.ps1'
$watchWorkflowScript = Join-Path $PSScriptRoot 'Watch-WorkflowRun.ps1'

foreach ($requiredScript in @($branchPolicyScript, $setBranchPolicyScript, $raceGateScript, $dispatchWorkflowScript, $watchWorkflowScript)) {
    if (-not (Test-Path -LiteralPath $requiredScript -PathType Leaf)) {
        throw "required_script_missing: $requiredScript"
    }
}

function ConvertTo-StringArray {
    param([Parameter()][AllowNull()]$Value)

    if ($null -eq $Value) {
        return @()
    }

    if ($Value -is [string]) {
        if ([string]::IsNullOrWhiteSpace([string]$Value)) {
            return @()
        }
        return @([string]$Value)
    }

    $items = [System.Collections.Generic.List[string]]::new()
    foreach ($entry in @($Value)) {
        $text = [string]$entry
        if ([string]::IsNullOrWhiteSpace($text)) {
            continue
        }
        if (-not $items.Contains($text)) {
            [void]$items.Add($text)
        }
    }

    return @($items)
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

    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $DefaultValue
    }

    return $property.Value
}

function Get-ReasonCodesFromReport {
    param([Parameter()][AllowNull()]$Report)

    return @(
        ConvertTo-StringArray -Value (Get-PropertyValueOrDefault -Object $Report -Name 'reason_codes' -DefaultValue @())
    )
}

function Format-ReasonCodeSet {
    param([Parameter()][string[]]$ReasonCodes = @())

    $normalized = ConvertTo-StringArray -Value $ReasonCodes
    if (@($normalized).Count -eq 0) {
        return 'none'
    }

    return [string]::Join(',', @($normalized))
}

function Get-GuardrailsRemediationHints {
    param(
        [Parameter()][string[]]$BranchReasonCodes = @(),
        [Parameter()][string[]]$RaceReasonCodes = @()
    )

    $hints = [System.Collections.Generic.List[string]]::new()
    $normalizedBranchReasons = ConvertTo-StringArray -Value $BranchReasonCodes
    $normalizedRaceReasons = ConvertTo-StringArray -Value $RaceReasonCodes

    if (@($normalizedBranchReasons) -contains 'branch_protection_authentication_missing') {
        [void]$hints.Add('Configure WORKFLOW_BOT_TOKEN (or GH_TOKEN) with repository administration read/write permissions before rerunning guardrails remediation.')
    }
    if (@($normalizedBranchReasons) -contains 'branch_protection_authz_denied') {
        [void]$hints.Add('Token lacks sufficient repository administration permissions for branch-protection GraphQL operations; rotate/replace WORKFLOW_BOT_TOKEN and rerun.')
    }
    if (@($normalizedBranchReasons) -contains 'branch_protection_query_failed' -and @($hints).Count -eq 0) {
        [void]$hints.Add('Review branch-protection query connectivity/authentication in GitHub Actions logs, then rerun guardrails remediation.')
    }
    if (@($normalizedRaceReasons) -contains 'drill_run_stale') {
        [void]$hints.Add('Dispatch release-race-hardening-drill.yml and confirm a fresh successful run is available before re-evaluating guardrails.')
    }

    return @($hints)
}

function Test-ContainsAnyReasonCode {
    param(
        [Parameter()][string[]]$Source = @(),
        [Parameter()][string[]]$Candidates = @()
    )

    $normalizedSource = ConvertTo-StringArray -Value $Source
    foreach ($reason in @($normalizedSource)) {
        if (@($Candidates) -contains [string]$reason) {
            return $true
        }
    }

    return $false
}

function Invoke-BranchPolicyAssessment {
    param(
        [Parameter(Mandatory = $true)][string]$ScriptPath,
        [Parameter(Mandatory = $true)][string]$RepositorySlug,
        [Parameter(Mandatory = $true)][string]$ReportPath
    )

    $runtimeError = ''
    $exitCode = 1
    try {
        & pwsh -NoProfile -File $ScriptPath `
            -Repository $RepositorySlug `
            -OutputPath $ReportPath | Out-Null
        $exitCode = if ($null -eq $LASTEXITCODE) { 0 } else { [int]$LASTEXITCODE }
    } catch {
        $runtimeError = [string]$_.Exception.Message
        $exitCode = 1
    }

    $report = $null
    if (Test-Path -LiteralPath $ReportPath -PathType Leaf) {
        $report = Get-Content -LiteralPath $ReportPath -Raw | ConvertFrom-Json -Depth 100 -ErrorAction Stop
    }

    if ($null -eq $report) {
        $report = [pscustomobject]@{
            status = 'fail'
            reason_codes = @('branch_policy_report_missing')
            message = if ([string]::IsNullOrWhiteSpace($runtimeError)) { "branch_policy_report_missing: $ReportPath" } else { $runtimeError }
        }
    } elseif (-not [string]::IsNullOrWhiteSpace($runtimeError)) {
        $report.status = 'fail'
        $report.reason_codes = @('branch_policy_runtime_error')
        $report.message = $runtimeError
    }

    return [pscustomobject]@{
        exit_code = $exitCode
        report = $report
    }
}

function Invoke-RaceGateAssessment {
    param(
        [Parameter(Mandatory = $true)][string]$ScriptPath,
        [Parameter(Mandatory = $true)][string]$RepositorySlug,
        [Parameter(Mandatory = $true)][string]$SourceBranch,
        [Parameter(Mandatory = $true)][int]$MaxAgeHours,
        [Parameter(Mandatory = $true)][string]$ReportPath
    )

    $runtimeError = ''
    $exitCode = 1
    try {
        & pwsh -NoProfile -File $ScriptPath `
            -Repository $RepositorySlug `
            -SourceBranch $SourceBranch `
            -MaxAgeHours $MaxAgeHours `
            -OutputPath $ReportPath | Out-Null
        $exitCode = if ($null -eq $LASTEXITCODE) { 0 } else { [int]$LASTEXITCODE }
    } catch {
        $runtimeError = [string]$_.Exception.Message
        $exitCode = 1
    }

    $report = $null
    if (Test-Path -LiteralPath $ReportPath -PathType Leaf) {
        $report = Get-Content -LiteralPath $ReportPath -Raw | ConvertFrom-Json -Depth 100 -ErrorAction Stop
    }

    if ($null -eq $report) {
        $report = [pscustomobject]@{
            status = 'fail'
            reason_codes = @('race_gate_report_missing')
            message = if ([string]::IsNullOrWhiteSpace($runtimeError)) { "race_gate_report_missing: $ReportPath" } else { $runtimeError }
        }
    } elseif (-not [string]::IsNullOrWhiteSpace($runtimeError)) {
        $report.status = 'fail'
        $report.reason_codes = @('race_gate_runtime_error')
        $report.message = $runtimeError
    }

    return [pscustomobject]@{
        exit_code = $exitCode
        report = $report
    }
}

function New-AssessmentSummary {
    param([Parameter(Mandatory = $true)]$Assessment)

    $assessmentReport = $Assessment.report
    return [ordered]@{
        status = [string](Get-PropertyValueOrDefault -Object $assessmentReport -Name 'status' -DefaultValue 'fail')
        reason_codes = @(
            ConvertTo-StringArray -Value (Get-PropertyValueOrDefault -Object $assessmentReport -Name 'reason_codes' -DefaultValue @())
        )
        message = [string](Get-PropertyValueOrDefault -Object $assessmentReport -Name 'message' -DefaultValue '')
        exit_code = [int]$Assessment.exit_code
    }
}

function Test-IsAssessmentPass {
    param([Parameter(Mandatory = $true)]$Assessment)

    return ([string](Get-PropertyValueOrDefault -Object $Assessment.report -Name 'status' -DefaultValue 'fail') -eq 'pass')
}

$scratchRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("release-guardrails-self-heal-" + [Guid]::NewGuid().ToString('N'))
New-Item -Path $scratchRoot -ItemType Directory -Force | Out-Null

$report = [ordered]@{
    schema_version = '1.0'
    generated_at_utc = Get-UtcNowIso
    repository = $Repository
    branch = $Branch
    drill_workflow = $DrillWorkflow
    race_gate_max_age_hours = $RaceGateMaxAgeHours
    auto_self_heal = [bool]$AutoSelfHeal
    max_attempts = $MaxAttempts
    drill_watch_timeout_minutes = $DrillWatchTimeoutMinutes
    status = 'fail'
    reason_code = ''
    message = ''
    remediation_hints = @()
    initial_assessment = $null
    remediation_attempts = @()
    final_assessment = $null
}

try {
    $initialBranchPath = Join-Path $scratchRoot 'initial-branch-policy.json'
    $initialRacePath = Join-Path $scratchRoot 'initial-race-gate.json'
    $currentBranchAssessment = Invoke-BranchPolicyAssessment -ScriptPath $branchPolicyScript -RepositorySlug $Repository -ReportPath $initialBranchPath
    $currentRaceAssessment = Invoke-RaceGateAssessment -ScriptPath $raceGateScript -RepositorySlug $Repository -SourceBranch $Branch -MaxAgeHours $RaceGateMaxAgeHours -ReportPath $initialRacePath

    $report.initial_assessment = [ordered]@{
        branch_protection = New-AssessmentSummary -Assessment $currentBranchAssessment
        release_race_gate = New-AssessmentSummary -Assessment $currentRaceAssessment
    }
    $report.final_assessment = $report.initial_assessment

    $branchPass = Test-IsAssessmentPass -Assessment $currentBranchAssessment
    $racePass = Test-IsAssessmentPass -Assessment $currentRaceAssessment

    if ($branchPass -and $racePass) {
        $report.status = 'pass'
        $report.reason_code = 'already_healthy'
        $report.message = 'Release guardrails are already passing. No remediation required.'
    } elseif (-not $AutoSelfHeal) {
        $report.status = 'fail'
        $report.reason_code = 'auto_remediation_disabled'
        $report.message = 'Release guardrails failed and auto-remediation is disabled.'
    } else {
        $branchAutomatableReasons = @(
            'main_rule_missing',
            'main_rule_mismatch',
            'integration_rule_missing',
            'integration_rule_mismatch'
        )
        $raceAutomatableReasons = @(
            'drill_run_missing',
            'drill_run_stale',
            'drill_report_missing',
            'drill_report_download_failed'
        )

        $attemptRecords = [System.Collections.Generic.List[object]]::new()
        $executionFailureCount = 0
        $noAutomatableAction = $false
        $recovered = $false
        $normalizedMaxAttempts = [Math]::Max(1, [Math]::Min($MaxAttempts, 5))

        for ($attempt = 1; $attempt -le $normalizedMaxAttempts; $attempt++) {
            $attemptRecord = [ordered]@{
                attempt = $attempt
                status = 'pending'
                pre_assessment = [ordered]@{
                    branch_protection = New-AssessmentSummary -Assessment $currentBranchAssessment
                    release_race_gate = New-AssessmentSummary -Assessment $currentRaceAssessment
                }
                actions = @()
                error = ''
                post_assessment = $null
            }

            $actions = [System.Collections.Generic.List[object]]::new()
            $attemptHasAutomatableAction = $false
            $attemptExecutionError = ''

            $preBranchReasonCodes = Get-ReasonCodesFromReport -Report $currentBranchAssessment.report
            $preRaceReasonCodes = Get-ReasonCodesFromReport -Report $currentRaceAssessment.report
            $branchRequiresRemediation = (-not (Test-IsAssessmentPass -Assessment $currentBranchAssessment))
            $raceRequiresRemediation = (-not (Test-IsAssessmentPass -Assessment $currentRaceAssessment))

            try {
                if ($branchRequiresRemediation) {
                    if (Test-ContainsAnyReasonCode -Source @($preBranchReasonCodes) -Candidates @($branchAutomatableReasons)) {
                        $applyPath = Join-Path $scratchRoot ("attempt-{0}-branch-apply.json" -f $attempt)
                        & pwsh -NoProfile -File $setBranchPolicyScript `
                            -Repository $Repository `
                            -OutputPath $applyPath | Out-Null
                        if ($LASTEXITCODE -ne 0) {
                            throw "branch_protection_apply_failed: attempt=$attempt exit_code=$LASTEXITCODE"
                        }

                        $applyReport = Get-Content -LiteralPath $applyPath -Raw | ConvertFrom-Json -Depth 100 -ErrorAction Stop
                        [void]$actions.Add([ordered]@{
                                action = 'apply_branch_protection_policy'
                                status = [string](Get-PropertyValueOrDefault -Object $applyReport -Name 'status' -DefaultValue 'unknown')
                                reason_codes = @(
                                    ConvertTo-StringArray -Value (Get-PropertyValueOrDefault -Object $applyReport -Name 'reason_codes' -DefaultValue @())
                                )
                                message = [string](Get-PropertyValueOrDefault -Object $applyReport -Name 'message' -DefaultValue '')
                            })
                        $attemptHasAutomatableAction = $true
                    } else {
                        [void]$actions.Add([ordered]@{
                                action = 'apply_branch_protection_policy'
                                status = 'skipped'
                                reason_codes = @('no_automatable_reason_code')
                                message = "Branch protection check failed with non-automatable reason codes: $(Format-ReasonCodeSet -ReasonCodes $preBranchReasonCodes)"
                            })
                    }
                }

                if ($raceRequiresRemediation) {
                    if (Test-ContainsAnyReasonCode -Source @($preRaceReasonCodes) -Candidates @($raceAutomatableReasons)) {
                        $dispatchPath = Join-Path $scratchRoot ("attempt-{0}-race-drill-dispatch.json" -f $attempt)
                        $dispatchInputs = @(
                            'auto_remediate=true',
                            'keep_latest_canary_n=1',
                            "watch_timeout_minutes=$DrillWatchTimeoutMinutes"
                        )
                        & pwsh -NoProfile -File $dispatchWorkflowScript `
                            -Repository $Repository `
                            -WorkflowFile $DrillWorkflow `
                            -Branch $Branch `
                            -Inputs $dispatchInputs `
                            -OutputPath $dispatchPath | Out-Null
                        if ($LASTEXITCODE -ne 0) {
                            throw "race_drill_dispatch_failed: attempt=$attempt exit_code=$LASTEXITCODE"
                        }
                        $dispatchReport = Get-Content -LiteralPath $dispatchPath -Raw | ConvertFrom-Json -Depth 100 -ErrorAction Stop
                        [void]$actions.Add([ordered]@{
                                action = 'dispatch_release_race_hardening_drill'
                                status = 'success'
                                run_id = [string](Get-PropertyValueOrDefault -Object $dispatchReport -Name 'run_id' -DefaultValue '')
                                run_url = [string](Get-PropertyValueOrDefault -Object $dispatchReport -Name 'url' -DefaultValue '')
                            })

                        $watchPath = Join-Path $scratchRoot ("attempt-{0}-race-drill-watch.json" -f $attempt)
                        & pwsh -NoProfile -File $watchWorkflowScript `
                            -Repository $Repository `
                            -RunId ([string](Get-PropertyValueOrDefault -Object $dispatchReport -Name 'run_id' -DefaultValue '')) `
                            -TimeoutMinutes $DrillWatchTimeoutMinutes `
                            -OutputPath $watchPath | Out-Null
                        if ($LASTEXITCODE -ne 0) {
                            throw "race_drill_watch_failed: attempt=$attempt run_id=$([string](Get-PropertyValueOrDefault -Object $dispatchReport -Name 'run_id' -DefaultValue '')) exit_code=$LASTEXITCODE"
                        }

                        $watchReport = Get-Content -LiteralPath $watchPath -Raw | ConvertFrom-Json -Depth 100 -ErrorAction Stop
                        [void]$actions.Add([ordered]@{
                                action = 'watch_release_race_hardening_drill'
                                status = [string](Get-PropertyValueOrDefault -Object $watchReport -Name 'conclusion' -DefaultValue 'unknown')
                                run_id = [string](Get-PropertyValueOrDefault -Object $watchReport -Name 'run_id' -DefaultValue '')
                                run_url = [string](Get-PropertyValueOrDefault -Object $watchReport -Name 'url' -DefaultValue '')
                                classified_reason = [string](Get-PropertyValueOrDefault -Object $watchReport -Name 'classified_reason' -DefaultValue '')
                            })

                        $attemptHasAutomatableAction = $true
                    } else {
                        [void]$actions.Add([ordered]@{
                                action = 'dispatch_release_race_hardening_drill'
                                status = 'skipped'
                                reason_codes = @('no_automatable_reason_code')
                                message = "Race-hardening gate failed with non-automatable reason codes: $(Format-ReasonCodeSet -ReasonCodes $preRaceReasonCodes)"
                            })
                    }
                }
            } catch {
                $executionFailureCount++
                $attemptExecutionError = [string]$_.Exception.Message
            }

            $attemptRecord.actions = @($actions)

            if (-not [string]::IsNullOrWhiteSpace($attemptExecutionError)) {
                $attemptRecord.status = 'remediation_execution_failed'
                $attemptRecord.error = $attemptExecutionError
                [void]$attemptRecords.Add($attemptRecord)
                continue
            }

            if (-not $attemptHasAutomatableAction) {
                $attemptRecord.status = 'no_automatable_action'
                $attemptRecord.error = 'No automatable guardrail remediation path for current reason codes.'
                [void]$attemptRecords.Add($attemptRecord)
                $noAutomatableAction = $true
                break
            }

            $verifyBranchPath = Join-Path $scratchRoot ("attempt-{0}-verify-branch-policy.json" -f $attempt)
            $verifyRacePath = Join-Path $scratchRoot ("attempt-{0}-verify-race-gate.json" -f $attempt)
            $currentBranchAssessment = Invoke-BranchPolicyAssessment -ScriptPath $branchPolicyScript -RepositorySlug $Repository -ReportPath $verifyBranchPath
            $currentRaceAssessment = Invoke-RaceGateAssessment -ScriptPath $raceGateScript -RepositorySlug $Repository -SourceBranch $Branch -MaxAgeHours $RaceGateMaxAgeHours -ReportPath $verifyRacePath

            $attemptRecord.post_assessment = [ordered]@{
                branch_protection = New-AssessmentSummary -Assessment $currentBranchAssessment
                release_race_gate = New-AssessmentSummary -Assessment $currentRaceAssessment
            }

            if ((Test-IsAssessmentPass -Assessment $currentBranchAssessment) -and (Test-IsAssessmentPass -Assessment $currentRaceAssessment)) {
                $attemptRecord.status = 'recovered'
                [void]$attemptRecords.Add($attemptRecord)
                $recovered = $true
                break
            }

            $attemptRecord.status = 'verify_failed'
            [void]$attemptRecords.Add($attemptRecord)
        }

        $report.remediation_attempts = @($attemptRecords)
        $report.final_assessment = [ordered]@{
            branch_protection = New-AssessmentSummary -Assessment $currentBranchAssessment
            release_race_gate = New-AssessmentSummary -Assessment $currentRaceAssessment
        }

        if ($recovered) {
            $report.status = 'pass'
            $report.reason_code = 'remediated'
            $report.message = 'Release guardrails auto-remediation completed and verification passed.'
        } elseif ($noAutomatableAction) {
            $report.status = 'fail'
            $report.reason_code = 'no_automatable_action'
            $finalBranchReasons = Get-ReasonCodesFromReport -Report $currentBranchAssessment.report
            $finalRaceReasons = Get-ReasonCodesFromReport -Report $currentRaceAssessment.report
            $report.remediation_hints = @(
                Get-GuardrailsRemediationHints -BranchReasonCodes @($finalBranchReasons) -RaceReasonCodes @($finalRaceReasons)
            )
            $hintText = if (@($report.remediation_hints).Count -gt 0) { " remediation_hints=$([string]::Join(' | ', @($report.remediation_hints)))" } else { '' }
            $report.message = "No automatable remediation path. branch_reason_codes=$(Format-ReasonCodeSet -ReasonCodes $finalBranchReasons) race_reason_codes=$(Format-ReasonCodeSet -ReasonCodes $finalRaceReasons)"
            if (-not [string]::IsNullOrWhiteSpace($hintText)) {
                $report.message = "$($report.message)$hintText"
            }
        } elseif ($executionFailureCount -gt 0) {
            $report.status = 'fail'
            $report.reason_code = 'remediation_execution_failed'
            $report.message = 'One or more remediation execution steps failed before verification could pass.'
        } else {
            $report.status = 'fail'
            $report.reason_code = 'remediation_verify_failed'
            $finalBranchReasons = Get-ReasonCodesFromReport -Report $currentBranchAssessment.report
            $finalRaceReasons = Get-ReasonCodesFromReport -Report $currentRaceAssessment.report
            $report.remediation_hints = @(
                Get-GuardrailsRemediationHints -BranchReasonCodes @($finalBranchReasons) -RaceReasonCodes @($finalRaceReasons)
            )
            $hintText = if (@($report.remediation_hints).Count -gt 0) { " remediation_hints=$([string]::Join(' | ', @($report.remediation_hints)))" } else { '' }
            $report.message = "Guardrails remain failing after bounded remediation. branch_reason_codes=$(Format-ReasonCodeSet -ReasonCodes $finalBranchReasons) race_reason_codes=$(Format-ReasonCodeSet -ReasonCodes $finalRaceReasons)"
            if (-not [string]::IsNullOrWhiteSpace($hintText)) {
                $report.message = "$($report.message)$hintText"
            }
        }
    }
}
catch {
    $report.status = 'fail'
    $report.reason_code = 'guardrails_self_heal_runtime_error'
    $report.message = [string]$_.Exception.Message
}
finally {
    Write-WorkflowOpsReport -Report $report -OutputPath $OutputPath | Out-Null
    if (Test-Path -LiteralPath $scratchRoot -PathType Container) {
        Remove-Item -LiteralPath $scratchRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

if ([string]$report.status -eq 'pass') {
    exit 0
}

exit 1
