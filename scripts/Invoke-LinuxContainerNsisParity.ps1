#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter()]
    [string]$Image = 'labview-cdev-surface-nsis-linux-parity:local',

    [Parameter()]
    [switch]$BuildLocalImage,

    [Parameter()]
    [string]$DockerfilePath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'tools\nsis-selftest-linux\Dockerfile'),

    [Parameter()]
    [string]$DockerContext = 'desktop-linux',

    [Parameter()]
    [string]$OutputRoot = (Join-Path (Split-Path -Parent $PSScriptRoot) 'artifacts\release\linux-container-nsis-parity'),

    [Parameter()]
    [string]$ContainerRepoMount = '/repo',

    [Parameter()]
    [string]$ContainerOutputMount = '/hostout',

    [Parameter()]
    [ValidatePattern('^[a-z0-9][a-z0-9_.-]{2,50}$')]
    [string]$ContainerNamePrefix = 'lvie-cdev-linux-nsis',

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

$repoRoot = (Resolve-Path -Path (Join-Path $PSScriptRoot '..')).Path
$resolvedDockerfilePath = [System.IO.Path]::GetFullPath($DockerfilePath)
$dockerBuildContext = [System.IO.Path]::GetDirectoryName($resolvedDockerfilePath)
$resolvedOutputRoot = [System.IO.Path]::GetFullPath($OutputRoot)
$containerScriptPath = Join-Path $resolvedOutputRoot 'container-run.sh'
$containerReportPath = Join-Path $resolvedOutputRoot 'container-report.json'
$hostReportPath = Join-Path $resolvedOutputRoot 'linux-container-nsis-parity-report.json'

Assert-Command -Name 'docker'

if (-not (Test-Path -LiteralPath $resolvedDockerfilePath -PathType Leaf)) {
    throw "Dockerfile not found: $resolvedDockerfilePath"
}

Ensure-Directory -Path $resolvedOutputRoot
if (Test-Path -LiteralPath $containerReportPath -PathType Leaf) {
    Remove-Item -LiteralPath $containerReportPath -Force
}

$contextArgs = @()
if (-not [string]::IsNullOrWhiteSpace($DockerContext)) {
    $contextArgs += @('--context', $DockerContext)
}

Get-CommandOutputOrThrow -Command 'docker' -Arguments @($contextArgs + @('info'))

if ($BuildLocalImage) {
    $buildArgs = @($contextArgs + @('build', '-f', $resolvedDockerfilePath, '-t', $Image, $dockerBuildContext))
    Get-CommandOutputOrThrow -Command 'docker' -Arguments $buildArgs
}

$containerScriptContent = @'
#!/usr/bin/env bash
set -euo pipefail

repo_root="__REPO_MOUNT__"
host_out="__OUTPUT_MOUNT__"
work_root="/tmp/nsis-linux-parity"
smoke_nsi="$work_root/nsis-smoke.nsi"
smoke_installer="$host_out/nsis-linux-parity-smoke.exe"
makensis_log="$host_out/makensis-linux-parity.log"

mkdir -p "$host_out"
rm -rf "$work_root"
mkdir -p "$work_root"

status="succeeded"
reason_code=""
compile_status="not_run"
smoke_sha256=""
missing_commands=()

# LabVIEWCLI binary casing varies by image surface; support both deterministic probes.
if ! command -v "labviewcli" >/dev/null 2>&1 && ! command -v "LabVIEWCLI" >/dev/null 2>&1; then
  missing_commands+=("LabVIEWCLI")
fi

for command_name in makensis git dotnet pwsh; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    missing_commands+=("$command_name")
  fi
done

if [[ ${#missing_commands[@]} -gt 0 ]]; then
  status="failed"
  reason_code="toolchain_missing"
fi

cat > "$smoke_nsi" <<'NSIS'
Unicode True
OutFile "/hostout/nsis-linux-parity-smoke.exe"
Section
SectionEnd
NSIS

if [[ "$status" == "succeeded" ]]; then
  if makensis -V2 "$smoke_nsi" >"$makensis_log" 2>&1; then
    compile_status="pass"
  else
    compile_status="fail"
    status="failed"
    reason_code="nsis_compile_failed"
  fi
fi

if [[ -f "$smoke_installer" ]]; then
  smoke_sha256="$(sha256sum "$smoke_installer" | awk '{print $1}')"
fi

missing_csv=""
if [[ ${#missing_commands[@]} -gt 0 ]]; then
  missing_csv="$(IFS=,; echo "${missing_commands[*]}")"
fi

jq -n \
  --arg timestamp "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
  --arg status "$status" \
  --arg reason_code "$reason_code" \
  --arg missing_csv "$missing_csv" \
  --arg compile_status "$compile_status" \
  --arg makensis_log "$makensis_log" \
  --arg smoke_installer "$smoke_installer" \
  --arg smoke_sha256 "$smoke_sha256" \
  --arg installer_execution_status "skipped" \
  --arg installer_execution_reason "windows_installer_not_executable_on_linux" \
  '{
      timestamp_utc: $timestamp,
      status: $status,
      reason_code: $reason_code,
      missing_commands: (if $missing_csv == "" then [] else ($missing_csv | split(",")) end),
      nsis_compile_status: $compile_status,
      makensis_log_path: $makensis_log,
      smoke_installer_path: $smoke_installer,
      smoke_installer_sha256: $smoke_sha256,
      installer_execution_status: $installer_execution_status,
      installer_execution_reason: $installer_execution_reason
   }' > "$host_out/container-report.json"

if [[ "$status" != "succeeded" ]]; then
  exit 1
fi

exit 0
'@

$containerScriptContent = $containerScriptContent.Replace('__REPO_MOUNT__', $ContainerRepoMount)
$containerScriptContent = $containerScriptContent.Replace('__OUTPUT_MOUNT__', $ContainerOutputMount)
$containerScriptContent = $containerScriptContent -replace "`r`n", "`n"
[System.IO.File]::WriteAllText($containerScriptPath, $containerScriptContent, [System.Text.UTF8Encoding]::new($false))

$containerName = ('{0}-{1}' -f $ContainerNamePrefix, ([guid]::NewGuid().ToString('n').Substring(0, 12))).ToLowerInvariant()
$dockerRepoVolume = ('{0}:{1}' -f $repoRoot, $ContainerRepoMount)
$dockerOutputVolume = ('{0}:{1}' -f $resolvedOutputRoot, $ContainerOutputMount)
$containerScriptInContainer = if ($ContainerOutputMount.EndsWith('/')) {
    "$ContainerOutputMount" + 'container-run.sh'
} else {
    "$ContainerOutputMount/container-run.sh"
}
$containerExitCode = 0
$status = 'unknown'
$errors = @()
$containerReport = $null
$startedUtc = (Get-Date).ToUniversalTime()

try {
    $runArgs = @($contextArgs + @(
        'run',
        '--rm',
        '--name', $containerName,
        '-v', $dockerRepoVolume,
        '-v', $dockerOutputVolume,
        $Image,
        'bash', $containerScriptInContainer
    ))

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
    container_exit_code = $containerExitCode
    container_report_path = $containerReportPath
    container_report = $containerReport
    errors = $errors
} | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $hostReportPath -Encoding utf8

if (-not $KeepContainerScript -and (Test-Path -LiteralPath $containerScriptPath -PathType Leaf)) {
    Remove-Item -LiteralPath $containerScriptPath -Force
}

Write-Host "Linux container NSIS parity report: $hostReportPath"

if ($status -ne 'succeeded') {
    exit 1
}

exit 0
