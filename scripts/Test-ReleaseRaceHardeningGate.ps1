#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter()]
    [ValidatePattern('^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$')]
    [string]$Repository = 'LabVIEW-Community-CI-CD/labview-cdev-surface-fork',

    [Parameter()]
    [ValidatePattern('^[A-Za-z0-9._/-]+$')]
    [string]$SourceBranch = 'main',

    [Parameter()]
    [ValidatePattern('^[A-Za-z0-9._/-]+$')]
    [string]$WorkflowFile = 'release-race-hardening-drill.yml',

    [Parameter()]
    [ValidateRange(1, 720)]
    [int]$MaxAgeHours = 168,

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

function Try-ParseUtcDateTimeOffset {
    param(
        [Parameter()][AllowNull()]$Value
    )

    $parsed = [DateTimeOffset]::MinValue
    if ($null -eq $Value) {
        return $null
    }

    $text = [string]$Value
    if ([string]::IsNullOrWhiteSpace($text)) {
        return $null
    }

    if ([DateTimeOffset]::TryParse($text, [ref]$parsed)) {
        return $parsed.ToUniversalTime()
    }

    return $null
}

$reasonCodes = [System.Collections.Generic.List[string]]::new()
$warnings = [System.Collections.Generic.List[string]]::new()

$report = [ordered]@{
    schema_version = '1.0'
    generated_at_utc = Get-UtcNowIso
    repository = $Repository
    source_branch = $SourceBranch
    workflow_file = $WorkflowFile
    max_age_hours = $MaxAgeHours
    status = 'fail'
    reason_codes = @()
    message = ''
    latest_successful_run = $null
    drill_report = $null
}

try {
    $runs = @(
        Get-GhWorkflowRunsPortable `
            -Repository $Repository `
            -Workflow $WorkflowFile `
            -Branch $SourceBranch `
            -Limit 50
    )

    $successfulRuns = @(
        $runs |
            Where-Object {
                [string]$_.status -eq 'completed' -and
                [string]$_.conclusion -eq 'success'
            } |
            Sort-Object { Parse-RunTimestamp -Run $_ } -Descending
    )

    if (@($successfulRuns).Count -eq 0) {
        Add-ReasonCode -Target $reasonCodes -ReasonCode 'drill_run_missing'
        throw 'No successful race-hardening drill runs were found.'
    }

    $latestRun = $successfulRuns[0]
    $latestRunCreatedAt = Parse-RunTimestamp -Run $latestRun
    $maxAge = [TimeSpan]::FromHours([double]$MaxAgeHours)
    $runAge = [DateTimeOffset]::UtcNow - $latestRunCreatedAt
    if ($runAge -gt $maxAge) {
        Add-ReasonCode -Target $reasonCodes -ReasonCode 'drill_run_stale'
        throw ("Latest successful race-hardening run is stale. run_id={0} age_hours={1}" -f [string]$latestRun.databaseId, [Math]::Round($runAge.TotalHours, 2))
    }

    $report.latest_successful_run = [ordered]@{
        run_id = [string]$latestRun.databaseId
        status = [string]$latestRun.status
        conclusion = [string]$latestRun.conclusion
        created_at_utc = [string]$latestRun.createdAt
        url = [string]$latestRun.url
        age_hours = [Math]::Round($runAge.TotalHours, 2)
    }

    $artifactName = "release-race-hardening-drill-report-$([string]$latestRun.databaseId)"
    $downloadRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("race-hardening-gate-" + [Guid]::NewGuid().ToString('N'))
    New-Item -Path $downloadRoot -ItemType Directory -Force | Out-Null

    try {
        & gh run download ([string]$latestRun.databaseId) -R $Repository -n $artifactName -D $downloadRoot
        $downloadExit = if ($null -eq $LASTEXITCODE) { 0 } else { [int]$LASTEXITCODE }
        if ($downloadExit -ne 0) {
            Add-ReasonCode -Target $reasonCodes -ReasonCode 'drill_report_download_failed'
            throw ("Unable to download drill report artifact. run_id={0} artifact={1} exit_code={2}" -f [string]$latestRun.databaseId, $artifactName, $downloadExit)
        }

        $reportPath = @(
            Get-ChildItem -Path $downloadRoot -Recurse -File -Filter 'release-race-hardening-drill-report.json' |
                Select-Object -First 1 -ExpandProperty FullName
        )
        if (@($reportPath).Count -ne 1 -or [string]::IsNullOrWhiteSpace([string]$reportPath[0])) {
            Add-ReasonCode -Target $reasonCodes -ReasonCode 'drill_report_missing'
            throw ("Downloaded artifact is missing release-race-hardening-drill-report.json. run_id={0}" -f [string]$latestRun.databaseId)
        }

        $drillReport = Get-Content -LiteralPath ([string]$reportPath[0]) -Raw | ConvertFrom-Json -Depth 100
        $collisionSignals = @($drillReport.evidence.collision_signals | ForEach-Object { [string]$_ })
        $collisionRetries = 0
        [void][int]::TryParse([string]$drillReport.evidence.collision_retries, [ref]$collisionRetries)
        $collisionObserved = [bool]$drillReport.evidence.collision_observed

        $report.drill_report = [ordered]@{
            status = [string]$drillReport.status
            reason_code = [string]$drillReport.reason_code
            message = [string]$drillReport.message
            collision_observed = $collisionObserved
            collision_retries = $collisionRetries
            collision_signals = @($collisionSignals)
            release_verification_status = [string]$drillReport.evidence.release_verification_status
            source_run_url = [string]$latestRun.url
        }

        if ([string]$drillReport.status -ne 'pass' -or [string]$drillReport.reason_code -ne 'drill_passed') {
            Add-ReasonCode -Target $reasonCodes -ReasonCode 'drill_reason_code_invalid'
            throw ("Latest drill report is not passing. status={0} reason_code={1}" -f [string]$drillReport.status, [string]$drillReport.reason_code)
        }

        if (-not $collisionObserved -or ($collisionRetries -lt 1 -and @($collisionSignals).Count -eq 0)) {
            Add-ReasonCode -Target $reasonCodes -ReasonCode 'drill_collision_evidence_missing'
            throw 'Latest drill report does not include required collision evidence.'
        }

        if ([string]$drillReport.evidence.release_verification_status -ne 'pass') {
            Add-ReasonCode -Target $reasonCodes -ReasonCode 'drill_release_verification_missing'
            throw ("Latest drill report release verification is not pass. status={0}" -f [string]$drillReport.evidence.release_verification_status)
        }
    }
    finally {
        if (Test-Path -LiteralPath $downloadRoot -PathType Container) {
            Remove-Item -LiteralPath $downloadRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    $report.status = 'pass'
    $report.reason_codes = @('ok')
    $report.message = 'Release race-hardening gate passed.'
}
catch {
    if ($reasonCodes.Count -eq 0) {
        Add-ReasonCode -Target $reasonCodes -ReasonCode 'drill_gate_runtime_error'
    }
    $report.status = 'fail'
    $report.reason_codes = @($reasonCodes)
    $report.message = [string]$_.Exception.Message
}
finally {
    $report.generated_at_utc = Get-UtcNowIso
    if ($warnings.Count -gt 0) {
        $report.warnings = @($warnings)
    }
    Write-WorkflowOpsReport -Report $report -OutputPath $OutputPath | Out-Null
}

if ([string]$report.status -eq 'pass') {
    exit 0
}

exit 1
