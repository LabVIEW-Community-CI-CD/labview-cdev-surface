#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$PayloadRoot,

    [Parameter(Mandatory = $true)]
    [string]$OutputPath,

    [Parameter(Mandatory = $false)]
    [string]$WorkspaceRootDefault = 'C:\dev',

    [Parameter(Mandatory = $false)]
    [string]$NsisScriptPath,

    [Parameter(Mandatory = $false)]
    [string]$MakensisPath,

    [Parameter(Mandatory = $false)]
    [string]$NsisRoot = 'C:\Program Files (x86)\NSIS'
)

$ErrorActionPreference = 'Stop'

function Resolve-MakensisPath {
    param(
        [Parameter(Mandatory = $false)]
        [string]$Override,

        [Parameter(Mandatory = $false)]
        [string]$Root
    )

    if (-not [string]::IsNullOrWhiteSpace($Override)) {
        if (-not (Test-Path -LiteralPath $Override -PathType Leaf)) {
            throw "makensis not found at override path: $Override"
        }
        return (Resolve-Path -LiteralPath $Override).Path
    }

    $resolvedRoot = if (-not [string]::IsNullOrWhiteSpace($Root)) {
        [System.IO.Path]::GetFullPath($Root)
    } else {
        'C:\Program Files (x86)\NSIS'
    }

    $candidate = Join-Path $resolvedRoot 'makensis.exe'
    if (Test-Path -LiteralPath $candidate -PathType Leaf) {
        return $candidate
    }

    throw ("Required NSIS binary not found at '{0}'. Install NSIS to '{1}' or pass -MakensisPath <full-path>." -f $candidate, $resolvedRoot)
}

$resolvedPayloadRoot = (Resolve-Path -LiteralPath $PayloadRoot).Path
if (-not (Test-Path -LiteralPath $resolvedPayloadRoot -PathType Container)) {
    throw "Payload root not found: $resolvedPayloadRoot"
}

$resolvedOutputPath = [System.IO.Path]::GetFullPath($OutputPath)
$outputDirectory = Split-Path -Path $resolvedOutputPath -Parent
if (-not [string]::IsNullOrWhiteSpace($outputDirectory)) {
    New-Item -Path $outputDirectory -ItemType Directory -Force | Out-Null
}

$resolvedScriptPath = if ([string]::IsNullOrWhiteSpace($NsisScriptPath)) {
    Join-Path (Split-Path -Parent $PSScriptRoot) 'nsis\workspace-bootstrap-installer.nsi'
} else {
    [System.IO.Path]::GetFullPath($NsisScriptPath)
}

if (-not (Test-Path -LiteralPath $resolvedScriptPath -PathType Leaf)) {
    throw "NSIS script not found: $resolvedScriptPath"
}

$makensis = Resolve-MakensisPath -Override $MakensisPath -Root $NsisRoot
Write-Host ("Using makensis at {0}" -f $makensis)

$args = @(
    '/V3',
    ("/DOUT_FILE=$resolvedOutputPath"),
    ("/DPAYLOAD_DIR=$resolvedPayloadRoot"),
    ("/DWORKSPACE_ROOT=$WorkspaceRootDefault"),
    $resolvedScriptPath
)

& $makensis @args
if ($LASTEXITCODE -ne 0) {
    throw "makensis failed with exit code $LASTEXITCODE"
}

if (-not (Test-Path -LiteralPath $resolvedOutputPath -PathType Leaf)) {
    throw "Workspace installer output not found at $resolvedOutputPath"
}

Write-Output $resolvedOutputPath
