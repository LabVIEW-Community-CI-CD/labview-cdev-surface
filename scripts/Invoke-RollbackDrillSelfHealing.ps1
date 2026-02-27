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
    [ValidateSet('stable', 'prerelease', 'canary')]
    [string]$Channel = 'canary',

    [Parameter()]
    [ValidateRange(2, 100)]
    [int]$RequiredHistoryCount = 2,

    [Parameter()]
    [ValidateRange(10, 200)]
    [int]$ReleaseLimit = 100,

    [Parameter()]
    [bool]$AutoRemediate = $true,

    [Parameter()]
    [ValidatePattern('^[A-Za-z0-9._/-]+$')]
    [string]$ReleaseWorkflowFile = 'release-workspace-installer.yml',

    [Parameter()]
    [ValidateRange(1, 5)]
    [int]$MaxAttempts = 1,

    [Parameter()]
    [ValidateRange(5, 240)]
    [int]$WatchTimeoutMinutes = 120,

    [Parameter()]
    [ValidateRange(1, 49)]
    [int]$CanarySequenceMin = 1,

    [Parameter()]
    [ValidateRange(1, 99)]
    [int]$CanarySequenceMax = 49,

    [Parameter()]
    [string]$OutputPath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'lib/WorkflowOps.Common.ps1')

$rollbackDrillScript = Join-Path $PSScriptRoot 'Invoke-ReleaseRollbackDrill.ps1'
$dispatchWorkflowScript = Join-Path $PSScriptRoot 'Dispatch-WorkflowAtRemoteHead.ps1'
$watchWorkflowScript = Join-Path $PSScriptRoot 'Watch-WorkflowRun.ps1'

foreach ($requiredScript in @($rollbackDrillScript, $dispatchWorkflowScript, $watchWorkflowScript)) {
    if (-not (Test-Path -LiteralPath $requiredScript -PathType Leaf)) {
        throw "required_script_missing: $requiredScript"
    }
}

function Parse-ReleaseTagRecord {
    param([Parameter(Mandatory = $true)][string]$TagName)

    $match = [regex]::Match($TagName, '^v0\.(?<date>\d{8})\.(?<sequence>\d+)$')
    if (-not $match.Success) {
        return $null
    }

    $sequence = 0
    if (-not [int]::TryParse([string]$match.Groups['sequence'].Value, [ref]$sequence)) {
        return $null
    }

    return [pscustomobject]@{
        tag_name = $TagName
        date = [string]$match.Groups['date'].Value
        sequence = $sequence
    }
}

function Get-NextCanaryTag {
    param(
        [Parameter(Mandatory = $true)][string]$TargetRepository,
        [Parameter(Mandatory = $true)][int]$MaxReleases,
        [Parameter(Mandatory = $true)][int]$RangeMin,
        [Parameter(Mandatory = $true)][int]$RangeMax
    )

    if ($RangeMin -gt $RangeMax) {
        throw "canary_range_invalid: min=$RangeMin max=$RangeMax"
    }

    $dateKey = (Get-Date).ToUniversalTime().ToString('yyyyMMdd')
    $releases = @(Get-GhReleasesPortable -Repository $TargetRepository -Limit $MaxReleases -ExcludeDrafts)
    $matched = @()
    foreach ($release in $releases) {
        if (-not [bool]$release.isPrerelease) {
            continue
        }

        $parsed = Parse-ReleaseTagRecord -TagName ([string]$release.tagName)
        if ($null -eq $parsed) {
            continue
        }
        if ([string]$parsed.date -ne $dateKey) {
            continue
        }
        if ([int]$parsed.sequence -lt $RangeMin -or [int]$parsed.sequence -gt $RangeMax) {
            continue
        }

        $matched += [int]$parsed.sequence
    }

    $nextSequence = if (@($matched).Count -eq 0) {
        $RangeMin
    } else {
        ((@($matched) | Measure-Object -Maximum).Maximum + 1)
    }

    if ($nextSequence -gt $RangeMax) {
        throw "canary_tag_range_exhausted: date=$dateKey next_sequence=$nextSequence range_max=$RangeMax"
    }

    return [pscustomobject]@{
        date_key = $dateKey
        sequence = $nextSequence
        tag = "v0.$dateKey.$nextSequence"
    }
}

function Invoke-RollbackAssessment {
    param(
        [Parameter(Mandatory = $true)][string]$ScriptPath,
        [Parameter(Mandatory = $true)][string]$TargetRepository,
        [Parameter(Mandatory = $true)][string]$TargetChannel,
        [Parameter(Mandatory = $true)][int]$HistoryCount,
        [Parameter(Mandatory = $true)][int]$Limit,
        [Parameter(Mandatory = $true)][string]$ReportPath
    )

    $runtimeError = ''
    $exitCode = 1
    try {
        & pwsh -NoProfile -File $ScriptPath `
            -Repository $TargetRepository `
            -Channel $TargetChannel `
            -RequiredHistoryCount $HistoryCount `
            -ReleaseLimit $Limit `
            -OutputPath $ReportPath | Out-Null
        $exitCode = if ($null -eq $LASTEXITCODE) { 0 } else { [int]$LASTEXITCODE }
    } catch {
        $runtimeError = [string]$_.Exception.Message
        $exitCode = 1
    }

    $loadedReport = $null
    if (Test-Path -LiteralPath $ReportPath -PathType Leaf) {
        $loadedReport = Get-Content -LiteralPath $ReportPath -Raw | ConvertFrom-Json -ErrorAction Stop
    }

    if ($null -eq $loadedReport) {
        $message = if ([string]::IsNullOrWhiteSpace($runtimeError)) {
            "rollback_drill_report_missing: $ReportPath"
        } else {
            $runtimeError
        }
        $loadedReport = [pscustomobject]@{
            status = 'fail'
            reason_codes = @('rollback_drill_runtime_error')
            message = $message
            candidate_count = 0
        }
    } elseif (-not [string]::IsNullOrWhiteSpace($runtimeError)) {
        $loadedReport.status = 'fail'
        $loadedReport.reason_codes = @('rollback_drill_runtime_error')
        $loadedReport.message = $runtimeError
    }

    return [pscustomobject]@{
        exit_code = $exitCode
        report = $loadedReport
    }
}

$scratchRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("rollback-self-heal-" + [Guid]::NewGuid().ToString('N'))
New-Item -Path $scratchRoot -ItemType Directory -Force | Out-Null

$report = [ordered]@{
    schema_version = '1.0'
    generated_at_utc = Get-UtcNowIso
    repository = $Repository
    branch = $Branch
    channel = $Channel
    required_history_count = $RequiredHistoryCount
    release_limit = $ReleaseLimit
    auto_remediate = [bool]$AutoRemediate
    release_workflow = $ReleaseWorkflowFile
    max_attempts = $MaxAttempts
    watch_timeout_minutes = $WatchTimeoutMinutes
    canary_sequence_min = $CanarySequenceMin
    canary_sequence_max = $CanarySequenceMax
    status = 'fail'
    reason_code = ''
    message = ''
    initial_report = $null
    remediation_attempts = @()
    final_report = $null
}

try {
    $initialPath = Join-Path $scratchRoot 'initial-rollback-drill.json'
    $initialAssessment = Invoke-RollbackAssessment `
        -ScriptPath $rollbackDrillScript `
        -TargetRepository $Repository `
        -TargetChannel $Channel `
        -HistoryCount $RequiredHistoryCount `
        -Limit $ReleaseLimit `
        -ReportPath $initialPath
    $initialReport = $initialAssessment.report
    $report.initial_report = $initialReport
    $report.final_report = $initialReport

    if ([string]$initialReport.status -eq 'pass') {
        $report.status = 'pass'
        $report.reason_code = 'already_ready'
        $report.message = 'Rollback drill is already passing. No remediation was required.'
    } elseif (-not $AutoRemediate) {
        $report.status = 'fail'
        $report.reason_code = 'auto_remediation_disabled'
        $report.message = 'Rollback drill failed and auto-remediation is disabled.'
    } else {
        $initialReasons = @($initialReport.reason_codes | ForEach-Object { [string]$_ })
        $canAutomate = (($initialReasons -contains 'rollback_candidate_missing') -and ([string]$Channel -eq 'canary'))
        if (-not $canAutomate) {
            $report.status = 'fail'
            $report.reason_code = 'no_automatable_action'
            $report.message = "Rollback drill failed with no automatable remediation path. reason_codes=$([string]::Join(',', $initialReasons))"
        } else {
            $attemptRecords = [System.Collections.Generic.List[object]]::new()
            $recovered = $false
            $hadExecutionFailure = $false
            $lastExecutionError = ''
            $finalReport = $initialReport
            $normalizedMaxAttempts = [Math]::Max(1, [Math]::Min($MaxAttempts, 5))

            for ($attempt = 1; $attempt -le $normalizedMaxAttempts; $attempt++) {
                $attemptRecord = [ordered]@{
                    attempt = $attempt
                    status = 'pending'
                    target_tag = ''
                    dispatch = $null
                    watch = $null
                    verify = $null
                    error = ''
                }

                $executionOk = $true
                try {
                    $targetTagRecord = Get-NextCanaryTag `
                        -TargetRepository $Repository `
                        -MaxReleases $ReleaseLimit `
                        -RangeMin $CanarySequenceMin `
                        -RangeMax $CanarySequenceMax
                    $attemptRecord.target_tag = [string]$targetTagRecord.tag

                    $dispatchPath = Join-Path $scratchRoot ("attempt-{0}-dispatch.json" -f $attempt)
                    & pwsh -NoProfile -File $dispatchWorkflowScript `
                        -Repository $Repository `
                        -WorkflowFile $ReleaseWorkflowFile `
                        -Branch $Branch `
                        -Input @(
                            "release_tag=$([string]$targetTagRecord.tag)",
                            'allow_existing_tag=false',
                            'prerelease=true',
                            'release_channel=canary'
                        ) `
                        -OutputPath $dispatchPath | Out-Null
                    if ($LASTEXITCODE -ne 0) {
                        throw "rollback_auto_release_dispatch_failed: exit_code=$LASTEXITCODE"
                    }
                    $dispatchReport = Get-Content -LiteralPath $dispatchPath -Raw | ConvertFrom-Json -ErrorAction Stop
                    $attemptRecord.dispatch = [ordered]@{
                        run_id = [string]$dispatchReport.run_id
                        head_sha = [string]$dispatchReport.head_sha
                        url = [string]$dispatchReport.url
                    }

                    $watchPath = Join-Path $scratchRoot ("attempt-{0}-watch.json" -f $attempt)
                    & pwsh -NoProfile -File $watchWorkflowScript `
                        -Repository $Repository `
                        -RunId ([string]$dispatchReport.run_id) `
                        -TimeoutMinutes $WatchTimeoutMinutes `
                        -OutputPath $watchPath | Out-Null
                    if ($LASTEXITCODE -ne 0) {
                        throw "rollback_auto_release_watch_failed: run_id=$([string]$dispatchReport.run_id) exit_code=$LASTEXITCODE"
                    }
                    $watchReport = Get-Content -LiteralPath $watchPath -Raw | ConvertFrom-Json -ErrorAction Stop
                    $attemptRecord.watch = [ordered]@{
                        run_id = [string]$watchReport.run_id
                        conclusion = [string]$watchReport.conclusion
                        url = [string]$watchReport.url
                        classified_reason = [string]$watchReport.classified_reason
                    }
                } catch {
                    $executionOk = $false
                    $hadExecutionFailure = $true
                    $lastExecutionError = [string]$_.Exception.Message
                    $attemptRecord.error = $lastExecutionError
                }

                $verifyPath = Join-Path $scratchRoot ("attempt-{0}-verify.json" -f $attempt)
                $verifyAssessment = Invoke-RollbackAssessment `
                    -ScriptPath $rollbackDrillScript `
                    -TargetRepository $Repository `
                    -TargetChannel $Channel `
                    -HistoryCount $RequiredHistoryCount `
                    -Limit $ReleaseLimit `
                    -ReportPath $verifyPath

                $verifyReport = $verifyAssessment.report
                $finalReport = $verifyReport
                $attemptRecord.verify = [ordered]@{
                    status = [string]$verifyReport.status
                    reason_codes = @($verifyReport.reason_codes | ForEach-Object { [string]$_ })
                    message = [string]$verifyReport.message
                    candidate_count = [int]$verifyReport.candidate_count
                }

                if ($executionOk -and [string]$verifyReport.status -eq 'pass') {
                    $attemptRecord.status = 'recovered'
                    [void]$attemptRecords.Add($attemptRecord)
                    $recovered = $true
                    break
                }

                if (-not $executionOk) {
                    $attemptRecord.status = 'remediation_execution_failed'
                } else {
                    $attemptRecord.status = 'verify_failed'
                }
                [void]$attemptRecords.Add($attemptRecord)
            }

            $report.remediation_attempts = @($attemptRecords)
            $report.final_report = $finalReport

            if ($recovered) {
                $report.status = 'pass'
                $report.reason_code = 'remediated'
                $report.message = 'Rollback drill auto-remediation completed and verification passed.'
            } else {
                $report.status = 'fail'
                if ($hadExecutionFailure -and $null -eq $finalReport) {
                    $report.reason_code = 'remediation_execution_failed'
                    $report.message = $lastExecutionError
                } else {
                    $report.reason_code = 'remediation_verify_failed'
                    $finalReasons = @()
                    if ($null -ne $finalReport) {
                        $finalReasons = @($finalReport.reason_codes | ForEach-Object { [string]$_ })
                    }
                    $finalReasonText = if ($finalReasons.Count -gt 0) { [string]::Join(',', $finalReasons) } else { 'unknown' }
                    $report.message = "Rollback drill remains failing after bounded remediation. final_reason_codes=$finalReasonText"
                }
            }
        }
    }
} catch {
    $report.status = 'fail'
    $report.reason_code = 'rollback_self_heal_runtime_error'
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
