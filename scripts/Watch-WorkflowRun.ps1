#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Repository,

    [Parameter()]
    [string]$RunId = '',

    [Parameter()]
    [string]$WorkflowFile = '',

    [Parameter()]
    [string]$Branch = 'main',

    [Parameter()]
    [int]$TimeoutMinutes = 60,

    [Parameter()]
    [int]$PollSeconds = 20,

    [Parameter()]
    [string]$OutputPath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'lib/WorkflowOps.Common.ps1')

if ([string]::IsNullOrWhiteSpace($RunId)) {
    if ([string]::IsNullOrWhiteSpace($WorkflowFile)) {
        throw 'run_id_or_workflow_required: provide -RunId or both -WorkflowFile and -Branch.'
    }

    $latest = @(Get-GhWorkflowRunsPortable -Repository $Repository -Workflow $WorkflowFile -Branch $Branch -Limit 1) | Select-Object -First 1

    if ($null -eq $latest) {
        throw 'run_not_found: no workflow runs available to watch.'
    }

    $RunId = [string]$latest.databaseId
}

$deadline = (Get-Date).ToUniversalTime().AddMinutes([Math]::Max($TimeoutMinutes, 1))
$lastState = $null
while ($true) {
    $run = Invoke-GhJson -Arguments @(
        'run', 'view',
        $RunId,
        '-R', $Repository,
        '--json', 'databaseId,status,conclusion,url,createdAt,updatedAt,headSha,workflowName,displayTitle'
    )

    $lastState = $run
    if ([string]$run.status -eq 'completed') {
        break
    }

    if ((Get-Date).ToUniversalTime() -ge $deadline) {
        $report = [ordered]@{
            timestamp_utc = Get-UtcNowIso
            repository = $Repository
            run_id = $RunId
            status = [string]$run.status
            conclusion = [string]$run.conclusion
            url = [string]$run.url
            timeout_minutes = $TimeoutMinutes
            classified_reason = 'timeout'
        }
        Write-WorkflowOpsReport -Report $report -OutputPath $OutputPath
        throw ("workflow_watch_timeout: run {0} did not complete within {1} minutes." -f $RunId, $TimeoutMinutes)
    }

    Start-Sleep -Seconds ([Math]::Max($PollSeconds, 5))
}

$classification = if ([string]$lastState.conclusion -eq 'success') { 'success' } else { 'non_success_conclusion' }
$report = [ordered]@{
    timestamp_utc = Get-UtcNowIso
    repository = $Repository
    run_id = $RunId
    status = [string]$lastState.status
    conclusion = [string]$lastState.conclusion
    url = [string]$lastState.url
    head_sha = [string]$lastState.headSha
    classified_reason = $classification
}

Write-WorkflowOpsReport -Report $report -OutputPath $OutputPath
if ($classification -ne 'success') {
    throw ("workflow_run_failed: run {0} completed with conclusion '{1}'." -f $RunId, [string]$lastState.conclusion)
}
