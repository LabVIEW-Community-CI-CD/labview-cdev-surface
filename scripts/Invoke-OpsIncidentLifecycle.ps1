#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter()]
    [ValidatePattern('^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$')]
    [string]$Repository = 'LabVIEW-Community-CI-CD/labview-cdev-surface-fork',

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$IssueTitle,

    [Parameter()]
    [ValidateSet('Fail', 'Recover')]
    [string]$Mode = 'Fail',

    [Parameter()]
    [string]$Body = '',

    [Parameter()]
    [string]$RunUrl = '',

    [Parameter()]
    [string]$OutputPath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'lib/WorkflowOps.Common.ps1')

function Parse-IssueTimestampUtc {
    param([Parameter(Mandatory = $true)][object]$Issue)

    $value = [DateTimeOffset]::MinValue
    if ([DateTimeOffset]::TryParse([string]$Issue.updatedAt, [ref]$value)) {
        return $value.ToUniversalTime()
    }
    return [DateTimeOffset]::MinValue
}

function Resolve-Body {
    param(
        [Parameter(Mandatory = $true)][string]$LifecycleMode,
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][string]$Url
    )

    if (-not [string]::IsNullOrWhiteSpace($Text)) {
        return $Text
    }

    if ($LifecycleMode -eq 'Fail') {
        return @"
Ops incident detected.

- Run: $Url
"@
    }

    return @"
Ops incident recovered.

- Run: $Url
"@
}

$report = [ordered]@{
    schema_version = '1.0'
    timestamp_utc = Get-UtcNowIso
    repository = $Repository
    issue_title = $IssueTitle
    mode = $Mode
    run_url = $RunUrl
    status = 'fail'
    action = ''
    issue = $null
    message = ''
}

try {
    $resolvedBody = Resolve-Body -LifecycleMode $Mode -Text $Body -Url $RunUrl
    $issues = @(Invoke-GhJson -Arguments @(
            'issue', 'list',
            '-R', $Repository,
            '--state', 'all',
            '--search', "$IssueTitle in:title",
            '--json', 'number,title,state,updatedAt,url',
            '--limit', '50'
        ))
    $matches = @($issues | Where-Object { [string]$_.title -eq $IssueTitle })
    $target = @($matches | Sort-Object { Parse-IssueTimestampUtc -Issue $_ } -Descending | Select-Object -First 1)

    if ($Mode -eq 'Fail') {
        if (@($target).Count -eq 0) {
            $createOutput = (Invoke-GhText -Arguments @(
                    'issue', 'create',
                    '-R', $Repository,
                    '--title', $IssueTitle,
                    '--body', $resolvedBody
                )).Trim()
            $report.action = 'created'
            $report.issue = [ordered]@{
                number = [string]::Empty
                state_before = 'missing'
                state_after = 'open'
                url = $createOutput
            }
            $report.message = 'Issue created for incident.'
        } else {
            $issueNumber = [string]$target[0].number
            $issueState = [string]$target[0].state
            $issueUrl = [string]$target[0].url

            if ($issueState -eq 'CLOSED') {
                Invoke-Gh -Arguments @('issue', 'reopen', $issueNumber, '-R', $Repository)
                Invoke-Gh -Arguments @('issue', 'comment', $issueNumber, '-R', $Repository, '--body', $resolvedBody)
                $report.action = 'reopened_and_commented'
                $report.issue = [ordered]@{
                    number = $issueNumber
                    state_before = 'closed'
                    state_after = 'open'
                    url = $issueUrl
                }
                $report.message = "Closed incident issue reopened and updated (#$issueNumber)."
            } else {
                Invoke-Gh -Arguments @('issue', 'comment', $issueNumber, '-R', $Repository, '--body', $resolvedBody)
                $report.action = 'commented'
                $report.issue = [ordered]@{
                    number = $issueNumber
                    state_before = 'open'
                    state_after = 'open'
                    url = $issueUrl
                }
                $report.message = "Open incident issue updated (#$issueNumber)."
            }
        }
    } else {
        if (@($target).Count -eq 0) {
            $report.action = 'no_issue_found'
            $report.issue = [ordered]@{
                number = [string]::Empty
                state_before = 'missing'
                state_after = 'missing'
                url = [string]::Empty
            }
            $report.message = 'No historical incident issue found to close.'
        } else {
            $issueNumber = [string]$target[0].number
            $issueState = [string]$target[0].state
            $issueUrl = [string]$target[0].url

            if ($issueState -eq 'OPEN') {
                Invoke-Gh -Arguments @('issue', 'comment', $issueNumber, '-R', $Repository, '--body', $resolvedBody)
                Invoke-Gh -Arguments @('issue', 'close', $issueNumber, '-R', $Repository)
                $report.action = 'commented_and_closed'
                $report.issue = [ordered]@{
                    number = $issueNumber
                    state_before = 'open'
                    state_after = 'closed'
                    url = $issueUrl
                }
                $report.message = "Incident issue closed after recovery (#$issueNumber)."
            } else {
                $report.action = 'already_closed'
                $report.issue = [ordered]@{
                    number = $issueNumber
                    state_before = 'closed'
                    state_after = 'closed'
                    url = $issueUrl
                }
                $report.message = "Latest incident issue already closed (#$issueNumber)."
            }
        }
    }

    $report.status = 'pass'
}
catch {
    $report.status = 'fail'
    $report.action = 'runtime_error'
    $report.message = [string]$_.Exception.Message
}
finally {
    Write-WorkflowOpsReport -Report $report -OutputPath $OutputPath | Out-Null
}

if ([string]$report.status -eq 'pass') {
    exit 0
}

exit 1
