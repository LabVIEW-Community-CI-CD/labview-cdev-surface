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
    $lines = @('| Setup | Machine | Run URL | Status | Conclusion |')
    $lines += '|---|---|---|---|---|'
    foreach ($row in $Rows) {
        $urlCell = if ([string]::IsNullOrWhiteSpace([string]$row.run_url)) { 'n/a' } else { "[run]($([string]$row.run_url))" }
        $machineCell = if ([string]::IsNullOrWhiteSpace([string]$row.machine_name)) { 'unknown' } else { [string]$row.machine_name }
        $lines += ("| {0} | {1} | {2} | {3} | {4} |" -f [string]$row.setup_name, $machineCell, $urlCell, [string]$row.status, [string]$row.conclusion)
    }
    return ($lines -join [Environment]::NewLine)
}

function Get-IssueComments {
    param([Parameter(Mandatory = $true)][string]$IssueUrl)

    $json = gh issue view $IssueUrl --json comments
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to read issue comments: $IssueUrl"
    }
    $payload = $json | ConvertFrom-Json -ErrorAction Stop
    return @($payload.comments)
}

function Get-OpenCertificationSessions {
    param(
        [Parameter(Mandatory = $true)][object[]]$Comments,
        [Parameter(Mandatory = $true)][string]$RecorderName,
        [Parameter(Mandatory = $true)][string]$Workflow,
        [Parameter(Mandatory = $true)][string]$Ref
    )

    $recorderRegex = [Regex]::Escape($RecorderName)
    $starts = @{}
    $ends = @{}

    foreach ($comment in @($Comments)) {
        $body = [string]$comment.body
        if ([string]::IsNullOrWhiteSpace($body)) { continue }
        if ($body -notmatch "^\[$recorderRegex\]\s+CERT_SESSION_(START|END)\s+id=([A-Za-z0-9\-]+)") {
            continue
        }

        $kind = [string]$Matches[1]
        $sessionId = [string]$Matches[2]

        $wf = ''
        $rf = ''
        if ($body -match "(?m)^- workflow:\s*(.+?)\s*$") { $wf = [string]$Matches[1].Trim() }
        if ($body -match "(?m)^- ref:\s*(.+?)\s*$") { $rf = [string]$Matches[1].Trim() }

        if ($wf -ne $Workflow -or $rf -ne $Ref) {
            continue
        }

        if ($kind -eq 'START') {
            $starts[$sessionId] = [pscustomobject]@{
                id = $sessionId
                created_at = [string]$comment.createdAt
                url = [string]$comment.url
            }
        } else {
            $ends[$sessionId] = [pscustomobject]@{
                id = $sessionId
                created_at = [string]$comment.createdAt
                url = [string]$comment.url
            }
        }
    }

    $open = @()
    foreach ($key in $starts.Keys) {
        if (-not $ends.ContainsKey($key)) {
            $open += @($starts[$key])
        }
    }
    return @($open | Sort-Object -Property created_at)
}

function Get-ActiveWorkflowRuns {
    param(
        [Parameter(Mandatory = $true)][string]$Repository,
        [Parameter(Mandatory = $true)][string]$WorkflowFile,
        [Parameter(Mandatory = $true)][string]$Ref
    )

    $json = gh run list -R $Repository --workflow $WorkflowFile --branch $Ref --limit 30 --json databaseId,status,conclusion,url,createdAt
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to list workflow runs for stale detection."
    }
    $rowsRaw = @($json | ConvertFrom-Json -ErrorAction Stop)
    $rows = @(
        $rowsRaw | ForEach-Object {
            $statusValue = if ($_.status -is [System.Array]) { [string]$_.status[0] } else { [string]$_.status }
            [pscustomobject]@{
                databaseId = if ($_.databaseId -is [System.Array]) { [string]$_.databaseId[0] } else { [string]$_.databaseId }
                status = $statusValue
                conclusion = if ($_.conclusion -is [System.Array]) { [string]$_.conclusion[0] } else { [string]$_.conclusion }
                url = if ($_.url -is [System.Array]) { [string]$_.url[0] } else { [string]$_.url }
                createdAt = if ($_.createdAt -is [System.Array]) { [string]$_.createdAt[0] } else { [string]$_.createdAt }
            }
        }
    )
    return @(
        $rows |
        Where-Object { [string]$_.status -in @('queued', 'in_progress', 'pending', 'requested', 'waiting', 'action_required') }
    )
}

function Assert-RequiredScriptPaths {
    param(
        [Parameter(Mandatory = $true)][string]$RepoRoot,
        [Parameter()][string[]]$RequiredPaths = @()
    )

    foreach ($relativePath in @($RequiredPaths | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })) {
        $normalized = [string]$relativePath -replace '/', '\'
        $absolutePath = Join-Path $RepoRoot $normalized
        if (-not (Test-Path -LiteralPath $absolutePath -PathType Leaf)) {
            throw ("branch_drift_missing_script: required script missing '{0}'. Checkout issue ref before execution. Do not implement missing scripts." -f $normalized)
        }
    }
}

function Invoke-GitCapture {
    param(
        [Parameter(Mandatory = $true)][string]$RepositoryRoot,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )

    $output = (& git -C $RepositoryRoot @Arguments 2>&1 | Out-String)
    $exitCode = if ($null -eq $LASTEXITCODE) { 0 } else { [int]$LASTEXITCODE }
    return [pscustomobject]@{
        exit_code = $exitCode
        output = ([string]$output).Trim()
    }
}

function Get-RemoteRefSha {
    param(
        [Parameter(Mandatory = $true)][string]$Repository,
        [Parameter(Mandatory = $true)][string]$Ref
    )

    $sha = (gh api "repos/$Repository/commits/$Ref" --jq '.sha' 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($sha)) {
        throw "Unable to resolve remote ref sha for '$Repository@$Ref'."
    }
    return $sha.ToLowerInvariant()
}

function Resolve-MatchingRemoteName {
    param(
        [Parameter(Mandatory = $true)][string]$RepositoryRoot,
        [Parameter(Mandatory = $true)][string]$RepositorySlug
    )

    $remoteLinesResult = Invoke-GitCapture -RepositoryRoot $RepositoryRoot -Arguments @('remote', '-v')
    if ($remoteLinesResult.exit_code -ne 0) {
        return ''
    }

    $candidate = ''
    foreach ($line in @($remoteLinesResult.output -split "(`r`n|`n|`r)") | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) {
        if ($line -notmatch '\(fetch\)$') {
            continue
        }

        $parts = $line -split '\s+'
        if (@($parts).Count -lt 2) {
            continue
        }
        $remoteName = [string]$parts[0]
        $remoteUrl = [string]$parts[1]
        if ($remoteUrl -match [Regex]::Escape($RepositorySlug)) {
            $candidate = $remoteName
            break
        }
    }

    if ([string]::IsNullOrWhiteSpace($candidate)) {
        return ''
    }
    return $candidate
}

function Assert-LocalRefSync {
    param(
        [Parameter(Mandatory = $true)][string]$RepositoryRoot,
        [Parameter(Mandatory = $true)][string]$RepositorySlug,
        [Parameter(Mandatory = $true)][string]$Ref
    )

    $isGitRepoResult = Invoke-GitCapture -RepositoryRoot $RepositoryRoot -Arguments @('rev-parse', '--is-inside-work-tree')
    if ($isGitRepoResult.exit_code -ne 0 -or [string]$isGitRepoResult.output -ne 'true') {
        throw "local_repo_not_git_checkout: '$RepositoryRoot' is not a git working tree."
    }

    $localHeadResult = Invoke-GitCapture -RepositoryRoot $RepositoryRoot -Arguments @('rev-parse', 'HEAD')
    if ($localHeadResult.exit_code -ne 0 -or [string]::IsNullOrWhiteSpace([string]$localHeadResult.output)) {
        throw "local_repo_head_unresolved: unable to resolve local HEAD in '$RepositoryRoot'."
    }
    $localHeadSha = ([string]$localHeadResult.output).ToLowerInvariant()

    $remoteHeadSha = Get-RemoteRefSha -Repository $RepositorySlug -Ref $Ref
    if ($localHeadSha -eq $remoteHeadSha) {
        return
    }

    $remoteName = Resolve-MatchingRemoteName -RepositoryRoot $RepositoryRoot -RepositorySlug $RepositorySlug
    $syncHint = if (-not [string]::IsNullOrWhiteSpace($remoteName)) {
        "git fetch --prune $remoteName $Ref`ngit checkout --force FETCH_HEAD"
    } else {
        "git fetch --prune <remote-for-$RepositorySlug> $Ref`ngit checkout --force FETCH_HEAD"
    }

    throw ("branch_not_pulled_or_stale: local HEAD '{0}' does not match issue ref '{1}' head '{2}'.`nRun:`n{3}`nDo not implement missing scripts from this state." -f $localHeadSha, $Ref, $remoteHeadSha, $syncHint)
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
                machine_name = 'unknown'
                run_id = [string]$RunId
                run_url = [string]$runView.url
                status = [string]$runView.status
                conclusion = [string]$runView.conclusion
            }
            continue
        }

        $rows += [pscustomobject]@{
            setup_name = [string]$setup
            machine_name = [string]$match.runnerName
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
$requiredScriptPaths = @($config.required_script_paths | ForEach-Object { [string]$_ })
$requireLocalRefSync = if ($null -eq $config.PSObject.Properties['require_local_ref_sync']) {
    $true
} else {
    [bool]$config.require_local_ref_sync
}
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
$orchestratorMachineName = [System.Environment]::MachineName

if ([string]::Equals($effectiveRecorderName, [string]$repoInfo.owner, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "recorder_name must differ from repository owner ('$($repoInfo.owner)')."
}

$repoRoot = (Resolve-Path -Path (Join-Path $PSScriptRoot '..')).Path
if ($requireLocalRefSync) {
    Assert-LocalRefSync -RepositoryRoot $repoRoot -RepositorySlug $repositorySlug -Ref $ref
}
Assert-RequiredScriptPaths -RepoRoot $repoRoot -RequiredPaths $requiredScriptPaths
$startScript = Join-Path $repoRoot 'scripts\Start-SelfHostedMachineCertification.ps1'
if (-not (Test-Path -LiteralPath $startScript -PathType Leaf)) {
    throw "Missing dispatcher script: $startScript"
}

$runReportPath = if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    Join-Path $repoRoot (".tmp-machine-certification-from-issue-{0}.json" -f ([DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss')))
} else {
    [System.IO.Path]::GetFullPath($OutputPath)
}

$sessionId = ("{0}-{1}" -f ([DateTime]::UtcNow.ToString('yyyyMMddHHmmss')), [Guid]::NewGuid().ToString('N').Substring(0, 8))
$sessionStartedUtc = (Get-Date).ToUniversalTime()
$sessionStatus = 'in_progress'
$sessionError = ''
$sessionEndedUtc = $null
$sessionStartCommentPosted = $false
$sessionRunIds = @()
$staleOpenSessions = @()
$staleActiveRuns = @()

$issueComments = Get-IssueComments -IssueUrl $IssueUrl
$staleOpenSessions = Get-OpenCertificationSessions `
    -Comments $issueComments `
    -RecorderName $effectiveRecorderName `
    -Workflow $workflowFile `
    -Ref $ref
$staleActiveRuns = Get-ActiveWorkflowRuns -Repository $repositorySlug -WorkflowFile $workflowFile -Ref $ref

$startCommentLines = @(
    "[$effectiveRecorderName] CERT_SESSION_START id=$sessionId",
    '',
    "- issue: $IssueUrl",
    "- workflow: $workflowFile",
    "- ref: $ref",
    "- orchestrator_machine: $orchestratorMachineName",
    "- started_utc: $($sessionStartedUtc.ToString('o'))",
    "- trigger_mode: $triggerMode",
    "- stale_open_session_count: $(@($staleOpenSessions).Count)",
    "- stale_active_run_count: $(@($staleActiveRuns).Count)"
)
if (@($staleOpenSessions).Count -gt 0) {
    $startCommentLines += '- stale_open_sessions:'
    foreach ($s in @($staleOpenSessions)) {
        $startCommentLines += ("  - id={0} created_at={1} url={2}" -f [string]$s.id, [string]$s.created_at, [string]$s.url)
    }
}
if (@($staleActiveRuns).Count -gt 0) {
    $startCommentLines += '- stale_active_runs:'
    foreach ($r in @($staleActiveRuns)) {
        $startCommentLines += ("  - run_id={0} status={1} url={2}" -f [string]$r.databaseId, [string]$r.status, [string]$r.url)
    }
}

gh issue comment $IssueUrl --body ($startCommentLines -join [Environment]::NewLine) | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw "Failed to post CERT_SESSION_START comment to issue."
}
$sessionStartCommentPosted = $true

$dispatchObj = $null
$dispatchErrorText = ''
$finalRows = @()

try {

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
                    machine_name = 'unknown'
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
                machine_name = 'unknown'
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

$sessionRunIds = @(
    @($dispatchObj.runs | ForEach-Object { [string]$_.run_id }) |
    Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
    Select-Object -Unique
)
$sessionStatus = if (@($finalRows).Count -eq 0) { 'dispatched' } else { 'completed' }
$sessionEndedUtc = (Get-Date).ToUniversalTime()

$report = [ordered]@{
    timestamp_utc = (Get-Date).ToUniversalTime().ToString('o')
    issue_url = $IssueUrl
    repository = $repositorySlug
    recorder_name = $effectiveRecorderName
    orchestrator_machine = $orchestratorMachineName
    workflow = $workflowFile
    ref = $ref
    trigger_mode = $triggerMode
    session_id = $sessionId
    session_started_utc = $sessionStartedUtc.ToString('o')
    session_ended_utc = $sessionEndedUtc.ToString('o')
    session_status = $sessionStatus
    stale_open_sessions_detected = @($staleOpenSessions)
    stale_active_runs_detected = @($staleActiveRuns)
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

} catch {
    $sessionStatus = 'failed'
    $sessionError = ($_ | Out-String).Trim()
    $sessionEndedUtc = (Get-Date).ToUniversalTime()
    throw
} finally {
    if ($sessionStartCommentPosted) {
        try {
            if ($null -eq $sessionEndedUtc) {
                $sessionEndedUtc = (Get-Date).ToUniversalTime()
            }
            $durationSeconds = [Math]::Round(($sessionEndedUtc - $sessionStartedUtc).TotalSeconds, 2)
            $endLines = @(
                "[$effectiveRecorderName] CERT_SESSION_END id=$sessionId",
                '',
                "- issue: $IssueUrl",
                "- workflow: $workflowFile",
                "- ref: $ref",
                "- orchestrator_machine: $orchestratorMachineName",
                "- started_utc: $($sessionStartedUtc.ToString('o'))",
                "- ended_utc: $($sessionEndedUtc.ToString('o'))",
                "- duration_seconds: $durationSeconds",
                "- status: $sessionStatus",
                "- run_ids: $(@($sessionRunIds) -join ', ')"
            )
            if (-not [string]::IsNullOrWhiteSpace($sessionError)) {
                $singleLineError = ($sessionError -replace "\r?\n", ' ') -replace '\s+', ' '
                $endLines += ("- error_summary: {0}" -f $singleLineError.Trim())
            }
            gh issue comment $IssueUrl --body ($endLines -join [Environment]::NewLine) | Out-Null
        } catch {
            Write-Warning ("Failed to post CERT_SESSION_END comment for session '{0}'." -f $sessionId)
        }
    }
}
