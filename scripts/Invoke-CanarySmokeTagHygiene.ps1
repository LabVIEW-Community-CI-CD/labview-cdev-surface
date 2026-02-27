#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter()]
    [ValidatePattern('^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$')]
    [string]$Repository = 'LabVIEW-Community-CI-CD/labview-cdev-surface-fork',

    [Parameter()]
    [ValidatePattern('^[0-9]{8}$')]
    [string]$DateUtc = (Get-Date).ToUniversalTime().ToString('yyyyMMdd'),

    [Parameter()]
    [ValidateRange(1, 10)]
    [int]$KeepLatestN = 1,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$CanaryTagRegex = '^v0\.(?<date>\d{8})\.(?<sequence>\d+)$',

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$SemverCanaryTagRegex = '^v(?<major>0|[1-9]\d*)\.(?<minor>0|[1-9]\d*)\.(?<patch>0|[1-9]\d*)-(?<prerelease>[0-9A-Za-z-]*(?i:canary)[0-9A-Za-z-]*(?:\.[0-9A-Za-z-]+)*)(?:\+(?<build>[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?$',

    [Parameter()]
    [ValidateSet('auto', 'legacy_date_window', 'semver')]
    [string]$TagFamily = 'auto',

    [Parameter()]
    [bool]$RequirePrerelease = $true,

    [Parameter()]
    [ValidateRange(1, 100)]
    [int]$MaxDeleteCount = 20,

    [Parameter()]
    [switch]$Delete,

    [Parameter()]
    [string]$OutputPath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'lib/WorkflowOps.Common.ps1')

$report = [ordered]@{
    schema_version = '1.0'
    timestamp_utc = Get-UtcNowIso
    repository = $Repository
    target_date_utc = $DateUtc
    tag_family_mode = $TagFamily
    legacy_canary_tag_regex = $CanaryTagRegex
    semver_canary_tag_regex = $SemverCanaryTagRegex
    require_prerelease = $RequirePrerelease
    keep_latest_n = $KeepLatestN
    delete_enabled = [bool]$Delete
    max_delete_count = $MaxDeleteCount
    status = 'fail'
    reason_code = ''
    message = ''
    releases_scanned = 0
    candidate_count = 0
    legacy_candidate_count = 0
    semver_candidate_count = 0
    kept_tags = @()
    delete_candidates = @()
    deleted_tags = @()
    migration_warnings = @()
}

try {
    $releaseList = @(Get-GhReleasesPortable -Repository $Repository -Limit 100 -ExcludeDrafts)
    $report.releases_scanned = @($releaseList).Count

    $legacyCandidates = @()
    $semverCandidates = @()
    foreach ($release in $releaseList) {
        $tagName = [string]$release.tagName
        if ([string]::IsNullOrWhiteSpace($tagName)) {
            continue
        }

        $isPrerelease = [bool]$release.isPrerelease
        $publishedAt = [DateTimeOffset]::MinValue
        [void][DateTimeOffset]::TryParse([string]$release.publishedAt, [ref]$publishedAt)
        $publishedAtUtcText = if ($publishedAt -eq [DateTimeOffset]::MinValue) { '' } else { $publishedAt.ToUniversalTime().ToString('o') }

        $legacyMatch = [regex]::Match($tagName, $CanaryTagRegex)
        if ($legacyMatch.Success) {
            $tagDate = [string]$legacyMatch.Groups['date'].Value
            if ($tagDate -eq $DateUtc) {
                $sequenceText = [string]$legacyMatch.Groups['sequence'].Value
                $sequence = 0
                if ([int]::TryParse($sequenceText, [ref]$sequence)) {
                    if (-not $RequirePrerelease -or $isPrerelease) {
                        $legacyCandidates += [ordered]@{
                            tag_name = $tagName
                            tag_family = 'legacy_date_window'
                            sequence = $sequence
                            major = -1
                            minor = -1
                            patch = -1
                            is_prerelease = $isPrerelease
                            published_at_utc = $publishedAtUtcText
                        }
                    }
                }
            }
        }

        $semverMatch = [regex]::Match($tagName, $SemverCanaryTagRegex)
        if ($semverMatch.Success) {
            if (-not $RequirePrerelease -or $isPrerelease) {
                $semverCandidates += [ordered]@{
                    tag_name = $tagName
                    tag_family = 'semver'
                    sequence = -1
                    major = [int]$semverMatch.Groups['major'].Value
                    minor = [int]$semverMatch.Groups['minor'].Value
                    patch = [int]$semverMatch.Groups['patch'].Value
                    is_prerelease = $isPrerelease
                    published_at_utc = $publishedAtUtcText
                }
            }
        }
    }

    $report.legacy_candidate_count = @($legacyCandidates).Count
    $report.semver_candidate_count = @($semverCandidates).Count

    if (@($legacyCandidates).Count -gt 0) {
        $report.migration_warnings += "Legacy date-window canary tags were detected for date '$DateUtc'. SemVer canary tags are preferred."
    }
    if ($TagFamily -eq 'auto' -and @($legacyCandidates).Count -gt 0 -and @($semverCandidates).Count -gt 0) {
        $report.migration_warnings += "Dual-mode hygiene processed both legacy_date_window and semver canary tags."
    }

    $selectedLegacyCandidates = @()
    $selectedSemverCandidates = @()
    switch ($TagFamily) {
        'legacy_date_window' {
            $selectedLegacyCandidates = @($legacyCandidates)
        }
        'semver' {
            $selectedSemverCandidates = @($semverCandidates)
        }
        default {
            $selectedLegacyCandidates = @($legacyCandidates)
            $selectedSemverCandidates = @($semverCandidates)
        }
    }

    $orderedLegacyCandidates = @(
        $selectedLegacyCandidates | Sort-Object `
            @{ Expression = { [int]$_.sequence }; Descending = $true }, `
            @{ Expression = {
                    $parsed = [DateTimeOffset]::MinValue
                    [void][DateTimeOffset]::TryParse([string]$_.published_at_utc, [ref]$parsed)
                    $parsed
                }; Descending = $true }, `
            @{ Expression = { [string]$_.tag_name }; Descending = $false }
    )
    $orderedSemverCandidates = @(
        $selectedSemverCandidates | Sort-Object `
            @{ Expression = { [int]$_.major }; Descending = $true }, `
            @{ Expression = { [int]$_.minor }; Descending = $true }, `
            @{ Expression = { [int]$_.patch }; Descending = $true }, `
            @{ Expression = {
                    $parsed = [DateTimeOffset]::MinValue
                    [void][DateTimeOffset]::TryParse([string]$_.published_at_utc, [ref]$parsed)
                    $parsed
                }; Descending = $true }, `
            @{ Expression = { [string]$_.tag_name }; Descending = $false }
    )

    $orderedCandidates = @($orderedLegacyCandidates + $orderedSemverCandidates)

    $report.candidate_count = @($orderedCandidates).Count

    if (@($orderedCandidates).Count -eq 0) {
        $report.status = 'pass'
        $report.reason_code = 'no_matching_tags'
        if ($TagFamily -eq 'legacy_date_window') {
            $report.message = "No legacy canary releases matched date '$DateUtc'."
        } elseif ($TagFamily -eq 'semver') {
            $report.message = 'No SemVer canary releases matched hygiene policy.'
        } else {
            $report.message = "No canary releases matched hygiene policy for mode '$TagFamily'."
        }
    } else {
        $keptLegacy = @($orderedLegacyCandidates | Select-Object -First $KeepLatestN)
        $deleteLegacy = @($orderedLegacyCandidates | Select-Object -Skip $KeepLatestN)
        $keptSemver = @($orderedSemverCandidates | Select-Object -First $KeepLatestN)
        $deleteSemver = @($orderedSemverCandidates | Select-Object -Skip $KeepLatestN)

        $kept = @($keptLegacy + $keptSemver)
        $deleteCandidates = @($deleteLegacy + $deleteSemver)

        $report.kept_tags = @($kept)
        $report.delete_candidates = @($deleteCandidates)

        if (@($deleteCandidates).Count -gt $MaxDeleteCount) {
            throw "delete_count_exceeds_guard: deleteCandidates=$(@($deleteCandidates).Count) max=$MaxDeleteCount"
        }

        $deleted = @()
        if ($Delete) {
            foreach ($candidate in $deleteCandidates) {
                Invoke-Gh -Arguments @(
                    'release', 'delete',
                    [string]$candidate.tag_name,
                    '-R', $Repository,
                    '--yes',
                    '--cleanup-tag'
                )

                $deleted += [ordered]@{
                    tag_name = [string]$candidate.tag_name
                    deleted_at_utc = Get-UtcNowIso
                }
            }

            $report.deleted_tags = @($deleted)
            $report.status = 'pass'
            $report.reason_code = 'applied'
            $report.message = "Deleted $(@($deleted).Count) stale canary release tags for mode '$TagFamily'."
        } else {
            $report.status = 'pass'
            $report.reason_code = 'dry_run'
            $report.message = "Dry-run only. $(@($deleteCandidates).Count) stale canary tags would be deleted for mode '$TagFamily'."
        }
    }
}
catch {
    $report.status = 'fail'
    $report.reason_code = 'hygiene_failed'
    $report.message = [string]$_.Exception.Message
}
finally {
    Write-WorkflowOpsReport -Report $report -OutputPath $OutputPath | Out-Null
}

if ([string]$report.status -eq 'pass') {
    exit 0
}

exit 1
