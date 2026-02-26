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
    [string]$LabVIEWPath = '',

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

function Resolve-LabVIEWPath {
    param(
        [Parameter(Mandatory = $true)][string]$Year,
        [Parameter(Mandatory = $true)][string]$Bitness,
        [Parameter()][string]$PreferredPath = ''
    )

    if (-not [string]::IsNullOrWhiteSpace($PreferredPath)) {
        return [System.IO.Path]::GetFullPath($PreferredPath)
    }

    if ($Bitness -eq '32') {
        return "C:\Program Files (x86)\National Instruments\LabVIEW $Year\LabVIEW.exe"
    }
    return "C:\Program Files\National Instruments\LabVIEW $Year\LabVIEW.exe"
}

function Ensure-ViAnalyzerCompatiblePortContract {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepoRoot
    )

    $contractPath = Join-Path $RepoRoot 'Tooling\labviewcli-port-contract.json'
    if (-not (Test-Path -LiteralPath $contractPath -PathType Leaf)) {
        throw "LabVIEW CLI port contract not found for VI Analyzer compatibility: $contractPath"
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

        $yearPorts = $null
        if ($yearEntry.PSObject.Properties.Name -contains 'windows') {
            $yearPorts = $yearEntry.windows
        } else {
            $yearPorts = $yearEntry
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

function Resolve-ViAnalyzerConfigFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepoRoot,
        [Parameter(Mandatory = $true)]
        [string]$BaseName
    )

    foreach ($extension in @('.viancfg', '.vianfg')) {
        $candidate = Join-Path $RepoRoot ("{0}{1}" -f $BaseName, $extension)
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return [System.IO.Path]::GetFullPath($candidate)
        }
    }

    throw ("Required VI Analyzer config file is missing for base '{0}' under '{1}'." -f $BaseName, $RepoRoot)
}

function New-DerivedViAnalyzerTasksFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepoRoot,
        [Parameter(Mandatory = $true)]
        [string]$ArtifactRoot
    )

    $requiredConfigs = @(
        [ordered]@{ id = 'labview-icon-api'; base_name = 'brokenVIsOnLabVIEWIconAPI' },
        [ordered]@{ id = 'plugins'; base_name = 'brokenVIsOnPlugins' },
        [ordered]@{ id = 'tooling'; base_name = 'brokenVIsOnTooling' }
    )

    $resolvedConfigs = @()
    $tasks = @()
    foreach ($spec in $requiredConfigs) {
        $configPath = Resolve-ViAnalyzerConfigFile -RepoRoot $RepoRoot -BaseName ([string]$spec.base_name)
        $resolvedConfigs += $configPath
        $tasks += [ordered]@{
            id = [string]$spec.id
            config_path = [System.IO.Path]::GetFileName($configPath)
        }
    }

    $tasksDoc = [ordered]@{
        version = 1
        tasks = $tasks
    }

    $derivedTasksPath = Join-Path $ArtifactRoot 'vi-analyzer-tasks.derived.json'
    $tasksDoc | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $derivedTasksPath -Encoding utf8

    return [pscustomobject]@{
        tasks_path = $derivedTasksPath
        resolved_config_files = @($resolvedConfigs)
    }
}

$resolvedRepoPath = [System.IO.Path]::GetFullPath($RepoPath)
$resolvedArtifactRoot = [System.IO.Path]::GetFullPath($ArtifactRoot)
Ensure-Directory -Path $resolvedArtifactRoot

$reportPath = if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    Join-Path $resolvedArtifactRoot 'vi-analyzer-certification-report.json'
} else {
    [System.IO.Path]::GetFullPath($OutputPath)
}
Ensure-Directory -Path (Split-Path -Path $reportPath -Parent)

$headlessState = Get-HeadlessState
if (-not [bool]$headlessState.is_headless) {
    $headlessMessage = ("runner_not_headless: VI Analyzer certification requires headless runner session. session='{0}' session_id={1} interactive={2}" -f [string]$headlessState.session_name, [int]$headlessState.session_id, [bool]$headlessState.interactive)
    throw $headlessMessage
}

if (-not (Test-Path -LiteralPath $resolvedRepoPath -PathType Container)) {
    throw "Repo path not found: $resolvedRepoPath"
}

$viAnalyzerScript = Join-Path $resolvedRepoPath 'Tooling\container-parity\run-vi-analyzer-windows.ps1'
if (-not (Test-Path -LiteralPath $viAnalyzerScript -PathType Leaf)) {
    throw "VI Analyzer script not found: $viAnalyzerScript"
}

$resolvedLabVIEWPath = Resolve-LabVIEWPath -Year $ExecutionLabviewYear -Bitness $SupportedBitness -PreferredPath $LabVIEWPath
if (-not (Test-Path -LiteralPath $resolvedLabVIEWPath -PathType Leaf)) {
    throw "LabVIEW executable not found for VI Analyzer certification: $resolvedLabVIEWPath"
}

$compatibilityContract = Ensure-ViAnalyzerCompatiblePortContract -RepoRoot $resolvedRepoPath
if ([bool]$compatibilityContract.rewritten) {
    Write-Host ("Rewrote LabVIEW CLI port contract for VI Analyzer compatibility: {0}" -f [string]$compatibilityContract.contract_path)
}

$statusPath = Join-Path $resolvedArtifactRoot 'vi-analyzer-status.json'
$reportsRoot = Join-Path $resolvedArtifactRoot 'reports'
$sourceSyncManifestPath = Join-Path $resolvedArtifactRoot 'source-sync-manifest.json'
$viAnalyzerLogPath = Join-Path $resolvedArtifactRoot 'vi-analyzer-certification.log'
$derivedTasks = New-DerivedViAnalyzerTasksFile -RepoRoot $resolvedRepoPath -ArtifactRoot $resolvedArtifactRoot
$tasksPath = [string]$derivedTasks.tasks_path
Ensure-Directory -Path $reportsRoot

$processArgs = @(
    '-NoLogo',
    '-NoProfile',
    '-NonInteractive',
    '-ExecutionPolicy', 'Bypass',
    '-File', $viAnalyzerScript,
    '-WorkspaceRoot', $resolvedRepoPath,
    '-LabVIEWPath', $resolvedLabVIEWPath,
    '-LabVIEWVersion', $ExecutionLabviewYear,
    '-LabVIEWBitness', $SupportedBitness,
    '-TasksPath', $tasksPath,
    '-ReportsRoot', $reportsRoot,
    '-StatusPath', $statusPath,
    '-SourceSyncManifestPath', $sourceSyncManifestPath
)

$process = $null
$timedOut = $false
$exitCode = 1
$processId = -1
$status = 'failed'
$stdoutPath = [System.IO.Path]::GetTempFileName()
$stderrPath = [System.IO.Path]::GetTempFileName()
$outputText = ''

try {
    $argumentLine = @(
        $processArgs | ForEach-Object {
            $value = [string]$_
            if ($value -match '[\s"]') {
                '"' + ($value.Replace('"', '\"')) + '"'
            } else {
                $value
            }
        }
    ) -join ' '

    $process = Start-Process `
        -FilePath 'powershell' `
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

    if ($exitCode -eq 0 -and -not $timedOut) {
        $status = 'succeeded'
    }
} finally {
    $stdoutText = if (Test-Path -LiteralPath $stdoutPath -PathType Leaf) { Get-Content -LiteralPath $stdoutPath -Raw } else { '' }
    $stderrText = if (Test-Path -LiteralPath $stderrPath -PathType Leaf) { Get-Content -LiteralPath $stderrPath -Raw } else { '' }
    $combinedOutput = @()
    if (-not [string]::IsNullOrWhiteSpace($stdoutText)) { $combinedOutput += [string]$stdoutText }
    if (-not [string]::IsNullOrWhiteSpace($stderrText)) { $combinedOutput += [string]$stderrText }
    $outputText = if (@($combinedOutput).Count -gt 0) { $combinedOutput -join [Environment]::NewLine } else { '' }
    Set-Content -LiteralPath $viAnalyzerLogPath -Value $outputText -Encoding utf8

    if (Test-Path -LiteralPath $stdoutPath -PathType Leaf) {
        Remove-Item -LiteralPath $stdoutPath -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path -LiteralPath $stderrPath -PathType Leaf) {
        Remove-Item -LiteralPath $stderrPath -Force -ErrorAction SilentlyContinue
    }

    $statusPayload = $null
    if (Test-Path -LiteralPath $statusPath -PathType Leaf) {
        try {
            $statusPayload = Get-Content -LiteralPath $statusPath -Raw | ConvertFrom-Json -ErrorAction Stop
            if ($null -eq $statusPayload.overall_success -or -not [bool]$statusPayload.overall_success) {
                $status = 'failed'
            }
        } catch {
            $status = 'failed'
        }
    } else {
        $status = 'failed'
    }

    $report = [ordered]@{
        timestamp_utc = (Get-Date).ToUniversalTime().ToString('o')
        status = $status
        repository_root = $resolvedRepoPath
        execution_labview_year = $ExecutionLabviewYear
        supported_bitness = $SupportedBitness
        headless_session = [ordered]@{
            is_headless = [bool]$headlessState.is_headless
            session_name = [string]$headlessState.session_name
            session_id = [int]$headlessState.session_id
            interactive = [bool]$headlessState.interactive
        }
        labview_path = $resolvedLabVIEWPath
        vi_analyzer_script = $viAnalyzerScript
        reports_root = $reportsRoot
        status_path = $statusPath
        source_sync_manifest_path = $sourceSyncManifestPath
        vi_analyzer_log_path = $viAnalyzerLogPath
        vi_analyzer_tasks_path = $tasksPath
        vi_analyzer_config_files = @($derivedTasks.resolved_config_files)
        port_contract_path = [string]$compatibilityContract.contract_path
        port_contract_rewritten = [bool]$compatibilityContract.rewritten
        port_contract_backup_path = [string]$compatibilityContract.backup_path
        timeout_seconds = $TimeoutSeconds
        timed_out = [bool]$timedOut
        exit_code = [int]$exitCode
        process_id = [int]$processId
        output_excerpt = if ([string]::IsNullOrWhiteSpace($outputText)) { '' } elseif ($outputText.Length -le 2000) { $outputText } else { $outputText.Substring($outputText.Length - 2000) }
        overall_success = if ($null -ne $statusPayload -and $statusPayload.PSObject.Properties.Name -contains 'overall_success') { [bool]$statusPayload.overall_success } else { $false }
        task_count = if ($null -ne $statusPayload -and $statusPayload.PSObject.Properties.Name -contains 'task_count') { [int]$statusPayload.task_count } else { 0 }
    }

    $report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $reportPath -Encoding utf8
}

Write-Host ("VI Analyzer certification report: {0}" -f $reportPath)
Write-Host ("VI Analyzer certification status: {0}" -f $status)

if ($status -ne 'succeeded') {
    throw ("VI Analyzer certification failed (exit={0}, timed_out={1}). See report: {2}; log: {3}" -f [int]$exitCode, [bool]$timedOut, $reportPath, $viAnalyzerLogPath)
}

Get-Content -LiteralPath $reportPath -Raw | Write-Output
