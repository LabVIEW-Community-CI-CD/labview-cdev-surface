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
    [ValidatePattern('^[A-Za-z0-9._/-]+$')]
    [string]$ReleaseWorkflowFile = 'release-workspace-installer.yml',

    [Parameter()]
    [ValidatePattern('^[A-Za-z0-9._/-]+$')]
    [string]$ControlPlaneWorkflowFile = 'release-control-plane.yml',

    [Parameter()]
    [ValidateRange(20, 200)]
    [int]$ReleaseLimit = 100,

    [Parameter()]
    [ValidateRange(5, 240)]
    [int]$WatchTimeoutMinutes = 120,

    [Parameter()]
    [ValidateRange(1, 10)]
    [int]$KeepLatestCanaryN = 1,

    [Parameter()]
    [bool]$AutoRemediate = $true,

    [Parameter()]
    [string]$OutputPath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'lib/WorkflowOps.Common.ps1')

$dispatchWorkflowScript = Join-Path $PSScriptRoot 'Dispatch-WorkflowAtRemoteHead.ps1'
$watchWorkflowScript = Join-Path $PSScriptRoot 'Watch-WorkflowRun.ps1'

foreach ($requiredScript in @($dispatchWorkflowScript, $watchWorkflowScript)) {
    if (-not (Test-Path -LiteralPath $requiredScript -PathType Leaf)) {
        throw "required_script_missing: $requiredScript"
    }
}

function Add-UniqueMessage {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][System.Collections.Generic.List[string]]$Target,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if (-not $Target.Contains($Message)) {
        [void]$Target.Add($Message)
    }
}

function Get-OptionalPropertyValue {
    param(
        [Parameter()][AllowNull()]$Object,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter()][AllowNull()]$DefaultValue = $null
    )

    if ($null -eq $Object) {
        return $DefaultValue
    }

    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $DefaultValue
    }

    return $property.Value
}

function Resolve-RaceDrillFailureReasonCode {
    param([Parameter()][string]$MessageText = '')

    $message = [string]$MessageText
    if ($message -match '^required_script_missing') { return 'required_script_missing' }
    if ($message -match '^contender_dispatch_report_invalid') { return 'contender_dispatch_report_invalid' }
    if ($message -match '^control_plane_dispatch_report_invalid') { return 'control_plane_dispatch_report_invalid' }
    if ($message -match '^contender_release_dispatch_failed') { return 'contender_release_dispatch_failed' }
    if ($message -match '^control_plane_dispatch_failed') { return 'control_plane_dispatch_failed' }
    if ($message -match '^control_plane_watch_timeout') { return 'control_plane_watch_timeout' }
    if ($message -match '^control_plane_run_failed') { return 'control_plane_run_failed' }
    if ($message -match '^control_plane_report_download_failed') { return 'control_plane_report_download_failed' }
    if ($message -match '^control_plane_report_missing') { return 'control_plane_report_missing' }
    if ($message -match '^control_plane_report_failed') { return 'control_plane_report_failed' }
    if ($message -match '^control_plane_canary_execution_missing') { return 'control_plane_canary_execution_missing' }
    if ($message -match '^control_plane_release_verification_missing') { return 'control_plane_release_verification_missing' }
    if ($message -match '^control_plane_release_verification_failed') { return 'control_plane_release_verification_failed' }
    if ($message -match '^control_plane_collision_not_observed') { return 'control_plane_collision_not_observed' }
    if ($message -match '^gh_command_failed') { return 'gh_command_failed' }

    return 'race_hardening_drill_runtime_error'
}

function Get-SequenceFromLabel {
    param(
        [Parameter(Mandatory = $true)][string]$Label,
        [Parameter(Mandatory = $true)][string]$Token
    )

    $pattern = "(?i)(?:^|[.-]){0}[.-](?<n>\d+)(?:$|[.-])" -f [regex]::Escape($Token)
    $match = [regex]::Match($Label, $pattern)
    if (-not $match.Success) {
        return 0
    }

    $value = 0
    if (-not [int]::TryParse([string]$match.Groups['n'].Value, [ref]$value)) {
        return 0
    }

    return $value
}

function Parse-ReleaseTagRecord {
    param(
        [Parameter(Mandatory = $true)][string]$TagName,
        [Parameter(Mandatory = $true)][bool]$IsPrerelease
    )

    $semverMatch = [regex]::Match(
        $TagName,
        '^v(?<major>0|[1-9]\d*)\.(?<minor>0|[1-9]\d*)\.(?<patch>0|[1-9]\d*)(?:-(?<prerelease>[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?(?:\+(?<build>[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?$'
    )
    if (-not $semverMatch.Success) {
        return $null
    }

    $prereleaseLabel = [string]$semverMatch.Groups['prerelease'].Value
    $channel = 'stable'
    $sequence = 0
    if (-not [string]::IsNullOrWhiteSpace($prereleaseLabel)) {
        if ($prereleaseLabel -match '(?i)(^|[.\-])canary([.\-]|$)') {
            $channel = 'canary'
            $sequence = Get-SequenceFromLabel -Label $prereleaseLabel -Token 'canary'
        } else {
            $channel = 'prerelease'
            $sequence = Get-SequenceFromLabel -Label $prereleaseLabel -Token 'rc'
        }
    }

    return [pscustomobject]@{
        tag_name = $TagName
        tag_family = 'semver'
        channel = $channel
        major = [int]$semverMatch.Groups['major'].Value
        minor = [int]$semverMatch.Groups['minor'].Value
        patch = [int]$semverMatch.Groups['patch'].Value
        prerelease_sequence = $sequence
        is_prerelease = $IsPrerelease
    }
}

function New-CoreVersion {
    param(
        [Parameter(Mandatory = $true)][int]$Major,
        [Parameter(Mandatory = $true)][int]$Minor,
        [Parameter(Mandatory = $true)][int]$Patch
    )

    return [pscustomobject]@{
        major = $Major
        minor = $Minor
        patch = $Patch
    }
}

function Format-CoreVersion {
    param([Parameter(Mandatory = $true)]$Core)
    return "{0}.{1}.{2}" -f [int]$Core.major, [int]$Core.minor, [int]$Core.patch
}

function Compare-CoreVersion {
    param(
        [Parameter(Mandatory = $true)]$Left,
        [Parameter(Mandatory = $true)]$Right
    )

    foreach ($part in @('major', 'minor', 'patch')) {
        $leftValue = [int]$Left.$part
        $rightValue = [int]$Right.$part
        if ($leftValue -gt $rightValue) { return 1 }
        if ($leftValue -lt $rightValue) { return -1 }
    }

    return 0
}

function Get-MaxCoreVersion {
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Records = @())

    $maxCore = $null
    foreach ($record in @($Records)) {
        $candidate = New-CoreVersion -Major ([int]$record.major) -Minor ([int]$record.minor) -Patch ([int]$record.patch)
        if ($null -eq $maxCore) {
            $maxCore = $candidate
            continue
        }

        if ((Compare-CoreVersion -Left $candidate -Right $maxCore) -gt 0) {
            $maxCore = $candidate
        }
    }

    return $maxCore
}

function Get-NextSemVerCanaryTag {
    param(
        [Parameter(Mandatory = $true)][string]$TargetRepository,
        [Parameter(Mandatory = $true)][int]$MaxReleases
    )

    $releases = @(Get-GhReleasesPortable -Repository $TargetRepository -Limit $MaxReleases -ExcludeDrafts)
    $semverRecords = @(
        $releases |
            ForEach-Object { Parse-ReleaseTagRecord -TagName ([string]$_.tagName) -IsPrerelease ([bool]$_.isPrerelease) } |
            Where-Object { $null -ne $_ -and [string]$_.tag_family -eq 'semver' }
    )

    $stableSemver = @($semverRecords | Where-Object { [string]$_.channel -eq 'stable' })
    $nonStableSemver = @($semverRecords | Where-Object { [string]$_.channel -eq 'canary' -or [string]$_.channel -eq 'prerelease' })

    $latestStableCore = Get-MaxCoreVersion -Records $stableSemver
    $latestNonStableCore = Get-MaxCoreVersion -Records $nonStableSemver

    $targetCore = $null
    if ($null -ne $latestNonStableCore -and (($null -eq $latestStableCore) -or ((Compare-CoreVersion -Left $latestNonStableCore -Right $latestStableCore) -gt 0))) {
        $targetCore = $latestNonStableCore
    } elseif ($null -ne $latestStableCore) {
        $targetCore = New-CoreVersion -Major ([int]$latestStableCore.major) -Minor ([int]$latestStableCore.minor) -Patch ([int]$latestStableCore.patch + 1)
    } elseif ($null -ne $latestNonStableCore) {
        $targetCore = $latestNonStableCore
    } else {
        $targetCore = New-CoreVersion -Major 0 -Minor 1 -Patch 0
    }

    $matchedCanary = @(
        $semverRecords |
            Where-Object {
                ([string]$_.channel -eq 'canary') -and
                ([int]$_.major -eq [int]$targetCore.major) -and
                ([int]$_.minor -eq [int]$targetCore.minor) -and
                ([int]$_.patch -eq [int]$targetCore.patch)
            } |
            ForEach-Object { [int]$_.prerelease_sequence }
    )

    $nextCanarySequence = if (@($matchedCanary).Count -eq 0) {
        1
    } else {
        ((@($matchedCanary) | Measure-Object -Maximum).Maximum + 1)
    }
    if ($nextCanarySequence -gt 9999) {
        throw "semver_prerelease_sequence_exhausted: channel=canary core=$(Format-CoreVersion -Core $targetCore) next_sequence=$nextCanarySequence"
    }

    return [ordered]@{
        tag_family = 'semver'
        core = Format-CoreVersion -Core $targetCore
        prerelease_sequence = $nextCanarySequence
        tag = "v$(Format-CoreVersion -Core $targetCore)-canary.$nextCanarySequence"
    }
}

function Invoke-WorkflowWatchCapture {
    param(
        [Parameter(Mandatory = $true)][string]$TargetRepository,
        [Parameter(Mandatory = $true)][string]$RunId,
        [Parameter(Mandatory = $true)][int]$TimeoutMinutes,
        [Parameter(Mandatory = $true)][string]$ReportPath
    )

    $runtimeError = ''
    $exitCode = 1
    try {
        & pwsh -NoProfile -File $watchWorkflowScript `
            -Repository $TargetRepository `
            -RunId $RunId `
            -TimeoutMinutes $TimeoutMinutes `
            -OutputPath $ReportPath | Out-Null
        $exitCode = if ($null -eq $LASTEXITCODE) { 0 } else { [int]$LASTEXITCODE }
    } catch {
        $runtimeError = [string]$_.Exception.Message
        $exitCode = 1
    }

    $watchReport = $null
    if (Test-Path -LiteralPath $ReportPath -PathType Leaf) {
        $watchReport = Get-Content -LiteralPath $ReportPath -Raw | ConvertFrom-Json -ErrorAction Stop
    }

    if ($null -eq $watchReport) {
        $watchReport = [pscustomobject]@{
            run_id = $RunId
            status = 'unknown'
            conclusion = ''
            url = ''
            classified_reason = 'watch_report_missing'
        }
    } elseif (-not [string]::IsNullOrWhiteSpace($runtimeError)) {
        if ([string]::IsNullOrWhiteSpace([string]$watchReport.classified_reason)) {
            $watchReport | Add-Member -NotePropertyName classified_reason -NotePropertyValue 'watch_runtime_error' -Force
        }
    }

    $successful = ($exitCode -eq 0 -and [string]$watchReport.conclusion -eq 'success')
    return [ordered]@{
        successful = [bool]$successful
        exit_code = $exitCode
        runtime_error = $runtimeError
        report = $watchReport
    }
}

$scratchRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("release-race-hardening-" + [Guid]::NewGuid().ToString('N'))
New-Item -Path $scratchRoot -ItemType Directory -Force | Out-Null

$report = [ordered]@{
    schema_version = '1.0'
    generated_at_utc = Get-UtcNowIso
    repository = $Repository
    branch = $Branch
    release_workflow = $ReleaseWorkflowFile
    control_plane_workflow = $ControlPlaneWorkflowFile
    release_limit = $ReleaseLimit
    watch_timeout_minutes = $WatchTimeoutMinutes
    auto_remediate = [bool]$AutoRemediate
    keep_latest_canary_n = $KeepLatestCanaryN
    predicted_canary_tag = ''
    predicted_canary_core = ''
    predicted_canary_sequence = 0
    status = 'fail'
    reason_code = ''
    message = ''
    warnings = @()
    dispatches = [ordered]@{
        contender_release = $null
        control_plane = $null
    }
    watches = [ordered]@{
        contender_release = $null
        control_plane = $null
    }
    artifacts = [ordered]@{
        control_plane_report_artifact = ''
        control_plane_report_path = ''
    }
    control_plane_report_summary = [ordered]@{
        status = ''
        reason_code = ''
        mode = ''
        message = ''
    }
    evidence = [ordered]@{
        dispatch_gap_seconds = 0
        collision_observed = $false
        collision_signals = @()
        collision_retries = 0
        predicted_target_tag = ''
        final_target_tag = ''
        contender_run_id = ''
        control_plane_run_id = ''
        dispatch_status = ''
        dispatch_reason_code = ''
        attempt_history_statuses = @()
        release_verification_status = ''
        release_verification_url = ''
    }
}

$warnings = [System.Collections.Generic.List[string]]::new()
$collisionSignals = [System.Collections.Generic.List[string]]::new()

try {
    $targetTagRecord = Get-NextSemVerCanaryTag -TargetRepository $Repository -MaxReleases $ReleaseLimit
    $report.predicted_canary_tag = [string]$targetTagRecord.tag
    $report.predicted_canary_core = [string]$targetTagRecord.core
    $report.predicted_canary_sequence = [int]$targetTagRecord.prerelease_sequence
    $report.evidence.predicted_target_tag = [string]$targetTagRecord.tag

    $contenderDispatchPath = Join-Path $scratchRoot 'contender-release-dispatch.json'
    $contenderDispatchInputs = @(
        "release_tag=$([string]$targetTagRecord.tag)",
        'allow_existing_tag=false',
        'prerelease=true',
        'release_channel=canary'
    )
    & $dispatchWorkflowScript `
        -Repository $Repository `
        -WorkflowFile $ReleaseWorkflowFile `
        -Branch $Branch `
        -Inputs $contenderDispatchInputs `
        -OutputPath $contenderDispatchPath | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "contender_release_dispatch_failed: workflow=$ReleaseWorkflowFile exit_code=$LASTEXITCODE"
    }
    $contenderDispatch = Get-Content -LiteralPath $contenderDispatchPath -Raw | ConvertFrom-Json -ErrorAction Stop
    $contenderRunId = [string]$contenderDispatch.run_id
    if ([string]::IsNullOrWhiteSpace($contenderRunId)) {
        throw "contender_dispatch_report_invalid: workflow=$ReleaseWorkflowFile field=run_id"
    }
    $report.dispatches.contender_release = [ordered]@{
        run_id = $contenderRunId
        head_sha = [string]$contenderDispatch.head_sha
        status = [string]$contenderDispatch.status
        url = [string]$contenderDispatch.url
        inputs = @($contenderDispatch.inputs | ForEach-Object { [string]$_ })
        timestamp_utc = [string]$contenderDispatch.timestamp_utc
    }

    $controlPlaneDispatchPath = Join-Path $scratchRoot 'control-plane-dispatch.json'
    $controlPlaneDispatchInputs = @(
        'mode=CanaryCycle',
        "auto_remediate=$(([string]$AutoRemediate).ToLowerInvariant())",
        "keep_latest_canary_n=$KeepLatestCanaryN",
        'dry_run=false'
    )
    & $dispatchWorkflowScript `
        -Repository $Repository `
        -WorkflowFile $ControlPlaneWorkflowFile `
        -Branch $Branch `
        -Inputs $controlPlaneDispatchInputs `
        -OutputPath $controlPlaneDispatchPath | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "control_plane_dispatch_failed: workflow=$ControlPlaneWorkflowFile exit_code=$LASTEXITCODE"
    }
    $controlPlaneDispatch = Get-Content -LiteralPath $controlPlaneDispatchPath -Raw | ConvertFrom-Json -ErrorAction Stop
    $controlPlaneRunId = [string]$controlPlaneDispatch.run_id
    if ([string]::IsNullOrWhiteSpace($controlPlaneRunId)) {
        throw "control_plane_dispatch_report_invalid: workflow=$ControlPlaneWorkflowFile field=run_id"
    }
    $report.dispatches.control_plane = [ordered]@{
        run_id = $controlPlaneRunId
        head_sha = [string]$controlPlaneDispatch.head_sha
        status = [string]$controlPlaneDispatch.status
        url = [string]$controlPlaneDispatch.url
        inputs = @($controlPlaneDispatch.inputs | ForEach-Object { [string]$_ })
        timestamp_utc = [string]$controlPlaneDispatch.timestamp_utc
    }

    $contenderDispatchedAt = [DateTimeOffset]::MinValue
    $controlPlaneDispatchedAt = [DateTimeOffset]::MinValue
    $hasContenderTimestamp = [DateTimeOffset]::TryParse([string]$contenderDispatch.timestamp_utc, [ref]$contenderDispatchedAt)
    $hasControlPlaneTimestamp = [DateTimeOffset]::TryParse([string]$controlPlaneDispatch.timestamp_utc, [ref]$controlPlaneDispatchedAt)
    if ($hasContenderTimestamp -and $hasControlPlaneTimestamp) {
        $gapSeconds = [Math]::Abs(($controlPlaneDispatchedAt - $contenderDispatchedAt).TotalSeconds)
        $report.evidence.dispatch_gap_seconds = [Math]::Round($gapSeconds, 3)
    }

    $contenderWatchPath = Join-Path $scratchRoot 'contender-release-watch.json'
    $contenderWatch = Invoke-WorkflowWatchCapture `
        -TargetRepository $Repository `
        -RunId $contenderRunId `
        -TimeoutMinutes $WatchTimeoutMinutes `
        -ReportPath $contenderWatchPath
    $report.watches.contender_release = [ordered]@{
        run_id = [string]$contenderWatch.report.run_id
        status = [string]$contenderWatch.report.status
        conclusion = [string]$contenderWatch.report.conclusion
        classified_reason = [string]$contenderWatch.report.classified_reason
        url = [string]$contenderWatch.report.url
        successful = [bool]$contenderWatch.successful
        exit_code = [int]$contenderWatch.exit_code
        runtime_error = [string]$contenderWatch.runtime_error
    }
    if (-not [bool]$contenderWatch.successful) {
        Add-UniqueMessage -Target $warnings -Message "contender_watch_non_success: run_id=$([string]$contenderWatch.report.run_id) conclusion=$([string]$contenderWatch.report.conclusion) classified_reason=$([string]$contenderWatch.report.classified_reason)"
    }

    $controlPlaneWatchPath = Join-Path $scratchRoot 'control-plane-watch.json'
    $controlPlaneWatch = Invoke-WorkflowWatchCapture `
        -TargetRepository $Repository `
        -RunId $controlPlaneRunId `
        -TimeoutMinutes $WatchTimeoutMinutes `
        -ReportPath $controlPlaneWatchPath
    $report.watches.control_plane = [ordered]@{
        run_id = [string]$controlPlaneWatch.report.run_id
        status = [string]$controlPlaneWatch.report.status
        conclusion = [string]$controlPlaneWatch.report.conclusion
        classified_reason = [string]$controlPlaneWatch.report.classified_reason
        url = [string]$controlPlaneWatch.report.url
        successful = [bool]$controlPlaneWatch.successful
        exit_code = [int]$controlPlaneWatch.exit_code
        runtime_error = [string]$controlPlaneWatch.runtime_error
    }
    if (-not [bool]$controlPlaneWatch.successful) {
        $controlPlaneClassifiedReason = [string]$controlPlaneWatch.report.classified_reason
        if ([string]::Equals($controlPlaneClassifiedReason, 'timeout', [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "control_plane_watch_timeout: run_id=$controlPlaneRunId timeout_minutes=$WatchTimeoutMinutes"
        }
        $controlPlaneConclusion = [string]$controlPlaneWatch.report.conclusion
        throw "control_plane_run_failed: run_id=$controlPlaneRunId conclusion=$controlPlaneConclusion classified_reason=$controlPlaneClassifiedReason"
    }

    $controlPlaneArtifactName = "release-control-plane-report-$controlPlaneRunId"
    $report.artifacts.control_plane_report_artifact = $controlPlaneArtifactName
    $artifactRoot = Join-Path $scratchRoot 'control-plane-report-artifact'
    New-Item -Path $artifactRoot -ItemType Directory -Force | Out-Null

    & gh run download $controlPlaneRunId -R $Repository -n $controlPlaneArtifactName -D $artifactRoot
    $downloadExit = if ($null -eq $LASTEXITCODE) { 0 } else { [int]$LASTEXITCODE }
    if ($downloadExit -ne 0) {
        throw "control_plane_report_download_failed: run_id=$controlPlaneRunId artifact=$controlPlaneArtifactName exit_code=$downloadExit"
    }

    $controlPlaneReportPath = @(
        Get-ChildItem -Path $artifactRoot -Recurse -File -Filter 'release-control-plane-report.json' |
            Select-Object -First 1 -ExpandProperty FullName
    )
    if (@($controlPlaneReportPath).Count -ne 1 -or [string]::IsNullOrWhiteSpace([string]$controlPlaneReportPath[0])) {
        throw "control_plane_report_missing: run_id=$controlPlaneRunId artifact=$controlPlaneArtifactName"
    }
    $report.artifacts.control_plane_report_path = [string]$controlPlaneReportPath[0]

    $controlPlaneReport = Get-Content -LiteralPath ([string]$controlPlaneReportPath[0]) -Raw | ConvertFrom-Json -Depth 100
    $report.control_plane_report_summary = [ordered]@{
        status = [string]$controlPlaneReport.status
        reason_code = [string]$controlPlaneReport.reason_code
        mode = [string]$controlPlaneReport.mode
        message = [string]$controlPlaneReport.message
    }
    if ([string]$controlPlaneReport.status -ne 'pass') {
        throw "control_plane_report_failed: reason_code=$([string]$controlPlaneReport.reason_code) message=$([string]$controlPlaneReport.message)"
    }

    $canaryExecution = @(
        @($controlPlaneReport.executions) |
            Where-Object {
                [string]$_.target_release.mode -eq 'CanaryCycle' -or
                [string]$_.target_release.channel -eq 'canary'
            } |
            Select-Object -First 1
    )
    if (@($canaryExecution).Count -ne 1) {
        throw 'control_plane_canary_execution_missing: canary execution record not found in control-plane report.'
    }

    $targetRelease = $canaryExecution[0].target_release
    $dispatchRecord = $canaryExecution[0].dispatch
    $releaseVerification = $canaryExecution[0].release_verification

    if ($null -eq $releaseVerification) {
        throw 'control_plane_release_verification_missing: canary execution missing release_verification payload.'
    }
    if ([string]$releaseVerification.status -ne 'pass') {
        throw "control_plane_release_verification_failed: status=$([string]$releaseVerification.status)"
    }

    $attemptHistory = @(Get-OptionalPropertyValue -Object $targetRelease -Name 'dispatch_attempt_history' -DefaultValue @())
    $attemptHistoryStatuses = @(
        $attemptHistory |
            ForEach-Object {
                [string](Get-OptionalPropertyValue -Object $_ -Name 'status' -DefaultValue '')
            } |
            Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }
    )
    $collisionRetries = 0
    [void][int]::TryParse([string](Get-OptionalPropertyValue -Object $targetRelease -Name 'collision_retries' -DefaultValue 0), [ref]$collisionRetries)
    if ($collisionRetries -ge 1) {
        Add-UniqueMessage -Target $collisionSignals -Message 'collision_retries_ge_1'
    }

    $dispatchStatus = [string](Get-OptionalPropertyValue -Object $dispatchRecord -Name 'status' -DefaultValue '')
    if ($dispatchStatus -like 'collision_*') {
        Add-UniqueMessage -Target $collisionSignals -Message ("dispatch_status_{0}" -f $dispatchStatus)
    }

    $dispatchReasonCode = [string](Get-OptionalPropertyValue -Object $dispatchRecord -Name 'reason_code' -DefaultValue '')
    if ($dispatchReasonCode -eq 'tag_already_published_by_peer') {
        Add-UniqueMessage -Target $collisionSignals -Message ("dispatch_reason_{0}" -f $dispatchReasonCode)
    }

    foreach ($attemptStatus in @($attemptHistoryStatuses)) {
        if ([string]$attemptStatus -like 'collision_*') {
            Add-UniqueMessage -Target $collisionSignals -Message ("attempt_status_{0}" -f [string]$attemptStatus)
        }
    }

    $targetTag = [string](Get-OptionalPropertyValue -Object $targetRelease -Name 'tag' -DefaultValue '')
    if (-not [string]::Equals($targetTag, [string]$targetTagRecord.tag, [System.StringComparison]::Ordinal)) {
        Add-UniqueMessage -Target $warnings -Message ("target_tag_replanned: predicted={0} final={1}" -f [string]$targetTagRecord.tag, $targetTag)
    }

    $manifestProvenanceAssets = @($releaseVerification.manifest_provenance_assets_checked | ForEach-Object { [string]$_ })
    if ($manifestProvenanceAssets -notcontains 'reproducibility-report.json') {
        throw 'control_plane_release_verification_failed: release verification did not report reproducibility-report.json provenance check.'
    }

    $report.evidence = [ordered]@{
        dispatch_gap_seconds = [double]$report.evidence.dispatch_gap_seconds
        collision_observed = (@($collisionSignals).Count -gt 0)
        collision_signals = @($collisionSignals)
        collision_retries = $collisionRetries
        predicted_target_tag = [string]$targetTagRecord.tag
        final_target_tag = $targetTag
        contender_run_id = $contenderRunId
        control_plane_run_id = $controlPlaneRunId
        dispatch_status = $dispatchStatus
        dispatch_reason_code = $dispatchReasonCode
        attempt_history_statuses = @($attemptHistoryStatuses)
        release_verification_status = [string]$releaseVerification.status
        release_verification_url = [string]$releaseVerification.release_url
    }

    if (-not [bool]$report.evidence.collision_observed) {
        throw ("control_plane_collision_not_observed: predicted_tag={0} final_tag={1} dispatch_status={2} collision_retries={3}" -f [string]$targetTagRecord.tag, $targetTag, $dispatchStatus, $collisionRetries)
    }

    $report.status = 'pass'
    $report.reason_code = 'drill_passed'
    $report.message = 'Race-hardening drill passed with collision evidence and verified canary release metadata.'
}
catch {
    $report.status = 'fail'
    $report.message = [string]$_.Exception.Message
    $report.reason_code = Resolve-RaceDrillFailureReasonCode -MessageText $report.message
}
finally {
    $report.warnings = @($warnings)
    Write-WorkflowOpsReport -Report $report -OutputPath $OutputPath | Out-Null
    if (Test-Path -LiteralPath $scratchRoot -PathType Container) {
        Remove-Item -LiteralPath $scratchRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

if ([string]$report.status -eq 'pass') {
    exit 0
}

exit 1
