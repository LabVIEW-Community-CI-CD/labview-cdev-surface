#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Repository,

    [Parameter(Mandatory = $true)]
    [string]$WorkflowFile,

    [Parameter()]
    [string]$Branch = 'main',

    [Parameter()]
    [Alias('Input')]
    [string[]]$Inputs = @(),

    [Parameter()]
    [switch]$CancelStale,

    [Parameter()]
    [int]$KeepLatestN = 1,

    [Parameter()]
    [int]$DispatchPauseSeconds = 4,

    [Parameter()]
    [string]$OutputPath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'lib/WorkflowOps.Common.ps1')

$expectedHeadSha = (Invoke-GhText -Arguments @('api', "repos/$Repository/branches/$Branch", '--jq', '.commit.sha')).Trim()
if ([string]::IsNullOrWhiteSpace($expectedHeadSha)) {
    throw ("remote_head_sha_missing: unable to resolve remote head for '{0}:{1}'." -f $Repository, $Branch)
}

$cancelReport = $null
if ($CancelStale) {
    $cancelScript = Join-Path $PSScriptRoot 'Cancel-StaleWorkflowRuns.ps1'
    $cancelJson = & pwsh -NoProfile -File $cancelScript `
        -Repository $Repository `
        -WorkflowFile $WorkflowFile `
        -Branch $Branch `
        -KeepLatestN $KeepLatestN `
        -TargetHeadSha $expectedHeadSha
    if ($LASTEXITCODE -ne 0) {
        throw 'stale_run_cancellation_failed: unable to cancel stale runs before dispatch.'
    }
    $cancelReport = $cancelJson | ConvertFrom-Json -ErrorAction Stop
}

$dispatchStartedUtc = (Get-Date).ToUniversalTime()
$dispatchArgs = @('workflow', 'run', $WorkflowFile, '-R', $Repository, '--ref', $Branch)
$dispatchArgs += @(Convert-InputPairsToGhArgs -Inputs $Inputs)
Invoke-Gh -Arguments $dispatchArgs

Start-Sleep -Seconds $DispatchPauseSeconds

$runList = @(Get-GhWorkflowRunsPortable -Repository $Repository -Workflow $WorkflowFile -Branch $Branch -Event 'workflow_dispatch' -Limit 30)

$candidates = @(
    $runList | Where-Object {
        $created = Parse-RunTimestamp -Run $_
        $created.UtcDateTime -ge $dispatchStartedUtc.AddMinutes(-2)
    } | Sort-Object { Parse-RunTimestamp -Run $_ } -Descending
)

$selectedRun = $candidates | Select-Object -First 1
if ($null -eq $selectedRun) {
    $selectedRun = @($runList | Sort-Object { Parse-RunTimestamp -Run $_ } -Descending | Select-Object -First 1)
}
if ($null -eq $selectedRun) {
    throw 'dispatch_run_not_discovered: unable to discover dispatched workflow run.'
}

$runHeadSha = [string]$selectedRun.headSha
if (-not [string]::Equals($runHeadSha, $expectedHeadSha, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw ("dispatch_head_sha_mismatch: expected {0} but dispatched run {1} resolved to {2}." -f $expectedHeadSha, [string]$selectedRun.databaseId, $runHeadSha)
}

$report = [ordered]@{
    timestamp_utc = Get-UtcNowIso
    repository = $Repository
    workflow = $WorkflowFile
    branch = $Branch
    expected_head_sha = $expectedHeadSha
    run_id = [string]$selectedRun.databaseId
    head_sha = $runHeadSha
    status = [string]$selectedRun.status
    conclusion = [string]$selectedRun.conclusion
    url = [string]$selectedRun.url
    inputs = @($Inputs)
    stale_cancel_report = $cancelReport
}

Write-WorkflowOpsReport -Report $report -OutputPath $OutputPath

