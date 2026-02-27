#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Repository,

    [Parameter(Mandatory = $true)]
    [string]$ReleaseTag,

    [Parameter()]
    [ValidateSet('stable', 'prerelease', 'canary')]
    [string]$Channel = 'stable',

    [Parameter(Mandatory = $true)]
    [string]$InstallerPath,

    [Parameter(Mandatory = $true)]
    [string]$InstallerSha256,

    [Parameter(Mandatory = $true)]
    [string]$InstallerShaPath,

    [Parameter(Mandatory = $true)]
    [string]$SpdxPath,

    [Parameter(Mandatory = $true)]
    [string]$SlsaPath,

    [Parameter(Mandatory = $true)]
    [string]$ReproducibilityPath,

    [Parameter(Mandatory = $true)]
    [string]$OutputPath,

    [Parameter()]
    [string]$InstallCommand = 'lvie-cdev-workspace-installer.exe /S',

    [Parameter()]
    [string]$PublishedAtUtc = '',

    [Parameter()]
    [string]$SignatureStatus = 'not_signed',

    [Parameter()]
    [string]$SignatureSubject = '',

    [Parameter()]
    [string]$SignatureThumbprint = '',

    [Parameter()]
    [string]$SignatureTimestampUtc = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-Sha256Hex {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $resolved = (Resolve-Path -LiteralPath $Path).Path
    return (Get-FileHash -LiteralPath $resolved -Algorithm SHA256).Hash.ToLowerInvariant()
}

function New-ProvenanceAsset {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [string]$Repository,
        [Parameter(Mandatory = $true)]
        [string]$ReleaseTag
    )

    $resolved = (Resolve-Path -LiteralPath $Path).Path
    $name = [System.IO.Path]::GetFileName($resolved)
    [ordered]@{
        name = $name
        sha256 = Get-Sha256Hex -Path $resolved
        url = "https://github.com/$Repository/releases/download/$ReleaseTag/$name"
    }
}

$resolvedInstallerPath = (Resolve-Path -LiteralPath $InstallerPath).Path
$resolvedInstallerShaPath = (Resolve-Path -LiteralPath $InstallerShaPath).Path
$resolvedSpdxPath = (Resolve-Path -LiteralPath $SpdxPath).Path
$resolvedSlsaPath = (Resolve-Path -LiteralPath $SlsaPath).Path
$resolvedReproPath = (Resolve-Path -LiteralPath $ReproducibilityPath).Path

foreach ($requiredPath in @($resolvedInstallerPath, $resolvedInstallerShaPath, $resolvedSpdxPath, $resolvedSlsaPath, $resolvedReproPath)) {
    if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
        throw "Required release asset was not found: $requiredPath"
    }
}

$normalizedSha = ([string]$InstallerSha256).ToLowerInvariant()
if ($normalizedSha -notmatch '^[0-9a-f]{64}$') {
    throw "Installer SHA256 is invalid: '$InstallerSha256'"
}

$installerName = [System.IO.Path]::GetFileName($resolvedInstallerPath)
$installerShaName = [System.IO.Path]::GetFileName($resolvedInstallerShaPath)
$publishedAt = if ([string]::IsNullOrWhiteSpace($PublishedAtUtc)) {
    (Get-Date).ToUniversalTime().ToString('o')
} else {
    [DateTime]::Parse($PublishedAtUtc).ToUniversalTime().ToString('o')
}

$provenanceAssets = @(
    (New-ProvenanceAsset -Path $resolvedSpdxPath -Repository $Repository -ReleaseTag $ReleaseTag),
    (New-ProvenanceAsset -Path $resolvedSlsaPath -Repository $Repository -ReleaseTag $ReleaseTag),
    (New-ProvenanceAsset -Path $resolvedReproPath -Repository $Repository -ReleaseTag $ReleaseTag)
)

$releaseManifest = [ordered]@{
    schema_version = '1.0'
    repository = $Repository
    release_tag = $ReleaseTag
    channel = $Channel
    published_at_utc = $publishedAt
    installer = [ordered]@{
        name = $installerName
        url = "https://github.com/$Repository/releases/download/$ReleaseTag/$installerName"
        sha256 = $normalizedSha
        sha256_file = $installerShaName
        signature = [ordered]@{
            provider = 'authenticode'
            status = $SignatureStatus
            subject = $SignatureSubject
            thumbprint = $SignatureThumbprint
            timestamp_utc = $SignatureTimestampUtc
        }
    }
    provenance = [ordered]@{
        required = $true
        assets = $provenanceAssets
    }
    install_command = $InstallCommand
    compatibility = [ordered]@{
        windows_only = $true
        minimum_powershell = '5.1'
        release_client_mode = 'policy-driven'
    }
    rollback = [ordered]@{
        strategy = 'state-file-previous-or-tag'
        state_path = 'C:\\dev\\artifacts\\workspace-release-state.json'
    }
}

$outputDirectory = Split-Path -Path $OutputPath -Parent
if (-not [string]::IsNullOrWhiteSpace($outputDirectory) -and -not (Test-Path -LiteralPath $outputDirectory -PathType Container)) {
    New-Item -Path $outputDirectory -ItemType Directory -Force | Out-Null
}

$releaseManifest | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $OutputPath -Encoding utf8
Write-Host "Release manifest written: $OutputPath"
