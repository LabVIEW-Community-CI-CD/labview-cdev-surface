[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$PayloadRoot,

    [Parameter(Mandatory = $true)]
    [string]$OutputPath,

    [Parameter(Mandatory = $false)]
    [string]$WorkspaceRootDefault = 'C:\dev',

    [Parameter(Mandatory = $false)]
    [string]$RequiredLabviewYear = '2020',

    [Parameter(Mandatory = $false)]
    [ValidateSet('NsisInstall', 'LocalInstallerExercise', 'ContainerSmoke')]
    [string]$InstallerExecutionContext = 'NsisInstall',

    [Parameter(Mandatory = $false)]
    [string]$NsisScriptPath,

    [Parameter(Mandatory = $false)]
    [string]$MakensisPath,

    [Parameter(Mandatory = $false)]
    [string]$NsisRoot = 'C:\Program Files (x86)\NSIS',

    [Parameter(Mandatory = $false)]
    [bool]$Deterministic = $true,

    [Parameter(Mandatory = $false)]
    [long]$SourceDateEpoch,

    [Parameter(Mandatory = $false)]
    [switch]$VerifyDeterminism,

    [Parameter(Mandatory = $false)]
    [string]$DeterminismReportPath
)

Set-StrictMode -Version Latest
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

function Convert-ToEpochIso8601 {
    param([Parameter(Mandatory = $true)][long]$EpochSeconds)
    return [DateTimeOffset]::FromUnixTimeSeconds($EpochSeconds).UtcDateTime.ToString('o')
}

function Get-Sha256Hex {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "File not found for hashing: $Path"
    }

    $hashCmd = Get-Command 'Get-FileHash' -ErrorAction SilentlyContinue
    if ($null -ne $hashCmd) {
        return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    }

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $stream = [System.IO.File]::OpenRead($Path)
        try {
            $hashBytes = $sha.ComputeHash($stream)
        } finally {
            $stream.Dispose()
        }
    } finally {
        $sha.Dispose()
    }

    return ([System.BitConverter]::ToString($hashBytes).Replace('-', '').ToLowerInvariant())
}

function Resolve-SourceDateEpoch {
    param(
        [Parameter(Mandatory = $true)][string]$PayloadRoot,
        [Parameter(Mandatory = $true)][bool]$DeterministicBuild,
        [Parameter()][long]$ExplicitEpoch
    )

    if ($PSBoundParameters.ContainsKey('ExplicitEpoch') -and $ExplicitEpoch -gt 0) {
        return $ExplicitEpoch
    }

    if (-not $DeterministicBuild) {
        return [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    }

    $metadataPath = Join-Path $PayloadRoot 'tools\runner-cli\win-x64\runner-cli.metadata.json'
    if (Test-Path -LiteralPath $metadataPath -PathType Leaf) {
        try {
            $metadata = Get-Content -LiteralPath $metadataPath -Raw | ConvertFrom-Json -ErrorAction Stop
            $epoch = 0L
            if ([long]::TryParse([string]$metadata.build_epoch_unix, [ref]$epoch) -and $epoch -gt 0) {
                return $epoch
            }
        } catch {
            throw "Failed to parse runner-cli metadata for SourceDateEpoch: $metadataPath"
        }
    }

    Write-Warning "Unable to resolve deterministic SourceDateEpoch from payload metadata. Falling back to current UTC epoch."
    return [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
}

function Set-DirectoryTreeTimestamp {
    param(
        [Parameter(Mandatory = $true)][string]$RootPath,
        [Parameter(Mandatory = $true)][long]$EpochSeconds
    )

    $utc = [DateTimeOffset]::FromUnixTimeSeconds($EpochSeconds).UtcDateTime
    foreach ($file in Get-ChildItem -LiteralPath $RootPath -Recurse -File) {
        $file.LastWriteTimeUtc = $utc
    }
    foreach ($dir in Get-ChildItem -LiteralPath $RootPath -Recurse -Directory) {
        $dir.LastWriteTimeUtc = $utc
    }
    (Get-Item -LiteralPath $RootPath).LastWriteTimeUtc = $utc
}

function Normalize-PeTimestamp {
    param(
        [Parameter(Mandatory = $true)][string]$ExecutablePath,
        [Parameter(Mandatory = $true)][long]$EpochSeconds
    )

    if (-not (Test-Path -LiteralPath $ExecutablePath -PathType Leaf)) {
        throw "PE normalization target not found: $ExecutablePath"
    }

    $bytes = [System.IO.File]::ReadAllBytes($ExecutablePath)
    if ($bytes.Length -lt 0x40) {
        throw "File is too small to be a PE executable: $ExecutablePath"
    }

    $peOffset = [BitConverter]::ToInt32($bytes, 0x3C)
    if ($peOffset -lt 0 -or ($peOffset + 0x0C) -gt $bytes.Length) {
        throw "Invalid PE header offset in '$ExecutablePath'."
    }

    $signature = [System.Text.Encoding]::ASCII.GetString($bytes, $peOffset, 4)
    if ($signature -ne "PE$([char]0)$([char]0)") {
        throw "Invalid PE signature in '$ExecutablePath'."
    }

    $timestampOffset = $peOffset + 8
    $timestampBytes = [BitConverter]::GetBytes([uint32]$EpochSeconds)
    [Array]::Copy($timestampBytes, 0, $bytes, $timestampOffset, 4)
    [System.IO.File]::WriteAllBytes($ExecutablePath, $bytes)
}

function Prepare-StagedPayload {
    param(
        [Parameter(Mandatory = $true)][string]$SourcePayloadRoot,
        [Parameter(Mandatory = $true)][string]$StagingPath,
        [Parameter(Mandatory = $true)][bool]$DeterministicBuild,
        [Parameter(Mandatory = $true)][long]$EpochSeconds
    )

    if (Test-Path -LiteralPath $StagingPath -PathType Container) {
        Remove-Item -LiteralPath $StagingPath -Recurse -Force
    }
    New-Item -Path $StagingPath -ItemType Directory -Force | Out-Null

    Copy-Item -Path (Join-Path $SourcePayloadRoot '*') -Destination $StagingPath -Recurse -Force

    if ($DeterministicBuild) {
        Set-DirectoryTreeTimestamp -RootPath $StagingPath -EpochSeconds $EpochSeconds
    }
}

function Invoke-NsisBuild {
    param(
        [Parameter(Mandatory = $true)][string]$MakensisPathResolved,
        [Parameter(Mandatory = $true)][string]$ScriptPathResolved,
        [Parameter(Mandatory = $true)][string]$StagedPayloadPath,
        [Parameter(Mandatory = $true)][string]$OutputInstallerPath,
        [Parameter(Mandatory = $true)][string]$WorkspaceRoot,
        [Parameter(Mandatory = $true)][string]$LabviewYear,
        [Parameter(Mandatory = $true)][string]$InstallExecutionContext,
        [Parameter(Mandatory = $true)][bool]$DeterministicBuild,
        [Parameter(Mandatory = $true)][long]$EpochSeconds
    )

    $args = @(
        '/V3',
        ("/DOUT_FILE=$OutputInstallerPath"),
        ("/DPAYLOAD_DIR=$StagedPayloadPath"),
        ("/DWORKSPACE_ROOT=$WorkspaceRoot"),
        ("/DREQUIRED_LABVIEW_YEAR=$LabviewYear"),
        ("/DINSTALL_EXEC_CONTEXT=$InstallExecutionContext"),
        ("/DSOURCE_DATE_EPOCH=$EpochSeconds"),
        $ScriptPathResolved
    )

    & $MakensisPathResolved @args
    if ($LASTEXITCODE -ne 0) {
        throw "makensis failed with exit code $LASTEXITCODE"
    }

    if (-not (Test-Path -LiteralPath $OutputInstallerPath -PathType Leaf)) {
        throw "Workspace installer output not found at $OutputInstallerPath"
    }

    if ($DeterministicBuild) {
        Normalize-PeTimestamp -ExecutablePath $OutputInstallerPath -EpochSeconds $EpochSeconds
    }
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
$epoch = Resolve-SourceDateEpoch -PayloadRoot $resolvedPayloadRoot -DeterministicBuild $Deterministic -ExplicitEpoch $SourceDateEpoch

$tempRoot = Join-Path $env:TEMP ("lvie-installer-build-{0}" -f ([guid]::NewGuid().ToString('n')))
New-Item -Path $tempRoot -ItemType Directory -Force | Out-Null

try {
    if ($VerifyDeterminism) {
        $buildResults = @()
        foreach ($index in 1..2) {
            $stagePath = Join-Path $tempRoot ("payload-{0}" -f $index)
            $outputPath = Join-Path $tempRoot ("installer-{0}.exe" -f $index)
            Prepare-StagedPayload -SourcePayloadRoot $resolvedPayloadRoot -StagingPath $stagePath -DeterministicBuild $Deterministic -EpochSeconds $epoch
            Invoke-NsisBuild `
                -MakensisPathResolved $makensis `
                -ScriptPathResolved $resolvedScriptPath `
                -StagedPayloadPath $stagePath `
                -OutputInstallerPath $outputPath `
                -WorkspaceRoot $WorkspaceRootDefault `
                -LabviewYear $RequiredLabviewYear `
                -InstallExecutionContext $InstallerExecutionContext `
                -DeterministicBuild $Deterministic `
                -EpochSeconds $epoch
            $hash = Get-Sha256Hex -Path $outputPath
            $buildResults += [pscustomobject]@{
                build_index = $index
                output_path = $outputPath
                sha256 = $hash
            }
        }

        if ($buildResults[0].sha256 -ne $buildResults[1].sha256) {
            throw "Determinism verification failed. Build hashes differ: '$($buildResults[0].sha256)' vs '$($buildResults[1].sha256)'."
        }

        Copy-Item -LiteralPath $buildResults[0].output_path -Destination $resolvedOutputPath -Force

        if (-not [string]::IsNullOrWhiteSpace($DeterminismReportPath)) {
            $reportPath = [System.IO.Path]::GetFullPath($DeterminismReportPath)
            $reportDir = Split-Path -Path $reportPath -Parent
            if (-not [string]::IsNullOrWhiteSpace($reportDir)) {
                New-Item -Path $reportDir -ItemType Directory -Force | Out-Null
            }
            [ordered]@{
                status = 'pass'
                deterministic = [bool]$Deterministic
                source_date_epoch = $epoch
                source_date_utc = (Convert-ToEpochIso8601 -EpochSeconds $epoch)
                output_path = $resolvedOutputPath
                output_sha256 = $buildResults[0].sha256
                comparisons = $buildResults
            } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $reportPath -Encoding utf8
        }
    } else {
        $stagePath = Join-Path $tempRoot 'payload'
        Prepare-StagedPayload -SourcePayloadRoot $resolvedPayloadRoot -StagingPath $stagePath -DeterministicBuild $Deterministic -EpochSeconds $epoch
        Invoke-NsisBuild `
            -MakensisPathResolved $makensis `
            -ScriptPathResolved $resolvedScriptPath `
            -StagedPayloadPath $stagePath `
            -OutputInstallerPath $resolvedOutputPath `
            -WorkspaceRoot $WorkspaceRootDefault `
            -LabviewYear $RequiredLabviewYear `
            -InstallExecutionContext $InstallerExecutionContext `
            -DeterministicBuild $Deterministic `
            -EpochSeconds $epoch

        if (-not [string]::IsNullOrWhiteSpace($DeterminismReportPath)) {
            $reportPath = [System.IO.Path]::GetFullPath($DeterminismReportPath)
            $reportDir = Split-Path -Path $reportPath -Parent
            if (-not [string]::IsNullOrWhiteSpace($reportDir)) {
                New-Item -Path $reportDir -ItemType Directory -Force | Out-Null
            }
            $outputHash = Get-Sha256Hex -Path $resolvedOutputPath
            [ordered]@{
                status = 'pass'
                deterministic = [bool]$Deterministic
                source_date_epoch = $epoch
                source_date_utc = (Convert-ToEpochIso8601 -EpochSeconds $epoch)
                output_path = $resolvedOutputPath
                output_sha256 = $outputHash
            } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $reportPath -Encoding utf8
        }
    }
} finally {
    if (Test-Path -LiteralPath $tempRoot -PathType Container) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force
    }
}

Write-Output $resolvedOutputPath
