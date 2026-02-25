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

    [Parameter()]
    [ValidateSet('windows-host')]
    [string]$PortContext = 'windows-host',

    [Parameter(Mandatory = $true)]
    [string]$ArtifactRoot,

    [Parameter()]
    [string]$LabVIEWPath = '',

    [Parameter()]
    [int]$TimeoutSeconds = 600,

    [Parameter()]
    [string[]]$ExcludeFiles = @('Polymorphic Template.vi'),

    [Parameter()]
    [string]$TargetRelativePath = 'vi.lib\LabVIEW Icon API',

    [Parameter()]
    [string]$OutputPath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

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

function Ensure-Directory {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        New-Item -Path $Path -ItemType Directory -Force | Out-Null
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

function Invoke-NativeWithTimeout {
    param(
        [Parameter(Mandatory = $true)][string]$Executable,
        [Parameter()][string[]]$Arguments = @(),
        [Parameter(Mandatory = $true)][int]$TimeoutSeconds,
        [Parameter(Mandatory = $true)][string]$LogPath
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
        try {
            $combined = @()
            if (-not [string]::IsNullOrWhiteSpace($stdout)) { $combined += [string]$stdout }
            if (-not [string]::IsNullOrWhiteSpace($stderr)) { $combined += [string]$stderr }
            $content = if (@($combined).Count -gt 0) { $combined -join [Environment]::NewLine } else { '' }
            Set-Content -LiteralPath $LogPath -Value $content -Encoding utf8
        } catch {
            # best effort
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
        stdout = [string]$stdout
        stderr = [string]$stderr
    }
}

$repoRoot = (Resolve-Path -Path (Join-Path $PSScriptRoot '..')).Path
$resolvedRepoPath = [System.IO.Path]::GetFullPath($RepoPath)
$resolvedArtifactRoot = [System.IO.Path]::GetFullPath($ArtifactRoot)
Ensure-Directory -Path $resolvedArtifactRoot

$headlessState = Get-HeadlessState
if (-not [bool]$headlessState.is_headless) {
    $headlessMessage = ("runner_not_headless: MassCompile certification requires headless runner session. session='{0}' session_id={1} interactive={2}" -f [string]$headlessState.session_name, [int]$headlessState.session_id, [bool]$headlessState.interactive)
    throw $headlessMessage
}

$timestamp = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss')
$massCompileLogPath = Join-Path $resolvedArtifactRoot ("labviewcli-masscompile-{0}.log" -f $timestamp)
$reportPath = if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    Join-Path $resolvedArtifactRoot 'masscompile-certification-report.json'
} else {
    [System.IO.Path]::GetFullPath($OutputPath)
}
Ensure-Directory -Path (Split-Path -Path $reportPath -Parent)

if (-not (Test-Path -LiteralPath $resolvedRepoPath -PathType Container)) {
    throw "Repo path not found: $resolvedRepoPath"
}

$targetDirectory = Join-Path $resolvedRepoPath $TargetRelativePath
if (-not (Test-Path -LiteralPath $targetDirectory -PathType Container)) {
    throw "MassCompile target directory not found: $targetDirectory"
}

$stagingDirectory = Join-Path $resolvedArtifactRoot ("masscompile-staging-{0}" -f ([Guid]::NewGuid().ToString('N')))
Ensure-Directory -Path $stagingDirectory
Copy-Item -Path (Join-Path $targetDirectory '*') -Destination $stagingDirectory -Recurse -Force
foreach ($relativePath in @($ExcludeFiles | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })) {
    $candidate = Join-Path $stagingDirectory ([string]$relativePath)
    if (Test-Path -LiteralPath $candidate) {
        Remove-Item -LiteralPath $candidate -Recurse -Force
    }
}

$resolvedLabVIEWPath = Resolve-LabVIEWPath -Year $ExecutionLabviewYear -Bitness $SupportedBitness -PreferredPath $LabVIEWPath
if (-not (Test-Path -LiteralPath $resolvedLabVIEWPath -PathType Leaf)) {
    throw "LabVIEW executable not found for MassCompile certification: $resolvedLabVIEWPath"
}

$ensurePortScript = Join-Path $repoRoot 'scripts\Ensure-LabVIEWCliPortContractAndIni.ps1'
if (-not (Test-Path -LiteralPath $ensurePortScript -PathType Leaf)) {
    throw "Required script missing: $ensurePortScript"
}

$portArtifactRoot = Join-Path $resolvedArtifactRoot 'port-contract'
Ensure-Directory -Path $portArtifactRoot

& $ensurePortScript `
    -RepoPath $resolvedRepoPath `
    -ExecutionLabviewYear $ExecutionLabviewYear `
    -SupportedBitness $SupportedBitness `
    -PortContext $PortContext `
    -ArtifactRoot $portArtifactRoot
$portEnsureExitCode = 0
$lastExitVar = Get-Variable -Name LASTEXITCODE -Scope Global -ErrorAction SilentlyContinue
if ($null -ne $lastExitVar) {
    $portEnsureExitCode = [int]$lastExitVar.Value
}
if ($portEnsureExitCode -ne 0) {
    throw "Port contract remediation failed before MassCompile certification (exit $portEnsureExitCode)."
}

$portReportPath = Join-Path $portArtifactRoot 'labview-cli-port-contract-remediation-report.json'
if (-not (Test-Path -LiteralPath $portReportPath -PathType Leaf)) {
    throw "Port contract remediation report not found: $portReportPath"
}
$portReport = Get-Content -LiteralPath $portReportPath -Raw | ConvertFrom-Json -ErrorAction Stop
$expectedPort = [int]$portReport.expected_port
if ($expectedPort -lt 1 -or $expectedPort -gt 65535) {
    throw "Invalid expected_port in remediation report: $expectedPort"
}

$labviewCliCommand = Get-Command -Name 'LabVIEWCLI' -ErrorAction SilentlyContinue | Select-Object -First 1
if ($null -eq $labviewCliCommand -or [string]::IsNullOrWhiteSpace([string]$labviewCliCommand.Source)) {
    throw "LabVIEWCLI command was not found on PATH."
}
$labviewCliPath = [string]$labviewCliCommand.Source

$labviewCliArgs = @(
    '-LogToConsole', 'TRUE',
    '-OperationName', 'MassCompile',
    '-DirectoryToCompile', $stagingDirectory,
    '-LabVIEWPath', $resolvedLabVIEWPath,
    '-PortNumber', $expectedPort.ToString(),
    '-Headless'
)

$invokeResult = Invoke-NativeWithTimeout `
    -Executable $labviewCliPath `
    -Arguments $labviewCliArgs `
    -TimeoutSeconds $TimeoutSeconds `
    -LogPath $massCompileLogPath

$status = if ($invokeResult.exit_code -eq 0 -and -not $invokeResult.timed_out) { 'succeeded' } else { 'failed' }

$report = [ordered]@{
    timestamp_utc = (Get-Date).ToUniversalTime().ToString('o')
    status = $status
    repository_root = $resolvedRepoPath
    target_relative_path = $TargetRelativePath
    target_directory = $targetDirectory
    staging_directory = $stagingDirectory
    excluded_files = @($ExcludeFiles)
    execution_labview_year = $ExecutionLabviewYear
    supported_bitness = $SupportedBitness
    headless_session = [ordered]@{
        is_headless = [bool]$headlessState.is_headless
        session_name = [string]$headlessState.session_name
        session_id = [int]$headlessState.session_id
        interactive = [bool]$headlessState.interactive
    }
    port_context = $PortContext
    expected_port = $expectedPort
    labview_path = $resolvedLabVIEWPath
    labviewcli_path = $labviewCliPath
    timeout_seconds = $TimeoutSeconds
    timed_out = [bool]$invokeResult.timed_out
    exit_code = [int]$invokeResult.exit_code
    process_id = [int]$invokeResult.process_id
    port_contract_report_path = $portReportPath
    masscompile_log_path = $massCompileLogPath
}

$report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $reportPath -Encoding utf8
Write-Host ("MassCompile certification report: {0}" -f $reportPath)
Write-Host ("MassCompile certification status: {0}" -f $status)

if ($status -ne 'succeeded') {
    if (Test-Path -LiteralPath $stagingDirectory -PathType Container) {
        Remove-Item -LiteralPath $stagingDirectory -Recurse -Force -ErrorAction SilentlyContinue
    }
    throw ("MassCompile certification failed (exit={0}, timed_out={1}). See log: {2}" -f [int]$invokeResult.exit_code, [bool]$invokeResult.timed_out, $massCompileLogPath)
}

if (Test-Path -LiteralPath $stagingDirectory -PathType Container) {
    Remove-Item -LiteralPath $stagingDirectory -Recurse -Force -ErrorAction SilentlyContinue
}

$report | ConvertTo-Json -Depth 8 | Write-Output
