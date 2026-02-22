#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter()]
    [string]$ManifestPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'workspace-governance.json'),

    [Parameter(Mandatory = $true)]
    [string]$OutputRoot,

    [Parameter()]
    [string]$RepoName = 'labview-icon-editor',

    [Parameter()]
    [string]$Runtime = 'win-x64',

    [Parameter()]
    [bool]$Deterministic = $true,

    [Parameter()]
    [long]$SourceDateEpoch,

    [Parameter()]
    [switch]$KeepTemp
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Ensure-Directory {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        New-Item -Path $Path -ItemType Directory -Force | Out-Null
    }
}

function Convert-ToEpochIso8601 {
    param([Parameter(Mandatory = $true)][long]$EpochSeconds)
    return [DateTimeOffset]::FromUnixTimeSeconds($EpochSeconds).UtcDateTime.ToString('o')
}

function Convert-ToPathSafeSegment {
    param(
        [Parameter(Mandatory = $true)][string]$Value,
        [Parameter()][int]$MaxLength = 64
    )

    $safe = $Value -replace '[^A-Za-z0-9._-]', '-'
    $safe = $safe -replace '-{2,}', '-'
    $safe = $safe.Trim('-')
    if ([string]::IsNullOrWhiteSpace($safe)) {
        $safe = 'segment'
    }
    if ($safe.Length -gt $MaxLength) {
        $safe = $safe.Substring(0, $MaxLength)
    }
    return $safe
}

function Get-TempBasePath {
    if (-not [string]::IsNullOrWhiteSpace($env:RUNNER_TEMP)) {
        return [System.IO.Path]::GetFullPath($env:RUNNER_TEMP)
    }
    if (-not [string]::IsNullOrWhiteSpace($env:TEMP)) {
        return [System.IO.Path]::GetFullPath($env:TEMP)
    }
    throw "Neither RUNNER_TEMP nor TEMP is set. Cannot allocate temporary workspace."
}

function Get-IsolationToken {
    $seed = [string]::Join(
        '|',
        @(
            [string]$env:GITHUB_RUN_ID,
            [string]$env:GITHUB_JOB,
            [string]$env:RUNNER_NAME,
            [string]$PID,
            [guid]::NewGuid().ToString('N')
        )
    )

    $hashAlgorithm = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($seed)
        $hashBytes = $hashAlgorithm.ComputeHash($bytes)
    } finally {
        $hashAlgorithm.Dispose()
    }

    $hash = [System.BitConverter]::ToString($hashBytes).Replace('-', '').ToLowerInvariant()
    return $hash.Substring(0, 12)
}

function Remove-Directory {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter()][switch]$BestEffort
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        return
    }

    try {
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
    } catch {
        if ($BestEffort) {
            Write-Warning "Failed to remove temporary directory '$Path': $($_.Exception.Message)"
            return
        }
        throw
    }
}

function Get-PinnedSdkVersion {
    param([Parameter(Mandatory = $true)][string]$RepoRoot)

    $globalJsonPath = Join-Path $RepoRoot 'global.json'
    if (-not (Test-Path -LiteralPath $globalJsonPath -PathType Leaf)) {
        throw "SDK contract file not found: $globalJsonPath"
    }

    $globalJson = Get-Content -LiteralPath $globalJsonPath -Raw | ConvertFrom-Json -ErrorAction Stop
    $sdkVersion = [string]$globalJson.sdk.version
    if ([string]::IsNullOrWhiteSpace($sdkVersion)) {
        throw "global.json is missing sdk.version: $globalJsonPath"
    }

    return $sdkVersion
}

function Assert-DotnetSdkContract {
    param(
        [Parameter(Mandatory = $true)][string]$PinnedSdkVersion
    )

    $installed = (& dotnet --version).Trim()
    if ([string]::IsNullOrWhiteSpace($installed)) {
        throw "dotnet --version returned empty output."
    }

    try {
        $pinnedVersion = [version]$PinnedSdkVersion
        $installedVersion = [version]$installed
    } catch {
        throw "Failed to parse SDK versions. pinned='$PinnedSdkVersion' installed='$installed'"
    }

    if (($installedVersion.Major -ne $pinnedVersion.Major) -or ($installedVersion.Minor -ne $pinnedVersion.Minor)) {
        throw "Installed dotnet SDK '$installed' does not satisfy pinned major/minor '$($pinnedVersion.Major).$($pinnedVersion.Minor)' from global.json."
    }

    return $installed
}

function Get-CommitUnixEpoch {
    param(
        [Parameter(Mandatory = $true)][string]$RepoPath,
        [Parameter(Mandatory = $true)][string]$CommitSha
    )

    $epochRaw = & git -C $RepoPath show -s --format=%ct $CommitSha 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to resolve commit epoch for '$CommitSha'. $([string]::Join("`n", @($epochRaw)))"
    }

    $epochText = [string]$epochRaw.Trim()
    $epoch = 0L
    if (-not [long]::TryParse($epochText, [ref]$epoch)) {
        throw "Commit epoch is not numeric for '$CommitSha': $epochText"
    }

    return $epoch
}

$resolvedManifestPath = [System.IO.Path]::GetFullPath($ManifestPath)
$resolvedOutputRoot = [System.IO.Path]::GetFullPath($OutputRoot)
$repoRoot = (Resolve-Path -Path (Join-Path $PSScriptRoot '..')).Path

foreach ($commandName in @('git', 'dotnet')) {
    if (-not (Get-Command $commandName -ErrorAction SilentlyContinue)) {
        throw "Required command '$commandName' was not found on PATH."
    }
}

$pinnedSdkVersion = Get-PinnedSdkVersion -RepoRoot $repoRoot
$installedSdkVersion = Assert-DotnetSdkContract -PinnedSdkVersion $pinnedSdkVersion

if (-not (Test-Path -LiteralPath $resolvedManifestPath -PathType Leaf)) {
    throw "Manifest not found: $resolvedManifestPath"
}

$manifest = Get-Content -LiteralPath $resolvedManifestPath -Raw | ConvertFrom-Json -ErrorAction Stop
$repoEntry = @($manifest.managed_repos | Where-Object { [string]$_.repo_name -eq $RepoName }) | Select-Object -First 1
if ($null -eq $repoEntry) {
    throw "Manifest does not include repo entry '$RepoName': $resolvedManifestPath"
}

$sourceUrl = [string]$repoEntry.required_remotes.origin
$pinnedSha = ([string]$repoEntry.pinned_sha).ToLowerInvariant()
$sourceRepo = [string]$repoEntry.required_gh_repo

if ([string]::IsNullOrWhiteSpace($sourceUrl)) {
    throw "Manifest repo '$RepoName' has no required_remotes.origin URL."
}
if ($pinnedSha -notmatch '^[0-9a-f]{40}$') {
    throw "Manifest repo '$RepoName' has invalid pinned_sha '$pinnedSha'."
}

$epoch = if ($PSBoundParameters.ContainsKey('SourceDateEpoch')) { $SourceDateEpoch } else { 0L }
$tempBasePath = Get-TempBasePath
Ensure-Directory -Path $tempBasePath
$tempRoot = Join-Path $tempBasePath (
    "lvie-runner-cli-bundle-{0}-{1}-{2}-{3}" -f
    (Convert-ToPathSafeSegment -Value $RepoName -MaxLength 24),
    $pinnedSha.Substring(0, 12),
    (Convert-ToPathSafeSegment -Value $Runtime -MaxLength 24),
    (Get-IsolationToken)
)
$cloneRoot = Join-Path $tempRoot 'src'
$publishRoot = Join-Path $tempRoot 'publish'
if (Test-Path -LiteralPath $tempRoot -PathType Container) {
    Remove-Directory -Path $tempRoot
}
Ensure-Directory -Path $cloneRoot
Ensure-Directory -Path $publishRoot

try {
    & git clone --no-tags $sourceUrl $cloneRoot
    if ($LASTEXITCODE -ne 0) {
        throw "git clone failed for '$sourceUrl'."
    }

    & git -C $cloneRoot checkout --detach $pinnedSha
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to checkout pinned SHA '$pinnedSha' in cloned source."
    }

    if (($epoch -le 0) -and $Deterministic) {
        $epoch = Get-CommitUnixEpoch -RepoPath $cloneRoot -CommitSha $pinnedSha
    }
    if ($epoch -le 0) {
        $epoch = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    }

    $csproj = Join-Path $cloneRoot 'Tooling\runner-cli\RunnerCli\RunnerCli.csproj'
    if (-not (Test-Path -LiteralPath $csproj -PathType Leaf)) {
        throw "runner-cli project file not found in source: $csproj"
    }

    $env:SOURCE_DATE_EPOCH = "$epoch"
    $env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'
    $publishArgs = @(
        'publish', $csproj,
        '--configuration', 'Release',
        '--runtime', $Runtime,
        '--self-contained', 'true',
        '-p:PublishSingleFile=true',
        '-p:PublishTrimmed=true',
        '-p:GenerateDocumentationFile=false',
        '-p:DebugSymbols=false',
        '--output', $publishRoot
    )
    if ($Deterministic) {
        $publishArgs += @(
            '-p:Deterministic=true',
            '-p:ContinuousIntegrationBuild=true',
            ("-p:PathMap={0}=/src" -f $cloneRoot),
            ("-p:RepositoryCommit={0}" -f $pinnedSha),
            ("-p:RepositoryUrl={0}" -f $sourceUrl),
            '-p:DebugType=None'
        )
    }

    & dotnet @publishArgs
    if ($LASTEXITCODE -ne 0) {
        throw "dotnet publish failed for runner-cli ($Runtime)."
    }

    $exeName = if ($Runtime.StartsWith('win-')) { 'runner-cli.exe' } else { 'runner-cli' }
    $publishedExe = Join-Path $publishRoot $exeName
    if (-not (Test-Path -LiteralPath $publishedExe -PathType Leaf)) {
        throw "Published runner-cli binary was not found: $publishedExe"
    }

    Ensure-Directory -Path $resolvedOutputRoot
    $bundleExePath = Join-Path $resolvedOutputRoot 'runner-cli.exe'
    $bundleShaPath = Join-Path $resolvedOutputRoot 'runner-cli.exe.sha256'
    $bundleMetadataPath = Join-Path $resolvedOutputRoot 'runner-cli.metadata.json'

    Copy-Item -LiteralPath $publishedExe -Destination $bundleExePath -Force

    $sha256 = (Get-FileHash -LiteralPath $bundleExePath -Algorithm SHA256).Hash.ToLowerInvariant()
    "{0} *{1}" -f $sha256, (Split-Path -Path $bundleExePath -Leaf) | Set-Content -LiteralPath $bundleShaPath -Encoding ascii

    $metadata = [ordered]@{
        source_repo = $sourceRepo
        source_url = $sourceUrl
        source_commit = $pinnedSha
        runtime = $Runtime
        deterministic = [bool]$Deterministic
        build_epoch_unix = $epoch
        build_epoch_utc = (Convert-ToEpochIso8601 -EpochSeconds $epoch)
        sdk_contract = [ordered]@{
            global_json_version = $pinnedSdkVersion
            installed_dotnet_version = $installedSdkVersion
        }
        publish_command = ("dotnet {0}" -f ($publishArgs -join ' '))
        output_file = 'runner-cli.exe'
        output_sha256 = $sha256
    }
    $metadata | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $bundleMetadataPath -Encoding UTF8

    [pscustomobject]@{
        repo_name = $RepoName
        source_repo = $sourceRepo
        source_url = $sourceUrl
        source_commit = $pinnedSha
        runtime = $Runtime
        deterministic = [bool]$Deterministic
        build_epoch_unix = $epoch
        build_epoch_utc = (Convert-ToEpochIso8601 -EpochSeconds $epoch)
        output_root = $resolvedOutputRoot
        executable = $bundleExePath
        sha256_file = $bundleShaPath
        metadata_file = $bundleMetadataPath
        sha256 = $sha256
    } | ConvertTo-Json -Depth 8 | Write-Output
} finally {
    if (-not $KeepTemp -and (Test-Path -LiteralPath $tempRoot -PathType Container)) {
        Remove-Directory -Path $tempRoot -BestEffort
    }
}
