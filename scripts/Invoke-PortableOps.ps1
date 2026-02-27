#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ScriptPath,

    [Parameter()]
    [string[]]$ScriptArguments = @(),

    [Parameter()]
    [string]$Image = 'ghcr.io/labview-community-ci-cd/labview-cdev-surface-ops:v1',

    [Parameter()]
    [switch]$BuildLocalImage,

    [Parameter()]
    [string]$LocalTag = 'labview-cdev-surface-ops:local',

    [Parameter()]
    [switch]$HostFallback
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path -Path (Join-Path $PSScriptRoot '..')).Path
$resolvedScriptPath = [System.IO.Path]::GetFullPath((Join-Path $repoRoot $ScriptPath))
if (-not (Test-Path -LiteralPath $resolvedScriptPath -PathType Leaf)) {
    throw "script_not_found: $resolvedScriptPath"
}

$dockerInfo = & docker info 2>$null
$dockerReady = ($LASTEXITCODE -eq 0)
if (-not $dockerReady -and $HostFallback) {
    & pwsh -NoProfile -File $resolvedScriptPath @ScriptArguments
    exit $LASTEXITCODE
}
if (-not $dockerReady) {
    throw 'docker_not_ready: start Docker Desktop or use -HostFallback.'
}

if ($BuildLocalImage) {
    & docker build -f (Join-Path $repoRoot 'tools/ops-runtime/Dockerfile') -t $LocalTag (Join-Path $repoRoot 'tools/ops-runtime')
    if ($LASTEXITCODE -ne 0) {
        throw 'docker_image_build_failed: unable to build local ops image.'
    }
    $Image = $LocalTag
}

$relativeScript = [System.IO.Path]::GetRelativePath($repoRoot, $resolvedScriptPath).Replace('\', '/')
$containerScript = "/workspace/$relativeScript"
$dockerArgs = @('run', '--rm', '-v', "${repoRoot}:/workspace", '-w', '/workspace')
if (-not [string]::IsNullOrWhiteSpace($env:GH_TOKEN)) {
    $dockerArgs += @('-e', "GH_TOKEN=$($env:GH_TOKEN)")
}
$dockerArgs += @($Image, 'pwsh', '-NoProfile', '-File', $containerScript)
$dockerArgs += @($ScriptArguments)

& docker @dockerArgs
$exitCode = if ($null -eq $LASTEXITCODE) { 0 } else { [int]$LASTEXITCODE }
exit $exitCode
