#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter()]
    [string]$Repository = 'LabVIEW-Community-CI-CD/labview-cdev-surface',

    [Parameter()]
    [string]$WorkflowFile = 'self-hosted-machine-certification.yml',

    [Parameter()]
    [string]$Ref = 'main',

    [Parameter()]
    [string[]]$SetupName = @(),

    [Parameter()]
    [string]$ProfilesPath = '',

    [Parameter()]
    [switch]$Watch,

    [Parameter()]
    [int]$DispatchPauseSeconds = 4,

    [Parameter()]
    [string]$OutputPath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-ProfilesPath {
    param([string]$InputPath)
    if (-not [string]::IsNullOrWhiteSpace($InputPath)) {
        return [System.IO.Path]::GetFullPath($InputPath)
    }
    $repoRoot = (Resolve-Path -Path (Join-Path $PSScriptRoot '..')).Path
    return (Join-Path $repoRoot 'tools\machine-certification\setup-profiles.json')
}

function Invoke-Gh {
    param([string[]]$Arguments)
    & gh @Arguments
    $exitCode = if ($null -eq $LASTEXITCODE) { 0 } else { [int]$LASTEXITCODE }
    if ($exitCode -ne 0) {
        throw "gh command failed with exit code ${exitCode}: gh $($Arguments -join ' ')"
    }
}

function Get-ScalarString {
    param([object]$Value)
    if ($null -eq $Value) {
        return ''
    }
    if ($Value -is [System.Array]) {
        $first = @($Value | Select-Object -First 1)
        if (@($first).Count -eq 0) { return '' }
        return [string]$first[0]
    }
    return [string]$Value
}

function Split-LabelCsv {
    param([Parameter(Mandatory = $true)][string]$Csv)
    return @(
        $Csv -split ',' |
        ForEach-Object { ([string]$_).Trim() } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )
}

function Join-LabelsCsv {
    param([Parameter(Mandatory = $true)][string[]]$Labels)
    return (@($Labels | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join ',')
}

function Get-RepositoryOwner {
    param([Parameter(Mandatory = $true)][string]$Repository)
    return ([string]$Repository -split '/')[0]
}

function Get-CollisionGuardLabel {
    param([Parameter(Mandatory = $true)][object]$Setup)
    return (Get-ScalarString -Value $Setup.collision_guard_label)
}

function Get-SetupBoolean {
    param(
        [Parameter(Mandatory = $true)][object]$Setup,
        [Parameter(Mandatory = $true)][string]$PropertyName,
        [Parameter(Mandatory = $true)][bool]$Default
    )

    $property = $Setup.PSObject.Properties[$PropertyName]
    if ($null -eq $property -or $null -eq $property.Value) {
        return $Default
    }

    $raw = [string]$property.Value
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return $Default
    }

    try {
        return [System.Convert]::ToBoolean($property.Value)
    } catch {
        throw ("setup_boolean_invalid: setup '{0}' has invalid boolean value for '{1}': '{2}'." -f [string]$Setup.name, $PropertyName, $raw)
    }
}

function Resolve-RunnerLabelsCsv {
    param([Parameter(Mandatory = $true)][object]$Setup)

    $csvValue = Get-ScalarString -Value $Setup.runner_labels_csv
    if (-not [string]::IsNullOrWhiteSpace($csvValue)) {
        return $csvValue
    }

    $jsonValue = Get-ScalarString -Value $Setup.runner_labels_json
    if (-not [string]::IsNullOrWhiteSpace($jsonValue)) {
        try {
            $labels = @($jsonValue | ConvertFrom-Json -ErrorAction Stop | ForEach-Object { [string]$_ })
            if (@($labels).Count -gt 0) {
                return ($labels -join ',')
            }
        } catch {
            # fall through to explicit error below
        }
    }

    throw "Setup '$([string]$Setup.name)' is missing runner labels (runner_labels_csv or valid runner_labels_json)."
}

function Resolve-UpstreamRunnerLabelsCsv {
    param(
        [Parameter(Mandatory = $true)][string]$Repository,
        [Parameter(Mandatory = $true)][object]$Setup
    )

    $baseCsv = Resolve-RunnerLabelsCsv -Setup $Setup
    $owner = Get-RepositoryOwner -Repository $Repository
    if (-not [string]::Equals($owner, 'LabVIEW-Community-CI-CD', [System.StringComparison]::OrdinalIgnoreCase)) {
        return $baseCsv
    }

    $guardLabel = Get-CollisionGuardLabel -Setup $Setup
    if ([string]::IsNullOrWhiteSpace($guardLabel)) {
        throw "runner_collision_guard_label_missing: setup '$([string]$Setup.name)' must define collision_guard_label for upstream dispatch."
    }

    $labels = Split-LabelCsv -Csv $baseCsv
    if ($labels -notcontains $guardLabel) {
        $labels += $guardLabel
    }
    return (Join-LabelsCsv -Labels $labels)
}

function Assert-UpstreamRunnerCapacity {
    param(
        [Parameter(Mandatory = $true)][string]$Repository,
        [Parameter(Mandatory = $true)][string]$RunnerLabelsCsv,
        [Parameter(Mandatory = $true)][string]$SetupName
    )

    $owner = Get-RepositoryOwner -Repository $Repository
    if (-not [string]::Equals($owner, 'LabVIEW-Community-CI-CD', [System.StringComparison]::OrdinalIgnoreCase)) {
        return
    }

    $requiredLabels = Split-LabelCsv -Csv $RunnerLabelsCsv
    if (@($requiredLabels).Count -eq 0) {
        throw "runner_labels_empty: setup '$SetupName' resolved to no runner labels."
    }

    $runnerLines = & gh api "repos/$Repository/actions/runners" --paginate --jq '.runners[] | @json'
    if ($LASTEXITCODE -ne 0) {
        throw "runner_inventory_query_failed: unable to query upstream runner inventory for '$Repository'."
    }
    $runners = @()
    foreach ($line in @($runnerLines)) {
        if ([string]::IsNullOrWhiteSpace([string]$line)) { continue }
        $runners += @(([string]$line | ConvertFrom-Json -ErrorAction Stop))
    }
    $eligibleOnline = @(
        $runners | Where-Object {
            [string]$_.status -eq 'online'
        } | Where-Object {
            $runnerLabels = @($_.labels | ForEach-Object { [string]$_.name })
            @($requiredLabels | Where-Object { $runnerLabels -notcontains $_ }).Count -eq 0
        }
    )
    $eligibleAvailable = @($eligibleOnline | Where-Object { -not [bool]$_.busy })

    if (@($eligibleOnline).Count -eq 0) {
        throw ("runner_label_collision_guard_unconfigured: no online upstream runner matches setup '{0}' labels '{1}'. Configure runner labels to avoid collisions." -f $SetupName, $RunnerLabelsCsv)
    }
    if (@($eligibleAvailable).Count -eq 0) {
        Write-Warning ("runner_label_collision_guard_busy: online runners for setup '{0}' labels '{1}' are currently busy; dispatch will queue." -f $SetupName, $RunnerLabelsCsv)
    }
}

$resolvedProfilesPath = Resolve-ProfilesPath -InputPath $ProfilesPath
if (-not (Test-Path -LiteralPath $resolvedProfilesPath -PathType Leaf)) {
    throw "Setup profiles file not found: $resolvedProfilesPath"
}

$profilesDoc = Get-Content -LiteralPath $resolvedProfilesPath -Raw | ConvertFrom-Json -ErrorAction Stop
$allSetups = @($profilesDoc.setups)
if (@($allSetups).Count -eq 0) {
    throw "No setup profiles found in $resolvedProfilesPath"
}

$selectedSetups = @()
if (@($SetupName).Count -gt 0) {
    foreach ($name in $SetupName) {
        $candidate = @($allSetups | Where-Object { [string]$_.name -eq [string]$name }) | Select-Object -First 1
        if ($null -eq $candidate) {
            throw "Unknown setup profile '$name' in $resolvedProfilesPath"
        }
        $selectedSetups += $candidate
    }
} else {
    $selectedSetups = @($allSetups | Where-Object { $_.active -eq $true })
}

if (@($selectedSetups).Count -eq 0) {
    throw "No active setup profiles selected."
}

$dispatchRecords = @()
$claimedRunIds = @{}
foreach ($setup in $selectedSetups) {
    $setupNameToken = [string]$setup.name
    $runnerLabelsCsv = Resolve-UpstreamRunnerLabelsCsv -Repository $Repository -Setup $setup
    $switchDockerContext = (Get-SetupBoolean -Setup $setup -PropertyName 'switch_docker_context' -Default $true).ToString().ToLowerInvariant()
    $startDockerDesktop = (Get-SetupBoolean -Setup $setup -PropertyName 'start_docker_desktop_if_needed' -Default $true).ToString().ToLowerInvariant()
    Assert-UpstreamRunnerCapacity -Repository $Repository -RunnerLabelsCsv $runnerLabelsCsv -SetupName $setupNameToken
    Write-Host ("Dispatching setup: {0}" -f $setupNameToken)
    $dispatchStartUtc = (Get-Date).ToUniversalTime()

    $dispatchArgs = @(
        'workflow', 'run', $WorkflowFile,
        '-R', $Repository,
        '--ref', $Ref,
        '-f', ("setup_name={0}" -f $setupNameToken),
        '-f', ("runner_labels_csv={0}" -f $runnerLabelsCsv),
        '-f', ("expected_labview_year={0}" -f ([string]$setup.expected_labview_year)),
        '-f', ("docker_context={0}" -f ([string]$setup.docker_context)),
        '-f', ("switch_docker_context={0}" -f $switchDockerContext),
        '-f', ("start_docker_desktop_if_needed={0}" -f $startDockerDesktop),
        '-f', ("skip_host_ini_mutation={0}" -f ([string]$setup.skip_host_ini_mutation).ToLowerInvariant()),
        '-f', ("skip_override_phase={0}" -f ([string]$setup.skip_override_phase).ToLowerInvariant())
    )
    Invoke-Gh -Arguments $dispatchArgs

    Start-Sleep -Seconds $DispatchPauseSeconds

    $runJson = gh run list -R $Repository --workflow $WorkflowFile --branch $Ref --event workflow_dispatch --limit 50 --json databaseId,status,conclusion,url,displayTitle,createdAt
    $runListRaw = @($runJson | ConvertFrom-Json -ErrorAction Stop)
    $runList = @(
        $runListRaw | ForEach-Object {
            [pscustomobject]@{
                databaseId = Get-ScalarString -Value $_.databaseId
                status = Get-ScalarString -Value $_.status
                conclusion = Get-ScalarString -Value $_.conclusion
                url = Get-ScalarString -Value $_.url
                displayTitle = Get-ScalarString -Value $_.displayTitle
                createdAt = Get-ScalarString -Value $_.createdAt
            }
        }
    )
    $candidateRuns = @(
        $runList |
        Where-Object {
            $runId = Get-ScalarString -Value $_.databaseId
            if ([string]::IsNullOrWhiteSpace($runId)) { return $false }
            if ($claimedRunIds.ContainsKey($runId)) { return $false }
            $createdAt = [DateTimeOffset]::MinValue
            if (-not [DateTimeOffset]::TryParse((Get-ScalarString -Value $_.createdAt), [ref]$createdAt)) { return $false }
            return ($createdAt.UtcDateTime -ge $dispatchStartUtc.AddMinutes(-2))
        } |
        Sort-Object -Property createdAt -Descending
    )
    $run = $candidateRuns | Select-Object -First 1
    if ($null -eq $run -and @($runList).Count -gt 0) {
        $run = @(
            $runList |
            Where-Object { -not $claimedRunIds.ContainsKey((Get-ScalarString -Value $_.databaseId)) } |
            Sort-Object -Property createdAt -Descending
        ) | Select-Object -First 1
    }
    if ($null -ne $run -and -not [string]::IsNullOrWhiteSpace((Get-ScalarString -Value $run.databaseId))) {
        $claimedRunIds[(Get-ScalarString -Value $run.databaseId)] = $true
    }

    $record = [ordered]@{
        setup_name = $setupNameToken
        machine_name = [System.Environment]::MachineName
        runner_labels_csv = $runnerLabelsCsv
        start_docker_desktop_if_needed = $startDockerDesktop
        switch_docker_context = $switchDockerContext
        run_id = if ($null -ne $run) { (Get-ScalarString -Value $run.databaseId) } else { '' }
        run_url = if ($null -ne $run) { (Get-ScalarString -Value $run.url) } else { '' }
        run_created_at = if ($null -ne $run) { (Get-ScalarString -Value $run.createdAt) } else { '' }
        status = if ($null -ne $run) { (Get-ScalarString -Value $run.status) } else { 'unknown' }
        conclusion = if ($null -ne $run) { (Get-ScalarString -Value $run.conclusion) } else { '' }
    }
    $dispatchRecords += [pscustomobject]$record

    if ($Watch -and $null -ne $run -and -not [string]::IsNullOrWhiteSpace([string]$run.databaseId)) {
        Invoke-Gh -Arguments @('run', 'watch', [string]$run.databaseId, '-R', $Repository)
    }
}

$report = [ordered]@{
    timestamp_utc = (Get-Date).ToUniversalTime().ToString('o')
    repository = $Repository
    workflow = $WorkflowFile
    ref = $Ref
    profiles_path = $resolvedProfilesPath
    dispatched_setups = @($selectedSetups | ForEach-Object { [string]$_.name })
    runs = @($dispatchRecords)
}

if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
    $resolvedOutputPath = [System.IO.Path]::GetFullPath($OutputPath)
    $parent = Split-Path -Path $resolvedOutputPath -Parent
    if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -Path $parent -ItemType Directory -Force | Out-Null
    }
    $report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $resolvedOutputPath -Encoding utf8
    Write-Host ("Dispatch report written: {0}" -f $resolvedOutputPath)
}

$report | ConvertTo-Json -Depth 8 | Write-Output
