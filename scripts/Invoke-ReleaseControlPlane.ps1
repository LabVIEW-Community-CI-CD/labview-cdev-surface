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

function Resolve-SemVerEnforcementPolicy {
    param(
        [Parameter(Mandatory = $true)][string]$ManifestPath,
        [Parameter(Mandatory = $true)][DateTimeOffset]$FallbackEnforceUtc
    )

    $warnings = [System.Collections.Generic.List[string]]::new()
    $policy = [ordered]@{
        semver_only_enforce_utc = $FallbackEnforceUtc
        source = 'default'
        warnings = @()
    }

    if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) {
        [void]$warnings.Add("workspace_governance_missing: path=$ManifestPath")
        $policy.warnings = @($warnings)
        return $policy
    }

    try {
        $manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json -Depth 100
        $candidateValue = $manifest.installer_contract.release_client.ops_control_plane_policy.tag_strategy.semver_only_enforce_utc
        if ($null -eq $candidateValue) {
            [void]$warnings.Add("semver_only_enforce_utc_missing: path=$ManifestPath")
            $policy.warnings = @($warnings)
            return $policy
        }

        if ($candidateValue -is [DateTimeOffset]) {
            $policy.semver_only_enforce_utc = ([DateTimeOffset]$candidateValue).ToUniversalTime()
            $policy.source = 'workspace_governance'
            $policy.warnings = @($warnings)
            return $policy
        }

        if ($candidateValue -is [DateTime]) {
            $candidateDate = [DateTime]$candidateValue
            if ($candidateDate.Kind -eq [DateTimeKind]::Unspecified) {
                $candidateDate = [DateTime]::SpecifyKind($candidateDate, [DateTimeKind]::Utc)
            }
            $policy.semver_only_enforce_utc = ([DateTimeOffset]$candidateDate).ToUniversalTime()
            $policy.source = 'workspace_governance'
            $policy.warnings = @($warnings)
            return $policy
        }

        $candidate = [string]$candidateValue
        if ([string]::IsNullOrWhiteSpace($candidate)) {
            [void]$warnings.Add("semver_only_enforce_utc_missing: path=$ManifestPath")
            $policy.warnings = @($warnings)
            return $policy
        }

        $parsed = [DateTimeOffset]::MinValue
        $parseStyles = [Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal
        if (-not [DateTimeOffset]::TryParse($candidate, [Globalization.CultureInfo]::InvariantCulture, $parseStyles, [ref]$parsed)) {
            [void]$warnings.Add("semver_only_enforce_utc_invalid: value=$candidate")
            $policy.warnings = @($warnings)
            return $policy
        }

        $policy.semver_only_enforce_utc = $parsed
        $policy.source = 'workspace_governance'
    } catch {
        [void]$warnings.Add("semver_policy_load_failed: $([string]$_.Exception.Message)")
    }

    $policy.warnings = @($warnings)
    return $policy
}

$defaultSemverOnlyEnforceUtc = [DateTimeOffset]::Parse('2026-07-01T00:00:00Z')
$workspaceGovernancePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'workspace-governance.json'
$semverPolicy = Resolve-SemVerEnforcementPolicy -ManifestPath $workspaceGovernancePath -FallbackEnforceUtc $defaultSemverOnlyEnforceUtc
$script:semverOnlyEnforceUtc = [DateTimeOffset]$semverPolicy.semver_only_enforce_utc
$script:semverPolicySource = [string]$semverPolicy.source
$script:semverOnlyEnforced = ([DateTimeOffset]::UtcNow -ge $script:semverOnlyEnforceUtc)
foreach ($warning in @($semverPolicy.warnings)) {
    Write-Warning "[semver_policy_warning] $warning"
}

function Get-ModeConfig {
    param([Parameter(Mandatory = $true)][string]$ModeName)

    switch ($ModeName) {
        'CanaryCycle' {
            return [ordered]@{
                channel = 'canary'
                prerelease = $true
                source_channel_for_promotion = ''
                enforce_prerelease_source = $false
            }
        }
        'PromotePrerelease' {
            return [ordered]@{
                channel = 'prerelease'
                prerelease = $true
                source_channel_for_promotion = 'canary'
                enforce_prerelease_source = $true
            }
        }
        'PromoteStable' {
            return [ordered]@{
                channel = 'stable'
                prerelease = $false
                source_channel_for_promotion = 'prerelease'
                enforce_prerelease_source = $true
            }
        }
        default {
            throw "unsupported_mode_config: $ModeName"
        }
    }
}

function Get-ReleasePublishedSortValue {
    param([Parameter(Mandatory = $true)][object]$Record)

    $parsed = [DateTimeOffset]::MinValue
    [void][DateTimeOffset]::TryParse([string]$Record.published_at_utc, [ref]$parsed)
    return $parsed
}

function New-CoreVersion {
    param(
        [Parameter(Mandatory = $true)][int]$Major,
        [Parameter(Mandatory = $true)][int]$Minor,
        [Parameter(Mandatory = $true)][int]$Patch
    )

    return [ordered]@{
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
        $l = [int]$Left.$part
        $r = [int]$Right.$part
        if ($l -gt $r) { return 1 }
        if ($l -lt $r) { return -1 }
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

function Test-CoreEquals {
    param(
        [Parameter(Mandatory = $true)]$Left,
        [Parameter(Mandatory = $true)]$Right
    )

    return ((Compare-CoreVersion -Left $Left -Right $Right) -eq 0)
}

function Get-SequenceFromLabel {
    param(
        [Parameter(Mandatory = $true)][string]$Label,
        [Parameter(Mandatory = $true)][string]$Token
    )

    if ([string]::IsNullOrWhiteSpace($Label)) {
        return 0
    }

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

function Convert-ReleaseToRecord {
    param([Parameter(Mandatory = $true)][object]$Release)

    $tagName = [string]$Release.tagName
    if ([string]::IsNullOrWhiteSpace($tagName)) {
        return $null
    }

    $isPrerelease = [bool]$Release.isPrerelease
    $publishedAt = [string]$Release.publishedAt
    $url = [string]$Release.url

    $legacyMatch = [regex]::Match($tagName, '^v0\.(?<date>\d{8})\.(?<sequence>\d+)$')
    if ($legacyMatch.Success) {
        $legacySequence = 0
        if (-not [int]::TryParse([string]$legacyMatch.Groups['sequence'].Value, [ref]$legacySequence)) {
            return $null
        }

        $legacyChannel = 'unknown'
        if ($legacySequence -ge 1 -and $legacySequence -le 49 -and $isPrerelease) {
            $legacyChannel = 'canary'
        } elseif ($legacySequence -ge 50 -and $legacySequence -le 79 -and $isPrerelease) {
            $legacyChannel = 'prerelease'
        } elseif ($legacySequence -ge 80 -and $legacySequence -le 99 -and -not $isPrerelease) {
            $legacyChannel = 'stable'
        }

        return [ordered]@{
            tag_name = $tagName
            tag_family = 'legacy_date_window'
            channel = $legacyChannel
            is_prerelease = $isPrerelease
            published_at_utc = $publishedAt
            url = $url
            major = 0
            minor = 0
            patch = 0
            prerelease_label = ''
            prerelease_sequence = 0
            legacy_date = [string]$legacyMatch.Groups['date'].Value
            legacy_sequence = $legacySequence
        }
    }

    $semverMatch = [regex]::Match(
        $tagName,
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

    return [ordered]@{
        tag_name = $tagName
        tag_family = 'semver'
        channel = $channel
        is_prerelease = $isPrerelease
        published_at_utc = $publishedAt
        url = $url
        major = [int]$semverMatch.Groups['major'].Value
        minor = [int]$semverMatch.Groups['minor'].Value
        patch = [int]$semverMatch.Groups['patch'].Value
        prerelease_label = $prereleaseLabel
        prerelease_sequence = $sequence
        legacy_date = ''
        legacy_sequence = 0
    }
}

function Get-LatestSemVerRecordByChannel {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Records = @(),
        [Parameter(Mandatory = $true)][string]$Channel
    )

    return @(
        $Records |
            Where-Object { [string]$_.tag_family -eq 'semver' -and [string]$_.channel -eq $Channel } |
            Sort-Object `
                @{ Expression = { [int]$_.major }; Descending = $true }, `
                @{ Expression = { [int]$_.minor }; Descending = $true }, `
                @{ Expression = { [int]$_.patch }; Descending = $true }, `
                @{ Expression = { [int]$_.prerelease_sequence }; Descending = $true }, `
                @{ Expression = { Get-ReleasePublishedSortValue -Record $_ }; Descending = $true }, `
                @{ Expression = { [string]$_.tag_name }; Descending = $false } |
            Select-Object -First 1
    )
}

function Get-MaxPrereleaseSequenceForCore {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Records = @(),
        [Parameter(Mandatory = $true)]$Core,
        [Parameter(Mandatory = $true)][string]$Channel
    )

    $matched = @(
        $Records |
            Where-Object {
                ([string]$_.tag_family -eq 'semver') -and
                ([string]$_.channel -eq $Channel) -and
                ([int]$_.major -eq [int]$Core.major) -and
                ([int]$_.minor -eq [int]$Core.minor) -and
                ([int]$_.patch -eq [int]$Core.patch)
            } |
            ForEach-Object { [int]$_.prerelease_sequence }
    )
    if (@($matched).Count -eq 0) {
        return 0
    }

    return [int]((@($matched) | Measure-Object -Maximum).Maximum)
}

function Resolve-CanaryTargetSemVer {
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Records = @())

    $semverRecords = @($Records | Where-Object { [string]$_.tag_family -eq 'semver' })
    $stableRecords = @($semverRecords | Where-Object { [string]$_.channel -eq 'stable' })
    $nonStableRecords = @($semverRecords | Where-Object { [string]$_.channel -ne 'stable' })

    $latestStableCore = Get-MaxCoreVersion -Records $stableRecords
    $latestNonStableCore = Get-MaxCoreVersion -Records $nonStableRecords

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

    $maxCanarySequence = Get-MaxPrereleaseSequenceForCore -Records $semverRecords -Core $targetCore -Channel 'canary'
    $nextCanarySequence = $maxCanarySequence + 1
    if ($nextCanarySequence -gt 9999) {
        throw "semver_prerelease_sequence_exhausted: channel=canary core=$(Format-CoreVersion -Core $targetCore) next_sequence=$nextCanarySequence"
    }

    return [ordered]@{
        core = $targetCore
        prerelease_sequence = $nextCanarySequence
        tag = "v$(Format-CoreVersion -Core $targetCore)-canary.$nextCanarySequence"
        skipped = $false
        reason_code = ''
    }
}

function Resolve-PromotedTargetSemVer {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Records = @(),
        [Parameter(Mandatory = $true)][string]$TargetChannel,
        [Parameter(Mandatory = $true)]$SourceCore
    )

    if ([string]$TargetChannel -eq 'prerelease') {
        $maxRcSequence = Get-MaxPrereleaseSequenceForCore -Records $Records -Core $SourceCore -Channel 'prerelease'
        $nextRcSequence = $maxRcSequence + 1
        if ($nextRcSequence -gt 9999) {
            throw "semver_prerelease_sequence_exhausted: channel=prerelease core=$(Format-CoreVersion -Core $SourceCore) next_sequence=$nextRcSequence"
        }

        return [ordered]@{
            core = $SourceCore
            prerelease_sequence = $nextRcSequence
            tag = "v$(Format-CoreVersion -Core $SourceCore)-rc.$nextRcSequence"
            skipped = $false
            reason_code = ''
        }
    }

    if ([string]$TargetChannel -eq 'stable') {
        $stableExists = @(
            $Records |
                Where-Object {
                    ([string]$_.tag_family -eq 'semver') -and
                    ([string]$_.channel -eq 'stable') -and
                    ([int]$_.major -eq [int]$SourceCore.major) -and
                    ([int]$_.minor -eq [int]$SourceCore.minor) -and
                    ([int]$_.patch -eq [int]$SourceCore.patch)
                }
        ).Count -gt 0

        if ($stableExists) {
            return [ordered]@{
                core = $SourceCore
                prerelease_sequence = 0
                tag = "v$(Format-CoreVersion -Core $SourceCore)"
                skipped = $true
                reason_code = 'stable_already_published'
            }
        }

        return [ordered]@{
            core = $SourceCore
            prerelease_sequence = 0
            tag = "v$(Format-CoreVersion -Core $SourceCore)"
            skipped = $false
            reason_code = ''
        }
    }

    throw "unsupported_target_channel: $TargetChannel"
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
    $allRecords = @(
        $releaseList |
            ForEach-Object { Convert-ReleaseToRecord -Release $_ } |
            Where-Object { $null -ne $_ }
    )
    $legacyRecords = @($allRecords | Where-Object { [string]$_.tag_family -eq 'legacy_date_window' -and [string]$_.channel -ne 'unknown' })
    $semverRecords = @($allRecords | Where-Object { [string]$_.tag_family -eq 'semver' })

    $migrationWarnings = @()
    if (@($legacyRecords).Count -gt 0) {
        if ($script:semverOnlyEnforced) {
            throw "semver_only_enforcement_violation: semver_only_enforce_utc=$($script:semverOnlyEnforceUtc.ToString('yyyy-MM-ddTHH:mm:ssZ')) legacy_tag_count=$(@($legacyRecords).Count)"
        }
        $migrationWarnings += "Legacy date-window release tags remain present in '$Repository'. Control-plane dispatch now targets SemVer channel tags and legacy compatibility ends at $($script:semverOnlyEnforceUtc.ToString('yyyy-MM-ddTHH:mm:ssZ'))."
    }

    $sourceRecord = $null
    $sourceCore = $null
    if (-not [string]::IsNullOrWhiteSpace([string]$modeConfig.source_channel_for_promotion)) {
        $sourceCandidates = @(Get-LatestSemVerRecordByChannel -Records $allRecords -Channel ([string]$modeConfig.source_channel_for_promotion))
        if (@($sourceCandidates).Count -ne 1) {
            throw "promotion_source_missing: channel=$([string]$modeConfig.source_channel_for_promotion) strategy=semver"
        }

        $sourceRecord = $sourceCandidates[0]
        $sourceTag = [string]$sourceRecord.tag_name
        $sourceCore = New-CoreVersion -Major ([int]$sourceRecord.major) -Minor ([int]$sourceRecord.minor) -Patch ([int]$sourceRecord.patch)
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
            tag_family = 'semver'
            core = Format-CoreVersion -Core $sourceCore
            prerelease_sequence = [int]$sourceRecord.prerelease_sequence
            source_sha = $sourceCommit
            head_sha = $headSha
            url = [string]$sourceRelease.url
        }
    }

    $targetPlan = $null
    if ($ModeName -eq 'CanaryCycle') {
        $targetPlan = Resolve-CanaryTargetSemVer -Records $allRecords
    } elseif ($ModeName -eq 'PromotePrerelease' -or $ModeName -eq 'PromoteStable') {
        if ($null -eq $sourceCore) {
            throw "promotion_source_missing: channel=$([string]$modeConfig.source_channel_for_promotion) strategy=semver"
        }
        $targetPlan = Resolve-PromotedTargetSemVer -Records $allRecords -TargetChannel ([string]$modeConfig.channel) -SourceCore $sourceCore
    } else {
        throw "unsupported_release_mode: $ModeName"
    }

    $targetTag = [string]$targetPlan.tag
    $targetCoreText = Format-CoreVersion -Core $targetPlan.core
    $ExecutionReport.target_release = [ordered]@{
        mode = $ModeName
        channel = [string]$modeConfig.channel
        prerelease = [bool]$modeConfig.prerelease
        tag = $targetTag
        tag_family = 'semver'
        core = $targetCoreText
        prerelease_sequence = [int]$targetPlan.prerelease_sequence
        status = if ([bool]$targetPlan.skipped) { 'skipped' } else { 'planned' }
        reason_code = if ([bool]$targetPlan.skipped) { [string]$targetPlan.reason_code } else { '' }
        migration_warnings = @($migrationWarnings)
    }

    if (@($migrationWarnings).Count -gt 0) {
        foreach ($warning in @($migrationWarnings)) {
            Write-Warning "[tag_migration_warning] $warning"
        }
    }

    if ([bool]$targetPlan.skipped) {
        return
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
        "prerelease=$(([string]([bool]$modeConfig.prerelease)).ToLowerInvariant())",
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
            -TagFamily semver `
            -KeepLatestN $KeepLatestCanaryN `
            -Delete `
            -OutputPath $hygienePath
        if ($LASTEXITCODE -ne 0) {
            throw "canary_hygiene_failed: tag_family=semver date=$DateKey exit_code=$LASTEXITCODE"
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
    tag_strategy = 'semver'
    migration_mode = 'dual_mode_publish_semver_control_plane'
    semver_policy_source = $script:semverPolicySource
    semver_only_enforce_utc = $script:semverOnlyEnforceUtc.ToString('yyyy-MM-ddTHH:mm:ssZ')
    semver_only_enforced = [bool]$script:semverOnlyEnforced
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
                    tag_family = 'semver'
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
