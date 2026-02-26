#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter()]
    [ValidatePattern('^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$')]
    [string]$SurfaceRepository = 'LabVIEW-Community-CI-CD/labview-cdev-surface-fork',

    [Parameter()]
    [ValidatePattern('^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$')]
    [string]$SyncGuardRepository = 'LabVIEW-Community-CI-CD/labview-cdev-cli',

    [Parameter()]
    [ValidateRange(1, 90)]
    [int]$LookbackDays = 7,

    [Parameter()]
    [string]$OutputPath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'lib/WorkflowOps.Common.ps1')

function Get-WorkflowSloSummary {
    param(
        [Parameter(Mandatory = $true)][string]$Repository,
        [Parameter(Mandatory = $true)][string]$WorkflowName,
        [Parameter(Mandatory = $true)][DateTime]$CutoffUtc
    )

    $runListOutput = & gh run list `
        -R $Repository `
        --workflow $WorkflowName `
        --limit 100 `
        --json databaseId,status,conclusion,createdAt,url,event 2>&1
    $runListExitCode = if ($null -eq $LASTEXITCODE) { 0 } else { [int]$LASTEXITCODE }

    $runs = @()
    if ($runListExitCode -eq 0) {
        $runListText = [string]::Join([Environment]::NewLine, @($runListOutput))
        if (-not [string]::IsNullOrWhiteSpace($runListText)) {
            $runs = @($runListText | ConvertFrom-Json -ErrorAction Stop)
        }
    } else {
        $runListErrorText = [string]::Join([Environment]::NewLine, @($runListOutput))
        if ($runListErrorText -match 'could not find any workflows named') {
            $runs = @()
        } else {
            throw ("workflow_slo_query_failed: repository={0} workflow={1} error={2}" -f $Repository, $WorkflowName, $runListErrorText)
        }
    }

    $windowRuns = @(
        $runs |
            Where-Object {
                $created = Parse-RunTimestamp -Run $_
                $created.UtcDateTime -ge $CutoffUtc
            }
    )
    $completedRuns = @($windowRuns | Where-Object { [string]$_.status -eq 'completed' })
    $successRuns = @($completedRuns | Where-Object { [string]$_.conclusion -eq 'success' })
    $failureRuns = @($completedRuns | Where-Object { [string]$_.conclusion -ne 'success' })

    $latestRun = @($windowRuns | Sort-Object { Parse-RunTimestamp -Run $_ } -Descending | Select-Object -First 1)
    $latest = $null
    if (@($latestRun).Count -eq 1) {
        $latest = [ordered]@{
            run_id = [string]$latestRun[0].databaseId
            status = [string]$latestRun[0].status
            conclusion = [string]$latestRun[0].conclusion
            event = [string]$latestRun[0].event
            created_at_utc = (Parse-RunTimestamp -Run $latestRun[0]).ToString('o')
            url = [string]$latestRun[0].url
        }
    }

    $successRate = if (@($completedRuns).Count -eq 0) { 0.0 } else { [Math]::Round((@($successRuns).Count / @($completedRuns).Count) * 100, 2) }

    return [ordered]@{
        workflow = $WorkflowName
        total_runs = @($windowRuns).Count
        completed_runs = @($completedRuns).Count
        success_runs = @($successRuns).Count
        failure_runs = @($failureRuns).Count
        success_rate_pct = $successRate
        latest_run = $latest
    }
}

$report = [ordered]@{
    schema_version = '1.0'
    generated_at_utc = Get-UtcNowIso
    surface_repository = $SurfaceRepository
    sync_guard_repository = $SyncGuardRepository
    lookback_days = $LookbackDays
    window_start_utc = ''
    workflows = @()
    sync_guard = [ordered]@{}
    canary_release_activity = [ordered]@{}
}

try {
    $cutoffUtc = (Get-Date).ToUniversalTime().AddDays(-1 * $LookbackDays)
    $report.window_start_utc = $cutoffUtc.ToString('o')

    $report.workflows = @(
        Get-WorkflowSloSummary -Repository $SurfaceRepository -WorkflowName 'ops-monitoring' -CutoffUtc $cutoffUtc
        Get-WorkflowSloSummary -Repository $SurfaceRepository -WorkflowName 'ops-autoremediate' -CutoffUtc $cutoffUtc
        Get-WorkflowSloSummary -Repository $SurfaceRepository -WorkflowName 'release-control-plane' -CutoffUtc $cutoffUtc
    )

    $syncGuardRuns = @(Invoke-GhJson -Arguments @(
        'run', 'list',
        '-R', $SyncGuardRepository,
        '--workflow', 'fork-upstream-sync-guard',
        '--branch', 'main',
        '--limit', '100',
        '--json', 'databaseId,status,conclusion,createdAt,url,event'
    ))
    $syncGuardWindow = @(
        $syncGuardRuns |
            Where-Object {
                (Parse-RunTimestamp -Run $_).UtcDateTime -ge $cutoffUtc
            } |
            Sort-Object { Parse-RunTimestamp -Run $_ } -Descending
    )
    $syncGuardLatestSuccess = @(
        $syncGuardWindow |
            Where-Object { [string]$_.status -eq 'completed' -and [string]$_.conclusion -eq 'success' } |
            Select-Object -First 1
    )
    $syncGuardAgeHours = $null
    if (@($syncGuardLatestSuccess).Count -eq 1) {
        $syncGuardAgeHours = [Math]::Round((((Get-Date).ToUniversalTime() - (Parse-RunTimestamp -Run $syncGuardLatestSuccess[0]).UtcDateTime).TotalHours), 2)
    }
    $report.sync_guard = [ordered]@{
        total_runs = @($syncGuardWindow).Count
        latest_success_age_hours = $syncGuardAgeHours
        latest_success_run = if (@($syncGuardLatestSuccess).Count -eq 1) {
            [ordered]@{
                run_id = [string]$syncGuardLatestSuccess[0].databaseId
                created_at_utc = (Parse-RunTimestamp -Run $syncGuardLatestSuccess[0]).ToString('o')
                url = [string]$syncGuardLatestSuccess[0].url
            }
        } else {
            $null
        }
    }

    $releases = @(Invoke-GhJson -Arguments @(
        'release', 'list',
        '-R', $SurfaceRepository,
        '--limit', '200',
        '--exclude-drafts',
        '--json', 'tagName,isPrerelease,publishedAt'
    ))
    $canaryReleases = @(
        $releases |
            Where-Object {
                ([string]$_.tagName -match '^v0\.\d{8}\.(?:[1-9]|[1-4][0-9])$') -and [bool]$_.isPrerelease
            } |
            Where-Object {
                $published = [DateTimeOffset]::MinValue
                [void][DateTimeOffset]::TryParse([string]$_.publishedAt, [ref]$published)
                $published.UtcDateTime -ge $cutoffUtc
            } |
            Sort-Object {
                $published = [DateTimeOffset]::MinValue
                [void][DateTimeOffset]::TryParse([string]$_.publishedAt, [ref]$published)
                $published
            } -Descending
    )
    $report.canary_release_activity = [ordered]@{
        count = @($canaryReleases).Count
        latest = if (@($canaryReleases).Count -gt 0) {
            [ordered]@{
                tag = [string]$canaryReleases[0].tagName
                published_at_utc = [string]$canaryReleases[0].publishedAt
            }
        } else {
            $null
        }
    }
}
catch {
    $report.error = [string]$_.Exception.Message
    Write-WorkflowOpsReport -Report $report -OutputPath $OutputPath | Out-Null
    throw
}

Write-WorkflowOpsReport -Report $report -OutputPath $OutputPath | Out-Null
