#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter()]
    [string]$Image = 'labview-cdev-surface-nsis-selftest:local',

    [Parameter()]
    [switch]$BuildLocalImage,

    [Parameter()]
    [string]$DockerfilePath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'tools\nsis-selftest-windows\Dockerfile'),

    [Parameter()]
    [string]$DockerContext = '',

    [Parameter()]
    [string]$OutputRoot = (Join-Path (Split-Path -Parent $PSScriptRoot) 'artifacts\release\windows-container-nsis-selftest'),

    [Parameter()]
    [string]$HostNsisRoot = 'C:\Program Files (x86)\NSIS',

    [Parameter()]
    [string]$ContainerWorkspaceRoot = 'C:\dev-smoke-lvie',

    [Parameter()]
    [string]$ContainerRepoMount = 'C:\repo',

    [Parameter()]
    [string]$ContainerOutputMount = 'C:\hostout',

    [Parameter()]
    [string]$ContainerPayloadMount = 'C:\payload',

    [Parameter()]
    [string]$ContainerNsisMount = 'C:\nsis',

    [Parameter()]
    [ValidatePattern('^[a-z0-9][a-z0-9_.-]{2,50}$')]
    [string]$ContainerNamePrefix = 'lvie-cdev-nsis-smoke',

    [Parameter()]
    [switch]$KeepContainerScript,

    [Parameter()]
    [switch]$KeepContainerOnFailure
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Ensure-Directory {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        New-Item -Path $Path -ItemType Directory -Force | Out-Null
    }
}

function Clear-DirectoryContents {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        return
    }

    Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue | ForEach-Object {
        Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction Stop
    }
}

function Assert-Command {
    param([Parameter(Mandatory = $true)][string]$Name)
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Required command '$Name' was not found on PATH."
    }
}

function Get-CommandOutputOrThrow {
    param(
        [Parameter(Mandatory = $true)][string]$Command,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )

    & $Command @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw ("Command failed: {0} {1} (exit={2})" -f $Command, ($Arguments -join ' '), $LASTEXITCODE)
    }
}

function Convert-ToSingleQuotedLiteral {
    param([Parameter(Mandatory = $true)][string]$Value)
    return $Value.Replace("'", "''")
}

$repoRoot = (Resolve-Path -Path (Join-Path $PSScriptRoot '..')).Path
$resolvedDockerfilePath = [System.IO.Path]::GetFullPath($DockerfilePath)
$dockerBuildContext = [System.IO.Path]::GetDirectoryName($resolvedDockerfilePath)
$resolvedOutputRoot = [System.IO.Path]::GetFullPath($OutputRoot)
$resolvedHostNsisRoot = [System.IO.Path]::GetFullPath($HostNsisRoot)
$hostMakensisPath = Join-Path $resolvedHostNsisRoot 'makensis.exe'
$containerScriptPath = Join-Path $resolvedOutputRoot 'container-run.ps1'
$containerReportPath = Join-Path $resolvedOutputRoot 'container-report.json'
$hostReportPath = Join-Path $resolvedOutputRoot 'windows-container-nsis-selftest-report.json'
$hostPayloadRoot = Join-Path $resolvedOutputRoot 'payload-host'
$hostPayloadManifestPath = Join-Path $hostPayloadRoot 'workspace-governance\workspace-governance.json'
$hostRunnerCliOutputRoot = Join-Path $hostPayloadRoot 'tools\runner-cli\win-x64'
$buildInstallerScript = Join-Path $repoRoot 'scripts\Build-WorkspaceBootstrapInstaller.ps1'
$buildRunnerCliScript = Join-Path $repoRoot 'scripts\Build-RunnerCliBundleFromManifest.ps1'
$convertManifestScript = Join-Path $repoRoot 'scripts\Convert-ManifestToWorkspace.ps1'
$installScript = Join-Path $repoRoot 'scripts\Install-WorkspaceFromManifest.ps1'
$canonicalPayloadRoot = Join-Path $repoRoot 'workspace-governance-payload'

Assert-Command -Name 'docker'
Assert-Command -Name 'powershell'
Assert-Command -Name 'git'
Assert-Command -Name 'dotnet'

if (-not (Test-Path -LiteralPath $resolvedDockerfilePath -PathType Leaf)) {
    throw "Dockerfile not found: $resolvedDockerfilePath"
}
foreach ($requiredPath in @($buildInstallerScript, $buildRunnerCliScript, $convertManifestScript, $installScript)) {
    if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
        throw "Required script not found: $requiredPath"
    }
}
if (-not (Test-Path -LiteralPath $canonicalPayloadRoot -PathType Container)) {
    throw "Canonical payload root not found: $canonicalPayloadRoot"
}
if (-not (Test-Path -LiteralPath $hostMakensisPath -PathType Leaf)) {
    throw ("host_nsis_missing: expected '{0}'. Install NSIS on host or pass -HostNsisRoot." -f $hostMakensisPath)
}

Ensure-Directory -Path $resolvedOutputRoot
if (Test-Path -LiteralPath $containerReportPath -PathType Leaf) {
    Remove-Item -LiteralPath $containerReportPath -Force
}
if (Test-Path -LiteralPath $hostPayloadRoot -PathType Container) {
    Remove-Item -LiteralPath $hostPayloadRoot -Recurse -Force
}
Ensure-Directory -Path $hostPayloadRoot

Copy-Item -Path (Join-Path $canonicalPayloadRoot '*') -Destination $hostPayloadRoot -Recurse -Force
Ensure-Directory -Path (Join-Path $hostPayloadRoot 'scripts')
Ensure-Directory -Path $hostRunnerCliOutputRoot
Copy-Item -LiteralPath $installScript -Destination (Join-Path $hostPayloadRoot 'scripts\Install-WorkspaceFromManifest.ps1') -Force

& $buildRunnerCliScript `
    -ManifestPath $hostPayloadManifestPath `
    -OutputRoot $hostRunnerCliOutputRoot `
    -RepoName 'labview-icon-editor' `
    -Runtime 'win-x64' `
    -Deterministic:$true | Out-Host
if ($LASTEXITCODE -ne 0) {
    throw "Build-RunnerCliBundleFromManifest.ps1 failed with exit code $LASTEXITCODE"
}

& $convertManifestScript -ManifestPath $hostPayloadManifestPath -WorkspaceRoot $ContainerWorkspaceRoot | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw "Convert-ManifestToWorkspace.ps1 failed with exit code $LASTEXITCODE"
}

$contextArgs = @()
if (-not [string]::IsNullOrWhiteSpace($DockerContext)) {
    $contextArgs += @('--context', $DockerContext)
}

$dockerOsTypeRaw = & docker @($contextArgs + @('info', '--format', '{{.OSType}}')) 2>$null
if ($LASTEXITCODE -ne 0) {
    throw ("docker_info_failed: unable to query Docker engine OSType for context '{0}'." -f $DockerContext)
}
$dockerOsType = ([string]$dockerOsTypeRaw).Trim().ToLowerInvariant()
if ($dockerOsType -ne 'windows') {
    throw ("windows_container_mode_required: Docker engine OSType is '{0}' for context '{1}'. Switch Docker Desktop to Windows containers or use a Windows-engine context." -f $dockerOsType, $DockerContext)
}

if ($BuildLocalImage) {
    $buildArgs = @($contextArgs + @('build', '-f', $resolvedDockerfilePath, '-t', $Image, $dockerBuildContext))
    Get-CommandOutputOrThrow -Command 'docker' -Arguments $buildArgs
}

$containerScriptTemplate = @'
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Ensure-Directory {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        New-Item -Path $Path -ItemType Directory -Force | Out-Null
    }
}

function Clear-DirectoryContents {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        return
    }

    Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue | ForEach-Object {
        Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction Stop
    }
}

function Assert-Command {
    param([Parameter(Mandatory = $true)][string]$Name)
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Required command '$Name' was not found on PATH in container."
    }
}

$repoRoot = '__REPO_MOUNT__'
$payloadRoot = '__PAYLOAD_MOUNT__'
$nsisRoot = '__NSIS_MOUNT__'
$hostOut = '__OUTPUT_MOUNT__'
$workspaceRoot = '__WORKSPACE_ROOT__'
$workRoot = 'C:\workspace\nsis-selftest'
$installerPath = Join-Path $workRoot 'lvie-cdev-workspace-installer-container-smoke.exe'
$cliExtractRoot = Join-Path $workRoot 'cdev-cli'
$cliBundleZipPath = Join-Path $payloadRoot 'tools\cdev-cli\cdev-cli-win-x64.zip'
$cliEntrypointPath = Join-Path $cliExtractRoot 'cdev-cli\scripts\Invoke-CdevCli.ps1'
$cliRunReportPath = Join-Path $hostOut 'cdev-cli-installer-run-report.json'
$cliRunReportResolvedPath = ''
$cliRunStatus = ''
$installReportPath = Join-Path $workspaceRoot 'artifacts\workspace-install-latest.json'
$launchLogPath = Join-Path $workspaceRoot 'artifacts\workspace-installer-launch.log'
$buildInstallerScript = Join-Path $repoRoot 'scripts\Build-WorkspaceBootstrapInstaller.ps1'
$containerMakensisPath = Join-Path $nsisRoot 'makensis.exe'

$containerStatus = 'unknown'
$errorMessage = ''
$reasonCode = ''
$installerSha256 = ''
$installerExitCode = 0
$installReportStatus = ''
$installReportErrors = @()
$installReportWarnings = @()

try {
    Assert-Command -Name 'powershell'
    if (-not (Test-Path -LiteralPath $buildInstallerScript -PathType Leaf)) {
        throw "Required build script missing in mounted repo: $buildInstallerScript"
    }
    if (-not (Test-Path -LiteralPath $payloadRoot -PathType Container)) {
        throw "Mounted payload root not found: $payloadRoot"
    }
    if (-not (Test-Path -LiteralPath $containerMakensisPath -PathType Leaf)) {
        throw "Mounted NSIS binary not found: $containerMakensisPath"
    }
    if (-not (Test-Path -LiteralPath $cliBundleZipPath -PathType Leaf)) {
        throw "Mounted cdev-cli Windows bundle not found: $cliBundleZipPath"
    }

    if (Test-Path -LiteralPath $workRoot -PathType Container) {
        Remove-Item -LiteralPath $workRoot -Recurse -Force
    }
    Clear-DirectoryContents -Path $workspaceRoot
    Ensure-Directory -Path $workRoot
    Ensure-Directory -Path $workspaceRoot
    Ensure-Directory -Path $hostOut

    & $buildInstallerScript `
        -PayloadRoot $payloadRoot `
        -OutputPath $installerPath `
        -WorkspaceRootDefault $workspaceRoot `
        -InstallerExecutionContext 'ContainerSmoke' `
        -NsisRoot $nsisRoot `
        -Deterministic $true | Out-Host
    if ($LASTEXITCODE -ne 0) {
        throw "Build-WorkspaceBootstrapInstaller.ps1 failed in container with exit code $LASTEXITCODE"
    }
    if (-not (Test-Path -LiteralPath $installerPath -PathType Leaf)) {
        throw "Installer output not found: $installerPath"
    }

    $installerSha256 = (Get-FileHash -LiteralPath $installerPath -Algorithm SHA256).Hash.ToLowerInvariant()
    "{0} *{1}" -f $installerSha256, (Split-Path -Path $installerPath -Leaf) | Set-Content -LiteralPath "$installerPath.sha256" -Encoding ascii

    if (Test-Path -LiteralPath $cliExtractRoot -PathType Container) {
        Remove-Item -LiteralPath $cliExtractRoot -Recurse -Force
    }
    Expand-Archive -LiteralPath $cliBundleZipPath -DestinationPath $cliExtractRoot -Force
    if (-not (Test-Path -LiteralPath $cliEntrypointPath -PathType Leaf)) {
        throw "cdev-cli entrypoint not found after bundle extraction: $cliEntrypointPath"
    }

    Ensure-Directory -Path (Split-Path -Path $installReportPath -Parent)
    if (-not (Test-Path -LiteralPath $installReportPath -PathType Leaf)) {
        [ordered]@{
            timestamp_utc = (Get-Date).ToUniversalTime().ToString('o')
            status = 'seeded'
            source = 'windows-container-nsis-selftest'
        } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $installReportPath -Encoding utf8
    }

    $cliCommandArgs = @(
        'installer',
        'install',
        '--installer-path', $installerPath,
        '--report-path', $installReportPath
    )
    & $cliEntrypointPath -ReportPath $cliRunReportPath -CommandArgs $cliCommandArgs | Out-Host
    $installerExitCode = if ($null -eq $LASTEXITCODE) { 0 } else { [int]$LASTEXITCODE }

    $cliRunReportResolvedPath = $cliRunReportPath
    if (-not (Test-Path -LiteralPath $cliRunReportResolvedPath -PathType Leaf) -and (Test-Path -LiteralPath $installReportPath -PathType Leaf)) {
        # Bundled cdev-cli versions may persist their run report to --report-path.
        $cliRunReportResolvedPath = $installReportPath
    }
    if (-not (Test-Path -LiteralPath $cliRunReportResolvedPath -PathType Leaf)) {
        $reasonCode = 'install_report_missing'
        throw "cdev-cli run report missing after installer operation: $cliRunReportPath"
    }

    $cliRunReport = Get-Content -LiteralPath $cliRunReportResolvedPath -Raw | ConvertFrom-Json -ErrorAction Stop
    $cliRunStatus = [string]$cliRunReport.status
    $cliRunErrors = if ($null -ne $cliRunReport.PSObject.Properties['errors']) { @($cliRunReport.errors) } else { @() }
    $cliRunWarnings = if ($null -ne $cliRunReport.PSObject.Properties['warnings']) { @($cliRunReport.warnings) } else { @() }
    $installReportStatus = $cliRunStatus
    $installReportErrors = $cliRunErrors
    $installReportWarnings = $cliRunWarnings
    if ($cliRunStatus -ne 'succeeded') {
        $reasonCode = if (($cliRunErrors -join "`n") -match 'Expected installer report not found') { 'install_report_missing' } else { 'installer_exit_nonzero' }
        throw "cdev-cli run report status is '$cliRunStatus' (expected 'succeeded')."
    }
    if ($installerExitCode -ne 0) {
        $reasonCode = 'installer_exit_nonzero'
        throw "cdev-cli installer install returned nonzero exit code $installerExitCode."
    }

    Copy-Item -LiteralPath $installerPath -Destination (Join-Path $hostOut 'lvie-cdev-workspace-installer-container-smoke.exe') -Force
    Copy-Item -LiteralPath "$installerPath.sha256" -Destination (Join-Path $hostOut 'lvie-cdev-workspace-installer-container-smoke.exe.sha256') -Force
    if (Test-Path -LiteralPath $installReportPath -PathType Leaf) {
        Copy-Item -LiteralPath $installReportPath -Destination (Join-Path $hostOut 'workspace-install-latest.container-smoke.json') -Force
    } elseif (Test-Path -LiteralPath $cliRunReportResolvedPath -PathType Leaf) {
        Copy-Item -LiteralPath $cliRunReportResolvedPath -Destination (Join-Path $hostOut 'workspace-install-latest.container-smoke.json') -Force
    }
    if (Test-Path -LiteralPath $launchLogPath -PathType Leaf) {
        Copy-Item -LiteralPath $launchLogPath -Destination (Join-Path $hostOut 'workspace-installer-launch.container-smoke.log') -Force
    }

    $containerStatus = 'succeeded'
} catch {
    if ([string]::IsNullOrWhiteSpace($reasonCode)) {
        $reasonCode = 'container_smoke_failed'
    }
    $containerStatus = 'failed'
    $errorMessage = $_.Exception.Message
}

[ordered]@{
    timestamp_utc = (Get-Date).ToUniversalTime().ToString('o')
    status = $containerStatus
    reason_code = $reasonCode
    repo_root = $repoRoot
    payload_root = $payloadRoot
    nsis_root = $nsisRoot
    host_output = $hostOut
    workspace_root = $workspaceRoot
    work_root = $workRoot
    installer_path = $installerPath
    installer_sha256 = $installerSha256
    installer_exit_code = $installerExitCode
    cdev_cli_entrypoint_path = $cliEntrypointPath
    cdev_cli_run_report_path = if ([string]::IsNullOrWhiteSpace($cliRunReportResolvedPath)) { $cliRunReportPath } else { $cliRunReportResolvedPath }
    cdev_cli_status = $cliRunStatus
    install_report_path = $installReportPath
    install_report_status = $installReportStatus
    install_report_errors = @($installReportErrors)
    install_report_warnings = @($installReportWarnings)
    launch_log_path = $launchLogPath
    error_message = $errorMessage
} | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $hostOut 'container-report.json') -Encoding utf8

if ($containerStatus -ne 'succeeded') {
    exit 1
}
exit 0
'@

$containerScriptContent = $containerScriptTemplate
$containerScriptContent = $containerScriptContent.Replace('__REPO_MOUNT__', (Convert-ToSingleQuotedLiteral -Value $ContainerRepoMount))
$containerScriptContent = $containerScriptContent.Replace('__PAYLOAD_MOUNT__', (Convert-ToSingleQuotedLiteral -Value $ContainerPayloadMount))
$containerScriptContent = $containerScriptContent.Replace('__NSIS_MOUNT__', (Convert-ToSingleQuotedLiteral -Value $ContainerNsisMount))
$containerScriptContent = $containerScriptContent.Replace('__OUTPUT_MOUNT__', (Convert-ToSingleQuotedLiteral -Value $ContainerOutputMount))
$containerScriptContent = $containerScriptContent.Replace('__WORKSPACE_ROOT__', (Convert-ToSingleQuotedLiteral -Value $ContainerWorkspaceRoot))
Set-Content -LiteralPath $containerScriptPath -Value $containerScriptContent -Encoding utf8

$containerName = ('{0}-{1}' -f $ContainerNamePrefix, ([guid]::NewGuid().ToString('n').Substring(0, 12))).ToLowerInvariant()
$dockerRepoVolume = ('{0}:{1}' -f $repoRoot, $ContainerRepoMount)
$dockerOutputVolume = ('{0}:{1}' -f $resolvedOutputRoot, $ContainerOutputMount)
$dockerPayloadVolume = ('{0}:{1}' -f $hostPayloadRoot, $ContainerPayloadMount)
$dockerNsisVolume = ('{0}:{1}' -f $resolvedHostNsisRoot, $ContainerNsisMount)
$hostWorkspaceMirrorRoot = Join-Path $resolvedOutputRoot 'workspace-root'
Ensure-Directory -Path $hostWorkspaceMirrorRoot
$dockerWorkspaceVolume = ('{0}:{1}' -f $hostWorkspaceMirrorRoot, $ContainerWorkspaceRoot)
$containerExitCode = 0
$status = 'unknown'
$errors = @()
$containerReport = $null
$startedUtc = (Get-Date).ToUniversalTime()
$removeOnExit = -not $KeepContainerOnFailure

try {
    $runArgs = @($contextArgs + @('run'))
    if ($removeOnExit) {
        $runArgs += '--rm'
    }
    $runArgs += @(
        '--name', $containerName,
        '-v', $dockerRepoVolume,
        '-v', $dockerOutputVolume,
        '-v', $dockerPayloadVolume,
        '-v', $dockerNsisVolume,
        '-v', $dockerWorkspaceVolume,
        $Image,
        'powershell', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $ContainerOutputMount 'container-run.ps1')
    )

    & docker @runArgs
    $containerExitCode = if ($null -eq $LASTEXITCODE) { 0 } else { [int]$LASTEXITCODE }
    if ($containerExitCode -ne 0) {
        throw "docker run failed with exit code $containerExitCode"
    }
    if (-not (Test-Path -LiteralPath $containerReportPath -PathType Leaf)) {
        throw "Container report missing: $containerReportPath"
    }

    $containerReport = Get-Content -LiteralPath $containerReportPath -Raw | ConvertFrom-Json -ErrorAction Stop
    if ([string]$containerReport.status -ne 'succeeded') {
        throw ("Container report status is '{0}' (expected 'succeeded')." -f [string]$containerReport.status)
    }

    $status = 'succeeded'
} catch {
    if ($containerExitCode -eq 0) {
        $containerExitCode = 1
    }
    $status = 'failed'
    $errors += $_.Exception.Message
    if (Test-Path -LiteralPath $containerReportPath -PathType Leaf) {
        try {
            $containerReport = Get-Content -LiteralPath $containerReportPath -Raw | ConvertFrom-Json -ErrorAction Stop
        } catch {
            $errors += "Failed to parse container report JSON: $($_.Exception.Message)"
        }
    }
} finally {
    if ($KeepContainerOnFailure -and $status -eq 'succeeded') {
        & docker @($contextArgs + @('rm', '-f', $containerName)) *> $null
    }
}

$endedUtc = (Get-Date).ToUniversalTime()
[ordered]@{
    timestamp_utc = $endedUtc.ToString('o')
    started_utc = $startedUtc.ToString('o')
    status = $status
    image = $Image
    build_local_image = [bool]$BuildLocalImage
    dockerfile = $resolvedDockerfilePath
    docker_context = $DockerContext
    container_name = $containerName
    output_root = $resolvedOutputRoot
    host_payload_root = $hostPayloadRoot
    host_nsis_root = $resolvedHostNsisRoot
    host_workspace_root = $hostWorkspaceMirrorRoot
    container_workspace_root = $ContainerWorkspaceRoot
    container_exit_code = $containerExitCode
    container_report_path = $containerReportPath
    container_report = $containerReport
    errors = $errors
} | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $hostReportPath -Encoding utf8

if (-not $KeepContainerScript -and (Test-Path -LiteralPath $containerScriptPath -PathType Leaf)) {
    Remove-Item -LiteralPath $containerScriptPath -Force
}

Write-Host "Windows container NSIS self-test report: $hostReportPath"

if ($status -ne 'succeeded') {
    exit 1
}
exit 0
