#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$InstallerPath,

    [Parameter(Mandatory = $true)]
    [string]$RunnerCliPath,

    [Parameter(Mandatory = $true)]
    [string]$ManifestPath,

    [Parameter(Mandatory = $true)]
    [string]$OutputDirectory,

    [Parameter()]
    [string]$BuilderId = 'https://github.com/LabVIEW-Community-CI-CD/labview-cdev-surface/.github/workflows/release-workspace-installer.yml'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Ensure-Directory {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        New-Item -Path $Path -ItemType Directory -Force | Out-Null
    }
}

function New-Subject {
    param([Parameter(Mandatory = $true)][string]$FilePath)
    $resolved = [System.IO.Path]::GetFullPath($FilePath)
    if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
        throw "Provenance subject not found: $resolved"
    }
    $hash = (Get-FileHash -LiteralPath $resolved -Algorithm SHA256).Hash.ToLowerInvariant()
    return [pscustomobject]@{
        name = (Split-Path -Path $resolved -Leaf)
        path = $resolved
        sha256 = $hash
    }
}

$resolvedInstaller = [System.IO.Path]::GetFullPath($InstallerPath)
$resolvedRunnerCli = [System.IO.Path]::GetFullPath($RunnerCliPath)
$resolvedManifest = [System.IO.Path]::GetFullPath($ManifestPath)
$resolvedOutputDir = [System.IO.Path]::GetFullPath($OutputDirectory)
Ensure-Directory -Path $resolvedOutputDir

$subjects = @(
    (New-Subject -FilePath $resolvedInstaller),
    (New-Subject -FilePath $resolvedRunnerCli),
    (New-Subject -FilePath $resolvedManifest)
)

$timestamp = (Get-Date).ToUniversalTime().ToString('o')
$spdxPath = Join-Path $resolvedOutputDir 'workspace-installer.spdx.json'
$slsaPath = Join-Path $resolvedOutputDir 'workspace-installer.slsa.json'
$summaryPath = Join-Path $resolvedOutputDir 'workspace-installer.provenance-summary.json'

$spdxFiles = @()
foreach ($subject in $subjects) {
    $spdxFiles += [ordered]@{
        fileName = $subject.path
        SPDXID = ('SPDXRef-File-{0}' -f $subject.name.Replace('.', '-'))
        checksums = @(
            [ordered]@{
                algorithm = 'SHA256'
                checksumValue = $subject.sha256
            }
        )
    }
}

$spdx = [ordered]@{
    spdxVersion = 'SPDX-2.3'
    dataLicense = 'CC0-1.0'
    SPDXID = 'SPDXRef-DOCUMENT'
    name = 'lvie-cdev-workspace-installer'
    documentNamespace = ("https://github.com/LabVIEW-Community-CI-CD/labview-cdev-surface/spdx/{0}" -f [guid]::NewGuid().ToString())
    creationInfo = [ordered]@{
        created = $timestamp
        creators = @('Tool: labview-cdev-surface/Write-ReleaseProvenance.ps1')
    }
    files = $spdxFiles
}

$slsaSubjects = @()
foreach ($subject in $subjects) {
    $slsaSubjects += [ordered]@{
        name = $subject.name
        digest = [ordered]@{
            sha256 = $subject.sha256
        }
    }
}

$slsa = [ordered]@{
    _type = 'https://in-toto.io/Statement/v1'
    predicateType = 'https://slsa.dev/provenance/v1'
    subject = $slsaSubjects
    predicate = [ordered]@{
        buildDefinition = [ordered]@{
            buildType = 'https://github.com/LabVIEW-Community-CI-CD/labview-cdev-surface/workspace-installer'
            externalParameters = [ordered]@{
                manifest_path = $resolvedManifest
                installer_path = $resolvedInstaller
                runner_cli_path = $resolvedRunnerCli
            }
        }
        runDetails = [ordered]@{
            builder = [ordered]@{
                id = $BuilderId
            }
            metadata = [ordered]@{
                invocation_id = [guid]::NewGuid().ToString()
                started_on = $timestamp
                finished_on = $timestamp
            }
        }
    }
}

$spdx | ConvertTo-Json -Depth 14 | Set-Content -LiteralPath $spdxPath -Encoding utf8
$slsa | ConvertTo-Json -Depth 14 | Set-Content -LiteralPath $slsaPath -Encoding utf8

[ordered]@{
    timestamp_utc = $timestamp
    status = 'pass'
    spdx_path = $spdxPath
    slsa_path = $slsaPath
    subjects = $subjects
} | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $summaryPath -Encoding utf8

Write-Host "Provenance summary: $summaryPath"
exit 0
