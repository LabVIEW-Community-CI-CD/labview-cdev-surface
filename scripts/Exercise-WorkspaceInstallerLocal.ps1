#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter()]
    [string]$OutputRoot = (Join-Path (Split-Path -Parent $PSScriptRoot) 'artifacts\release\local-installer-exercise'),

    [Parameter()]
    [string]$SmokeWorkspaceRoot = 'C:\dev-smoke-lvie',

    [Parameter()]
    [switch]$SkipSmokeInstall,

    [Parameter()]
    [switch]$SkipSmokeBuild,

    [Parameter()]
    [switch]$KeepSmokeWorkspace,

    [Parameter()]
    [string]$NsisRoot = 'C:\Program Files (x86)\NSIS',

    [Parameter()]
    [string]$ReleaseInstallerName = 'lvie-cdev-workspace-installer.exe',

    [Parameter()]
    [string]$SmokeInstallerName = 'lvie-cdev-workspace-installer-smoke.exe'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Ensure-Directory {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        New-Item -Path $Path -ItemType Directory -Force | Out-Null
    }
}

function Write-Sha256File {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][string]$OutputPath
    )

    $hash = (Get-FileHash -LiteralPath $FilePath -Algorithm SHA256).Hash.ToLowerInvariant()
    $name = Split-Path -Path $FilePath -Leaf
    "{0} *{1}" -f $hash, $name | Set-Content -LiteralPath $OutputPath -Encoding ascii
    return $hash
}

function Stage-Payload {
    param(
        [Parameter(Mandatory = $true)][string]$RepoRoot,
        [Parameter(Mandatory = $true)][string]$PayloadRoot
    )

    $canonicalPayloadRoot = Join-Path $RepoRoot 'workspace-governance-payload'
    if (-not (Test-Path -LiteralPath $canonicalPayloadRoot -PathType Container)) {
        throw "Canonical payload root not found: $canonicalPayloadRoot"
    }

    Ensure-Directory -Path $PayloadRoot
    Copy-Item -Path (Join-Path $canonicalPayloadRoot '*') -Destination $PayloadRoot -Recurse -Force
    Ensure-Directory -Path (Join-Path $PayloadRoot 'scripts')
    Ensure-Directory -Path (Join-Path $PayloadRoot 'tools\runner-cli\win-x64')

    Copy-Item -LiteralPath (Join-Path $RepoRoot 'scripts\Install-WorkspaceFromManifest.ps1') -Destination (Join-Path $PayloadRoot 'scripts\Install-WorkspaceFromManifest.ps1') -Force
}

function Convert-ManifestToWorkspace {
    param(
        [Parameter(Mandatory = $true)][string]$ManifestPath,
        [Parameter(Mandatory = $true)][string]$WorkspaceRoot
    )

    $manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json -ErrorAction Stop
    $sourceRoot = [string]$manifest.workspace_root
    if ([string]::IsNullOrWhiteSpace($sourceRoot)) {
        throw "Manifest is missing workspace_root: $ManifestPath"
    }

    $normalizedSource = [System.IO.Path]::GetFullPath($sourceRoot)
    $normalizedTarget = [System.IO.Path]::GetFullPath($WorkspaceRoot)
    $manifest.workspace_root = $normalizedTarget

    foreach ($repo in @($manifest.managed_repos)) {
        $repoPath = [string]$repo.path
        if ([string]::IsNullOrWhiteSpace($repoPath)) {
            throw "Managed repo path is empty in manifest: $ManifestPath"
        }

        $fullRepoPath = [System.IO.Path]::GetFullPath($repoPath)
        if ($fullRepoPath.StartsWith($normalizedSource, [System.StringComparison]::OrdinalIgnoreCase)) {
            $suffix = $fullRepoPath.Substring($normalizedSource.Length).TrimStart('\')
            $repo.path = if ([string]::IsNullOrWhiteSpace($suffix)) { $normalizedTarget } else { Join-Path $normalizedTarget $suffix }
        } else {
            # Keep non-workspace paths unchanged, but make deterministic absolute.
            $repo.path = $fullRepoPath
        }
    }

    $manifest | ConvertTo-Json -Depth 14 | Set-Content -LiteralPath $ManifestPath -Encoding utf8
}

$repoRoot = (Resolve-Path -Path (Join-Path $PSScriptRoot '..')).Path
$buildScript = Join-Path $repoRoot 'scripts\Build-WorkspaceBootstrapInstaller.ps1'
$bundleRunnerCliScript = Join-Path $repoRoot 'scripts\Build-RunnerCliBundleFromManifest.ps1'
if (-not (Test-Path -LiteralPath $buildScript -PathType Leaf)) {
    throw "Build script not found: $buildScript"
}
if (-not (Test-Path -LiteralPath $bundleRunnerCliScript -PathType Leaf)) {
    throw "Runner CLI bundle script not found: $bundleRunnerCliScript"
}

foreach ($commandName in @('pwsh', 'git', 'gh', 'dotnet', 'g-cli')) {
    if (-not (Get-Command $commandName -ErrorAction SilentlyContinue)) {
        throw "Required command '$commandName' was not found on PATH."
    }
}

$makensisPath = Join-Path $NsisRoot 'makensis.exe'
if (-not (Test-Path -LiteralPath $makensisPath -PathType Leaf)) {
    throw "Required NSIS binary not found at '$makensisPath'."
}

$resolvedOutputRoot = [System.IO.Path]::GetFullPath($OutputRoot)
$resolvedSmokeRoot = [System.IO.Path]::GetFullPath($SmokeWorkspaceRoot)
Ensure-Directory -Path $resolvedOutputRoot
Ensure-Directory -Path (Join-Path $resolvedOutputRoot 'bundle')
Ensure-Directory -Path (Join-Path $resolvedOutputRoot 'tmp')

$canonicalPayload = Join-Path $resolvedOutputRoot 'tmp\payload-canonical'
$smokePayload = Join-Path $resolvedOutputRoot 'tmp\payload-smoke'
if (Test-Path -LiteralPath $canonicalPayload -PathType Container) { Remove-Item -LiteralPath $canonicalPayload -Recurse -Force }
if (Test-Path -LiteralPath $smokePayload -PathType Container) { Remove-Item -LiteralPath $smokePayload -Recurse -Force }

Stage-Payload -RepoRoot $repoRoot -PayloadRoot $canonicalPayload
& $bundleRunnerCliScript `
    -ManifestPath (Join-Path $canonicalPayload 'workspace-governance\workspace-governance.json') `
    -OutputRoot (Join-Path $canonicalPayload 'tools\runner-cli\win-x64') `
    -RepoName 'labview-icon-editor' `
    -Runtime 'win-x64'
if ($LASTEXITCODE -ne 0) {
    throw "Failed to build deterministic runner-cli payload bundle. Exit code: $LASTEXITCODE"
}

if (-not $SkipSmokeBuild) {
    Stage-Payload -RepoRoot $repoRoot -PayloadRoot $smokePayload
    $runnerCliPayloadRoot = Join-Path $canonicalPayload 'tools\runner-cli\win-x64'
    foreach ($runnerCliFile in @('runner-cli.exe', 'runner-cli.exe.sha256', 'runner-cli.metadata.json')) {
        Copy-Item `
            -LiteralPath (Join-Path $runnerCliPayloadRoot $runnerCliFile) `
            -Destination (Join-Path $smokePayload 'tools\runner-cli\win-x64') `
            -Force
    }
    Convert-ManifestToWorkspace -ManifestPath (Join-Path $smokePayload 'workspace-governance\workspace-governance.json') -WorkspaceRoot $resolvedSmokeRoot
} elseif (-not $SkipSmokeInstall) {
    Write-Host "SkipSmokeBuild was set; forcing SkipSmokeInstall."
    $SkipSmokeInstall = $true
}

$releaseInstallerPath = Join-Path $resolvedOutputRoot $ReleaseInstallerName
$releaseShaPath = Join-Path $resolvedOutputRoot "$ReleaseInstallerName.sha256"
$smokeInstallerPath = Join-Path $resolvedOutputRoot $SmokeInstallerName

if (Test-Path -LiteralPath $releaseInstallerPath -PathType Leaf) { Remove-Item -LiteralPath $releaseInstallerPath -Force }
if (Test-Path -LiteralPath $smokeInstallerPath -PathType Leaf) { Remove-Item -LiteralPath $smokeInstallerPath -Force }

& $buildScript -PayloadRoot $canonicalPayload -OutputPath $releaseInstallerPath -WorkspaceRootDefault 'C:\dev' -NsisRoot $NsisRoot
if ($LASTEXITCODE -ne 0) {
    throw "Failed to build release installer. Exit code: $LASTEXITCODE"
}

if (-not $SkipSmokeBuild) {
    & $buildScript -PayloadRoot $smokePayload -OutputPath $smokeInstallerPath -WorkspaceRootDefault $resolvedSmokeRoot -NsisRoot $NsisRoot
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to build smoke installer. Exit code: $LASTEXITCODE"
    }
}

$releaseSha = Write-Sha256File -FilePath $releaseInstallerPath -OutputPath $releaseShaPath
$smokeReportPath = Join-Path $resolvedSmokeRoot 'artifacts\workspace-install-latest.json'
$smokeLaunchLogPath = Join-Path $resolvedSmokeRoot 'artifacts\workspace-installer-launch.log'
$smokeStatus = if ($SkipSmokeBuild) { 'build_skipped' } elseif ($SkipSmokeInstall) { 'install_skipped' } else { 'pending' }
$smokeExitCode = $null
$smokeErrorMessage = ''
$smokeReportStatus = ''
$smokeReportErrors = @()
$smokeReportWarnings = @()

if ((-not $SkipSmokeInstall) -and (-not $SkipSmokeBuild)) {
    try {
        if ((Test-Path -LiteralPath $resolvedSmokeRoot -PathType Container) -and (-not $KeepSmokeWorkspace)) {
            Remove-Item -LiteralPath $resolvedSmokeRoot -Recurse -Force
        }
        Ensure-Directory -Path $resolvedSmokeRoot

        & $smokeInstallerPath '/S' | Out-Host
        $smokeExitCode = $LASTEXITCODE
        if ($smokeExitCode -ne 0) {
            throw "Smoke installer failed with exit code $smokeExitCode"
        }

        if (-not (Test-Path -LiteralPath $smokeReportPath -PathType Leaf)) {
            throw "Smoke install report not found: $smokeReportPath"
        }

        $smokeInstallReport = Get-Content -LiteralPath $smokeReportPath -Raw | ConvertFrom-Json -ErrorAction Stop
        $smokeReportStatus = [string]$smokeInstallReport.status
        $smokeReportErrors = @($smokeInstallReport.errors)
        $smokeReportWarnings = @($smokeInstallReport.warnings)
        $smokeStatus = $smokeReportStatus
        if ($smokeStatus -ne 'succeeded') {
            throw "Smoke install report status is '$smokeStatus' (expected 'succeeded')."
        }
    } catch {
        if ($null -eq $smokeExitCode) {
            $smokeExitCode = 1
        }
        $smokeStatus = 'failed'
        $smokeErrorMessage = $_.Exception.Message

        if (Test-Path -LiteralPath $smokeLaunchLogPath -PathType Leaf) {
            try {
                $smokeReportWarnings += "NSIS launch log found: $smokeLaunchLogPath"
                $smokeReportErrors += (Get-Content -LiteralPath $smokeLaunchLogPath -Raw)
            } catch {
                $smokeReportWarnings += "Unable to read NSIS launch log: $($_.Exception.Message)"
            }
        }

        if (Test-Path -LiteralPath $smokeReportPath -PathType Leaf) {
            try {
                $smokeInstallReport = Get-Content -LiteralPath $smokeReportPath -Raw | ConvertFrom-Json -ErrorAction Stop
                $smokeReportStatus = [string]$smokeInstallReport.status
                $smokeReportErrors = @($smokeInstallReport.errors)
                $smokeReportWarnings = @($smokeInstallReport.warnings)
            } catch {
                $smokeReportErrors += "Failed to parse smoke install report: $($_.Exception.Message)"
            }
        }
    }
}

$bundleRoot = Join-Path $resolvedOutputRoot 'bundle'
$bundleInstallerPath = Join-Path $bundleRoot $ReleaseInstallerName
$bundleShaPath = Join-Path $bundleRoot "$ReleaseInstallerName.sha256"
$bundleManifestPath = Join-Path $bundleRoot 'workspace-governance.json'
$bundleReadmePath = Join-Path $bundleRoot 'README-install.txt'
$bundleVerifyScriptPath = Join-Path $bundleRoot 'Verify-And-Install.ps1'

Copy-Item -LiteralPath $releaseInstallerPath -Destination $bundleInstallerPath -Force
Copy-Item -LiteralPath $releaseShaPath -Destination $bundleShaPath -Force
Copy-Item -LiteralPath (Join-Path $canonicalPayload 'workspace-governance\workspace-governance.json') -Destination $bundleManifestPath -Force

@"
LVIE C:\dev Workspace Installer Bundle

Files:
- $ReleaseInstallerName
- $ReleaseInstallerName.sha256
- workspace-governance.json
- Verify-And-Install.ps1

Target prerequisites:
- pwsh
- git
- gh (authenticated for GitHub API access)
- g-cli

Install:
1) Verify hash:
   Get-FileHash .\$ReleaseInstallerName -Algorithm SHA256
2) Run silent installer:
   .\$ReleaseInstallerName /S

Report path after install:
- C:\dev\artifacts\workspace-install-latest.json
"@ | Set-Content -LiteralPath $bundleReadmePath -Encoding utf8

@"
param(
  [string]`$InstallerPath = '.\$ReleaseInstallerName',
  [string]`$ShaFile = '.\$ReleaseInstallerName.sha256'
)
`$ErrorActionPreference = 'Stop'
foreach (`$cmd in @('pwsh','git','gh')) {
  if (-not (Get-Command `$cmd -ErrorAction SilentlyContinue)) {
    throw "Required command '`$cmd' is missing."
  }
}
if (-not (Test-Path -LiteralPath `$InstallerPath -PathType Leaf)) { throw "Installer not found: `$InstallerPath" }
if (-not (Test-Path -LiteralPath `$ShaFile -PathType Leaf)) { throw "SHA file not found: `$ShaFile" }
`$expected = (Get-Content -LiteralPath `$ShaFile -Raw).Split(' ')[0].Trim().ToLowerInvariant()
`$actual = (Get-FileHash -LiteralPath `$InstallerPath -Algorithm SHA256).Hash.ToLowerInvariant()
if (`$expected -ne `$actual) { throw "SHA mismatch. Expected `$expected, got `$actual" }
Write-Host "SHA verified: `$actual"
`$p = Start-Process -FilePath `$InstallerPath -ArgumentList '/S' -Wait -PassThru
if (`$p.ExitCode -ne 0) { throw ('Installer failed with exit code ' + `$p.ExitCode) }
Write-Host 'Installer completed successfully.'
"@ | Set-Content -LiteralPath $bundleVerifyScriptPath -Encoding utf8

$bundleZipPath = Join-Path $resolvedOutputRoot 'lvie-cdev-workspace-installer-bundle.zip'
if (Test-Path -LiteralPath $bundleZipPath -PathType Leaf) { Remove-Item -LiteralPath $bundleZipPath -Force }
Compress-Archive -Path (Join-Path $bundleRoot '*') -DestinationPath $bundleZipPath
$bundleZipSha = (Get-FileHash -LiteralPath $bundleZipPath -Algorithm SHA256).Hash.ToLowerInvariant()

$reportPath = Join-Path $resolvedOutputRoot 'exercise-report.json'
$report = [ordered]@{
    timestamp_utc = (Get-Date).ToUniversalTime().ToString('o')
    repo_root = $repoRoot
    output_root = $resolvedOutputRoot
    release_installer = [ordered]@{
        path = $releaseInstallerPath
        sha256 = $releaseSha
    }
    smoke_installer = [ordered]@{
        path = $smokeInstallerPath
        workspace_root = $resolvedSmokeRoot
        status = $smokeStatus
        exit_code = $smokeExitCode
        report_path = $smokeReportPath
        launch_log_path = $smokeLaunchLogPath
        error_message = $smokeErrorMessage
        report_status = $smokeReportStatus
        report_errors = @($smokeReportErrors)
        report_warnings = @($smokeReportWarnings)
    }
    bundle = [ordered]@{
        root = $bundleRoot
        zip_path = $bundleZipPath
        zip_sha256 = $bundleZipSha
    }
}
$report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $reportPath -Encoding utf8

Write-Host "Release installer: $releaseInstallerPath"
Write-Host "Release installer sha256: $releaseSha"
Write-Host "Bundle zip: $bundleZipPath"
Write-Host "Bundle zip sha256: $bundleZipSha"
Write-Host "Exercise report: $reportPath"

if (-not [string]::IsNullOrWhiteSpace($smokeErrorMessage)) {
    throw $smokeErrorMessage
}
