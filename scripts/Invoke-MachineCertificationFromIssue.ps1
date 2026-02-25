#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$IssueUrl,

    [Parameter()]
    [string]$RecorderName = '',

    [Parameter()]
    [switch]$SkipWatch,

    [Parameter()]
    [string]$OutputPath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-IssueRepositorySlug {
    param([string]$Url)
    if ($Url -notmatch '^https://github.com/([^/]+/[^/]+)/issues/(\d+)$') {
        throw "IssueUrl must be a GitHub issue URL: $Url"
    }
    return [pscustomobject]@{
        repository = $Matches[1]
        issue_number = [int]$Matches[2]
        owner = ($Matches[1] -split '/')[0]
    }
}

function New-MarkdownTable {
    param([object[]]$Rows)
    $lines = @('| Setup | Run URL | Status | Conclusion |')
    $lines += '|---|---|---|---|'
    foreach ($row in $Rows) {
        $urlCell = if ([string]::IsNullOrWhiteSpace([string]$row.run_url)) { 'n/a' } else { "[run]($([string]$row.run_url))" }
        $lines += ("| {0} | {1} | {2} | {3} |" -f [string]$row.setup_name, $urlCell, [string]$row.status, [string]$row.conclusion)
    }
    return ($lines -join [Environment]::NewLine)
}

function Get-LatestRunForWorkflowRef {
    param(
        [Parameter(Mandatory = $true)][string]$Repository,
        [Parameter(Mandatory = $true)][string]$WorkflowFile,
        [Parameter(Mandatory = $true)][string]$Ref
    )

    $runListJson = gh run list -R $Repository --workflow $WorkflowFile --branch $Ref --limit 20 --json databaseId,status,conclusion,url,createdAt
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to list runs for workflow '$WorkflowFile' on ref '$Ref'."
    }
    $runs = @($runListJson | ConvertFrom-Json -ErrorAction Stop)
    if (@($runs).Count -eq 0) {
        throw "No existing runs found for workflow '$WorkflowFile' on ref '$Ref'."
    }
    return ($runs | Sort-Object -Property createdAt -Descending | Select-Object -First 1)
}

function Get-SetupRowsFromRun {
    param(
        [Parameter(Mandatory = $true)][string]$Repository,
        [Parameter(Mandatory = $true)][string]$RunId,
        [Parameter(Mandatory = $true)][string[]]$SetupNames
    )

    $runViewJson = gh run view $RunId -R $Repository --json status,conclusion,url,jobs
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to read run details for run id '$RunId'."
    }
    $runView = $runViewJson | ConvertFrom-Json -ErrorAction Stop
    $jobs = @($runView.jobs)

    $rows = @()
    foreach ($setup in $SetupNames) {
        $match = @($jobs | Where-Object { [string]$_.name -eq ("Self-Hosted Machine Certification ({0})" -f $setup) }) | Select-Object -First 1
        if ($null -eq $match) {
            $rows += [pscustomobject]@{
                setup_name = [string]$setup
                run_id = [string]$RunId
                run_url = [string]$runView.url
                status = [string]$runView.status
                conclusion = [string]$runView.conclusion
            }
            continue
        }

        $rows += [pscustomobject]@{
            setup_name = [string]$setup
            run_id = [string]$RunId
            run_url = [string]$match.url
            status = [string]$match.status
            conclusion = [string]$match.conclusion
        }
    }

    return @($rows)
}

$repoInfo = Get-IssueRepositorySlug -Url $IssueUrl
$repositorySlug = [string]$repoInfo.repository

$issue = gh issue view $IssueUrl --json number,title,body,url
if ($LASTEXITCODE -ne 0) {
    throw "Unable to read issue: $IssueUrl"
}

$issueObj = $issue | ConvertFrom-Json -ErrorAction Stop
$body = [string]$issueObj.body
$startMarker = '<!-- CERT_CONFIG_START -->'
$endMarker = '<!-- CERT_CONFIG_END -->'
$start = $body.IndexOf($startMarker, [System.StringComparison]::Ordinal)
$end = $body.IndexOf($endMarker, [System.StringComparison]::Ordinal)
if ($start -lt 0 -or $end -lt 0 -or $end -le $start) {
    throw "Issue is missing certification config block markers."
}

$configText = $body.Substring($start + $startMarker.Length, $end - ($start + $startMarker.Length)).Trim()
if ([string]::IsNullOrWhiteSpace($configText)) {
    throw "Certification config block is empty."
}

$config = $configText | ConvertFrom-Json -ErrorAction Stop
$workflowFile = [string]$config.workflow_file
$ref = [string]$config.ref
$setupNames = @($config.setup_names | ForEach-Object { [string]$_ })
$triggerMode = [string]$config.trigger_mode
if ([string]::IsNullOrWhiteSpace($workflowFile)) {
    $workflowFile = 'self-hosted-machine-certification.yml'
}
if ([string]::IsNullOrWhiteSpace($ref)) {
    $ref = 'main'
}
if ([string]::IsNullOrWhiteSpace($triggerMode)) {
    $triggerMode = 'auto'
}
if (@('auto', 'dispatch', 'rerun_latest') -notcontains $triggerMode) {
    throw "Unsupported trigger_mode '$triggerMode'. Supported values: auto, dispatch, rerun_latest."
}
if (@($setupNames).Count -eq 0) {
    throw "Issue config must include non-empty setup_names."
}

$effectiveRecorderName = if (-not [string]::IsNullOrWhiteSpace($RecorderName)) {
    $RecorderName
} elseif (-not [string]::IsNullOrWhiteSpace([string]$config.recorder_name)) {
    [string]$config.recorder_name
} else {
    'cdev-certification-recorder'
}

if ([string]::Equals($effectiveRecorderName, [string]$repoInfo.owner, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "recorder_name must differ from repository owner ('$($repoInfo.owner)')."
}

$repoRoot = (Resolve-Path -Path (Join-Path $PSScriptRoot '..')).Path
$startScript = Join-Path $repoRoot 'scripts\Start-SelfHostedMachineCertification.ps1'
if (-not (Test-Path -LiteralPath $startScript -PathType Leaf)) {
    throw "Missing dispatcher script: $startScript"
}

$runReportPath = if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    Join-Path $repoRoot (".tmp-machine-certification-from-issue-{0}.json" -f ([DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss')))
} else {
    [System.IO.Path]::GetFullPath($OutputPath)
}

$dispatchObj = $null
$dispatchErrorText = ''

if ($triggerMode -ne 'rerun_latest') {
    try {
        $dispatchJson = & $startScript -Repository $repositorySlug -WorkflowFile $workflowFile -Ref $ref -SetupName $setupNames -OutputPath $runReportPath
        if ($LASTEXITCODE -ne 0) {
            throw "Start-SelfHostedMachineCertification.ps1 failed."
        }
        $dispatchObj = if ($dispatchJson) { $dispatchJson | ConvertFrom-Json -ErrorAction Stop } else { Get-Content -LiteralPath $runReportPath -Raw | ConvertFrom-Json -ErrorAction Stop }
    } catch {
        $dispatchErrorText = $_ | Out-String
        if ($triggerMode -eq 'dispatch') {
            throw
        }
    }
}

$fallbackToRerunLatest = $false
if ($triggerMode -eq 'rerun_latest') {
    $fallbackToRerunLatest = $true
} elseif ($triggerMode -eq 'auto' -and $null -eq $dispatchObj) {
    $normalizedDispatchError = [string]$dispatchErrorText
    if (
        $normalizedDispatchError -match 'workflow .* not found on the default branch' -or
        $normalizedDispatchError -match 'HTTP 404' -or
        $normalizedDispatchError -match 'Not Found'
    ) {
        $fallbackToRerunLatest = $true
    } else {
        throw "Dispatch failed and trigger_mode=auto did not match fallback criteria. Error: $normalizedDispatchError"
    }
}

if ($fallbackToRerunLatest) {
    $latestRun = Get-LatestRunForWorkflowRef -Repository $repositorySlug -WorkflowFile $workflowFile -Ref $ref
    gh run rerun ([string]$latestRun.databaseId) -R $repositorySlug | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to rerun latest run id '$([string]$latestRun.databaseId)'."
    }
    Start-Sleep -Seconds 3

    $attemptRows = Get-SetupRowsFromRun -Repository $repositorySlug -RunId ([string]$latestRun.databaseId) -SetupNames $setupNames
    $dispatchObj = [pscustomobject]@{
        runs = @($attemptRows)
    }
}

$attemptTable = New-MarkdownTable -Rows @($dispatchObj.runs)
$attemptBody = @(
    "[$effectiveRecorderName] Certification attempts recorded",
    '',
    "- issue: $IssueUrl",
    "- workflow: $workflowFile",
    "- ref: $ref",
    "- trigger_mode: $triggerMode",
    "- setups: $($setupNames -join ', ')",
    '',
    $attemptTable
) -join [Environment]::NewLine

gh issue comment $IssueUrl --body $attemptBody | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw "Failed to post attempt comment to issue."
}

$finalRows = @()
if (-not $SkipWatch) {
    $runSetupMap = @{}
    foreach ($attempt in @($dispatchObj.runs)) {
        $attemptRunId = [string]$attempt.run_id
        $attemptSetup = [string]$attempt.setup_name
        if ([string]::IsNullOrWhiteSpace($attemptRunId) -or [string]::IsNullOrWhiteSpace($attemptSetup)) {
            continue
        }
        if (-not $runSetupMap.ContainsKey($attemptRunId)) {
            $runSetupMap[$attemptRunId] = New-Object System.Collections.Generic.List[string]
        }
        if (-not $runSetupMap[$attemptRunId].Contains($attemptSetup)) {
            [void]$runSetupMap[$attemptRunId].Add($attemptSetup)
        }
    }

    $uniqueRunIds = @(
        @($dispatchObj.runs | ForEach-Object { [string]$_.run_id }) |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        Select-Object -Unique
    )

    foreach ($runId in $uniqueRunIds) {
        gh run watch $runId -R $repositorySlug | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Warning ("Failed to watch run id '{0}', continuing to collect available results." -f $runId)
        }

        try {
            $expectedSetupsForRun = if ($runSetupMap.ContainsKey($runId) -and @($runSetupMap[$runId]).Count -gt 0) {
                @($runSetupMap[$runId])
            } else {
                @($setupNames)
            }
            $rows = Get-SetupRowsFromRun -Repository $repositorySlug -RunId $runId -SetupNames $expectedSetupsForRun
            $finalRows += @($rows)
        } catch {
            $expectedSetupsForRun = if ($runSetupMap.ContainsKey($runId) -and @($runSetupMap[$runId]).Count -gt 0) {
                @($runSetupMap[$runId])
            } else {
                @($setupNames)
            }
            foreach ($setupName in $expectedSetupsForRun) {
                $finalRows += [pscustomobject]@{
                    setup_name = [string]$setupName
                    run_id = [string]$runId
                    run_url = ''
                    status = 'unknown'
                    conclusion = 'unknown'
                }
            }
        }
    }

    if (@($uniqueRunIds).Count -eq 0) {
        foreach ($setupName in $setupNames) {
            $finalRows += [pscustomobject]@{
                setup_name = [string]$setupName
                run_id = ''
                run_url = ''
                status = 'unknown'
                conclusion = 'unknown'
            }
        }
    }

    $finalRows = @(
        $finalRows |
        Group-Object -Property setup_name |
        ForEach-Object {
            @($_.Group | Select-Object -Last 1)
        }
    )

    $resultTable = New-MarkdownTable -Rows $finalRows
    $resultBody = @(
        "[$effectiveRecorderName] Certification results recorded",
        '',
        "- issue: $IssueUrl",
        "- workflow: $workflowFile",
        "- ref: $ref",
        '',
        $resultTable
    ) -join [Environment]::NewLine

    gh issue comment $IssueUrl --body $resultBody | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to post result comment to issue."
    }
}

$report = [ordered]@{
    timestamp_utc = (Get-Date).ToUniversalTime().ToString('o')
    issue_url = $IssueUrl
    repository = $repositorySlug
    recorder_name = $effectiveRecorderName
    workflow = $workflowFile
    ref = $ref
    trigger_mode = $triggerMode
    setups = $setupNames
    attempts = @($dispatchObj.runs)
    results = @($finalRows)
    dispatch_report_path = $runReportPath
}

$reportPath = if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $runReportPath
} else {
    [System.IO.Path]::GetFullPath($OutputPath)
}
$report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $reportPath -Encoding utf8

Write-Host ("Issue certification orchestration completed: {0}" -f $IssueUrl)
Write-Host ("Report: {0}" -f $reportPath)
$report | ConvertTo-Json -Depth 8 | Write-Output
