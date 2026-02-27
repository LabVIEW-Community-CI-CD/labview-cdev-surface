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
    [int]$KeepLatestN = 1,

    [Parameter()]
    [string]$TargetHeadSha = '',

    [Parameter()]
    [string]$OutputPath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'lib/WorkflowOps.Common.ps1')

$allRuns = @(Get-GhWorkflowRunsPortable -Repository $Repository -Workflow $WorkflowFile -Branch $Branch -Event 'workflow_dispatch' -Limit 100)

$orderedRuns = @($allRuns | Sort-Object { Parse-RunTimestamp -Run $_ } -Descending)
$keepIds = @($orderedRuns | Select-Object -First ([Math]::Max($KeepLatestN, 0)) | ForEach-Object { [string]$_.databaseId })
$activeStatuses = @('queued', 'in_progress', 'requested', 'waiting', 'pending')

$canceled = @()
$skipped = @()
foreach ($run in $orderedRuns) {
    $runId = [string]$run.databaseId
    $status = [string]$run.status
    if ($activeStatuses -notcontains $status) {
        continue
    }

    if ($keepIds -contains $runId) {
        $skipped += [pscustomobject]@{ run_id = $runId; reason = 'keep_latest' }
        continue
    }

    if (-not [string]::IsNullOrWhiteSpace($TargetHeadSha) -and [string]::Equals([string]$run.headSha, $TargetHeadSha, [System.StringComparison]::OrdinalIgnoreCase)) {
        $skipped += [pscustomobject]@{ run_id = $runId; reason = 'target_head_sha' }
        continue
    }

    Invoke-Gh -Arguments @('run', 'cancel', $runId, '-R', $Repository)
    $canceled += [pscustomobject]@{
        run_id = $runId
        status = $status
        head_sha = [string]$run.headSha
        url = [string]$run.url
    }
}

$report = [ordered]@{
    timestamp_utc = Get-UtcNowIso
    repository = $Repository
    workflow = $WorkflowFile
    branch = $Branch
    keep_latest_n = $KeepLatestN
    target_head_sha = $TargetHeadSha
    total_runs_considered = @($orderedRuns).Count
    canceled_runs = @($canceled)
    skipped_runs = @($skipped)
}

Write-WorkflowOpsReport -Report $report -OutputPath $OutputPath
