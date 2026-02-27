#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter()]
    [ValidatePattern('^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$')]
    [string]$Repository = 'LabVIEW-Community-CI-CD/labview-cdev-surface-fork',

    [Parameter()]
    [ValidateSet('stable', 'prerelease', 'canary')]
    [string]$Channel = 'canary',

    [Parameter()]
    [ValidateRange(2, 100)]
    [int]$RequiredHistoryCount = 2,

    [Parameter()]
    [ValidateRange(10, 200)]
    [int]$ReleaseLimit = 100,

    [Parameter()]
    [string]$OutputPath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'lib/WorkflowOps.Common.ps1')

function Add-ReasonCode {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][System.Collections.Generic.List[string]]$Target,
        [Parameter(Mandatory = $true)][string]$ReasonCode
    )

    if (-not $Target.Contains($ReasonCode)) {
        [void]$Target.Add($ReasonCode)
    }
}

function Get-ReleasePublishedSortValue {
    param([Parameter(Mandatory = $true)][object]$Candidate)

    $parsed = [DateTimeOffset]::MinValue
    [void][DateTimeOffset]::TryParse([string]$Candidate.published_at_utc, [ref]$parsed)
    return $parsed
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

    $legacyMatch = [regex]::Match($TagName, '^v0\.(?<date>\d{8})\.(?<sequence>\d+)$')
    if ($legacyMatch.Success) {
        $legacySequence = 0
        if (-not [int]::TryParse([string]$legacyMatch.Groups['sequence'].Value, [ref]$legacySequence)) {
            return $null
        }

        $legacyChannel = 'unknown'
        if ($legacySequence -ge 1 -and $legacySequence -le 49 -and $IsPrerelease) {
            $legacyChannel = 'canary'
        } elseif ($legacySequence -ge 50 -and $legacySequence -le 79 -and $IsPrerelease) {
            $legacyChannel = 'prerelease'
        } elseif ($legacySequence -ge 80 -and $legacySequence -le 99 -and -not $IsPrerelease) {
            $legacyChannel = 'stable'
        }

        return [ordered]@{
            tag_name = $TagName
            tag_family = 'legacy_date_window'
            channel = $legacyChannel
            major = 0
            minor = 0
            patch = 0
            prerelease_label = ''
            prerelease_sequence = 0
            legacy_date = [string]$legacyMatch.Groups['date'].Value
            legacy_sequence = $legacySequence
            is_prerelease = $IsPrerelease
        }
    }

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

    return [ordered]@{
        tag_name = $TagName
        tag_family = 'semver'
        channel = $channel
        major = [int]$semverMatch.Groups['major'].Value
        minor = [int]$semverMatch.Groups['minor'].Value
        patch = [int]$semverMatch.Groups['patch'].Value
        prerelease_label = $prereleaseLabel
        prerelease_sequence = $sequence
        legacy_date = ''
        legacy_sequence = 0
        is_prerelease = $IsPrerelease
    }
}

$requiredAssets = @(
    'lvie-cdev-workspace-installer.exe',
    'lvie-cdev-workspace-installer.exe.sha256',
    'reproducibility-report.json',
    'workspace-installer.spdx.json',
    'workspace-installer.slsa.json',
    'release-manifest.json'
)

$report = [ordered]@{
    schema_version = '1.0'
    generated_at_utc = Get-UtcNowIso
    repository = $Repository
    channel = $Channel
    required_history_count = $RequiredHistoryCount
    tag_strategy = 'semver_preferred_dual_mode'
    status = 'fail'
    reason_codes = @()
    message = ''
    candidate_count = 0
    semver_candidate_count = 0
    legacy_candidate_count = 0
    candidate_tag_family_selected = ''
    migration_warnings = @()
    current = $null
    previous = $null
    required_assets = $requiredAssets
    asset_checks = @()
}

$reasonCodes = [System.Collections.Generic.List[string]]::new()
$assetChecks = [System.Collections.Generic.List[object]]::new()
$migrationWarnings = [System.Collections.Generic.List[string]]::new()

try {
    $releases = @(Get-GhReleasesPortable -Repository $Repository -Limit $ReleaseLimit -ExcludeDrafts)
    $channelCandidates = @()
    foreach ($release in @($releases)) {
        $parsed = Parse-ReleaseTagRecord -TagName ([string]$release.tagName) -IsPrerelease ([bool]$release.isPrerelease)
        if ($null -eq $parsed) {
            continue
        }
        if ([string]$parsed.channel -ne $Channel) {
            continue
        }

        $channelCandidates += [ordered]@{
            tag_name = [string]$release.tagName
            tag_family = [string]$parsed.tag_family
            channel = [string]$parsed.channel
            is_prerelease = [bool]$release.isPrerelease
            published_at_utc = [string]$release.publishedAt
            url = [string]$release.url
            major = [int]$parsed.major
            minor = [int]$parsed.minor
            patch = [int]$parsed.patch
            prerelease_sequence = [int]$parsed.prerelease_sequence
            legacy_date = [string]$parsed.legacy_date
            legacy_sequence = [int]$parsed.legacy_sequence
        }
    }

    $semverCandidates = @($channelCandidates | Where-Object { [string]$_.tag_family -eq 'semver' })
    $legacyCandidates = @($channelCandidates | Where-Object { [string]$_.tag_family -eq 'legacy_date_window' })
    $report.semver_candidate_count = @($semverCandidates).Count
    $report.legacy_candidate_count = @($legacyCandidates).Count

    if (@($legacyCandidates).Count -gt 0) {
        [void]$migrationWarnings.Add("Legacy date-window rollback candidates were detected for channel '$Channel'.")
    }

    $selectedFamily = ''
    $selectedCandidates = @()
    if (@($semverCandidates).Count -gt 0) {
        $selectedFamily = 'semver'
        $selectedCandidates = @(
            $semverCandidates |
                Sort-Object `
                    @{ Expression = { [int]$_.major }; Descending = $true }, `
                    @{ Expression = { [int]$_.minor }; Descending = $true }, `
                    @{ Expression = { [int]$_.patch }; Descending = $true }, `
                    @{ Expression = { [int]$_.prerelease_sequence }; Descending = $true }, `
                    @{ Expression = { Get-ReleasePublishedSortValue -Candidate $_ }; Descending = $true }, `
                    @{ Expression = { [string]$_.tag_name }; Descending = $false }
        )
        if (@($legacyCandidates).Count -gt 0) {
            [void]$migrationWarnings.Add("SemVer candidates were selected for rollback drill; legacy candidates were ignored for precedence.")
        }
    } else {
        $selectedFamily = 'legacy_date_window'
        $selectedCandidates = @(
            $legacyCandidates |
                Sort-Object `
                    @{ Expression = { [string]$_.legacy_date }; Descending = $true }, `
                    @{ Expression = { [int]$_.legacy_sequence }; Descending = $true }, `
                    @{ Expression = { Get-ReleasePublishedSortValue -Candidate $_ }; Descending = $true }, `
                    @{ Expression = { [string]$_.tag_name }; Descending = $false }
        )
    }

    $report.candidate_tag_family_selected = $selectedFamily
    $report.migration_warnings = @($migrationWarnings)
    $report.candidate_count = @($selectedCandidates).Count

    if (@($selectedCandidates).Count -lt $RequiredHistoryCount) {
        Add-ReasonCode -Target $reasonCodes -ReasonCode 'rollback_candidate_missing'
    } else {
        $current = $selectedCandidates[0]
        $previous = $selectedCandidates[1]
        $report.current = [ordered]@{
            tag = [string]$current.tag_name
            tag_family = [string]$current.tag_family
            published_at_utc = [string]$current.published_at_utc
            url = [string]$current.url
        }
        $report.previous = [ordered]@{
            tag = [string]$previous.tag_name
            tag_family = [string]$previous.tag_family
            published_at_utc = [string]$previous.published_at_utc
            url = [string]$previous.url
        }

        foreach ($tag in @([string]$current.tag_name, [string]$previous.tag_name)) {
            $release = Invoke-GhJson -Arguments @(
                'release', 'view',
                $tag,
                '-R', $Repository,
                '--json', 'tagName,assets,targetCommitish,isPrerelease,publishedAt,url'
            )
            $assetNames = @($release.assets | ForEach-Object { [string]$_.name })
            foreach ($asset in @($requiredAssets)) {
                $present = $assetNames -contains $asset
                $assetChecks.Add([ordered]@{
                        tag = $tag
                        asset = $asset
                        present = $present
                    }) | Out-Null
                if (-not $present) {
                    Add-ReasonCode -Target $reasonCodes -ReasonCode 'rollback_assets_missing'
                }
            }
        }
    }

    $report.asset_checks = @($assetChecks)
    if ($reasonCodes.Count -eq 0) {
        $report.status = 'pass'
        $report.reason_codes = @('ok')
        $report.message = 'Release rollback drill passed.'
    } else {
        $report.status = 'fail'
        $report.reason_codes = @($reasonCodes)
        $report.message = "Release rollback drill failed. reason_codes=$([string]::Join(',', @($reasonCodes)))"
    }
}
catch {
    $report.status = 'fail'
    $report.reason_codes = @('rollback_drill_runtime_error')
    $report.message = [string]$_.Exception.Message
}
finally {
    Write-WorkflowOpsReport -Report $report -OutputPath $OutputPath | Out-Null
}

if ([string]$report.status -eq 'pass') {
    exit 0
}

exit 1
