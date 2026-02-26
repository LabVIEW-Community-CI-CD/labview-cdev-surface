#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$PhaseName,

    [Parameter(Mandatory = $true)]
    [string]$ArtifactRoot,

    [Parameter()]
    [int]$TimeoutSeconds = 60,

    [Parameter()]
    [int]$PollSeconds = 2,

    [Parameter()]
    [string]$OutputPath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Ensure-Directory {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        New-Item -Path $Path -ItemType Directory -Force | Out-Null
    }
}

function Get-LabviewProcessSnapshot {
    $items = @()
    foreach ($name in @('LabVIEW', 'LabVIEWCLI')) {
        $processes = @(Get-Process -Name $name -ErrorAction SilentlyContinue)
        foreach ($process in $processes) {
            $items += [ordered]@{
                name = [string]$process.ProcessName
                id = [int]$process.Id
            }
        }
    }
    return @($items)
}

$resolvedArtifactRoot = [System.IO.Path]::GetFullPath($ArtifactRoot)
Ensure-Directory -Path $resolvedArtifactRoot

$resolvedOutputPath = if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $token = ([string]$PhaseName).Trim().ToLowerInvariant()
    $token = [Regex]::Replace($token, '[^a-z0-9\-]', '-')
    $token = [Regex]::Replace($token, '-{2,}', '-').Trim('-')
    if ([string]::IsNullOrWhiteSpace($token)) {
        $token = 'bitness-handoff'
    }
    Join-Path $resolvedArtifactRoot ("bitness-handoff-{0}.json" -f $token)
} else {
    [System.IO.Path]::GetFullPath($OutputPath)
}
Ensure-Directory -Path (Split-Path -Path $resolvedOutputPath -Parent)

$timeoutSeconds = [Math]::Max(10, [int]$TimeoutSeconds)
$pollSeconds = [Math]::Max(1, [int]$PollSeconds)

$initial = @(Get-LabviewProcessSnapshot)
$terminated = @()
$errors = @()
$attemptedIds = @{}

$deadlineUtc = [DateTime]::UtcNow.AddSeconds($timeoutSeconds)
do {
    $current = @(Get-LabviewProcessSnapshot)
    if (@($current).Count -eq 0) {
        break
    }

    foreach ($item in $current) {
        $idKey = [string]$item.id
        if ($attemptedIds.ContainsKey($idKey)) {
            continue
        }
        $attemptedIds[$idKey] = $true
        try {
            Stop-Process -Id ([int]$item.id) -Force -ErrorAction Stop
            $terminated += [ordered]@{
                name = [string]$item.name
                id = [int]$item.id
            }
        } catch {
            $message = [string]$_.Exception.Message
            if ([string]::IsNullOrWhiteSpace($message)) {
                $message = [string]$_
            }
            $errors += [ordered]@{
                name = [string]$item.name
                id = [int]$item.id
                message = $message
            }
        }
    }

    if ([DateTime]::UtcNow -ge $deadlineUtc) {
        break
    }
    Start-Sleep -Seconds $pollSeconds
} while ($true)

$remaining = @(Get-LabviewProcessSnapshot)
$succeeded = (@($remaining).Count -eq 0)

$report = [ordered]@{
    timestamp_utc = (Get-Date).ToUniversalTime().ToString('o')
    phase_name = [string]$PhaseName
    timeout_seconds = [int]$timeoutSeconds
    poll_seconds = [int]$pollSeconds
    status = if ($succeeded) { 'succeeded' } else { 'failed' }
    failure_signature = if ($succeeded) { '' } else { 'bitness_handoff_failed' }
    initial_processes = @($initial)
    terminated_processes = @($terminated)
    errors = @($errors)
    remaining_processes = @($remaining)
}

$report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $resolvedOutputPath -Encoding utf8
Write-Host ("LabVIEW bitness handoff report: {0}" -f $resolvedOutputPath)

if (-not $succeeded) {
    $remainingSummary = @($remaining | ForEach-Object { "{0}:{1}" -f [string]$_.name, [int]$_.id }) -join ', '
    throw ("bitness_handoff_failed: phase={0}; remaining_processes={1}; report={2}" -f [string]$PhaseName, $remainingSummary, $resolvedOutputPath)
}

Get-Content -LiteralPath $resolvedOutputPath -Raw | Write-Output
