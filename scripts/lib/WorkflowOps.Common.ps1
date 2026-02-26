#Requires -Version 7.0
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-Gh {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)

    & gh @Arguments
    $exitCode = if ($null -eq $LASTEXITCODE) { 0 } else { [int]$LASTEXITCODE }
    if ($exitCode -ne 0) {
        throw ("gh_command_failed: exit={0} command=gh {1}" -f $exitCode, ($Arguments -join ' '))
    }
}

function Invoke-GhText {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)

    $output = & gh @Arguments
    $exitCode = if ($null -eq $LASTEXITCODE) { 0 } else { [int]$LASTEXITCODE }
    if ($exitCode -ne 0) {
        throw ("gh_command_failed: exit={0} command=gh {1}" -f $exitCode, ($Arguments -join ' '))
    }

    if ($output -is [System.Array]) {
        return (($output | ForEach-Object { [string]$_ }) -join [Environment]::NewLine)
    }

    return [string]$output
}

function Invoke-GhJson {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)

    $json = Invoke-GhText -Arguments $Arguments
    if ([string]::IsNullOrWhiteSpace($json)) {
        return $null
    }

    return ($json | ConvertFrom-Json -ErrorAction Stop)
}

function Ensure-ParentDirectory {
    param([Parameter(Mandatory = $true)][string]$Path)

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $parent = Split-Path -Path $fullPath -Parent
    if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -Path $parent -ItemType Directory -Force | Out-Null
    }

    return $fullPath
}

function Write-WorkflowOpsReport {
    param(
        [Parameter(Mandatory = $true)][object]$Report,
        [Parameter()][string]$OutputPath = ''
    )

    $json = ($Report | ConvertTo-Json -Depth 10)
    if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
        $resolvedPath = Ensure-ParentDirectory -Path $OutputPath
        Set-Content -LiteralPath $resolvedPath -Value $json -Encoding utf8
        Write-Host ("Report written: {0}" -f $resolvedPath)
    }

    Write-Output $json
}

function Get-UtcNowIso {
    return (Get-Date).ToUniversalTime().ToString('o')
}

function Convert-InputPairsToGhArgs {
    param([Parameter()][string[]]$Input = @())

    $arguments = @()
    foreach ($pair in @($Input)) {
        $text = ([string]$pair).Trim()
        if ([string]::IsNullOrWhiteSpace($text)) {
            continue
        }

        $splitIndex = $text.IndexOf('=')
        if ($splitIndex -lt 1) {
            throw ("input_pair_invalid: '{0}' must be key=value." -f $text)
        }

        $key = $text.Substring(0, $splitIndex).Trim()
        $value = $text.Substring($splitIndex + 1)
        if ([string]::IsNullOrWhiteSpace($key)) {
            throw ("input_key_invalid: '{0}' has empty key." -f $text)
        }

        $arguments += @('-f', ("{0}={1}" -f $key, $value))
    }

    return ,$arguments
}

function Test-WorkflowRunMatch {
    param(
        [Parameter(Mandatory = $true)][object]$Run,
        [Parameter()][string]$Workflow = ''
    )

    if ([string]::IsNullOrWhiteSpace($Workflow)) {
        return $true
    }

    $token = ([string]$Workflow).Trim().ToLowerInvariant()
    $runName = ([string]$Run.name).Trim().ToLowerInvariant()
    $runPath = ([string]$Run.path).Trim().ToLowerInvariant()
    if ($runName -eq $token) {
        return $true
    }
    if ([string]::IsNullOrWhiteSpace($runPath)) {
        return $false
    }

    if ($runPath.Contains($token)) {
        return $true
    }

    if (-not $token.EndsWith('.yml') -and -not $token.EndsWith('.yaml')) {
        if ($runPath.EndsWith("/$token.yml") -or $runPath.EndsWith("/$token.yaml")) {
            return $true
        }
    }

    return $false
}

function Get-GhWorkflowRunsPortable {
    param(
        [Parameter(Mandatory = $true)][string]$Repository,
        [Parameter()][string]$Workflow = '',
        [Parameter()][string]$Branch = '',
        [Parameter()][string]$Event = '',
        [Parameter()][int]$Limit = 20
    )

    $safeLimit = [Math]::Max(1, [Math]::Min($Limit, 100))
    $runsPayload = Invoke-GhJson -Arguments @(
        'api',
        "repos/$Repository/actions/runs?per_page=100"
    )
    $allRuns = @($runsPayload.workflow_runs)
    if (@($allRuns).Count -eq 0) {
        return @()
    }

    $branchToken = ([string]$Branch).Trim().ToLowerInvariant()
    $eventToken = ([string]$Event).Trim().ToLowerInvariant()
    $records = @()
    foreach ($run in $allRuns) {
        if (-not (Test-WorkflowRunMatch -Run $run -Workflow $Workflow)) {
            continue
        }

        $runBranch = ([string]$run.head_branch).Trim().ToLowerInvariant()
        if (-not [string]::IsNullOrWhiteSpace($branchToken) -and $runBranch -ne $branchToken) {
            continue
        }

        $runEvent = ([string]$run.event).Trim().ToLowerInvariant()
        if (-not [string]::IsNullOrWhiteSpace($eventToken) -and $runEvent -ne $eventToken) {
            continue
        }

        $records += [pscustomobject]@{
            databaseId = [string]$run.id
            status = [string]$run.status
            conclusion = [string]$run.conclusion
            url = [string]$run.html_url
            createdAt = [string]$run.created_at
            updatedAt = [string]$run.updated_at
            headSha = [string]$run.head_sha
            event = [string]$run.event
            workflowName = [string]$run.name
            displayTitle = [string]$run.display_title
            headBranch = [string]$run.head_branch
        }
    }

    return @(
        $records |
            Sort-Object { Parse-RunTimestamp -Run $_ } -Descending |
            Select-Object -First $safeLimit
    )
}

function Get-GhReleasesPortable {
    param(
        [Parameter(Mandatory = $true)][string]$Repository,
        [Parameter()][int]$Limit = 30,
        [Parameter()][switch]$ExcludeDrafts
    )

    $safeLimit = [Math]::Max(1, [Math]::Min($Limit, 100))
    $releasePayload = Invoke-GhJson -Arguments @(
        'api',
        "repos/$Repository/releases?per_page=100"
    )
    $allReleases = @($releasePayload)
    if (@($allReleases).Count -eq 0) {
        return @()
    }

    $records = @()
    foreach ($release in $allReleases) {
        $isDraft = [bool]$release.draft
        if ($ExcludeDrafts -and $isDraft) {
            continue
        }

        $records += [pscustomobject]@{
            tagName = [string]$release.tag_name
            isPrerelease = [bool]$release.prerelease
            publishedAt = [string]$release.published_at
            url = [string]$release.html_url
            isDraft = $isDraft
        }
    }

    return @(
        $records |
            Select-Object -First $safeLimit
    )
}

function Parse-RunTimestamp {
    param([Parameter(Mandatory = $true)][object]$Run)

    $createdAt = [string]$Run.createdAt
    if ([string]::IsNullOrWhiteSpace($createdAt)) {
        return [DateTimeOffset]::MinValue
    }

    $value = [DateTimeOffset]::MinValue
    if ([DateTimeOffset]::TryParse($createdAt, [ref]$value)) {
        return $value
    }

    return [DateTimeOffset]::MinValue
}
