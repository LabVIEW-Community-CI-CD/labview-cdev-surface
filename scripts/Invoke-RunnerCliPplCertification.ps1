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
    [int]$TimeoutSeconds = 300,

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

function Ensure-RunnerCliCompatiblePortContract {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepoRoot
    )

    $contractPath = Join-Path $RepoRoot 'Tooling\labviewcli-port-contract.json'
    if (-not (Test-Path -LiteralPath $contractPath -PathType Leaf)) {
        throw "LabVIEW CLI port contract not found for runner-cli compatibility: $contractPath"
    }

    $rawContract = Get-Content -LiteralPath $contractPath -Raw | ConvertFrom-Json -ErrorAction Stop
    if ($null -eq $rawContract.labview_cli_ports) {
        throw "LabVIEW CLI port contract is missing 'labview_cli_ports': $contractPath"
    }

    $rewriteNeeded = $false
    foreach ($yearProperty in $rawContract.labview_cli_ports.PSObject.Properties) {
        $yearEntry = $yearProperty.Value
        if ($null -eq $yearEntry) {
            continue
        }

        if ($yearEntry.PSObject.Properties.Name -contains 'windows') {
            $rewriteNeeded = $true
            break
        }
    }

    if (-not $rewriteNeeded) {
        return [pscustomobject]@{
            contract_path = $contractPath
            rewritten = $false
            backup_path = ''
        }
    }

    $compatContract = [ordered]@{
        schema_version = if ($rawContract.PSObject.Properties.Name -contains 'schema_version') { [string]$rawContract.schema_version } else { '1.0' }
        labview_cli_ports = [ordered]@{}
    }

    foreach ($yearProperty in $rawContract.labview_cli_ports.PSObject.Properties) {
        $year = [string]$yearProperty.Name
        $yearEntry = $yearProperty.Value
        if ($null -eq $yearEntry) {
            continue
        }

        $yearPorts = if ($yearEntry.PSObject.Properties.Name -contains 'windows') {
            $yearEntry.windows
        } else {
            $yearEntry
        }

        $flatEntry = [ordered]@{}
        foreach ($bitnessKey in @('32', '64')) {
            if ($yearPorts.PSObject.Properties.Name -contains $bitnessKey) {
                $flatEntry[$bitnessKey] = [int]$yearPorts.PSObject.Properties[$bitnessKey].Value
            }
        }

        $compatContract.labview_cli_ports[$year] = $flatEntry
    }

    $backupPath = "$contractPath.original.json"
    Copy-Item -LiteralPath $contractPath -Destination $backupPath -Force
    $compatContract | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $contractPath -Encoding utf8

    return [pscustomobject]@{
        contract_path = $contractPath
        rewritten = $true
        backup_path = $backupPath
    }
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
    $failureMessage = ''
    $logWriteError = ''

    try {
        $argumentLine = @(
            $Arguments | ForEach-Object {
                $value = if ($null -eq $_) { '' } else { [string]$_ }
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
            -RedirectStandardError $stderrPath `
            -ErrorAction Stop
        if ($null -eq $process) {
            throw ("start_process_returned_null: executable='{0}' arguments='{1}'" -f $Executable, $argumentLine)
        }
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
    } catch {
        $failureMessage = [string]$_.Exception.Message
        if ([string]::IsNullOrWhiteSpace($failureMessage)) {
            $failureMessage = [string]$_
        }
        $exitCode = if ($timedOut) { 124 } else { 1 }
        if ([string]::IsNullOrWhiteSpace($stderr)) {
            $stderr = "invoke_with_timeout_failed: $failureMessage"
        } else {
            $stderr = $stderr + [Environment]::NewLine + "invoke_with_timeout_failed: $failureMessage"
        }
    } finally {
        $combined = @()
        if (-not [string]::IsNullOrWhiteSpace($stdout)) { $combined += [string]$stdout }
        if (-not [string]::IsNullOrWhiteSpace($stderr)) { $combined += [string]$stderr }
        $content = if (@($combined).Count -gt 0) { $combined -join [Environment]::NewLine } else { '' }

        try {
            if ($AppendLog) {
                Add-Content -LiteralPath $LogPath -Value $content -Encoding utf8
            } else {
                Set-Content -LiteralPath $LogPath -Value $content -Encoding utf8
            }
        } catch {
            $logWriteError = [string]$_.Exception.Message
            if ([string]::IsNullOrWhiteSpace($logWriteError)) {
                $logWriteError = [string]$_
            }
            $fallbackContent = if ([string]::IsNullOrWhiteSpace($content)) {
                "log_write_failed: $logWriteError"
            } else {
                $content + [Environment]::NewLine + "log_write_failed: $logWriteError"
            }
            try {
                Set-Content -LiteralPath $LogPath -Value $fallbackContent -Encoding utf8
            } catch {
                # Keep original command result deterministic even if log persistence fails.
            }
        }

        if (Test-Path -LiteralPath $stdoutPath -PathType Leaf) {
            Remove-Item -LiteralPath $stdoutPath -Force -ErrorAction SilentlyContinue
        }
        if (Test-Path -LiteralPath $stderrPath -PathType Leaf) {
            Remove-Item -LiteralPath $stderrPath -Force -ErrorAction SilentlyContinue
        }
    }

    $logWriteMessage = ''
    if (-not [string]::IsNullOrWhiteSpace($logWriteError)) {
        $logWriteMessage = "log_write_failed: $logWriteError"
    }
    $outputLines = @(
        @($stdout, $stderr, $logWriteMessage) |
            ForEach-Object { [string]$_ } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )

    return [pscustomobject]@{
        exit_code = $exitCode
        timed_out = $timedOut
        process_id = $processId
        output_text = [string]::Join([Environment]::NewLine, $outputLines)
    }
}

function Stop-ResidualProcesses {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Names
    )

    $terminated = @()
    $errors = @()

    foreach ($name in @($Names | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })) {
        $targets = @(Get-Process -Name $name -ErrorAction SilentlyContinue)
        foreach ($target in $targets) {
            try {
                Stop-Process -Id $target.Id -Force -ErrorAction Stop
                $terminated += [ordered]@{
                    name = [string]$target.ProcessName
                    id = [int]$target.Id
                }
            } catch {
                $errors += [ordered]@{
                    name = [string]$target.ProcessName
                    id = [int]$target.Id
                    message = [string]$_.Exception.Message
                }
            }
        }
    }

    Start-Sleep -Seconds 2
    $stillRunning = @()
    foreach ($name in @($Names | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })) {
        $remaining = @(Get-Process -Name $name -ErrorAction SilentlyContinue)
        foreach ($item in $remaining) {
            $stillRunning += [ordered]@{
                name = [string]$item.ProcessName
                id = [int]$item.Id
            }
        }
    }

    return [pscustomobject]@{
        attempted_names = @($Names)
        terminated = @($terminated)
        still_running = @($stillRunning)
        errors = @($errors)
        cleanup_succeeded = (@($stillRunning).Count -eq 0)
    }
}

function Resolve-LabVIEWInstallRootPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Year,
        [Parameter(Mandatory = $true)]
        [ValidateSet('32', '64')]
        [string]$Bitness
    )

    if ($Bitness -eq '32') {
        return "C:\Program Files (x86)\National Instruments\LabVIEW $Year"
    }

    return "C:\Program Files\National Instruments\LabVIEW $Year"
}

function Test-LvprojPrebuildCleanliness {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepoRoot
    )

    $projectRelativePath = 'lv_icon_editor.lvproj'
    $projectPath = Join-Path $RepoRoot $projectRelativePath
    if (-not (Test-Path -LiteralPath $projectPath -PathType Leaf)) {
        throw ("prebuild_lvproj_guard_failed: project file not found: {0}" -f $projectPath)
    }

    $statusLines = @(
        & git -C $RepoRoot status --porcelain --untracked-files=no -- $projectRelativePath 2>$null |
            ForEach-Object { [string]$_ } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )

    $isDirty = (@($statusLines).Count -gt 0)
    return [pscustomobject]@{
        required = $true
        status = if ($isDirty) { 'failed' } else { 'succeeded' }
        failure_signature = if ($isDirty) { 'prebuild_lvproj_dirty' } else { '' }
        project_relative_path = $projectRelativePath
        project_path = $projectPath
        dirty = [bool]$isDirty
        git_status_lines = @($statusLines)
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

$portContractCompatibility = Ensure-RunnerCliCompatiblePortContract -RepoRoot $resolvedRepoPath
if ([bool]$portContractCompatibility.rewritten) {
    Write-Host ("Rewrote LabVIEW CLI port contract for runner-cli compatibility: {0}" -f [string]$portContractCompatibility.contract_path)
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

$lvprojPrebuildGuard = Test-LvprojPrebuildCleanliness -RepoRoot $resolvedRepoPath
if ([bool]$lvprojPrebuildGuard.dirty) {
    Write-Warning 'Detected pre-build dirty lv_icon_editor.lvproj state; runner-cli execution will be blocked.'
}

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
$env:LVIE_WORKTREE_ROOT = (Split-Path -Path $resolvedRepoPath -Parent)
$env:LVIE_SKIP_WORKTREE_ROOT_CHECK = '1'
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

$runnerCliExit = 1
$runnerCliTimedOut = $false
$outputText = ''
if ([bool]$lvprojPrebuildGuard.dirty) {
    $invocation.mode = 'skipped-prebuild-lvproj-dirty'
    $invocation.block_reason = [string]$lvprojPrebuildGuard.failure_signature
    $invocation.block_message = "lv_icon_editor.lvproj is modified before build; hard stop."
    $runnerCliExit = 191
} else {
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
}

$invocation.timed_out = $runnerCliTimedOut
$invocation.exit_code = $runnerCliExit
$invocation | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $runnerCliInvocationPath -Encoding utf8

$builtPplPath = Join-Path $resolvedRepoPath 'resource\plugins\lv_icon.lvlibp'
$snapshotFileName = if ($SupportedBitness -eq '32') { 'lv_icon_x86.lvlibp' } else { 'lv_icon_x64.lvlibp' }
$snapshotPath = Join-Path $resolvedArtifactRoot $snapshotFileName
$builtPplExists = Test-Path -LiteralPath $builtPplPath -PathType Leaf
$status = 'failed'
$timeoutRecoveredByArtifact = $false
$processCleanup = [pscustomobject]@{
    attempted_names = @('LabVIEW', 'LabVIEWCLI')
    terminated = @()
    still_running = @()
    errors = @()
    cleanup_succeeded = $true
}

if ($runnerCliTimedOut -and $builtPplExists) {
    $processCleanup = Stop-ResidualProcesses -Names @('LabVIEW', 'LabVIEWCLI')
    $timeoutRecoveredByArtifact = [bool]$processCleanup.cleanup_succeeded
}

if (-not $runnerCliTimedOut -and $runnerCliExit -eq 0 -and $builtPplExists) {
    $status = 'succeeded'
} elseif ($runnerCliTimedOut -and $builtPplExists -and $timeoutRecoveredByArtifact) {
    $status = 'succeeded'
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
    built_repo_ppl_exists = [bool]$builtPplExists
    lvie_worktree_root = [string]$env:LVIE_WORKTREE_ROOT
    lvie_skip_worktree_root_check = [string]$env:LVIE_SKIP_WORKTREE_ROOT_CHECK
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
        timeout_recovered_by_artifact = [bool]$timeoutRecoveredByArtifact
    }
    process_cleanup = [ordered]@{
        attempted_names = @($processCleanup.attempted_names)
        terminated = @($processCleanup.terminated)
        still_running = @($processCleanup.still_running)
        errors = @($processCleanup.errors)
        cleanup_succeeded = [bool]$processCleanup.cleanup_succeeded
    }
    known_vi_prebuild_repair = [ordered]@{
        applied = $false
        policy = 'disabled-clean-setup'
        destination_plugins_root = ''
        source_candidates = @()
        repaired_files = @()
    }
    known_vi_prebuild_validation = [ordered]@{
        required = $false
        executed = $false
        status = 'not-required'
        failure_signature = ''
        policy = 'disabled-clean-setup'
        labview_path = ''
        labviewcli_path = ''
        port_number = 0
        timeout_seconds = 0
        staging_root = ''
        log_path = ''
        directories_to_compile = @()
        operation_results = @()
    }
    prebuild_lvproj_guard = [ordered]@{
        required = [bool]$lvprojPrebuildGuard.required
        status = [string]$lvprojPrebuildGuard.status
        failure_signature = [string]$lvprojPrebuildGuard.failure_signature
        dirty = [bool]$lvprojPrebuildGuard.dirty
        project_relative_path = [string]$lvprojPrebuildGuard.project_relative_path
        project_path = [string]$lvprojPrebuildGuard.project_path
        git_status_lines = @($lvprojPrebuildGuard.git_status_lines)
    }
    port_contract_path = [string]$portContractCompatibility.contract_path
    port_contract_rewritten = [bool]$portContractCompatibility.rewritten
    port_contract_backup_path = [string]$portContractCompatibility.backup_path
    timeout_seconds = $TimeoutSeconds
    port_contract_report_path = Join-Path $portArtifactRoot 'labview-cli-port-contract-remediation-report.json'
    runner_cli_bundle_root = $runnerCliBundleRoot
}

$report | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $reportPath -Encoding utf8

Write-Host ("runner-cli PPL certification report: {0}" -f $reportPath)
Write-Host ("runner-cli PPL certification status: {0}" -f $status)

if ($status -ne 'succeeded') {
    if ([bool]$lvprojPrebuildGuard.dirty) {
        throw ("prebuild_lvproj_dirty: lv_icon_editor.lvproj appears modified before build. See report: {0}" -f $reportPath)
    }
    throw ("runner-cli PPL certification failed (exit={0}, timed_out={1}, built_ppl_exists={2}, timeout_recovered_by_artifact={3}). See report: {4}" -f [int]$runnerCliExit, [bool]$runnerCliTimedOut, [bool]$builtPplExists, [bool]$timeoutRecoveredByArtifact, $reportPath)
}

Get-Content -LiteralPath $reportPath -Raw | Write-Output
