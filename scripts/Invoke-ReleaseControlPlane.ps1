#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter()]
    [ValidatePattern('^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$')]
    [string]$Repository = 'LabVIEW-Community-CI-CD/labview-cdev-surface-fork',

    [Parameter()]
    [ValidatePattern('^[A-Za-z0-9._/-]+$')]
    [string]$Branch = 'main',

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$ReleaseWorkflowFile = 'release-workspace-installer.yml',

    [Parameter()]
    [ValidateSet('Validate', 'CanaryCycle', 'PromotePrerelease', 'PromoteStable', 'FullCycle')]
    [string]$Mode = 'FullCycle',

    [Parameter()]
    [ValidateRange(1, 168)]
    [int]$SyncGuardMaxAgeHours = 12,

    [Parameter()]
    [ValidateRange(1, 10)]
    [int]$KeepLatestCanaryN = 1,

    [Parameter()]
    [bool]$AutoRemediate = $true,

    [Parameter()]
    [ValidateRange(5, 240)]
    [int]$WatchTimeoutMinutes = 120,

    [Parameter()]
    [switch]$DryRun,

    [Parameter()]
    [string]$OutputPath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'lib/WorkflowOps.Common.ps1')

$opsSnapshotScript = Join-Path $PSScriptRoot 'Invoke-OpsMonitoringSnapshot.ps1'
$opsRemediateScript = Join-Path $PSScriptRoot 'Invoke-OpsAutoRemediation.ps1'
$dispatchWorkflowScript = Join-Path $PSScriptRoot 'Dispatch-WorkflowAtRemoteHead.ps1'
$watchWorkflowScript = Join-Path $PSScriptRoot 'Watch-WorkflowRun.ps1'
$canaryHygieneScript = Join-Path $PSScriptRoot 'Invoke-CanarySmokeTagHygiene.ps1'
$releaseRunnerLabels = @('self-hosted', 'windows', 'self-hosted-windows-lv')
$releaseRunnerLabelsCsv = [string]::Join(',', $releaseRunnerLabels)

foreach ($requiredScript in @($opsSnapshotScript, $opsRemediateScript, $dispatchWorkflowScript, $watchWorkflowScript, $canaryHygieneScript)) {
    if (-not (Test-Path -LiteralPath $requiredScript -PathType Leaf)) {
        throw "required_script_missing: $requiredScript"
    }
}

function Get-ModeConfig {
    param([Parameter(Mandatory = $true)][string]$ModeName)

    switch ($ModeName) {
        'CanaryCycle' {
            return [ordered]@{
                channel = 'canary'
                prerelease = $true
                range_min = 1
                range_max = 49
                source_channel_for_promotion = ''
                enforce_prerelease_source = $false
            }
        }
        'PromotePrerelease' {
            return [ordered]@{
                channel = 'prerelease'
                prerelease = $true
                range_min = 50
                range_max = 79
                source_channel_for_promotion = 'canary'
                enforce_prerelease_source = $true
            }
        }
        'PromoteStable' {
            return [ordered]@{
                channel = 'stable'
                prerelease = $false
                range_min = 80
                range_max = 99
                source_channel_for_promotion = 'prerelease'
                enforce_prerelease_source = $true
            }
        }
        default {
            throw "unsupported_mode_config: $ModeName"
        }
    }
}

function Parse-ReleaseTag {
    param([Parameter(Mandatory = $true)][string]$TagName)

    $match = [regex]::Match($TagName, '^v0\.(?<date>\d{8})\.(?<sequence>\d+)$')
    if (-not $match.Success) {
        return $null
    }

    $sequence = 0
    if (-not [int]::TryParse([string]$match.Groups['sequence'].Value, [ref]$sequence)) {
        return $null
    }

    return [ordered]@{
        tag_name = $TagName
        date = [string]$match.Groups['date'].Value
        sequence = $sequence
    }
}

function Get-ReleaseRecordsForDate {
    param(
        [Parameter(Mandatory = $true)][object[]]$ReleaseList,
        [Parameter(Mandatory = $true)][string]$DateKey
    )

    $records = @()
    foreach ($release in $ReleaseList) {
        $parsed = Parse-ReleaseTag -TagName ([string]$release.tagName)
        if ($null -eq $parsed) {
            continue
        }
        if ([string]$parsed.date -ne $DateKey) {
            continue
        }

        $records += [ordered]@{
            tag_name = [string]$parsed.tag_name
            date = [string]$parsed.date
            sequence = [int]$parsed.sequence
            is_prerelease = [bool]$release.isPrerelease
            published_at_utc = [string]$release.publishedAt
        }
    }

    return @($records | Sort-Object @{ Expression = { [int]$_.sequence }; Descending = $true })
}

function Get-LatestRecordInRange {
    param(
        [Parameter(Mandatory = $true)][object[]]$Records,
        [Parameter(Mandatory = $true)][int]$RangeMin,
        [Parameter(Mandatory = $true)][int]$RangeMax
    )

    return @(
        $Records |
            Where-Object { [int]$_.sequence -ge $RangeMin -and [int]$_.sequence -le $RangeMax } |
            Sort-Object @{ Expression = { [int]$_.sequence }; Descending = $true } |
            Select-Object -First 1
    )
}

function Invoke-ReleaseMode {
    param(
        [Parameter(Mandatory = $true)][string]$ModeName,
        [Parameter(Mandatory = $true)][string]$DateKey,
        [Parameter(Mandatory = $true)][string]$ScratchRoot,
        [Parameter(Mandatory = $true)][hashtable]$ExecutionReport
    )

    $modeConfig = Get-ModeConfig -ModeName $ModeName
    $releaseList = @(Get-GhReleasesPortable -Repository $Repository -Limit 100 -ExcludeDrafts)

    $records = @(Get-ReleaseRecordsForDate -ReleaseList $releaseList -DateKey $DateKey)
    $targetRangeRecords = @(
        $records |
            Where-Object { [int]$_.sequence -ge [int]$modeConfig.range_min -and [int]$_.sequence -le [int]$modeConfig.range_max } |
            Sort-Object @{ Expression = { [int]$_.sequence }; Descending = $true }
    )

    if (-not [string]::IsNullOrWhiteSpace([string]$modeConfig.source_channel_for_promotion)) {
        $sourceRange = switch ([string]$modeConfig.source_channel_for_promotion) {
            'canary' { [ordered]@{ min = 1; max = 49 } }
            'prerelease' { [ordered]@{ min = 50; max = 79 } }
            default { throw "unsupported_source_channel: $([string]$modeConfig.source_channel_for_promotion)" }
        }
        $sourceRecord = @(Get-LatestRecordInRange -Records $records -RangeMin $sourceRange.min -RangeMax $sourceRange.max)
        if (@($sourceRecord).Count -ne 1) {
            throw "promotion_source_missing: channel=$([string]$modeConfig.source_channel_for_promotion) date=$DateKey"
        }

        $sourceTag = [string]$sourceRecord[0].tag_name
        $sourceRelease = Invoke-GhJson -Arguments @(
            'release', 'view',
            $sourceTag,
            '-R', $Repository,
            '--json', 'tagName,isPrerelease,targetCommitish,publishedAt,assets,url'
        )

        if ($modeConfig.enforce_prerelease_source -and -not [bool]$sourceRelease.isPrerelease) {
            throw "promotion_source_not_prerelease: tag=$sourceTag channel=$([string]$modeConfig.source_channel_for_promotion)"
        }

        $requiredAssets = @(
            'lvie-cdev-workspace-installer.exe',
            'lvie-cdev-workspace-installer.exe.sha256',
            'reproducibility-report.json',
            'workspace-installer.spdx.json',
            'workspace-installer.slsa.json',
            'release-manifest.json'
        )
        $assetNames = @($sourceRelease.assets | ForEach-Object { [string]$_.name })
        foreach ($requiredAsset in $requiredAssets) {
            if ($assetNames -notcontains $requiredAsset) {
                throw "promotion_source_asset_missing: tag=$sourceTag asset=$requiredAsset"
            }
        }

        $headSha = (Invoke-GhText -Arguments @('api', "repos/$Repository/branches/$Branch", '--jq', '.commit.sha')).Trim().ToLowerInvariant()
        $sourceCommit = ([string]$sourceRelease.targetCommitish).Trim().ToLowerInvariant()
        if ($headSha -notmatch '^[0-9a-f]{40}$') {
            throw "branch_head_unresolved: repository=$Repository branch=$Branch"
        }
        if ($sourceCommit -notmatch '^[0-9a-f]{40}$') {
            throw "promotion_source_commit_invalid: tag=$sourceTag targetCommitish=$sourceCommit"
        }
        if ($headSha -ne $sourceCommit) {
            throw "promotion_source_not_at_head: tag=$sourceTag source_sha=$sourceCommit head_sha=$headSha"
        }

        $ExecutionReport.source_release = [ordered]@{
            channel = [string]$modeConfig.source_channel_for_promotion
            tag = $sourceTag
            source_sha = $sourceCommit
            head_sha = $headSha
            url = [string]$sourceRelease.url
        }
    }

    $nextSequence = if (@($targetRangeRecords).Count -eq 0) {
        [int]$modeConfig.range_min
    } else {
        ([int]$targetRangeRecords[0].sequence) + 1
    }

    if ($nextSequence -gt [int]$modeConfig.range_max) {
        throw "release_tag_range_exhausted: mode=$ModeName date=$DateKey next_sequence=$nextSequence range_max=$([int]$modeConfig.range_max)"
    }

    $targetTag = "v0.$DateKey.$nextSequence"
    $ExecutionReport.target_release = [ordered]@{
        mode = $ModeName
        channel = [string]$modeConfig.channel
        prerelease = [bool]$modeConfig.prerelease
        tag = $targetTag
        range_min = [int]$modeConfig.range_min
        range_max = [int]$modeConfig.range_max
    }

    if ($DryRun) {
        $ExecutionReport.dispatch = [ordered]@{
            status = 'skipped_dry_run'
            workflow = $ReleaseWorkflowFile
            branch = $Branch
            run_id = ''
            url = ''
        }
        return
    }

    $dispatchReportPath = Join-Path $ScratchRoot "$ModeName-dispatch.json"
    $dispatchInputs = @(
        "release_tag=$targetTag",
        'allow_existing_tag=false',
        "prerelease=$([string]([bool]$modeConfig.prerelease).ToLowerInvariant())",
        "release_channel=$([string]$modeConfig.channel)"
    )
    & $dispatchWorkflowScript `
        -Repository $Repository `
        -WorkflowFile $ReleaseWorkflowFile `
        -Branch $Branch `
        -Inputs $dispatchInputs `
        -OutputPath $dispatchReportPath
    $dispatchReport = Get-Content -LiteralPath $dispatchReportPath -Raw | ConvertFrom-Json -ErrorAction Stop

    $watchReportPath = Join-Path $ScratchRoot "$ModeName-watch.json"
    & pwsh -NoProfile -File $watchWorkflowScript `
        -Repository $Repository `
        -RunId ([string]$dispatchReport.run_id) `
        -TimeoutMinutes $WatchTimeoutMinutes `
        -OutputPath $watchReportPath
    if ($LASTEXITCODE -ne 0) {
        throw "release_watch_failed: mode=$ModeName run_id=$([string]$dispatchReport.run_id) exit_code=$LASTEXITCODE"
    }
    $watchReport = Get-Content -LiteralPath $watchReportPath -Raw | ConvertFrom-Json -ErrorAction Stop

    $ExecutionReport.dispatch = [ordered]@{
        status = 'success'
        workflow = $ReleaseWorkflowFile
        branch = $Branch
        run_id = [string]$dispatchReport.run_id
        url = [string]$watchReport.url
        conclusion = [string]$watchReport.conclusion
    }

    if ($ModeName -eq 'CanaryCycle') {
        $hygienePath = Join-Path $ScratchRoot 'canary-hygiene.json'
        & pwsh -NoProfile -File $canaryHygieneScript `
            -Repository $Repository `
            -DateUtc $DateKey `
            -KeepLatestN $KeepLatestCanaryN `
            -Delete `
            -OutputPath $hygienePath
        if ($LASTEXITCODE -ne 0) {
            throw "canary_hygiene_failed: date=$DateKey exit_code=$LASTEXITCODE"
        }
        $ExecutionReport.hygiene = Get-Content -LiteralPath $hygienePath -Raw | ConvertFrom-Json -ErrorAction Stop
    }
}

$scratchRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("release-control-plane-" + [Guid]::NewGuid().ToString('N'))
New-Item -Path $scratchRoot -ItemType Directory -Force | Out-Null

$report = [ordered]@{
    schema_version = '1.0'
    timestamp_utc = Get-UtcNowIso
    repository = $Repository
    branch = $Branch
    mode = $Mode
    dry_run = [bool]$DryRun
    auto_remediate = [bool]$AutoRemediate
    sync_guard_max_age_hours = $SyncGuardMaxAgeHours
    keep_latest_canary_n = $KeepLatestCanaryN
    status = 'fail'
    reason_code = ''
    message = ''
    pre_health = $null
    remediation = $null
    post_health = $null
    executions = @()
}

try {
    $preHealthPath = Join-Path $scratchRoot 'pre-health.json'
    $healthy = $false
    try {
        & pwsh -NoProfile -File $opsSnapshotScript `
            -SurfaceRepository $Repository `
            -RequiredRunnerLabelsCsv $releaseRunnerLabelsCsv `
            -SyncGuardMaxAgeHours $SyncGuardMaxAgeHours `
            -OutputPath $preHealthPath
        if ($LASTEXITCODE -eq 0) {
            $healthy = $true
        }
    } catch {
        $healthy = $false
    }

    if (Test-Path -LiteralPath $preHealthPath -PathType Leaf) {
        $report.pre_health = Get-Content -LiteralPath $preHealthPath -Raw | ConvertFrom-Json -ErrorAction Stop
    }

    if (-not $healthy -and $AutoRemediate) {
        $remediationPath = Join-Path $scratchRoot 'remediation.json'
        & pwsh -NoProfile -File $opsRemediateScript `
            -SurfaceRepository $Repository `
            -RequiredRunnerLabelsCsv $releaseRunnerLabelsCsv `
            -SyncGuardMaxAgeHours $SyncGuardMaxAgeHours `
            -OutputPath $remediationPath
        if (Test-Path -LiteralPath $remediationPath -PathType Leaf) {
            $report.remediation = Get-Content -LiteralPath $remediationPath -Raw | ConvertFrom-Json -ErrorAction Stop
        }
    }

    $postHealthPath = Join-Path $scratchRoot 'post-health.json'
    & pwsh -NoProfile -File $opsSnapshotScript `
        -SurfaceRepository $Repository `
        -RequiredRunnerLabelsCsv $releaseRunnerLabelsCsv `
        -SyncGuardMaxAgeHours $SyncGuardMaxAgeHours `
        -OutputPath $postHealthPath
    if ($LASTEXITCODE -ne 0) {
        throw 'ops_health_gate_failed'
    }
    $report.post_health = Get-Content -LiteralPath $postHealthPath -Raw | ConvertFrom-Json -ErrorAction Stop

    if ([string]$report.post_health.status -ne 'pass') {
        throw "ops_unhealthy: reason_codes=$([string]::Join(',', @($report.post_health.reason_codes)))"
    }

    if ($Mode -eq 'Validate') {
        $report.status = 'pass'
        $report.reason_code = if ($DryRun) { 'validate_dry_run' } else { 'validated' }
        $report.message = 'Release control plane validation completed without dispatch.'
    } else {
        $dateKey = (Get-Date).ToUniversalTime().ToString('yyyyMMdd')
        $executionList = [System.Collections.Generic.List[object]]::new()

        if ($Mode -eq 'FullCycle') {
            $canaryExec = [ordered]@{}
            Invoke-ReleaseMode -ModeName 'CanaryCycle' -DateKey $dateKey -ScratchRoot $scratchRoot -ExecutionReport $canaryExec
            [void]$executionList.Add($canaryExec)

            $prereleaseExec = [ordered]@{}
            Invoke-ReleaseMode -ModeName 'PromotePrerelease' -DateKey $dateKey -ScratchRoot $scratchRoot -ExecutionReport $prereleaseExec
            [void]$executionList.Add($prereleaseExec)

            $stableExec = [ordered]@{
                target_release = [ordered]@{
                    mode = 'PromoteStable'
                    status = 'skipped'
                    reason_code = 'stable_window_closed'
                }
            }
            $dayOfWeekUtc = (Get-Date).ToUniversalTime().DayOfWeek.ToString()
            if ($dayOfWeekUtc -eq 'Monday') {
                $stableExec = [ordered]@{}
                Invoke-ReleaseMode -ModeName 'PromoteStable' -DateKey $dateKey -ScratchRoot $scratchRoot -ExecutionReport $stableExec
            }
            [void]$executionList.Add($stableExec)
        } else {
            $singleExec = [ordered]@{}
            Invoke-ReleaseMode -ModeName $Mode -DateKey $dateKey -ScratchRoot $scratchRoot -ExecutionReport $singleExec
            [void]$executionList.Add($singleExec)
        }

        $report.executions = @($executionList)
        $report.status = 'pass'
        $report.reason_code = if ($DryRun) { 'dry_run' } else { 'completed' }
        $report.message = 'Release control plane completed.'
    }
}
catch {
    $report.status = 'fail'
    $report.reason_code = 'control_plane_failed'
    $report.message = [string]$_.Exception.Message
}
finally {
    Write-WorkflowOpsReport -Report $report -OutputPath $OutputPath | Out-Null
    if (Test-Path -LiteralPath $scratchRoot -PathType Container) {
        Remove-Item -LiteralPath $scratchRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

if ([string]$report.status -eq 'pass') {
    exit 0
}

exit 1
