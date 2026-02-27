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
        [Parameter(Mandatory = $true)][System.Collections.Generic.List[string]]$Target,
        [Parameter(Mandatory = $true)][string]$ReasonCode
    )

    if (-not $Target.Contains($ReasonCode)) {
        [void]$Target.Add($ReasonCode)
    }
}

function Parse-ReleaseTagRecord {
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

function Test-ChannelMatch {
    param(
        [Parameter(Mandatory = $true)][object]$ReleaseRecord,
        [Parameter(Mandatory = $true)][string]$TargetChannel
    )

    $parsed = Parse-ReleaseTagRecord -TagName ([string]$ReleaseRecord.tagName)
    if ($null -eq $parsed) {
        return $false
    }

    $seq = [int]$parsed.sequence
    $isPrerelease = [bool]$ReleaseRecord.isPrerelease
    switch ($TargetChannel) {
        'canary' { return $isPrerelease -and $seq -ge 1 -and $seq -le 49 }
        'prerelease' { return $isPrerelease -and $seq -ge 50 -and $seq -le 79 }
        'stable' { return (-not $isPrerelease) -and $seq -ge 80 -and $seq -le 99 }
        default { return $false }
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
    status = 'fail'
    reason_codes = @()
    message = ''
    candidate_count = 0
    current = $null
    previous = $null
    required_assets = $requiredAssets
    asset_checks = @()
}

$reasonCodes = [System.Collections.Generic.List[string]]::new()
$assetChecks = [System.Collections.Generic.List[object]]::new()

try {
    $releases = @(Get-GhReleasesPortable -Repository $Repository -Limit $ReleaseLimit -ExcludeDrafts)
    $candidates = @(
        $releases |
            Where-Object { Test-ChannelMatch -ReleaseRecord $_ -TargetChannel $Channel } |
            Sort-Object {
                $parsed = Parse-ReleaseTagRecord -TagName ([string]$_.tagName)
                "{0}-{1:D3}" -f [string]$parsed.date, [int]$parsed.sequence
            } -Descending
    )

    $report.candidate_count = @($candidates).Count
    if (@($candidates).Count -lt $RequiredHistoryCount) {
        Add-ReasonCode -Target $reasonCodes -ReasonCode 'rollback_candidate_missing'
    } else {
        $current = $candidates[0]
        $previous = $candidates[1]
        $report.current = [ordered]@{
            tag = [string]$current.tagName
            published_at_utc = [string]$current.publishedAt
            url = [string]$current.url
        }
        $report.previous = [ordered]@{
            tag = [string]$previous.tagName
            published_at_utc = [string]$previous.publishedAt
            url = [string]$previous.url
        }

        foreach ($tag in @([string]$current.tagName, [string]$previous.tagName)) {
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
