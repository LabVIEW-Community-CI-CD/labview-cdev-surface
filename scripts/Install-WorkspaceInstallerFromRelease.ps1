#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter()]
    [string]$WorkspaceRoot = 'C:\dev',

    [Parameter()]
    [string]$ManifestPath = '',

    [Parameter()]
    [ValidateSet('Install', 'Upgrade', 'Rollback', 'Status', 'ValidatePolicy')]
    [string]$Mode = 'Install',

    [Parameter()]
    [ValidateSet('stable', 'prerelease', 'canary')]
    [string]$Channel = 'stable',

    [Parameter()]
    [string]$Tag = '',

    [Parameter()]
    [string]$Repository = '',

    [Parameter()]
    [string]$PolicyPath = '',

    [Parameter()]
    [string]$OutputPath = '',

    [Parameter()]
    [switch]$AllowMajor,

    [Parameter()]
    [switch]$AllowPrerelease,

    [Parameter()]
    [string]$RollbackTo = 'previous'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Ensure-Directory {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        New-Item -Path $Path -ItemType Directory -Force | Out-Null
    }
}

function Read-JsonFile {
    param([Parameter(Mandatory = $true)][string]$Path)

    return (Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -Depth 100 -ErrorAction Stop)
}

function Write-JsonFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$Object
    )

    $parent = Split-Path -Path $Path -Parent
    if (-not [string]::IsNullOrWhiteSpace($parent)) {
        Ensure-Directory -Path $parent
    }
    ($Object | ConvertTo-Json -Depth 100) + "`n" | Set-Content -LiteralPath $Path -Encoding utf8
}

function Throw-ReleaseClientError {
    param(
        [Parameter(Mandatory = $true)][string]$ReasonCode,
        [Parameter(Mandatory = $true)][string]$Message
    )

    throw "[$ReasonCode] $Message"
}

function Resolve-Sha256Hex {
    param([Parameter(Mandatory = $true)][string]$Path)

    $resolved = (Resolve-Path -LiteralPath $Path).Path
    return (Get-FileHash -LiteralPath $resolved -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-ReasonCodeFromException {
    param([Parameter(Mandatory = $true)][string]$Message)

    if ($Message -match '^\[(?<reason>[a-z0-9_\-]+)\]') {
        return $Matches['reason']
    }
    return 'source_blocked'
}

function Get-SemVer {
    param([string]$TagName)

    if ([string]::IsNullOrWhiteSpace($TagName)) {
        return $null
    }

    $match = [regex]::Match($TagName, '^v?(?<major>\d+)\.(?<minor>\d+)\.(?<patch>\d+)')
    if (-not $match.Success) {
        return $null
    }

    return [pscustomobject]@{
        major = [int]$match.Groups['major'].Value
        minor = [int]$match.Groups['minor'].Value
        patch = [int]$match.Groups['patch'].Value
    }
}

function Compare-SemVer {
    param(
        [Parameter(Mandatory = $true)]$Left,
        [Parameter(Mandatory = $true)]$Right
    )

    foreach ($name in @('major', 'minor', 'patch')) {
        $l = [int]$Left.$name
        $r = [int]$Right.$name
        if ($l -gt $r) { return 1 }
        if ($l -lt $r) { return -1 }
    }

    return 0
}

function Test-ContainsValue {
    param(
        [Parameter(Mandatory = $true)]$Collection,
        [Parameter(Mandatory = $true)][string]$Value
    )

    foreach ($item in @($Collection)) {
        if ([string]$item -eq $Value) {
            return $true
        }
    }
    return $false
}

function Select-LatestReleaseTag {
    param(
        [Parameter(Mandatory = $true)][string]$Repository,
        [Parameter(Mandatory = $true)][string]$Channel,
        [Parameter(Mandatory = $true)][string]$CanaryRegex
    )

    $listJson = & gh release list -R $Repository --limit 100 --exclude-drafts --json tagName,isPrerelease,publishedAt 2>&1
    if ($LASTEXITCODE -ne 0) {
        Throw-ReleaseClientError -ReasonCode 'source_blocked' -Message "Failed to list releases for '$Repository'. $([string]::Join("`n", @($listJson)))"
    }

    $allReleases = $listJson | ConvertFrom-Json -ErrorAction Stop
    $filtered = @()
    foreach ($release in @($allReleases)) {
        $tagName = [string]$release.tagName
        $isPrerelease = [bool]$release.isPrerelease

        if ($Channel -eq 'stable' -and -not $isPrerelease) {
            $filtered += $release
            continue
        }

        if ($Channel -eq 'prerelease' -and $isPrerelease -and ($tagName -notmatch $CanaryRegex)) {
            $filtered += $release
            continue
        }

        if ($Channel -eq 'canary' -and $isPrerelease -and ($tagName -match $CanaryRegex)) {
            $filtered += $release
            continue
        }
    }

    if (@($filtered).Count -eq 0) {
        Throw-ReleaseClientError -ReasonCode 'asset_missing' -Message "No '$Channel' release was found in '$Repository'."
    }

    $selected = $filtered |
        Sort-Object -Property @{Expression = { [DateTime]::Parse([string]$_.publishedAt).ToUniversalTime() }; Descending = $true } |
        Select-Object -First 1

    return [string]$selected.tagName
}

function Download-ReleaseAsset {
    param(
        [Parameter(Mandatory = $true)][string]$Repository,
        [Parameter(Mandatory = $true)][string]$ReleaseTag,
        [Parameter(Mandatory = $true)][string]$AssetName,
        [Parameter(Mandatory = $true)][string]$DestinationDirectory
    )

    $downloadOutput = & gh release download $ReleaseTag -R $Repository -p $AssetName -D $DestinationDirectory --clobber 2>&1
    if ($LASTEXITCODE -ne 0) {
        Throw-ReleaseClientError -ReasonCode 'asset_missing' -Message "Failed to download release asset '$AssetName' from '$Repository@$ReleaseTag'. $([string]::Join("`n", @($downloadOutput)))"
    }

    $assetPath = Join-Path $DestinationDirectory $AssetName
    if (-not (Test-Path -LiteralPath $assetPath -PathType Leaf)) {
        Throw-ReleaseClientError -ReasonCode 'asset_missing' -Message "Release asset was not found after download: $assetPath"
    }

    return $assetPath
}

function Get-SignatureEnforcement {
    param(
        [Parameter(Mandatory = $true)]$SignaturePolicy,
        [Parameter(Mandatory = $true)][string]$Channel
    )

    $now = (Get-Date).ToUniversalTime()
    $dualStart = [DateTime]::Parse([string]$SignaturePolicy.dual_mode_start_utc).ToUniversalTime()
    $canaryEnforce = [DateTime]::Parse([string]$SignaturePolicy.canary_enforce_utc).ToUniversalTime()
    $graceEnd = [DateTime]::Parse([string]$SignaturePolicy.grace_end_utc).ToUniversalTime()

    $enforceAt = if ($Channel -eq 'canary') { $canaryEnforce } else { $graceEnd }

    return [pscustomobject]@{
        now_utc = $now.ToString('o')
        dual_mode_start_utc = $dualStart.ToString('o')
        enforce_at_utc = $enforceAt.ToString('o')
        enforce_signature = ($now -ge $enforceAt)
        warn_if_unsigned = ($now -ge $dualStart -and $now -lt $enforceAt)
    }
}

function Initialize-ReleaseState {
    param([Parameter(Mandatory = $true)][string]$StatePath)

    if (Test-Path -LiteralPath $StatePath -PathType Leaf) {
        return Read-JsonFile -Path $StatePath
    }

    return [pscustomobject]@{
        current = $null
        history = @()
        updated_at_utc = ''
    }
}

function Save-ReleaseState {
    param(
        [Parameter(Mandatory = $true)][string]$StatePath,
        [Parameter(Mandatory = $true)]$State
    )

    $State.updated_at_utc = (Get-Date).ToUniversalTime().ToString('o')
    Write-JsonFile -Path $StatePath -Object $State
}

function Convert-PolicyToHashtable {
    param([Parameter(Mandatory = $true)]$PolicyObject)

    $json = $PolicyObject | ConvertTo-Json -Depth 100
    return ($json | ConvertFrom-Json -AsHashtable -Depth 100)
}

function Merge-PolicyNode {
    param(
        [Parameter(Mandatory = $true)]$BaseNode,
        [Parameter(Mandatory = $true)]$OverrideNode
    )

    if ($BaseNode -isnot [System.Collections.IDictionary] -or $OverrideNode -isnot [System.Collections.IDictionary]) {
        return $OverrideNode
    }

    $merged = @{}
    foreach ($key in $BaseNode.Keys) {
        $merged[$key] = $BaseNode[$key]
    }
    foreach ($key in $OverrideNode.Keys) {
        if ($merged.Contains($key)) {
            $merged[$key] = Merge-PolicyNode -BaseNode $merged[$key] -OverrideNode $OverrideNode[$key]
        } else {
            $merged[$key] = $OverrideNode[$key]
        }
    }

    return $merged
}

function Load-EffectivePolicy {
    param(
        [Parameter(Mandatory = $true)]$ManifestReleaseClient,
        [Parameter(Mandatory = $true)][string]$PolicyPath
    )

    $basePolicy = Convert-PolicyToHashtable -PolicyObject $ManifestReleaseClient

    if (-not (Test-Path -LiteralPath $PolicyPath -PathType Leaf)) {
        Write-JsonFile -Path $PolicyPath -Object $ManifestReleaseClient
        return (Read-JsonFile -Path $PolicyPath)
    }

    $overridePolicy = Read-JsonFile -Path $PolicyPath
    $overrideHash = Convert-PolicyToHashtable -PolicyObject $overridePolicy
    $mergedHash = Merge-PolicyNode -BaseNode $basePolicy -OverrideNode $overrideHash

    $mergedJson = $mergedHash | ConvertTo-Json -Depth 100
    return ($mergedJson | ConvertFrom-Json -Depth 100)
}

function Assert-ReleaseClientPolicy {
    param([Parameter(Mandatory = $true)]$Policy)

    if ([string]::IsNullOrWhiteSpace([string]$Policy.schema_version)) {
        Throw-ReleaseClientError -ReasonCode 'source_blocked' -Message 'Release policy is missing schema_version.'
    }

    $allowedRepos = @($Policy.allowed_repositories)
    if ($allowedRepos.Count -lt 1) {
        Throw-ReleaseClientError -ReasonCode 'source_blocked' -Message 'Release policy must define allowed_repositories.'
    }

    foreach ($requiredChannel in @('stable', 'prerelease', 'canary')) {
        if (-not (Test-ContainsValue -Collection @($Policy.channel_rules.allowed_channels) -Value $requiredChannel)) {
            Throw-ReleaseClientError -ReasonCode 'source_blocked' -Message "Release policy is missing allowed channel '$requiredChannel'."
        }
    }

    if ([string]$Policy.signature_policy.provider -ne 'authenticode') {
        Throw-ReleaseClientError -ReasonCode 'source_blocked' -Message "Unsupported signature provider '$($Policy.signature_policy.provider)'."
    }

    [void][DateTime]::Parse([string]$Policy.signature_policy.dual_mode_start_utc)
    [void][DateTime]::Parse([string]$Policy.signature_policy.canary_enforce_utc)
    [void][DateTime]::Parse([string]$Policy.signature_policy.grace_end_utc)
}

$report = [ordered]@{
    timestamp_utc = (Get-Date).ToUniversalTime().ToString('o')
    mode = $Mode
    status = 'fail'
    reason_code = ''
    message = ''
    repository = ''
    release_tag = ''
    requested_channel = $Channel
    selected_channel = ''
    policy_path = ''
    state_path = ''
    install_report_path = ''
    warnings = @()
    details = [ordered]@{}
}

$exitCode = 1

try {
    foreach ($commandName in @('gh', 'git', 'pwsh')) {
        if (-not (Get-Command $commandName -ErrorAction SilentlyContinue)) {
            Throw-ReleaseClientError -ReasonCode 'source_blocked' -Message "Required command '$commandName' was not found on PATH."
        }
    }

    $resolvedManifestPath = if ([string]::IsNullOrWhiteSpace($ManifestPath)) {
        Join-Path $WorkspaceRoot 'workspace-governance.json'
    } else {
        [System.IO.Path]::GetFullPath($ManifestPath)
    }

    if (-not (Test-Path -LiteralPath $resolvedManifestPath -PathType Leaf)) {
        Throw-ReleaseClientError -ReasonCode 'source_blocked' -Message "Workspace manifest was not found: $resolvedManifestPath"
    }

    $manifest = Read-JsonFile -Path $resolvedManifestPath
    if ($null -eq $manifest.installer_contract -or $null -eq $manifest.installer_contract.release_client) {
        Throw-ReleaseClientError -ReasonCode 'source_blocked' -Message "Manifest is missing installer_contract.release_client: $resolvedManifestPath"
    }

    $manifestPolicy = $manifest.installer_contract.release_client
    $resolvedPolicyPath = if ([string]::IsNullOrWhiteSpace($PolicyPath)) {
        [string]$manifestPolicy.policy_path
    } else {
        [System.IO.Path]::GetFullPath($PolicyPath)
    }
    if ([string]::IsNullOrWhiteSpace($resolvedPolicyPath)) {
        $resolvedPolicyPath = 'C:\dev\workspace-governance\release-policy.json'
    }

    $policy = Load-EffectivePolicy -ManifestReleaseClient $manifestPolicy -PolicyPath $resolvedPolicyPath
    Assert-ReleaseClientPolicy -Policy $policy

    $statePath = [string]$policy.state_path
    if ([string]::IsNullOrWhiteSpace($statePath)) {
        $statePath = 'C:\dev\artifacts\workspace-release-state.json'
    }

    $resolvedOutputPath = if ([string]::IsNullOrWhiteSpace($OutputPath)) {
        [string]$policy.latest_report_path
    } else {
        [System.IO.Path]::GetFullPath($OutputPath)
    }
    if ([string]::IsNullOrWhiteSpace($resolvedOutputPath)) {
        $resolvedOutputPath = 'C:\dev\artifacts\workspace-release-client-latest.json'
    }

    $installReportPath = Join-Path $WorkspaceRoot 'artifacts\workspace-install-latest.json'

    $report.policy_path = $resolvedPolicyPath
    $report.state_path = $statePath
    $report.install_report_path = $installReportPath

    if ($Mode -eq 'ValidatePolicy') {
        $report.status = 'pass'
        $report.reason_code = 'ok'
        $report.message = 'Release policy validation passed.'
        $report.details.policy = $policy
        Write-JsonFile -Path $resolvedOutputPath -Object $report
        Write-Output ($report | ConvertTo-Json -Depth 30)
        exit 0
    }

    $state = Initialize-ReleaseState -StatePath $statePath

    if ($Mode -eq 'Status') {
        $report.status = 'pass'
        $report.reason_code = 'ok'
        $report.message = 'Release client status resolved from state file.'
        $report.details.state = $state
        Write-JsonFile -Path $resolvedOutputPath -Object $report
        Write-Output ($report | ConvertTo-Json -Depth 30)
        exit 0
    }

    $allowedRepositories = @($policy.allowed_repositories)
    $selectedRepository = if ([string]::IsNullOrWhiteSpace($Repository)) {
        [string]$allowedRepositories[0]
    } else {
        [string]$Repository
    }

    if (-not (Test-ContainsValue -Collection $allowedRepositories -Value $selectedRepository)) {
        Throw-ReleaseClientError -ReasonCode 'source_blocked' -Message "Repository '$selectedRepository' is not in release_client.allowed_repositories."
    }

    $targetTag = [string]$Tag

    if ($Mode -eq 'Rollback') {
        if ($RollbackTo -eq 'previous') {
            $history = @($state.history)
            if ($history.Count -lt 1) {
                Throw-ReleaseClientError -ReasonCode 'source_blocked' -Message 'Rollback requested but no previous release state exists.'
            }
            $targetTag = [string]$history[0].release_tag
            if ([string]::IsNullOrWhiteSpace($Repository) -and -not [string]::IsNullOrWhiteSpace([string]$history[0].repository)) {
                $selectedRepository = [string]$history[0].repository
            }
        } else {
            $targetTag = $RollbackTo
        }
    }

    if ([string]::IsNullOrWhiteSpace($targetTag)) {
        $targetTag = Select-LatestReleaseTag `
            -Repository $selectedRepository `
            -Channel $Channel `
            -CanaryRegex ([string]$policy.channel_rules.canary_tag_regex)
    }

    $releaseViewJson = & gh release view $targetTag -R $selectedRepository --json tagName,isPrerelease,publishedAt,url 2>&1
    if ($LASTEXITCODE -ne 0) {
        Throw-ReleaseClientError -ReasonCode 'asset_missing' -Message "Failed to resolve release '$targetTag' in '$selectedRepository'. $([string]::Join("`n", @($releaseViewJson)))"
    }

    $releaseInfo = $releaseViewJson | ConvertFrom-Json -ErrorAction Stop
    $releaseTag = [string]$releaseInfo.tagName
    $releaseIsPrerelease = [bool]$releaseInfo.isPrerelease
    $releaseUrl = [string]$releaseInfo.url

    $selectedChannel = if ($releaseIsPrerelease) {
        if ($releaseTag -match [string]$policy.channel_rules.canary_tag_regex) { 'canary' } else { 'prerelease' }
    } else {
        'stable'
    }

    if ($Mode -ne 'Rollback') {
        if ($selectedChannel -eq 'prerelease' -and [string]$Channel -eq 'stable') {
            Throw-ReleaseClientError -ReasonCode 'source_blocked' -Message "Stable channel does not allow prerelease target '$releaseTag'."
        }
        if ($selectedChannel -eq 'canary' -and [string]$Channel -ne 'canary') {
            Throw-ReleaseClientError -ReasonCode 'source_blocked' -Message "Canary release '$releaseTag' requires channel canary."
        }
    }

    if ($selectedChannel -eq 'prerelease' -and -not $AllowPrerelease -and [bool]$policy.channel_rules.prerelease_requires_opt_in -and $Mode -eq 'Upgrade') {
        Throw-ReleaseClientError -ReasonCode 'source_blocked' -Message 'Prerelease upgrade requires explicit opt-in.'
    }

    if ($selectedChannel -eq 'canary' -and -not $AllowPrerelease -and [bool]$policy.channel_rules.canary_requires_opt_in -and $Mode -eq 'Upgrade') {
        Throw-ReleaseClientError -ReasonCode 'source_blocked' -Message 'Canary upgrade requires explicit opt-in.'
    }

    $report.repository = $selectedRepository
    $report.release_tag = $releaseTag
    $report.selected_channel = $selectedChannel
    $report.details.release_url = $releaseUrl

    $current = $state.current
    if ($Mode -eq 'Upgrade' -and $null -ne $current) {
        $currentTag = [string]$current.release_tag
        if ($currentTag -eq $releaseTag) {
            $report.status = 'pass'
            $report.reason_code = 'ok'
            $report.message = "Already on release '$releaseTag'."
            $report.details.state = $state
            Write-JsonFile -Path $resolvedOutputPath -Object $report
            Write-Output ($report | ConvertTo-Json -Depth 30)
            exit 0
        }

        $currentSemVer = Get-SemVer -TagName $currentTag
        $targetSemVer = Get-SemVer -TagName $releaseTag
        if ($null -ne $currentSemVer -and $null -ne $targetSemVer) {
            $comparison = Compare-SemVer -Left $targetSemVer -Right $currentSemVer
            if ($comparison -lt 0 -and -not [bool]$policy.upgrade_policy.allow_downgrade) {
                Throw-ReleaseClientError -ReasonCode 'source_blocked' -Message "Downgrade from '$currentTag' to '$releaseTag' is blocked by upgrade policy."
            }

            $majorUpgradeRequested = ($targetSemVer.major -gt $currentSemVer.major)
            if ($majorUpgradeRequested -and -not $AllowMajor -and -not [bool]$policy.upgrade_policy.allow_major_upgrade) {
                Throw-ReleaseClientError -ReasonCode 'source_blocked' -Message "Major upgrade from '$currentTag' to '$releaseTag' requires -AllowMajor."
            }
        }
    }

    $downloadRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("lvie-release-client-{0}" -f ([guid]::NewGuid().ToString('N')))
    Ensure-Directory -Path $downloadRoot

    $releaseManifestPath = Download-ReleaseAsset -Repository $selectedRepository -ReleaseTag $releaseTag -AssetName 'release-manifest.json' -DestinationDirectory $downloadRoot
    $releaseManifest = Read-JsonFile -Path $releaseManifestPath

    if ([string]$releaseManifest.repository -ne $selectedRepository) {
        Throw-ReleaseClientError -ReasonCode 'source_blocked' -Message "Release manifest repository mismatch. expected=$selectedRepository actual=$($releaseManifest.repository)"
    }
    if ([string]$releaseManifest.release_tag -ne $releaseTag) {
        Throw-ReleaseClientError -ReasonCode 'source_blocked' -Message "Release manifest tag mismatch. expected=$releaseTag actual=$($releaseManifest.release_tag)"
    }

    $installerAssetName = [string]$releaseManifest.installer.name
    $shaAssetName = [string]$releaseManifest.installer.sha256_file
    if ([string]::IsNullOrWhiteSpace($installerAssetName)) {
        Throw-ReleaseClientError -ReasonCode 'asset_missing' -Message 'Release manifest is missing installer.name.'
    }
    if ([string]::IsNullOrWhiteSpace($shaAssetName)) {
        $shaAssetName = "$installerAssetName.sha256"
    }

    $installerPath = Download-ReleaseAsset -Repository $selectedRepository -ReleaseTag $releaseTag -AssetName $installerAssetName -DestinationDirectory $downloadRoot
    $shaPath = Download-ReleaseAsset -Repository $selectedRepository -ReleaseTag $releaseTag -AssetName $shaAssetName -DestinationDirectory $downloadRoot

    $spdxAsset = @($releaseManifest.provenance.assets | Where-Object { [string]$_.name -like '*.spdx.json' } | Select-Object -First 1)
    $slsaAsset = @($releaseManifest.provenance.assets | Where-Object { [string]$_.name -like '*.slsa.json' } | Select-Object -First 1)
    $reproAsset = @($releaseManifest.provenance.assets | Where-Object { [string]$_.name -eq 'reproducibility-report.json' } | Select-Object -First 1)

    if ($spdxAsset.Count -ne 1 -or $slsaAsset.Count -ne 1 -or $reproAsset.Count -ne 1) {
        Throw-ReleaseClientError -ReasonCode 'provenance_invalid' -Message 'Release manifest provenance assets are incomplete.'
    }

    $spdxPath = Download-ReleaseAsset -Repository $selectedRepository -ReleaseTag $releaseTag -AssetName ([string]$spdxAsset[0].name) -DestinationDirectory $downloadRoot
    $slsaPath = Download-ReleaseAsset -Repository $selectedRepository -ReleaseTag $releaseTag -AssetName ([string]$slsaAsset[0].name) -DestinationDirectory $downloadRoot
    $reproPath = Download-ReleaseAsset -Repository $selectedRepository -ReleaseTag $releaseTag -AssetName ([string]$reproAsset[0].name) -DestinationDirectory $downloadRoot

    $expectedInstallerSha = ([string]$releaseManifest.installer.sha256).ToLowerInvariant()
    if ($expectedInstallerSha -notmatch '^[0-9a-f]{64}$') {
        Throw-ReleaseClientError -ReasonCode 'provenance_invalid' -Message "Release manifest installer sha256 is invalid: '$expectedInstallerSha'"
    }

    $actualInstallerSha = Resolve-Sha256Hex -Path $installerPath
    if ($actualInstallerSha -ne $expectedInstallerSha) {
        Throw-ReleaseClientError -ReasonCode 'hash_mismatch' -Message "Installer hash mismatch. expected=$expectedInstallerSha actual=$actualInstallerSha"
    }

    $shaFromFile = ((Get-Content -LiteralPath $shaPath -Raw).Split(' ')[0].Trim()).ToLowerInvariant()
    if ($shaFromFile -ne $expectedInstallerSha) {
        Throw-ReleaseClientError -ReasonCode 'hash_mismatch' -Message "Installer SHA file mismatch. expected=$expectedInstallerSha actual=$shaFromFile"
    }

    $signaturePolicy = $policy.signature_policy
    $enforcement = Get-SignatureEnforcement -SignaturePolicy $signaturePolicy -Channel $selectedChannel

    $signature = $null
    if (Get-Command 'Get-AuthenticodeSignature' -ErrorAction SilentlyContinue) {
        $signature = Get-AuthenticodeSignature -FilePath $installerPath
    }

    $signatureStatus = if ($null -ne $signature) { [string]$signature.Status } else { 'CommandUnavailable' }
    $signatureSubject = ''
    $signatureThumbprint = ''
    $signatureTimestampUtc = ''
    if ($null -ne $signature -and $null -ne $signature.SignerCertificate) {
        $signatureSubject = [string]$signature.SignerCertificate.Subject
        $signatureThumbprint = [string]$signature.SignerCertificate.Thumbprint
    }
    if ($null -ne $signature -and $null -ne $signature.TimeStamperCertificate) {
        $signatureTimestampUtc = (Get-Date $signature.TimeStamperCertificate.NotBefore).ToUniversalTime().ToString('o')
    }

    $signatureIsMissing = ($signatureStatus -eq 'NotSigned') -or ($signatureStatus -eq 'CommandUnavailable')
    $signatureIsInvalid = ($signatureStatus -ne 'Valid' -and -not $signatureIsMissing)

    if ([bool]$enforcement.enforce_signature) {
        if ($signatureIsMissing) {
            Throw-ReleaseClientError -ReasonCode 'signature_missing' -Message "Signature is required by policy but missing for '$installerAssetName'."
        }
        if ($signatureIsInvalid) {
            Throw-ReleaseClientError -ReasonCode 'signature_invalid' -Message "Signature status '$signatureStatus' is invalid for required policy."
        }
        if ([bool]$signaturePolicy.require_timestamp -and [string]::IsNullOrWhiteSpace($signatureTimestampUtc)) {
            Throw-ReleaseClientError -ReasonCode 'signature_invalid' -Message 'Timestamped Authenticode signature is required by policy.'
        }
    } else {
        if ($signatureIsMissing -and [bool]$enforcement.warn_if_unsigned) {
            $report.warnings += "Unsigned installer is temporarily allowed until $($enforcement.enforce_at_utc)."
        } elseif ($signatureIsInvalid) {
            $report.warnings += "Installer signature status '$signatureStatus' is not valid and remains in warning window."
        }
    }

    $spdxText = Get-Content -LiteralPath $spdxPath -Raw
    $slsaText = Get-Content -LiteralPath $slsaPath -Raw
    if ($spdxText -notmatch [regex]::Escape($expectedInstallerSha)) {
        Throw-ReleaseClientError -ReasonCode 'provenance_invalid' -Message 'SPDX provenance does not contain installer hash.'
    }
    if ($slsaText -notmatch [regex]::Escape($expectedInstallerSha)) {
        Throw-ReleaseClientError -ReasonCode 'provenance_invalid' -Message 'SLSA provenance does not contain installer hash.'
    }

    $report.details.signature = [ordered]@{
        status = $signatureStatus
        subject = $signatureSubject
        thumbprint = $signatureThumbprint
        timestamp_utc = $signatureTimestampUtc
        enforcement = $enforcement
    }

    $process = Start-Process -FilePath $installerPath -ArgumentList '/S' -Wait -PassThru
    if ([int]$process.ExitCode -ne 0) {
        Throw-ReleaseClientError -ReasonCode 'installer_exit_nonzero' -Message "Installer exited with code $([int]$process.ExitCode)."
    }

    if (-not (Test-Path -LiteralPath $installReportPath -PathType Leaf)) {
        Throw-ReleaseClientError -ReasonCode 'install_report_missing' -Message "Installer report was not found: $installReportPath"
    }

    $newEntry = [ordered]@{
        repository = $selectedRepository
        release_tag = $releaseTag
        channel = $selectedChannel
        installed_at_utc = (Get-Date).ToUniversalTime().ToString('o')
        release_url = $releaseUrl
        installer_sha256 = $expectedInstallerSha
        signature_status = $signatureStatus
        install_report_path = $installReportPath
    }

    if ($null -ne $state.current) {
        $history = @($state.history)
        $history = ,$state.current + $history
        if ($history.Count -gt 20) {
            $history = $history[0..19]
        }
        $state.history = $history
    }

    $state.current = $newEntry
    Save-ReleaseState -StatePath $statePath -State $state

    $report.status = 'pass'
    $report.reason_code = 'ok'
    $report.message = "Release '$releaseTag' installed successfully from '$selectedRepository'."
    $report.details.installer_sha256 = $expectedInstallerSha
    $report.details.release_manifest_path = $releaseManifestPath
    $report.details.assets = [ordered]@{
        installer = $installerPath
        sha256 = $shaPath
        spdx = $spdxPath
        slsa = $slsaPath
        reproducibility = $reproPath
    }

    Write-JsonFile -Path $resolvedOutputPath -Object $report
    Write-Output ($report | ConvertTo-Json -Depth 30)
    $exitCode = 0
} catch {
    $errorMessage = [string]$_.Exception.Message
    $reasonCode = Get-ReasonCodeFromException -Message $errorMessage

    $report.status = 'fail'
    $report.reason_code = $reasonCode
    $report.message = $errorMessage

    if ([string]::IsNullOrWhiteSpace($report.repository)) {
        $report.repository = if ([string]::IsNullOrWhiteSpace($Repository)) { '' } else { $Repository }
    }
    if ([string]::IsNullOrWhiteSpace($report.release_tag)) {
        $report.release_tag = if ([string]::IsNullOrWhiteSpace($Tag)) { '' } else { $Tag }
    }

    if ([string]::IsNullOrWhiteSpace($report.policy_path)) {
        $report.policy_path = if ([string]::IsNullOrWhiteSpace($PolicyPath)) { '' } else { $PolicyPath }
    }
    if ([string]::IsNullOrWhiteSpace($report.install_report_path)) {
        $report.install_report_path = Join-Path $WorkspaceRoot 'artifacts\workspace-install-latest.json'
    }

    $finalOutputPath = if ([string]::IsNullOrWhiteSpace($OutputPath)) {
        if ([string]::IsNullOrWhiteSpace($report.policy_path)) {
            'C:\dev\artifacts\workspace-release-client-latest.json'
        } else {
            Join-Path (Split-Path -Path $report.policy_path -Parent) '..\artifacts\workspace-release-client-latest.json'
        }
    } else {
        [System.IO.Path]::GetFullPath($OutputPath)
    }

    Write-JsonFile -Path $finalOutputPath -Object $report
    Write-Output ($report | ConvertTo-Json -Depth 30)
    $exitCode = 1
}

exit $exitCode
