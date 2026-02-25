#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter()]
    [string]$ExpectedLabviewYear = '2020',

    [Parameter()]
    [string]$DockerContext = 'desktop-linux',

    [Parameter()]
    [string]$NsisPath = 'C:\Program Files (x86)\NSIS\makensis.exe',

    [Parameter()]
    [string]$OutputPath = '',

    [Parameter()]
    [ValidateSet('error', 'warning')]
    [string]$DockerCheckSeverity = 'error',

    [Parameter()]
    [switch]$FailOnWarning,

    [Parameter()]
    [switch]$SwitchDockerContext,

    [Parameter()]
    [int]$DockerSwitchTimeoutSeconds = 20,

    [Parameter()]
    [int]$DockerSwitchPollSeconds = 5,

    [Parameter()]
    [switch]$StartDockerDesktopIfNeeded,

    [Parameter()]
    [int]$DockerStartupTimeoutSeconds = 20,

    [Parameter()]
    [int]$NativeCommandTimeoutSeconds = 15
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$checks = @()
$errors = @()
$warnings = @()
$resolvedTools = @{}

$toolFallbackMap = @{
    'pwsh' = @(
        (Join-Path $PSHOME 'pwsh.exe'),
        'C:\Program Files\PowerShell\7\pwsh.exe'
    )
    'git' = @(
        'C:\Program Files\Git\cmd\git.exe'
    )
    'gh' = @(
        'C:\Program Files\GitHub CLI\gh.exe'
    )
    'g-cli' = @(
        'C:\Program Files\G-CLI\bin\g-cli.exe'
    )
    'vipm' = @(
        'C:\Program Files\JKI\VI Package Manager\support\vipm.exe'
    )
    'docker' = @(
        'C:\Program Files\Docker\Docker\resources\bin\docker.exe'
    )
}

function Add-Check {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][bool]$Passed,
        [Parameter(Mandatory = $true)][string]$Detail,
        [Parameter()][ValidateSet('error', 'warning')][string]$Severity = 'error'
    )

    $entry = [ordered]@{
        check = $Name
        passed = $Passed
        severity = $Severity
        detail = $Detail
    }
    $script:checks += [pscustomobject]$entry

    if (-not $Passed) {
        if ($Severity -eq 'warning') {
            $script:warnings += "$Name :: $Detail"
        } else {
            $script:errors += "$Name :: $Detail"
        }
    }
}

function Resolve-Tool {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter()][string[]]$FallbackPaths = @()
    )

    $command = Get-Command $Name -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -ne $command) {
        return [pscustomobject]@{
            found = $true
            path = [string]$command.Source
            source = 'PATH'
        }
    }

    foreach ($fallbackPath in @($FallbackPaths)) {
        if (-not [string]::IsNullOrWhiteSpace($fallbackPath) -and (Test-Path -LiteralPath $fallbackPath -PathType Leaf)) {
            return [pscustomobject]@{
                found = $true
                path = [string]$fallbackPath
                source = 'fallback'
            }
        }
    }

    return [pscustomobject]@{
        found = $false
        path = 'missing'
        source = 'missing'
    }
}

function Invoke-NativeCapture {
    param(
        [Parameter(Mandatory = $true)][string]$Executable,
        [Parameter()][string[]]$Arguments = @(),
        [Parameter()][int]$TimeoutSeconds = 0
    )

    $effectiveTimeoutSeconds = if ($TimeoutSeconds -gt 0) {
        [Math]::Max(1, [int]$TimeoutSeconds)
    } else {
        [Math]::Max(1, [int]$script:NativeCommandTimeoutSeconds)
    }

    $stdOutPath = [System.IO.Path]::GetTempFileName()
    $stdErrPath = [System.IO.Path]::GetTempFileName()
    $output = ''
    $exitCode = 1
    $timedOut = $false
    try {
        $process = Start-Process `
            -FilePath $Executable `
            -ArgumentList $Arguments `
            -NoNewWindow `
            -PassThru `
            -RedirectStandardOutput $stdOutPath `
            -RedirectStandardError $stdErrPath

        $waitMilliseconds = $effectiveTimeoutSeconds * 1000
        $exited = $process.WaitForExit($waitMilliseconds)
        if (-not $exited) {
            $timedOut = $true
            try {
                $process.Kill()
            } catch {
                # Best-effort kill only.
            }
            $exitCode = 124
        } else {
            $exitCode = [int]$process.ExitCode
        }

        $stdout = if (Test-Path -LiteralPath $stdOutPath -PathType Leaf) { Get-Content -LiteralPath $stdOutPath -Raw } else { '' }
        $stderr = if (Test-Path -LiteralPath $stdErrPath -PathType Leaf) { Get-Content -LiteralPath $stdErrPath -Raw } else { '' }
        if ($timedOut) {
            $output = ("command_timeout_after_{0}s`n{1}`n{2}" -f $effectiveTimeoutSeconds, [string]$stdout, [string]$stderr).Trim()
        } else {
            $output = ("{0}`n{1}" -f [string]$stdout, [string]$stderr).Trim()
        }
    } catch {
        $output = ($_ | Out-String)
        $exitCode = 1
    } finally {
        if (Test-Path -LiteralPath $stdOutPath -PathType Leaf) {
            Remove-Item -LiteralPath $stdOutPath -Force -ErrorAction SilentlyContinue
        }
        if (Test-Path -LiteralPath $stdErrPath -PathType Leaf) {
            Remove-Item -LiteralPath $stdErrPath -Force -ErrorAction SilentlyContinue
        }
    }

    return [pscustomobject]@{
        output = ([string]$output).Trim()
        exit_code = $exitCode
        timed_out = [bool]$timedOut
    }
}

function Test-DockerContextReachable {
    param(
        [Parameter(Mandatory = $true)][string]$DockerExecutable,
        [Parameter(Mandatory = $true)][string]$Context
    )

    $result = Invoke-NativeCapture -Executable $DockerExecutable -Arguments @('--context', $Context, 'info', '--format', '{{.ServerVersion}}|{{.OSType}}')
    $output = [string]$result.output
    $parts = @($output -split '\|')
    $hasStructuredOutput = (@($parts).Count -ge 2) -and (-not [string]::IsNullOrWhiteSpace([string]$parts[0])) -and (@('linux', 'windows') -contains ([string]$parts[1]).Trim().ToLowerInvariant())
    $hasErrorText = $output -match '(?i)(internal server error|failed to connect|cannot find|not running|is the docker daemon running|error response from daemon)'
    return [pscustomobject]@{
        reachable = ([int]$result.exit_code -eq 0 -and $hasStructuredOutput -and -not $hasErrorText)
        detail = $output
    }
}

function Wait-DockerContextReachable {
    param(
        [Parameter(Mandatory = $true)][string]$DockerExecutable,
        [Parameter(Mandatory = $true)][string]$Context,
        [Parameter(Mandatory = $true)][int]$TimeoutSeconds,
        [Parameter(Mandatory = $true)][int]$PollSeconds
    )

    $deadlineUtc = [DateTime]::UtcNow.AddSeconds([Math]::Max(1, $TimeoutSeconds))
    $intervalSeconds = [Math]::Max(1, $PollSeconds)
    $latest = [pscustomobject]@{
        reachable = $false
        detail = ''
    }

    do {
        $latest = Test-DockerContextReachable -DockerExecutable $DockerExecutable -Context $Context
        if ([bool]$latest.reachable) {
            return $latest
        }

        if ([DateTime]::UtcNow -ge $deadlineUtc) {
            break
        }

        Start-Sleep -Seconds $intervalSeconds
    } while ($true)

    return $latest
}

function Test-DockerDaemonReachable {
    param([Parameter(Mandatory = $true)][string]$DockerExecutable)

    $result = Invoke-NativeCapture -Executable $DockerExecutable -Arguments @('version', '--format', '{{.Server.Version}}|{{.Server.Os}}')
    $output = [string]$result.output
    $parts = @($output -split '\|')
    $hasStructuredOutput = (@($parts).Count -ge 2) -and (-not [string]::IsNullOrWhiteSpace([string]$parts[0])) -and (@('linux', 'windows') -contains ([string]$parts[1]).Trim().ToLowerInvariant())
    $hasErrorText = $output -match '(?i)(internal server error|failed to connect|cannot find|not running|is the docker daemon running|error response from daemon)'
    return [pscustomobject]@{
        reachable = ([int]$result.exit_code -eq 0 -and $hasStructuredOutput -and -not $hasErrorText)
        detail = $output
    }
}

function Wait-DockerDaemonReachable {
    param(
        [Parameter(Mandatory = $true)][string]$DockerExecutable,
        [Parameter(Mandatory = $true)][int]$TimeoutSeconds,
        [Parameter(Mandatory = $true)][int]$PollSeconds
    )

    $deadlineUtc = [DateTime]::UtcNow.AddSeconds([Math]::Max(1, $TimeoutSeconds))
    $intervalSeconds = [Math]::Max(1, $PollSeconds)
    $latest = [pscustomobject]@{
        reachable = $false
        detail = ''
    }

    do {
        $latest = Test-DockerDaemonReachable -DockerExecutable $DockerExecutable
        if ([bool]$latest.reachable) {
            return $latest
        }

        if ([DateTime]::UtcNow -ge $deadlineUtc) {
            break
        }

        Start-Sleep -Seconds $intervalSeconds
    } while ($true)

    return $latest
}

function Get-DockerDesktopContextHost {
    param([Parameter(Mandatory = $true)][string]$Context)

    switch ($Context.ToLowerInvariant()) {
        'desktop-linux' { return 'npipe:////./pipe/dockerDesktopLinuxEngine' }
        'desktop-windows' { return 'npipe:////./pipe/dockerDesktopWindowsEngine' }
        default { return '' }
    }
}

function Invoke-DockerBackendRecovery {
    param(
        [Parameter(Mandatory = $true)][string]$DockerExecutable,
        [Parameter(Mandatory = $true)][string]$DockerContext,
        [Parameter(Mandatory = $true)][bool]$DockerContextExists,
        [Parameter(Mandatory = $true)][int]$StartupTimeoutSeconds,
        [Parameter(Mandatory = $true)][int]$PollSeconds
    )

    $steps = @()

    $dockerService = Get-Service -Name 'com.docker.service' -ErrorAction SilentlyContinue
    if ($null -ne $dockerService) {
        try {
            if ([string]$dockerService.Status -eq 'Running') {
                Restart-Service -Name 'com.docker.service' -Force -ErrorAction Stop
                $steps += 'restarted com.docker.service'
            } else {
                Start-Service -Name 'com.docker.service' -ErrorAction Stop
                $steps += 'started com.docker.service'
            }
        } catch {
            $steps += ("service action failed: {0}" -f [string]$_.Exception.Message)
        }
    } else {
        $steps += 'com.docker.service not found'
    }

    foreach ($procName in @('Docker Desktop', 'com.docker.backend', 'com.docker.build')) {
        $procs = @(Get-Process -Name $procName -ErrorAction SilentlyContinue)
        if (@($procs).Count -gt 0) {
            foreach ($proc in $procs) {
                try {
                    Stop-Process -Id $proc.Id -Force -ErrorAction Stop
                } catch {
                    # best effort
                }
            }
            $steps += ("stopped process: {0} count={1}" -f $procName, @($procs).Count)
        }
    }

    $dockerDesktopExe = 'C:\Program Files\Docker\Docker\Docker Desktop.exe'
    if (Test-Path -LiteralPath $dockerDesktopExe -PathType Leaf) {
        try {
            Start-Process -FilePath $dockerDesktopExe | Out-Null
            $steps += 'started Docker Desktop.exe'
        } catch {
            $steps += ("start Docker Desktop.exe failed: {0}" -f [string]$_.Exception.Message)
        }
    } else {
        $steps += ("Docker Desktop executable missing: {0}" -f $dockerDesktopExe)
    }

    $reachability = if ($DockerContextExists) {
        Wait-DockerContextReachable `
            -DockerExecutable $DockerExecutable `
            -Context $DockerContext `
            -TimeoutSeconds $StartupTimeoutSeconds `
            -PollSeconds $PollSeconds
    } else {
        Wait-DockerDaemonReachable `
            -DockerExecutable $DockerExecutable `
            -TimeoutSeconds $StartupTimeoutSeconds `
            -PollSeconds $PollSeconds
    }

    return [pscustomobject]@{
        recovered = [bool]$reachability.reachable
        detail = [string]$reachability.detail
        steps = [string]($steps -join ' | ')
    }
}

foreach ($commandName in @('pwsh', 'git', 'gh', 'g-cli', 'vipm', 'docker')) {
    $resolved = Resolve-Tool -Name $commandName -FallbackPaths @($toolFallbackMap[$commandName])
    $resolvedTools[$commandName] = $resolved
    $commandDetail = "{0} [{1}]" -f $resolved.path, $resolved.source
    $severity = if ($commandName -eq 'docker') { $DockerCheckSeverity } else { 'error' }
    Add-Check `
        -Name ("command:{0}" -f $commandName) `
        -Passed ([bool]$resolved.found) `
        -Detail $commandDetail `
        -Severity $severity
}

$nsisResolved = $NsisPath
if (-not (Test-Path -LiteralPath $nsisResolved -PathType Leaf)) {
    $makensis = Get-Command makensis -ErrorAction SilentlyContinue
    if ($null -ne $makensis) {
        $nsisResolved = $makensis.Source
    }
}
Add-Check `
    -Name 'command:makensis' `
    -Passed (Test-Path -LiteralPath $nsisResolved -PathType Leaf) `
    -Detail $nsisResolved

$labview64 = "C:\Program Files\National Instruments\LabVIEW $ExpectedLabviewYear"
$labview32 = "C:\Program Files (x86)\National Instruments\LabVIEW $ExpectedLabviewYear"
Add-Check -Name 'labview:x64' -Passed (Test-Path -LiteralPath $labview64 -PathType Container) -Detail $labview64
Add-Check -Name 'labview:x86' -Passed (Test-Path -LiteralPath $labview32 -PathType Container) -Detail $labview32

$dockerContextExists = $false
$dockerContextInspectOutput = ''
$dockerTool = $resolvedTools['docker']
if ($null -ne $dockerTool -and [bool]$dockerTool.found) {
    $inspectResult = Invoke-NativeCapture -Executable $dockerTool.path -Arguments @('context', 'inspect', $DockerContext)
    $dockerContextInspectOutput = [string]$inspectResult.output
    if ([int]$inspectResult.exit_code -eq 0) {
        $dockerContextExists = $true
    }
}
Add-Check `
    -Name 'docker:context_exists' `
    -Passed $dockerContextExists `
    -Detail ("context={0}" -f $DockerContext) `
    -Severity $DockerCheckSeverity

if (-not $dockerContextExists -and ($StartDockerDesktopIfNeeded -or $SwitchDockerContext)) {
    if ($null -eq $dockerTool -or -not [bool]$dockerTool.found) {
        Add-Check `
            -Name 'docker:context_ensure' `
            -Passed $false `
            -Detail 'docker command unavailable; cannot create missing context.' `
            -Severity $DockerCheckSeverity
    } else {
        $dockerHost = Get-DockerDesktopContextHost -Context $DockerContext
        if ([string]::IsNullOrWhiteSpace($dockerHost)) {
            Add-Check `
                -Name 'docker:context_ensure' `
                -Passed $false `
                -Detail ("Unsupported Docker Desktop context for auto-create: {0}" -f $DockerContext) `
                -Severity $DockerCheckSeverity
        } else {
            $createResult = Invoke-NativeCapture -Executable $dockerTool.path -Arguments @('context', 'create', $DockerContext, '--docker', ("host={0}" -f $dockerHost))
            $refreshInspect = Invoke-NativeCapture -Executable $dockerTool.path -Arguments @('context', 'inspect', $DockerContext)
            $dockerContextInspectOutput = [string]$refreshInspect.output
            $dockerContextExists = ([int]$refreshInspect.exit_code -eq 0)
            $detail = ("context={0}; host={1}; create_exit={2}; create_output={3}" -f $DockerContext, $dockerHost, [int]$createResult.exit_code, [string]$createResult.output)
            Add-Check `
                -Name 'docker:context_ensure' `
                -Passed $dockerContextExists `
                -Detail $detail `
                -Severity $DockerCheckSeverity
        }
    }
}

if ($StartDockerDesktopIfNeeded) {
    if ($null -eq $dockerTool -or -not [bool]$dockerTool.found) {
        Add-Check `
            -Name 'docker:desktop_startup' `
            -Passed $false `
            -Detail 'docker command not available; cannot start Docker Desktop.' `
            -Severity $DockerCheckSeverity
    } else {
        $startupAttempts = @()
        $reachabilityProbe = if ($dockerContextExists) {
            Test-DockerContextReachable -DockerExecutable $dockerTool.path -Context $DockerContext
        } else {
            Test-DockerDaemonReachable -DockerExecutable $dockerTool.path
        }

        if ([bool]$reachabilityProbe.reachable) {
            $startupAttempts += 'Docker engine already reachable; startup skipped.'
            Add-Check `
                -Name 'docker:desktop_startup' `
                -Passed $true `
                -Detail ($startupAttempts -join ' | ') `
                -Severity $DockerCheckSeverity
        } else {
            $dockerDesktopExe = 'C:\Program Files\Docker\Docker\Docker Desktop.exe'
            if (-not (Test-Path -LiteralPath $dockerDesktopExe -PathType Leaf)) {
                Add-Check `
                    -Name 'docker:desktop_startup' `
                    -Passed $false `
                    -Detail ("Docker Desktop executable not found: {0}" -f $dockerDesktopExe) `
                    -Severity $DockerCheckSeverity
            } else {
                $dockerService = Get-Service -Name 'com.docker.service' -ErrorAction SilentlyContinue
                if ($null -ne $dockerService) {
                    if ([string]$dockerService.Status -ne 'Running') {
                        try {
                            Start-Service -Name 'com.docker.service' -ErrorAction Stop
                            $startupAttempts += 'Started com.docker.service.'
                        } catch {
                            $startupAttempts += ("Failed to start com.docker.service: {0}" -f [string]$_.Exception.Message)
                        }
                    } else {
                        $startupAttempts += 'com.docker.service already running.'
                    }
                } else {
                    $startupAttempts += 'com.docker.service not found on host.'
                }

                $desktopAlreadyRunning = (@(Get-Process -Name 'Docker Desktop' -ErrorAction SilentlyContinue)).Count -gt 0
                if ($desktopAlreadyRunning) {
                    $startupAttempts += 'Docker Desktop process already running.'
                } else {
                    Start-Process -FilePath $dockerDesktopExe | Out-Null
                    $startupAttempts += 'Docker Desktop process started.'
                }

                $postStartupReachability = if ($dockerContextExists) {
                    Wait-DockerContextReachable `
                        -DockerExecutable $dockerTool.path `
                        -Context $DockerContext `
                        -TimeoutSeconds $DockerStartupTimeoutSeconds `
                        -PollSeconds $DockerSwitchPollSeconds
                } else {
                    Wait-DockerDaemonReachable `
                        -DockerExecutable $dockerTool.path `
                        -TimeoutSeconds $DockerStartupTimeoutSeconds `
                        -PollSeconds $DockerSwitchPollSeconds
                }

                Add-Check `
                    -Name 'docker:desktop_startup' `
                    -Passed ([bool]$postStartupReachability.reachable) `
                    -Detail ("timeout={0}s; detail={1}; attempts={2}" -f $DockerStartupTimeoutSeconds, [string]$postStartupReachability.detail, ($startupAttempts -join ' | ')) `
                    -Severity $DockerCheckSeverity
            }
        }

        if (-not $dockerContextExists) {
            $refreshInspect = Invoke-NativeCapture -Executable $dockerTool.path -Arguments @('context', 'inspect', $DockerContext)
            $dockerContextInspectOutput = [string]$refreshInspect.output
            if ([int]$refreshInspect.exit_code -eq 0) {
                $dockerContextExists = $true
            }
        }
    }
}

if ($SwitchDockerContext) {
    if (-not $dockerContextExists) {
        Add-Check `
            -Name 'docker:context_switch' `
            -Passed $false `
            -Detail ("context={0} is not defined; cannot switch." -f $DockerContext) `
            -Severity $DockerCheckSeverity
    } elseif ($null -eq $dockerTool -or -not [bool]$dockerTool.found) {
        Add-Check `
            -Name 'docker:context_switch' `
            -Passed $false `
            -Detail 'docker command not available; cannot switch context.' `
            -Severity $DockerCheckSeverity
    } else {
        $switchAttempts = @()
        $switchResult = Invoke-NativeCapture -Executable $dockerTool.path -Arguments @('context', 'use', $DockerContext)
        $switchAttempts += ("docker context use {0} => exit={1}" -f $DockerContext, [int]$switchResult.exit_code)
        if (-not [string]::IsNullOrWhiteSpace([string]$switchResult.output)) {
            $switchAttempts += ("docker context use output: {0}" -f [string]$switchResult.output)
        }

        $reachability = Test-DockerContextReachable -DockerExecutable $dockerTool.path -Context $DockerContext
        if (-not [bool]$reachability.reachable) {
            $reachability = Wait-DockerContextReachable `
                -DockerExecutable $dockerTool.path `
                -Context $DockerContext `
                -TimeoutSeconds $DockerSwitchTimeoutSeconds `
                -PollSeconds $DockerSwitchPollSeconds
        }

        if (-not [bool]$reachability.reachable) {
            $dockerCliPath = 'C:\Program Files\Docker\Docker\DockerCli.exe'
            $engineSwitchArgument = ''
            switch ($DockerContext.ToLowerInvariant()) {
                'desktop-linux' { $engineSwitchArgument = '-SwitchLinuxEngine' }
                'desktop-windows' { $engineSwitchArgument = '-SwitchWindowsEngine' }
                default { $engineSwitchArgument = '' }
            }

            if (-not [string]::IsNullOrWhiteSpace($engineSwitchArgument) -and (Test-Path -LiteralPath $dockerCliPath -PathType Leaf)) {
                $switchAttempts += ("DockerCli engine switch attempt: {0}" -f $engineSwitchArgument)
                $engineResult = Invoke-NativeCapture -Executable $dockerCliPath -Arguments @($engineSwitchArgument)
                $switchAttempts += ("DockerCli engine switch exit={0}" -f [int]$engineResult.exit_code)
                if (-not [string]::IsNullOrWhiteSpace([string]$engineResult.output)) {
                    $switchAttempts += ("DockerCli output: {0}" -f [string]$engineResult.output)
                }

                $useAfterEngineSwitch = Invoke-NativeCapture -Executable $dockerTool.path -Arguments @('context', 'use', $DockerContext)
                $switchAttempts += ("docker context use (post-engine-switch) exit={0}" -f [int]$useAfterEngineSwitch.exit_code)
                if (-not [string]::IsNullOrWhiteSpace([string]$useAfterEngineSwitch.output)) {
                    $switchAttempts += ("docker context use (post-engine-switch) output: {0}" -f [string]$useAfterEngineSwitch.output)
                }

                $reachability = Wait-DockerContextReachable `
                    -DockerExecutable $dockerTool.path `
                    -Context $DockerContext `
                    -TimeoutSeconds $DockerSwitchTimeoutSeconds `
                    -PollSeconds $DockerSwitchPollSeconds
            }
        }

        $switchPassed = [bool]$reachability.reachable
        $switchDetail = ("context={0}; reachable={1}; detail={2}; attempts={3}" -f $DockerContext, $switchPassed, [string]$reachability.detail, ($switchAttempts -join ' | '))
        Add-Check `
            -Name 'docker:context_switch' `
            -Passed $switchPassed `
            -Detail $switchDetail `
            -Severity $DockerCheckSeverity
    }
}

$dockerRecoveryResult = $null
if ($StartDockerDesktopIfNeeded -and $null -ne $dockerTool -and [bool]$dockerTool.found) {
    $preRecoveryReachability = if ($dockerContextExists) {
        Test-DockerContextReachable -DockerExecutable $dockerTool.path -Context $DockerContext
    } else {
        Test-DockerDaemonReachable -DockerExecutable $dockerTool.path
    }

    if (-not [bool]$preRecoveryReachability.reachable) {
        $dockerRecoveryResult = Invoke-DockerBackendRecovery `
            -DockerExecutable $dockerTool.path `
            -DockerContext $DockerContext `
            -DockerContextExists $dockerContextExists `
            -StartupTimeoutSeconds $DockerStartupTimeoutSeconds `
            -PollSeconds $DockerSwitchPollSeconds
        Add-Check `
            -Name 'docker:backend_recovery' `
            -Passed ([bool]$dockerRecoveryResult.recovered) `
            -Detail ("context={0}; detail={1}; steps={2}" -f $DockerContext, [string]$dockerRecoveryResult.detail, [string]$dockerRecoveryResult.steps) `
            -Severity $DockerCheckSeverity
    } else {
        Add-Check `
            -Name 'docker:backend_recovery' `
            -Passed $true `
            -Detail 'not needed; docker context already reachable after startup/switch phases.' `
            -Severity $DockerCheckSeverity
    }
}

$dockerContextReachable = $false
$dockerInfoDetail = ''
if ($dockerContextExists) {
    if ($null -ne $dockerTool -and [bool]$dockerTool.found) {
        $reachability = Test-DockerContextReachable -DockerExecutable $dockerTool.path -Context $DockerContext
        $dockerContextReachable = [bool]$reachability.reachable
        $dockerInfoDetail = [string]$reachability.detail
    } else {
        $dockerInfoDetail = 'docker command unavailable.'
    }
} else {
    $dockerInfoDetail = $dockerContextInspectOutput.Trim()
}
Add-Check `
    -Name 'docker:context_reachable' `
    -Passed $dockerContextReachable `
    -Detail ("context={0}; detail={1}" -f $DockerContext, $dockerInfoDetail) `
    -Severity $DockerCheckSeverity

# Reconcile early startup false negatives when later phases prove the target context is reachable.
if ($StartDockerDesktopIfNeeded -and $dockerContextReachable) {
    $startupChecks = @($checks | Where-Object { [string]$_.check -eq 'docker:desktop_startup' -and -not [bool]$_.passed })
    foreach ($startupCheck in $startupChecks) {
        $startupCheck.passed = $true
        $startupCheck.detail = ("{0} | reconciled_after_context_reachable=true" -f [string]$startupCheck.detail)
    }
    if (@($startupChecks).Count -gt 0) {
        $errors = @($errors | Where-Object { [string]$_ -notlike 'docker:desktop_startup ::*' })
    }
}

$status = if ($errors.Count -gt 0) { 'failed' } else { 'succeeded' }
$report = [ordered]@{
    timestamp_utc = (Get-Date).ToUniversalTime().ToString('o')
    expected_labview_year = $ExpectedLabviewYear
    docker_context = $DockerContext
    docker_desktop_startup_requested = [bool]$StartDockerDesktopIfNeeded
    docker_desktop_startup_timeout_seconds = $DockerStartupTimeoutSeconds
    docker_context_switch_requested = [bool]$SwitchDockerContext
    docker_context_switch_timeout_seconds = $DockerSwitchTimeoutSeconds
    docker_context_switch_poll_seconds = $DockerSwitchPollSeconds
    native_command_timeout_seconds = $NativeCommandTimeoutSeconds
    nsis_path = $nsisResolved
    status = $status
    summary = [ordered]@{
        checks = $checks.Count
        errors = $errors.Count
        warnings = $warnings.Count
    }
    checks = $checks
    errors = $errors
    warnings = $warnings
}

if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
    $resolvedOutput = [System.IO.Path]::GetFullPath($OutputPath)
    $outputDir = Split-Path -Path $resolvedOutput -Parent
    if (-not [string]::IsNullOrWhiteSpace($outputDir) -and -not (Test-Path -LiteralPath $outputDir -PathType Container)) {
        New-Item -Path $outputDir -ItemType Directory -Force | Out-Null
    }
    $report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $resolvedOutput -Encoding utf8
    Write-Host "Machine preflight report: $resolvedOutput"
} else {
    $report | ConvertTo-Json -Depth 8 | Write-Output
}

if ($errors.Count -gt 0) {
    exit 1
}
if ($FailOnWarning -and $warnings.Count -gt 0) {
    exit 1
}

exit 0
