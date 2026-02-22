#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter()]
    [string]$Image = 'mcr.microsoft.com/powershell:7.4-ubuntu-22.04',

    [Parameter()]
    [string]$ManifestPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'workspace-governance.json'),

    [Parameter()]
    [string]$RepoName = 'labview-icon-editor',

    [Parameter()]
    [string]$Runtime = 'linux-x64',

    [Parameter()]
    [string]$DockerContext = 'desktop-linux',

    [Parameter()]
    [string]$OutputRoot = (Join-Path (Split-Path -Parent $PSScriptRoot) 'artifacts\release\docker-linux-iteration'),

    [Parameter()]
    [switch]$SkipPester,

    [Parameter()]
    [switch]$KeepContainerScript
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Ensure-Directory {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        New-Item -Path $Path -ItemType Directory -Force | Out-Null
    }
}

function Assert-Command {
    param([Parameter(Mandatory = $true)][string]$Name)
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Required command '$Name' was not found on PATH."
    }
}

function Get-OptionalFeatureStateSafe {
    param([Parameter(Mandatory = $true)][string]$FeatureName)

    try {
        $feature = Get-WindowsOptionalFeature -Online -FeatureName $FeatureName -ErrorAction Stop
        return [string]$feature.State
    } catch {
        $message = [string]$_.Exception.Message
        if ($message -match 'requires elevation') {
            return 'Unknown (requires elevation)'
        }
        return 'Unknown'
    }
}

$repoRoot = (Resolve-Path -Path (Join-Path $PSScriptRoot '..')).Path
$resolvedManifestPath = [System.IO.Path]::GetFullPath($ManifestPath)
$resolvedOutputRoot = [System.IO.Path]::GetFullPath($OutputRoot)
$bundleRoot = Join-Path $resolvedOutputRoot 'runner-cli-linux'
$containerReportPath = Join-Path $resolvedOutputRoot 'container-report.json'
$hostReportPath = Join-Path $resolvedOutputRoot 'docker-linux-iteration-report.json'
$containerScriptHostPath = Join-Path $resolvedOutputRoot 'container-run.ps1'
$bundleScript = Join-Path $repoRoot 'scripts\Build-RunnerCliBundleFromManifest.ps1'

foreach ($commandName in @('pwsh', 'git', 'dotnet', 'docker')) {
    Assert-Command -Name $commandName
}

if (-not (Test-Path -LiteralPath $bundleScript -PathType Leaf)) {
    throw "Required script not found: $bundleScript"
}

Ensure-Directory -Path $resolvedOutputRoot
if (Test-Path -LiteralPath $bundleRoot -PathType Container) {
    Remove-Item -LiteralPath $bundleRoot -Recurse -Force
}
Ensure-Directory -Path $bundleRoot

if (Test-Path -LiteralPath $containerReportPath -PathType Leaf) {
    Remove-Item -LiteralPath $containerReportPath -Force
}

& docker --context $DockerContext version *> $null
if ($LASTEXITCODE -ne 0) {
    $hyperVState = Get-OptionalFeatureStateSafe -FeatureName 'Microsoft-Hyper-V-All'
    $virtualMachinePlatformState = Get-OptionalFeatureStateSafe -FeatureName 'VirtualMachinePlatform'
    $wslState = Get-OptionalFeatureStateSafe -FeatureName 'Microsoft-Windows-Subsystem-Linux'
    throw ("docker version failed for context '{0}'. Ensure Docker Desktop Linux mode is running. Feature states: Microsoft-Hyper-V-All={1}; VirtualMachinePlatform={2}; Microsoft-Windows-Subsystem-Linux={3}" -f $DockerContext, $hyperVState, $virtualMachinePlatformState, $wslState)
}

& pwsh -NoProfile -File $bundleScript -ManifestPath $resolvedManifestPath -OutputRoot $bundleRoot -RepoName $RepoName -Runtime $Runtime
if ($LASTEXITCODE -ne 0) {
    throw "Build-RunnerCliBundleFromManifest.ps1 failed with exit code $LASTEXITCODE."
}

$containerScriptContent = @"
param(
    [switch]`$SkipPester
)
`$ErrorActionPreference = 'Stop'

`$runnerCliSource = '/bundle/runner-cli.exe'
if (-not (Test-Path -LiteralPath `$runnerCliSource -PathType Leaf)) {
    throw "Bundled runner-cli not found: `$runnerCliSource"
}

`$runnerCliPath = '/tmp/runner-cli'
Copy-Item -LiteralPath `$runnerCliSource -Destination `$runnerCliPath -Force
& chmod +x `$runnerCliPath

& `$runnerCliPath --help *> /tmp/runner-cli-help.log
if (`$LASTEXITCODE -ne 0) {
    throw "runner-cli --help failed with exit code `$LASTEXITCODE"
}

& `$runnerCliPath ppl --help *> /tmp/runner-cli-ppl-help.log
if (`$LASTEXITCODE -ne 0) {
    throw "runner-cli ppl --help failed with exit code `$LASTEXITCODE"
}

if (-not `$SkipPester) {
    if (-not (Get-Module -ListAvailable -Name Pester | Where-Object { `$_.Version -ge [version]'5.0.0' })) {
        Install-Module -Name Pester -Scope CurrentUser -Force -SkipPublisherCheck -MinimumVersion 5.0.0
    }
    Set-Location -Path /repo
    Invoke-Pester -Path @(
        './tests/WorkspaceSurfaceContract.Tests.ps1',
        './tests/WorkspaceInstallerReleaseContract.Tests.ps1',
        './tests/WorkspaceInstallRuntimeContract.Tests.ps1',
        './tests/Build-RunnerCliBundleFromManifest.Tests.ps1'
    ) -CI -Output Detailed
}

[ordered]@{
    timestamp_utc = (Get-Date).ToUniversalTime().ToString('o')
    status = 'succeeded'
    image = '$Image'
    runtime = '$Runtime'
    runner_cli_help_log = '/tmp/runner-cli-help.log'
    runner_cli_ppl_help_log = '/tmp/runner-cli-ppl-help.log'
    pester_ran = [bool](-not `$SkipPester)
} | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath /hostout/container-report.json -Encoding utf8
"@

Set-Content -LiteralPath $containerScriptHostPath -Value $containerScriptContent -Encoding utf8

$dockerVolumeRepo = "{0}:/repo" -f $repoRoot
$dockerVolumeBundle = "{0}:/bundle" -f $bundleRoot
$dockerVolumeOutput = "{0}:/hostout" -f $resolvedOutputRoot
$containerName = "lvie-cdev-linux-iter-{0}" -f ([guid]::NewGuid().ToString('n').Substring(0, 12))
$containerExitCode = 0
$status = 'unknown'
$errors = @()

try {
    $dockerArgs = @(
        '--context', $DockerContext,
        'run',
        '--rm',
        '--name', $containerName,
        '-v', $dockerVolumeRepo,
        '-v', $dockerVolumeBundle,
        '-v', $dockerVolumeOutput,
        $Image,
        'pwsh', '-NoProfile', '-File', '/hostout/container-run.ps1'
    )
    if ($SkipPester) {
        $dockerArgs += '-SkipPester'
    }

    & docker @dockerArgs
    $containerExitCode = $LASTEXITCODE
    if ($containerExitCode -ne 0) {
        throw "docker run failed with exit code $containerExitCode"
    }

    if (-not (Test-Path -LiteralPath $containerReportPath -PathType Leaf)) {
        throw "Container report not found: $containerReportPath"
    }

    $status = 'succeeded'
} catch {
    $status = 'failed'
    if ($containerExitCode -eq 0) {
        $containerExitCode = 1
    }
    $errors += $_.Exception.Message
}

$containerReport = $null
if (Test-Path -LiteralPath $containerReportPath -PathType Leaf) {
    try {
        $containerReport = Get-Content -LiteralPath $containerReportPath -Raw | ConvertFrom-Json -ErrorAction Stop
    } catch {
        $errors += "Failed to parse container report: $($_.Exception.Message)"
        $status = 'failed'
    }
}

[ordered]@{
    timestamp_utc = (Get-Date).ToUniversalTime().ToString('o')
    status = $status
    image = $Image
    runtime = $Runtime
    docker_context = $DockerContext
    manifest_path = $resolvedManifestPath
    repo_name = $RepoName
    output_root = $resolvedOutputRoot
    bundle_root = $bundleRoot
    container_script = $containerScriptHostPath
    container_exit_code = $containerExitCode
    skip_pester = [bool]$SkipPester
    container_report = $containerReport
    errors = $errors
} | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $hostReportPath -Encoding utf8

if (-not $KeepContainerScript -and (Test-Path -LiteralPath $containerScriptHostPath -PathType Leaf)) {
    Remove-Item -LiteralPath $containerScriptHostPath -Force
}

Write-Host "Docker Linux iteration report: $hostReportPath"

if ($status -ne 'succeeded') {
    exit 1
}

exit 0
