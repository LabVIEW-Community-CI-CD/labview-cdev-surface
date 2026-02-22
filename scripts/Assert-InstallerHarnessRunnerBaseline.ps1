#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter()]
    [string]$Repository = 'LabVIEW-Community-CI-CD/labview-cdev-surface',

    [Parameter()]
    [string[]]$RunnerRoots = @(
        'C:\actions-runner-cdev',
        'C:\actions-runner-cdev-2'
    ),

    [Parameter()]
    [string]$ExpectedServiceAccount = 'NT AUTHORITY\NETWORK SERVICE',

    [Parameter()]
    [switch]$AllowInteractiveRunner,

    [Parameter()]
    [string[]]$RequiredLabels = @('self-hosted', 'windows', 'self-hosted-windows-lv'),

    [Parameter()]
    [string]$OutputPath = '',

    [Parameter()]
    [switch]$FailOnWarning
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$checks = @()
$errors = @()
$warnings = @()
$runnerRootResults = @()
$serviceResults = @()
$apiRunnerResults = @()

function Add-Check {
    param(
        [Parameter(Mandatory = $true)][string]$Scope,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][bool]$Passed,
        [Parameter(Mandatory = $true)][string]$Detail,
        [Parameter()][ValidateSet('error', 'warning')][string]$Severity = 'error'
    )

    $entry = [ordered]@{
        scope = $Scope
        check = $Name
        passed = $Passed
        severity = $Severity
        detail = $Detail
    }
    $script:checks += [pscustomobject]$entry

    if (-not $Passed) {
        if ($Severity -eq 'warning') {
            $script:warnings += "$Scope::$Name::$Detail"
        } else {
            $script:errors += "$Scope::$Name::$Detail"
        }
    }
}

function Normalize-StringArray {
    param(
        [Parameter()]
        [AllowNull()]
        [string[]]$Values
    )

    $normalized = @()
    foreach ($value in @($Values)) {
        if ([string]::IsNullOrWhiteSpace($value)) {
            continue
        }

        foreach ($segment in @(([string]$value) -split ',')) {
            if ([string]::IsNullOrWhiteSpace($segment)) {
                continue
            }
            $normalized += $segment.Trim()
        }
    }

    return @($normalized)
}

$RunnerRoots = Normalize-StringArray -Values $RunnerRoots
$RequiredLabels = Normalize-StringArray -Values $RequiredLabels

if ($RunnerRoots.Count -eq 0) {
    throw "At least one runner root must be provided."
}
if ($RequiredLabels.Count -eq 0) {
    throw "At least one required label must be provided."
}

if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
    throw "Required command 'gh' was not found on PATH."
}

$expectedGitHubUrl = "https://github.com/$Repository"

$serviceInventory = @(Get-CimInstance Win32_Service | Where-Object { $_.Name -like 'actions.runner.LabVIEW-Community-CI-CD-labview-cdev-surface*' })
$requiredServiceCount = if ($AllowInteractiveRunner.IsPresent) { 0 } else { $RunnerRoots.Count }
Add-Check -Scope 'services' -Name 'service_count' -Passed ($serviceInventory.Count -ge $requiredServiceCount) -Detail ("count={0}; required_minimum={1}" -f $serviceInventory.Count, $requiredServiceCount)

foreach ($runnerRoot in $RunnerRoots) {
    $scope = "runner-root:$runnerRoot"
    $resolvedRoot = [System.IO.Path]::GetFullPath($runnerRoot)
    $runnerFile = Join-Path $resolvedRoot '.runner'
    $serviceExe = Join-Path $resolvedRoot 'bin\RunnerService.exe'

    Add-Check -Scope $scope -Name 'root_exists' -Passed (Test-Path -LiteralPath $resolvedRoot -PathType Container) -Detail $resolvedRoot
    Add-Check -Scope $scope -Name 'runner_file_exists' -Passed (Test-Path -LiteralPath $runnerFile -PathType Leaf) -Detail $runnerFile
    Add-Check -Scope $scope -Name 'service_exe_exists' -Passed (Test-Path -LiteralPath $serviceExe -PathType Leaf) -Detail $serviceExe

    $runnerData = $null
    if (Test-Path -LiteralPath $runnerFile -PathType Leaf) {
        try {
            $runnerData = Get-Content -LiteralPath $runnerFile -Raw | ConvertFrom-Json -ErrorAction Stop
        } catch {
            Add-Check -Scope $scope -Name 'runner_json_parse' -Passed $false -Detail $_.Exception.Message
        }
    }

    if ($null -ne $runnerData) {
        $agentName = [string]$runnerData.agentName
        $runnerRepoUrl = [string]$runnerData.gitHubUrl
        $runnerRootResults += [pscustomobject]@{
            root = $resolvedRoot
            agent_name = $agentName
            github_url = $runnerRepoUrl
        }

        Add-Check -Scope $scope -Name 'github_url_matches_repo' -Passed ($runnerRepoUrl -eq $expectedGitHubUrl) -Detail $runnerRepoUrl
        Add-Check -Scope $scope -Name 'agent_name_present' -Passed (-not [string]::IsNullOrWhiteSpace($agentName)) -Detail $agentName

        $serviceMatch = $serviceInventory |
            Where-Object { ([string]$_.PathName).Trim('"') -ieq $serviceExe } |
            Select-Object -First 1
        if ($null -eq $serviceMatch) {
            if ($AllowInteractiveRunner.IsPresent) {
                $listenerExe = Join-Path $resolvedRoot 'bin\Runner.Listener.exe'
                Add-Check -Scope $scope -Name 'interactive_listener_exists' -Passed (Test-Path -LiteralPath $listenerExe -PathType Leaf) -Detail $listenerExe

                $listenerProcesses = @()
                try {
                    $listenerProcesses = @(
                        Get-CimInstance Win32_Process -Filter "Name='Runner.Listener.exe'" |
                        Where-Object { ([string]$_.ExecutablePath) -ieq $listenerExe }
                    )
                } catch {
                    Add-Check -Scope $scope -Name 'interactive_runner_process_query' -Passed $false -Detail $_.Exception.Message -Severity warning
                }
                Add-Check -Scope $scope -Name 'interactive_runner_process' -Passed ($listenerProcesses.Count -ge 1) -Detail ("count={0}; listener={1}" -f $listenerProcesses.Count, $listenerExe)
            } else {
                Add-Check -Scope $scope -Name 'service_mapping' -Passed $false -Detail ("No service mapped to {0}" -f $serviceExe)
            }
        } else {
            $serviceResults += [pscustomobject]@{
                root = $resolvedRoot
                service_name = [string]$serviceMatch.Name
                state = [string]$serviceMatch.State
                start_mode = [string]$serviceMatch.StartMode
                start_name = [string]$serviceMatch.StartName
            }
            Add-Check -Scope $scope -Name 'service_running' -Passed (([string]$serviceMatch.State) -eq 'Running') -Detail ([string]$serviceMatch.State)
            Add-Check -Scope $scope -Name 'service_auto_start' -Passed (([string]$serviceMatch.StartMode) -eq 'Auto') -Detail ([string]$serviceMatch.StartMode)
            Add-Check -Scope $scope -Name 'service_account' -Passed (([string]$serviceMatch.StartName) -eq $ExpectedServiceAccount) -Detail ([string]$serviceMatch.StartName)
        }
    }
}

$apiOutput = & gh api "repos/$Repository/actions/runners" 2>&1
if ($LASTEXITCODE -ne 0) {
    $apiErrorText = ($apiOutput | Out-String).Trim()
    $apiPermissionDenied = (
        $apiErrorText -match 'Must have admin rights to Repository' -or
        $apiErrorText -match 'HTTP 403' -or
        $apiErrorText -match 'Resource not accessible'
    )
    $severity = if ($apiPermissionDenied) { 'warning' } else { 'error' }
    Add-Check -Scope 'github-api' -Name 'runners_query' -Passed $false -Detail $apiErrorText -Severity $severity
} else {
    $apiResponse = $apiOutput | ConvertFrom-Json -ErrorAction Stop
    foreach ($runner in @($apiResponse.runners)) {
        $labelSet = @($runner.labels | ForEach-Object { [string]$_.name })
        $apiRunnerResults += [pscustomobject]@{
            name = [string]$runner.name
            status = [string]$runner.status
            busy = [bool]$runner.busy
            labels = $labelSet
        }
    }

    foreach ($runnerRootResult in $runnerRootResults) {
        $scope = "github-api:$($runnerRootResult.agent_name)"
        $apiRunner = @($apiRunnerResults | Where-Object { $_.name -eq $runnerRootResult.agent_name } | Select-Object -First 1)
        if ($null -eq $apiRunner) {
            Add-Check -Scope $scope -Name 'runner_registered' -Passed $false -Detail 'Runner not found in GitHub API list.'
            continue
        }

        Add-Check -Scope $scope -Name 'runner_online' -Passed ($apiRunner.status -eq 'online') -Detail $apiRunner.status
        foreach ($requiredLabel in $RequiredLabels) {
            Add-Check `
                -Scope $scope `
                -Name ("label:{0}" -f $requiredLabel) `
                -Passed (@($apiRunner.labels) -contains $requiredLabel) `
                -Detail ([string]::Join(',', @($apiRunner.labels)))
        }
    }
}

$status = if ($errors.Count -gt 0) { 'failed' } else { 'succeeded' }
$report = [ordered]@{
    timestamp_utc = (Get-Date).ToUniversalTime().ToString('o')
    repository = $Repository
    expected_github_url = $expectedGitHubUrl
    expected_runner_roots = $RunnerRoots
    required_labels = $RequiredLabels
    expected_service_account = $ExpectedServiceAccount
    status = $status
    summary = [ordered]@{
        checks = $checks.Count
        errors = $errors.Count
        warnings = $warnings.Count
    }
    checks = $checks
    runner_roots = $runnerRootResults
    services = $serviceResults
    api_runners = $apiRunnerResults
    errors = $errors
    warnings = $warnings
}

if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
    $resolvedOutput = [System.IO.Path]::GetFullPath($OutputPath)
    $outputDir = Split-Path -Path $resolvedOutput -Parent
    if (-not [string]::IsNullOrWhiteSpace($outputDir) -and -not (Test-Path -LiteralPath $outputDir -PathType Container)) {
        New-Item -Path $outputDir -ItemType Directory -Force | Out-Null
    }
    $report | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $resolvedOutput -Encoding utf8
    Write-Host "Runner baseline report: $resolvedOutput"
} else {
    $report | ConvertTo-Json -Depth 10 | Write-Output
}

if ($errors.Count -gt 0) {
    exit 1
}
if ($FailOnWarning -and $warnings.Count -gt 0) {
    exit 1
}

exit 0
