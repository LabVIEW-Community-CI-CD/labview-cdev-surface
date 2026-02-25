#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$RepoPath,

    [Parameter(Mandatory = $true)]
    [string]$ExecutionLabviewYear,

    [Parameter()]
    [ValidateSet('32', '64')]
    [string]$SupportedBitness = '64',

    [Parameter(Mandatory = $true)]
    [string]$ArtifactRoot,

    [Parameter()]
    [string]$ManifestPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'workspace-governance.json'),

    [Parameter()]
    [int]$TimeoutSeconds = 900,

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

function Get-HeadlessState {
    $sessionName = [string]$env:SESSIONNAME
    if ([string]::IsNullOrWhiteSpace($sessionName)) {
        $sessionName = 'unknown'
    }

    $sessionId = -1
    try {
        $sessionId = [System.Diagnostics.Process]::GetCurrentProcess().SessionId
    } catch {
        $sessionId = -1
    }

    $isInteractive = [System.Environment]::UserInteractive
    $sessionSignalsHeadless = ($sessionId -eq 0) -or ($sessionName -match '^(Services|Service)$')
    $isHeadless = (-not $isInteractive) -and $sessionSignalsHeadless

    return [pscustomobject]@{
        is_headless = $isHeadless
        session_name = $sessionName
        session_id = $sessionId
        interactive = $isInteractive
    }
}

function Resolve-LabVIEWSourceYear {
    param([Parameter(Mandatory = $true)][string]$RepoRoot)

    $lvversionPath = Join-Path $RepoRoot '.lvversion'
    if (-not (Test-Path -LiteralPath $lvversionPath -PathType Leaf)) {
        throw ".lvversion was not found in source repo: $lvversionPath"
    }

    $sourceLvversionRaw = (Get-Content -LiteralPath $lvversionPath -Raw).Trim()
    if ($sourceLvversionRaw -match '^(\d{4})$') {
        return [pscustomobject]@{
            source_year = [string]$Matches[1]
            raw = $sourceLvversionRaw
        }
    }
    if ($sourceLvversionRaw -match '^(\d{2})\.') {
        return [pscustomobject]@{
            source_year = [string](2000 + [int]$Matches[1])
            raw = $sourceLvversionRaw
        }
    }
    if ($sourceLvversionRaw -match '^(\d{4})\.') {
        return [pscustomobject]@{
            source_year = [string]$Matches[1]
            raw = $sourceLvversionRaw
        }
    }

    throw "Unsupported .lvversion format '$sourceLvversionRaw' in source repo."
}

function Invoke-CommandWithTimeout {
    param(
        [Parameter(Mandatory = $true)][string]$Executable,
        [Parameter()][string[]]$Arguments = @(),
        [Parameter(Mandatory = $true)][int]$TimeoutSeconds,
        [Parameter(Mandatory = $true)][string]$LogPath,
        [Parameter()][switch]$AppendLog
    )

    $stdoutPath = [System.IO.Path]::GetTempFileName()
    $stderrPath = [System.IO.Path]::GetTempFileName()
    $timedOut = $false
    $exitCode = 1
    $stdout = ''
    $stderr = ''
    $processId = -1

    try {
        $argumentLine = @(
            $Arguments | ForEach-Object {
                $value = [string]$_
                if ($value -match '[\s"]') {
                    '"' + ($value.Replace('"', '\"')) + '"'
                } else {
                    $value
                }
            }
        ) -join ' '

        $process = Start-Process `
            -FilePath $Executable `
            -ArgumentList $argumentLine `
            -NoNewWindow `
            -PassThru `
            -RedirectStandardOutput $stdoutPath `
            -RedirectStandardError $stderrPath
        $processId = [int]$process.Id

        $waitMilliseconds = [Math]::Max(1, [int]$TimeoutSeconds) * 1000
        $exited = $process.WaitForExit($waitMilliseconds)
        if (-not $exited) {
            $timedOut = $true
            try {
                $process.Kill()
            } catch {
                # best effort
            }
            $exitCode = 124
        } else {
            $exitCode = [int]$process.ExitCode
        }

        $stdout = if (Test-Path -LiteralPath $stdoutPath -PathType Leaf) { Get-Content -LiteralPath $stdoutPath -Raw } else { '' }
        $stderr = if (Test-Path -LiteralPath $stderrPath -PathType Leaf) { Get-Content -LiteralPath $stderrPath -Raw } else { '' }
    } finally {
        $combined = @()
        if (-not [string]::IsNullOrWhiteSpace($stdout)) { $combined += [string]$stdout }
        if (-not [string]::IsNullOrWhiteSpace($stderr)) { $combined += [string]$stderr }
        $content = if (@($combined).Count -gt 0) { $combined -join [Environment]::NewLine } else { '' }

        if ($AppendLog) {
            Add-Content -LiteralPath $LogPath -Value $content -Encoding utf8
        } else {
            Set-Content -LiteralPath $LogPath -Value $content -Encoding utf8
        }

        if (Test-Path -LiteralPath $stdoutPath -PathType Leaf) {
            Remove-Item -LiteralPath $stdoutPath -Force -ErrorAction SilentlyContinue
        }
        if (Test-Path -LiteralPath $stderrPath -PathType Leaf) {
            Remove-Item -LiteralPath $stderrPath -Force -ErrorAction SilentlyContinue
        }
    }

    return [pscustomobject]@{
        exit_code = $exitCode
        timed_out = $timedOut
        process_id = $processId
        output_text = [string]::Join([Environment]::NewLine, @($stdout, $stderr))
    }
}

$repoRoot = (Resolve-Path -Path (Join-Path $PSScriptRoot '..')).Path
$resolvedRepoPath = [System.IO.Path]::GetFullPath($RepoPath)
$resolvedManifestPath = [System.IO.Path]::GetFullPath($ManifestPath)
$resolvedArtifactRoot = [System.IO.Path]::GetFullPath($ArtifactRoot)
Ensure-Directory -Path $resolvedArtifactRoot

$reportPath = if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    Join-Path $resolvedArtifactRoot 'runner-cli-ppl-certification-report.json'
} else {
    [System.IO.Path]::GetFullPath($OutputPath)
}
Ensure-Directory -Path (Split-Path -Path $reportPath -Parent)

$headlessState = Get-HeadlessState
if (-not [bool]$headlessState.is_headless) {
    $headlessMessage = ("runner_not_headless: runner-cli PPL certification requires headless runner session. session='{0}' session_id={1} interactive={2}" -f [string]$headlessState.session_name, [int]$headlessState.session_id, [bool]$headlessState.interactive)
    throw $headlessMessage
}

if (-not (Test-Path -LiteralPath $resolvedRepoPath -PathType Container)) {
    throw "Repo path not found: $resolvedRepoPath"
}
if (-not (Test-Path -LiteralPath $resolvedManifestPath -PathType Leaf)) {
    throw "Manifest path not found: $resolvedManifestPath"
}

$portArtifactRoot = Join-Path $resolvedArtifactRoot 'port-contract'
Ensure-Directory -Path $portArtifactRoot
$ensurePortScript = Join-Path $repoRoot 'scripts\Ensure-LabVIEWCliPortContractAndIni.ps1'
if (-not (Test-Path -LiteralPath $ensurePortScript -PathType Leaf)) {
    throw "Required script missing: $ensurePortScript"
}

& $ensurePortScript `
    -RepoPath $resolvedRepoPath `
    -ExecutionLabviewYear $ExecutionLabviewYear `
    -SupportedBitness $SupportedBitness `
    -ArtifactRoot $portArtifactRoot
$portEnsureExitCode = 0
$lastExitVar = Get-Variable -Name LASTEXITCODE -Scope Global -ErrorAction SilentlyContinue
if ($null -ne $lastExitVar) {
    $portEnsureExitCode = [int]$lastExitVar.Value
}
if ($portEnsureExitCode -ne 0) {
    throw "Port contract remediation failed before runner-cli PPL certification (exit $portEnsureExitCode)."
}

$runnerCliBundleRoot = Join-Path $resolvedArtifactRoot 'runner-cli\win-x64'
Ensure-Directory -Path $runnerCliBundleRoot
$buildRunnerCliScript = Join-Path $repoRoot 'scripts\Build-RunnerCliBundleFromManifest.ps1'
if (-not (Test-Path -LiteralPath $buildRunnerCliScript -PathType Leaf)) {
    throw "Required script missing: $buildRunnerCliScript"
}

& $buildRunnerCliScript `
    -ManifestPath $resolvedManifestPath `
    -OutputRoot $runnerCliBundleRoot `
    -RepoName 'labview-icon-editor' `
    -Runtime 'win-x64'
$bundleExitCode = 0
$bundleExitVar = Get-Variable -Name LASTEXITCODE -Scope Global -ErrorAction SilentlyContinue
if ($null -ne $bundleExitVar) {
    $bundleExitCode = [int]$bundleExitVar.Value
}
if ($bundleExitCode -ne 0) {
    throw "Build-RunnerCliBundleFromManifest failed with exit code $bundleExitCode."
}

$runnerCliPath = Join-Path $runnerCliBundleRoot 'runner-cli.exe'
$runnerCliDllPath = Join-Path $runnerCliBundleRoot 'runner-cli.dll'
if (-not (Test-Path -LiteralPath $runnerCliPath -PathType Leaf)) {
    throw "runner-cli executable not found: $runnerCliPath"
}
if (-not (Test-Path -LiteralPath $runnerCliDllPath -PathType Leaf)) {
    throw "runner-cli launcher DLL not found: $runnerCliDllPath"
}

$sourceVersion = Resolve-LabVIEWSourceYear -RepoRoot $resolvedRepoPath
$repoPinnedSha = (& git -C $resolvedRepoPath rev-parse HEAD 2>$null).Trim().ToLowerInvariant()
if ($repoPinnedSha -notmatch '^[0-9a-f]{40}$') {
    throw "Unable to resolve source repo commit SHA for '$resolvedRepoPath'."
}
$commitArg = if ($repoPinnedSha.Length -gt 12) { $repoPinnedSha.Substring(0, 12) } else { $repoPinnedSha }

$commandArgs = @(
    'ppl', 'build',
    '--repo-root', $resolvedRepoPath,
    '--labview-version', [string]$sourceVersion.source_year,
    '--supported-bitness', $SupportedBitness,
    '--major', '0',
    '--minor', '0',
    '--patch', '0',
    '--build', '1',
    '--commit', $commitArg
)

$env:LVIE_RUNNERCLI_EXECUTION_LABVIEW_YEAR = $ExecutionLabviewYear
$env:LVIE_REMEDIATE_LABVIEWCLI_PORT_CONTRACT = '1'
$runnerCliLogPath = Join-Path $resolvedArtifactRoot ("runner-cli-ppl-build-{0}.log" -f $SupportedBitness)
$runnerCliInvocationPath = Join-Path $resolvedArtifactRoot 'runner-cli-invocation.json'

$invocation = [ordered]@{
    mode = 'exe'
    executable = $runnerCliPath
    launcher_dll = $runnerCliDllPath
    fallback_triggered = $false
    block_reason = ''
    block_message = ''
    timed_out = $false
    exit_code = 1
    timestamp_utc = (Get-Date).ToUniversalTime().ToString('o')
}

$primary = Invoke-CommandWithTimeout `
    -Executable $runnerCliPath `
    -Arguments $commandArgs `
    -TimeoutSeconds $TimeoutSeconds `
    -LogPath $runnerCliLogPath

$runnerCliExit = [int]$primary.exit_code
$runnerCliTimedOut = [bool]$primary.timed_out
$outputText = [string]$primary.output_text

if ($outputText -match 'Application Control policy has blocked this file') {
    $invocation.mode = 'dotnet-dll-fallback'
    $invocation.fallback_triggered = $true
    $invocation.block_reason = 'application_control_policy'
    $invocation.block_message = $outputText
    $fallback = Invoke-CommandWithTimeout `
        -Executable 'dotnet' `
        -Arguments @($runnerCliDllPath) + $commandArgs `
        -TimeoutSeconds $TimeoutSeconds `
        -LogPath $runnerCliLogPath `
        -AppendLog
    $runnerCliExit = [int]$fallback.exit_code
    $runnerCliTimedOut = [bool]$fallback.timed_out
}

$invocation.timed_out = $runnerCliTimedOut
$invocation.exit_code = $runnerCliExit
$invocation | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $runnerCliInvocationPath -Encoding utf8

$status = 'succeeded'
$builtPplPath = Join-Path $resolvedRepoPath 'resource\plugins\lv_icon.lvlibp'
$snapshotFileName = if ($SupportedBitness -eq '32') { 'lv_icon_x86.lvlibp' } else { 'lv_icon_x64.lvlibp' }
$snapshotPath = Join-Path $resolvedArtifactRoot $snapshotFileName

if ($runnerCliTimedOut -or $runnerCliExit -ne 0) {
    $status = 'failed'
}
if (-not (Test-Path -LiteralPath $builtPplPath -PathType Leaf)) {
    $status = 'failed'
}
if ($status -eq 'succeeded') {
    Copy-Item -LiteralPath $builtPplPath -Destination $snapshotPath -Force
}

$report = [ordered]@{
    timestamp_utc = (Get-Date).ToUniversalTime().ToString('o')
    status = $status
    repository_root = $resolvedRepoPath
    source_labview_year = [string]$sourceVersion.source_year
    source_lvversion_raw = [string]$sourceVersion.raw
    execution_labview_year = $ExecutionLabviewYear
    supported_bitness = $SupportedBitness
    source_repo_commit = $repoPinnedSha
    output_ppl_path = if ($status -eq 'succeeded') { $snapshotPath } else { '' }
    expected_repo_ppl_path = $builtPplPath
    headless_session = [ordered]@{
        is_headless = [bool]$headlessState.is_headless
        session_name = [string]$headlessState.session_name
        session_id = [int]$headlessState.session_id
        interactive = [bool]$headlessState.interactive
    }
    runner_cli = [ordered]@{
        executable = $runnerCliPath
        launcher_dll = $runnerCliDllPath
        invocation_path = $runnerCliInvocationPath
        log_path = $runnerCliLogPath
        timed_out = $runnerCliTimedOut
        exit_code = $runnerCliExit
        mode = [string]$invocation.mode
        fallback_triggered = [bool]$invocation.fallback_triggered
    }
    timeout_seconds = $TimeoutSeconds
    port_contract_report_path = Join-Path $portArtifactRoot 'labview-cli-port-contract-remediation-report.json'
    runner_cli_bundle_root = $runnerCliBundleRoot
}

$report | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $reportPath -Encoding utf8

Write-Host ("runner-cli PPL certification report: {0}" -f $reportPath)
Write-Host ("runner-cli PPL certification status: {0}" -f $status)

if ($status -ne 'succeeded') {
    throw ("runner-cli PPL certification failed (exit={0}, timed_out={1}). See report: {2}" -f [int]$runnerCliExit, [bool]$runnerCliTimedOut, $reportPath)
}

Get-Content -LiteralPath $reportPath -Raw | Write-Output
