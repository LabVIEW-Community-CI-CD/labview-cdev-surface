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

$repoInfo = Get-IssueRepositorySlug -Url $IssueUrl
$repositorySlug = [string]$repoInfo.repository

$issue = gh issue view $IssueUrl --json number,title,body,url,repository
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
if ([string]::IsNullOrWhiteSpace($workflowFile)) {
    $workflowFile = 'self-hosted-machine-certification.yml'
}
if ([string]::IsNullOrWhiteSpace($ref)) {
    $ref = 'main'
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

$dispatchJson = & $startScript -Repository $repositorySlug -WorkflowFile $workflowFile -Ref $ref -SetupName $setupNames -OutputPath $runReportPath
if ($LASTEXITCODE -ne 0) {
    throw "Start-SelfHostedMachineCertification.ps1 failed."
}
$dispatchObj = if ($dispatchJson) { $dispatchJson | ConvertFrom-Json -ErrorAction Stop } else { Get-Content -LiteralPath $runReportPath -Raw | ConvertFrom-Json -ErrorAction Stop }

$attemptTable = New-MarkdownTable -Rows @($dispatchObj.runs)
$attemptBody = @(
    "[$effectiveRecorderName] Certification attempts recorded",
    '',
    "- issue: $IssueUrl",
    "- workflow: $workflowFile",
    "- ref: $ref",
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
    foreach ($row in @($dispatchObj.runs)) {
        $runId = [string]$row.run_id
        if ([string]::IsNullOrWhiteSpace($runId)) {
            $finalRows += [pscustomobject]@{
                setup_name = [string]$row.setup_name
                run_url = [string]$row.run_url
                status = 'unknown'
                conclusion = 'unknown'
            }
            continue
        }

        gh run watch $runId -R $repositorySlug | Out-Null

        $runViewJson = gh run view $runId -R $repositorySlug --json status,conclusion,url
        if ($LASTEXITCODE -ne 0) {
            $finalRows += [pscustomobject]@{
                setup_name = [string]$row.setup_name
                run_url = [string]$row.run_url
                status = 'unknown'
                conclusion = 'unknown'
            }
            continue
        }

        $runView = $runViewJson | ConvertFrom-Json -ErrorAction Stop
        $finalRows += [pscustomobject]@{
            setup_name = [string]$row.setup_name
            run_url = [string]$runView.url
            status = [string]$runView.status
            conclusion = [string]$runView.conclusion
        }
    }

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
