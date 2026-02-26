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
    canary_tag_regex = $CanaryTagRegex
    require_prerelease = $RequirePrerelease
    keep_latest_n = $KeepLatestN
    delete_enabled = [bool]$Delete
    max_delete_count = $MaxDeleteCount
    status = 'fail'
    reason_code = ''
    message = ''
    releases_scanned = 0
    candidate_count = 0
    kept_tags = @()
    delete_candidates = @()
    deleted_tags = @()
}

try {
    $releaseList = @(Get-GhReleasesPortable -Repository $Repository -Limit 100 -ExcludeDrafts)
    $report.releases_scanned = @($releaseList).Count

    $candidates = @()
    foreach ($release in $releaseList) {
        $tagName = [string]$release.tagName
        if ([string]::IsNullOrWhiteSpace($tagName)) {
            continue
        }

        $match = [regex]::Match($tagName, $CanaryTagRegex)
        if (-not $match.Success) {
            continue
        }

        $tagDate = [string]$match.Groups['date'].Value
        if ($tagDate -ne $DateUtc) {
            continue
        }

        $sequenceText = [string]$match.Groups['sequence'].Value
        $sequence = 0
        if (-not [int]::TryParse($sequenceText, [ref]$sequence)) {
            continue
        }

        $isPrerelease = [bool]$release.isPrerelease
        if ($RequirePrerelease -and -not $isPrerelease) {
            continue
        }

        $publishedAt = [DateTimeOffset]::MinValue
        [void][DateTimeOffset]::TryParse([string]$release.publishedAt, [ref]$publishedAt)

        $candidates += [ordered]@{
            tag_name = $tagName
            sequence = $sequence
            is_prerelease = $isPrerelease
            published_at_utc = if ($publishedAt -eq [DateTimeOffset]::MinValue) { '' } else { $publishedAt.ToUniversalTime().ToString('o') }
        }
    }

    $orderedCandidates = @(
        $candidates | Sort-Object `
            @{ Expression = { [int]$_.sequence }; Descending = $true }, `
            @{ Expression = {
                    $parsed = [DateTimeOffset]::MinValue
                    [void][DateTimeOffset]::TryParse([string]$_.published_at_utc, [ref]$parsed)
                    $parsed
                }; Descending = $true }, `
            @{ Expression = { [string]$_.tag_name }; Descending = $false }
    )

    $report.candidate_count = @($orderedCandidates).Count

    if (@($orderedCandidates).Count -eq 0) {
        $report.status = 'pass'
        $report.reason_code = 'no_matching_tags'
        $report.message = "No canary releases matched date '$DateUtc'."
    } else {
        $kept = @($orderedCandidates | Select-Object -First $KeepLatestN)
        $deleteCandidates = @($orderedCandidates | Select-Object -Skip $KeepLatestN)

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
            $report.message = "Deleted $(@($deleted).Count) stale canary release tags for date '$DateUtc'."
        } else {
            $report.status = 'pass'
            $report.reason_code = 'dry_run'
            $report.message = "Dry-run only. $(@($deleteCandidates).Count) stale canary tags would be deleted for date '$DateUtc'."
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
