#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter()]
    [string]$WorkspaceRoot = 'C:\dev',

    [Parameter(Mandatory = $true)]
    [string]$ManifestPath,

    [Parameter()]
    [ValidateSet('Install', 'Verify')]
    [string]$Mode = 'Install',

    [Parameter()]
    [string]$InstallerExecutionContext = '',

    [Parameter(Mandatory = $true)]
    [string]$OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Ensure-Directory {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        New-Item -Path $Path -ItemType Directory -Force | Out-Null
    }
}

function Normalize-Url {
    param([string]$Url)
    if ([string]::IsNullOrWhiteSpace($Url)) {
        return ''
    }
    return ($Url.Trim().TrimEnd('/')).ToLowerInvariant()
}

function To-Bool {
    param($Value)
    return [bool]$Value
}

function Write-InstallerFeedback {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    Write-Host ("[workspace-installer] {0}" -f $Message)
}

function Get-PreferredPowerShellExecutable {
    [CmdletBinding()]
    param()

    # Prefer Windows PowerShell on Windows containers; fall back to pwsh when needed.
    $preferredCommands = @('powershell', 'pwsh')
    foreach ($commandName in $preferredCommands) {
        $cmd = Get-Command -Name $commandName -ErrorAction SilentlyContinue
        if ($null -ne $cmd -and -not [string]::IsNullOrWhiteSpace([string]$cmd.Source)) {
            return [string]$cmd.Source
        }
    }

    throw "Neither 'powershell' nor 'pwsh' was found on PATH."
}

function Invoke-PowerShellFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$PowerShellExecutable,
        [Parameter(Mandatory = $true)]
        [string]$ScriptPath,
        [Parameter()]
        [string[]]$ScriptArguments = @()
    )

    if (-not (Test-Path -LiteralPath $ScriptPath -PathType Leaf)) {
        throw "PowerShell script not found: $ScriptPath"
    }

    $invocationArgs = @(
        '-NoLogo',
        '-NoProfile',
        '-NonInteractive',
        '-ExecutionPolicy', 'Bypass',
        '-File', $ScriptPath
    )
    if ($null -ne $ScriptArguments -and $ScriptArguments.Count -gt 0) {
        $invocationArgs += @($ScriptArguments)
    }

    $commandOutput = & $PowerShellExecutable @invocationArgs 2>&1
    foreach ($line in @($commandOutput)) {
        Write-Host $line
    }
    if ($null -eq $LASTEXITCODE) {
        return 0
    }
    return [int]$LASTEXITCODE
}

function Add-PostActionSequenceEntry {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [System.Collections.IList]$Sequence,
        [Parameter(Mandatory = $true)]
        [string]$Phase,
        [Parameter(Mandatory = $true)]
        [string]$Status,
        [Parameter()]
        [string]$Bitness = '',
        [Parameter()]
        [string]$Message = ''
    )

    $entry = [ordered]@{
        index = $Sequence.Count + 1
        timestamp_utc = (Get-Date).ToUniversalTime().ToString('o')
        phase = $Phase
        bitness = $Bitness
        status = $Status
        message = $Message
    }
    [void]$Sequence.Add([pscustomobject]$entry)
}

function Get-LabVIEWInstallRoot {
    param(
        [Parameter(Mandatory = $true)]
        [string]$VersionYear,
        [Parameter(Mandatory = $true)]
        [ValidateSet('32', '64')]
        [string]$Bitness
    )

    $candidates = @()
    $regPaths = @()
    if ($Bitness -eq '32') {
        $candidates += "C:\Program Files (x86)\National Instruments\LabVIEW $VersionYear"
        $regPaths += "HKLM:\SOFTWARE\WOW6432Node\National Instruments\LabVIEW $VersionYear"
    } else {
        $candidates += "C:\Program Files\National Instruments\LabVIEW $VersionYear"
        $regPaths += "HKLM:\SOFTWARE\National Instruments\LabVIEW $VersionYear"
    }

    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Container) {
            return $candidate
        }
    }

    foreach ($regPath in $regPaths) {
        try {
            $props = Get-ItemProperty -Path $regPath -ErrorAction Stop
            foreach ($name in @('Path', 'InstallDir', 'InstallPath')) {
                $value = [string]$props.$name
                if (-not [string]::IsNullOrWhiteSpace($value) -and (Test-Path -LiteralPath $value -PathType Container)) {
                    return $value
                }
            }
        } catch {
            continue
        }
    }

    return $null
}

function Get-LabVIEWCliContractExpectedPort {
    param(
        [Parameter(Mandatory = $true)]
        [string]$IconEditorRepoPath,
        [Parameter(Mandatory = $true)]
        [string]$LabVIEWYear,
        [Parameter(Mandatory = $true)]
        [ValidateSet('32', '64')]
        [string]$Bitness
    )

    $contractPath = Join-Path -Path $IconEditorRepoPath -ChildPath 'Tooling\labviewcli-port-contract.json'
    if (-not (Test-Path -LiteralPath $contractPath -PathType Leaf)) {
        throw "LabVIEW CLI port contract file was not found: $contractPath"
    }

    $contract = Get-Content -LiteralPath $contractPath -Raw | ConvertFrom-Json -ErrorAction Stop
    if (-not $contract.PSObject.Properties.Name.Contains('labview_cli_ports')) {
        throw "LabVIEW CLI port contract is missing 'labview_cli_ports': $contractPath"
    }
    if (-not $contract.labview_cli_ports.PSObject.Properties.Name.Contains($LabVIEWYear)) {
        throw "LabVIEW CLI port contract does not define year '$LabVIEWYear': $contractPath"
    }

    $yearNode = $contract.labview_cli_ports.$LabVIEWYear
    if (-not $yearNode.PSObject.Properties.Name.Contains($Bitness)) {
        throw "LabVIEW CLI port contract does not define bitness '$Bitness' for year '$LabVIEWYear': $contractPath"
    }

    $expectedPortRaw = [string]$yearNode.$Bitness
    $expectedPort = 0
    if (-not [int]::TryParse($expectedPortRaw, [ref]$expectedPort) -or $expectedPort -lt 1 -or $expectedPort -gt 65535) {
        throw "LabVIEW CLI port contract has invalid value '$expectedPortRaw' for year '$LabVIEWYear' bitness '$Bitness': $contractPath"
    }

    return [pscustomobject]@{
        contract_path = $contractPath
        labview_year = $LabVIEWYear
        bitness = $Bitness
        expected_port = $expectedPort
    }
}

function Set-IniKeyValueStrict {
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.Generic.List[string]]$Lines,
        [Parameter(Mandatory = $true)]
        [string]$Key,
        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    for ($index = 0; $index -lt $Lines.Count; $index++) {
        $line = [string]$Lines[$index]
        $trimmed = $line.Trim()
        if ([string]::IsNullOrWhiteSpace($trimmed) -or $trimmed.StartsWith(';') -or $trimmed.StartsWith('#')) {
            continue
        }

        $separator = $trimmed.IndexOf('=')
        if ($separator -lt 0) {
            continue
        }

        $lineKey = $trimmed.Substring(0, $separator).Trim()
        if ($lineKey.Equals($Key, [System.StringComparison]::OrdinalIgnoreCase)) {
            $Lines[$index] = ('{0}={1}' -f $Key, $Value)
            return
        }
    }

    $Lines.Add(('{0}={1}' -f $Key, $Value)) | Out-Null
}

function Ensure-LabVIEWIniPortContract {
    param(
        [Parameter(Mandatory = $true)]
        [string]$LabVIEWInstallRoot,
        [Parameter(Mandatory = $true)]
        [string]$LabVIEWYear,
        [Parameter(Mandatory = $true)]
        [ValidateSet('32', '64')]
        [string]$Bitness,
        [Parameter(Mandatory = $true)]
        [int]$ExpectedPort
    )

    if (-not (Test-Path -LiteralPath $LabVIEWInstallRoot -PathType Container)) {
        throw "LabVIEW install root does not exist for INI contract remediation: $LabVIEWInstallRoot"
    }

    $iniPath = Join-Path -Path $LabVIEWInstallRoot -ChildPath 'LabVIEW.ini'
    $created = $false
    $lines = New-Object 'System.Collections.Generic.List[string]'
    if (Test-Path -LiteralPath $iniPath -PathType Leaf) {
        foreach ($line in @(Get-Content -LiteralPath $iniPath -ErrorAction Stop)) {
            $lines.Add([string]$line) | Out-Null
        }
    } else {
        $created = $true
        $lines.Add('; Generated by Install-WorkspaceFromManifest for LabVIEW CLI port contract') | Out-Null
        $lines.Add(('; LabVIEW {0} {1}-bit' -f $LabVIEWYear, $Bitness)) | Out-Null
    }

    Set-IniKeyValueStrict -Lines $lines -Key 'server.tcp.enabled' -Value 'true'
    Set-IniKeyValueStrict -Lines $lines -Key 'server.tcp.port' -Value ([string]$ExpectedPort)
    Set-Content -LiteralPath $iniPath -Value @($lines.ToArray()) -Encoding ascii

    return [pscustomobject]@{
        ini_path = $iniPath
        created = $created
        expected_port = $ExpectedPort
    }
}

function Get-LabVIEWYearFromText {
    param(
        [Parameter()]
        [string]$Text
    )

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return ''
    }

    if ($Text -match 'LabVIEW\s+(\d{4})') {
        return [string]$Matches[1]
    }

    return ''
}

function Test-PplBuildLabVIEWVersionAlignment {
    param(
        [Parameter(Mandatory = $true)]
        [string]$IconEditorRepoPath,
        [Parameter(Mandatory = $true)]
        [string]$RequiredLabviewYear,
        [Parameter()]
        [string[]]$PreExistingExecuteBuildSpecLogs = @()
    )

    $result = [ordered]@{
        status = 'fail'
        message = ''
        buildspec_log_path = ''
        detected_labview_executable = ''
        detected_labview_year = ''
    }

    try {
        $logsRoot = Join-Path -Path $IconEditorRepoPath -ChildPath 'builds\logs'
        if (-not (Test-Path -LiteralPath $logsRoot -PathType Container)) {
            throw "PPL build log root not found: $logsRoot"
        }

        $allLogs = @(
            Get-ChildItem -Path $logsRoot -Filter 'labviewcli-executebuildspec-*.log' -File -ErrorAction SilentlyContinue |
            Sort-Object -Property LastWriteTimeUtc -Descending
        )
        if (@($allLogs).Count -eq 0) {
            throw "No LabVIEW CLI execute-buildspec logs were found in '$logsRoot'."
        }

        $normalizedPreviousLogs = @($PreExistingExecuteBuildSpecLogs | ForEach-Object { ([string]$_).ToLowerInvariant() })
        $newLogs = @($allLogs | Where-Object { $_.FullName.ToLowerInvariant() -notin $normalizedPreviousLogs })
        $selectedLog = if (@($newLogs).Count -gt 0) { $newLogs[0] } else { $allLogs[0] }
        $result.buildspec_log_path = [string]$selectedLog.FullName

        $logContent = Get-Content -LiteralPath $selectedLog.FullName -Raw
        if ($logContent -match 'Using LabVIEW:\s*"([^"]+)"') {
            $result.detected_labview_executable = [string]$Matches[1]
        }

        $detectedYear = Get-LabVIEWYearFromText -Text $result.detected_labview_executable
        if ([string]::IsNullOrWhiteSpace($detectedYear)) {
            $detectedYear = Get-LabVIEWYearFromText -Text $logContent
        }
        $result.detected_labview_year = [string]$detectedYear

        if ([string]::IsNullOrWhiteSpace($detectedYear)) {
            throw "Could not determine LabVIEW year from execute-buildspec log '$($selectedLog.FullName)'."
        }

        if ([string]$detectedYear -ne [string]$RequiredLabviewYear) {
            throw "Illegal combination: PPL build executed with LabVIEW $detectedYear while VIP/package target requires LabVIEW $RequiredLabviewYear."
        }

        $result.status = 'pass'
        $result.message = "PPL build executed with LabVIEW $detectedYear, matching required year $RequiredLabviewYear."
    } catch {
        $result.status = 'fail'
        $result.message = $_.Exception.Message
    }

    return [pscustomobject]$result
}

function Get-ExpectedShaFromFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ShaFilePath
    )

    if (-not (Test-Path -LiteralPath $ShaFilePath -PathType Leaf)) {
        throw "SHA256 file not found: $ShaFilePath"
    }

    $raw = (Get-Content -LiteralPath $ShaFilePath -Raw).Trim()
    if ([string]::IsNullOrWhiteSpace($raw)) {
        throw "SHA256 file is empty: $ShaFilePath"
    }

    $expected = ($raw.Split(' ')[0]).Trim().ToLowerInvariant()
    if ($expected -notmatch '^[0-9a-f]{64}$') {
        throw "SHA256 file has invalid hash format: $ShaFilePath"
    }
    return $expected
}

function Get-Sha256Hex {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "File not found for hashing: $Path"
    }

    $hashCmd = Get-Command 'Get-FileHash' -ErrorAction SilentlyContinue
    if ($null -ne $hashCmd) {
        return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    }

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $stream = [System.IO.File]::OpenRead($Path)
        try {
            $hashBytes = $sha.ComputeHash($stream)
        } finally {
            $stream.Dispose()
        }
    } finally {
        $sha.Dispose()
    }

    return ([System.BitConverter]::ToString($hashBytes).Replace('-', '').ToLowerInvariant())
}

function Get-LatestVipPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepoRoot
    )

    $vipRoot = Join-Path -Path $RepoRoot -ChildPath 'builds\VI Package'
    if (-not (Test-Path -LiteralPath $vipRoot -PathType Container)) {
        return ''
    }

    $latestVip = Get-ChildItem -Path $vipRoot -Filter '*.vip' -File -Recurse -ErrorAction SilentlyContinue |
        Sort-Object -Property LastWriteTime -Descending |
        Select-Object -First 1
    if ($null -eq $latestVip) {
        return ''
    }

    return [string]$latestVip.FullName
}

function Expand-CdevCliWindowsBundle {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ZipPath,
        [Parameter(Mandatory = $true)]
        [string]$DestinationPath
    )

    if (-not (Test-Path -LiteralPath $ZipPath -PathType Leaf)) {
        throw "cdev-cli Windows asset not found: $ZipPath"
    }

    if (Test-Path -LiteralPath $DestinationPath -PathType Container) {
        Remove-Item -LiteralPath $DestinationPath -Recurse -Force
    }
    Ensure-Directory -Path $DestinationPath
    Expand-Archive -LiteralPath $ZipPath -DestinationPath $DestinationPath -Force
}

function Invoke-VipcApplyWithVipmCli {
    param(
        [Parameter(Mandatory = $true)]
        [string]$IconEditorRepoPath,
        [Parameter(Mandatory = $true)]
        [string]$VipcPath,
        [Parameter(Mandatory = $true)]
        [string]$RequiredLabviewYear,
        [Parameter(Mandatory = $true)]
        [ValidateSet('32', '64')]
        [string]$RequiredBitness
    )

    $result = [ordered]@{
        status = 'pending'
        message = ''
        command = @()
        exit_code = $null
        resolved_vipc_path = ''
        vipm_cli_path = ''
    }

    try {
        $vipmCommand = Get-Command -Name 'vipm' -ErrorAction Stop
        $result.vipm_cli_path = [string]$vipmCommand.Source

        $resolvedVipcPath = if ([System.IO.Path]::IsPathRooted($VipcPath)) {
            [System.IO.Path]::GetFullPath($VipcPath)
        } else {
            [System.IO.Path]::GetFullPath((Join-Path -Path $IconEditorRepoPath -ChildPath $VipcPath))
        }
        if (-not (Test-Path -LiteralPath $resolvedVipcPath -PathType Leaf)) {
            throw "VIPC file was not found for native VIPM apply: $resolvedVipcPath"
        }
        $result.resolved_vipc_path = $resolvedVipcPath

        $vipmArgs = @(
            '--labview-version', $RequiredLabviewYear,
            '--labview-bitness', $RequiredBitness,
            'install',
            $resolvedVipcPath
        )
        $result.command = @($vipmArgs)
        Write-InstallerFeedback -Message ("Executing native VIPM CLI apply: {0} {1}" -f $result.vipm_cli_path, ($vipmArgs -join ' '))

        $vipmOutput = & $result.vipm_cli_path @vipmArgs 2>&1
        if ($null -ne $vipmOutput) {
            $vipmOutput
        }
        $result.exit_code = $LASTEXITCODE
        if ($result.exit_code -ne 0) {
            throw "vipm install failed with exit code $($result.exit_code)."
        }

        $result.status = 'pass'
        $result.message = 'Native VIPM CLI VIPC apply completed successfully.'
    } catch {
        if ($null -eq $result.exit_code) {
            $result.exit_code = 1
        }
        $result.status = 'fail'
        $result.message = $_.Exception.Message
    }

    return [pscustomobject]$result
}

function Get-VipcMismatchAssessment {
    param(
        [Parameter(Mandatory = $true)]
        [string]$VipcAuditPath,
        [Parameter()]
        [string[]]$NonBlockingRoots = @()
    )

    $assessment = [ordered]@{
        has_audit = $false
        mismatched_roots = @()
        all_non_blocking = $false
        parse_error = ''
    }

    if ([string]::IsNullOrWhiteSpace($VipcAuditPath) -or -not (Test-Path -LiteralPath $VipcAuditPath -PathType Leaf)) {
        return [pscustomobject]$assessment
    }

    $assessment.has_audit = $true
    try {
        $audit = Get-Content -LiteralPath $VipcAuditPath -Raw | ConvertFrom-Json -ErrorAction Stop
        $mismatchRoots = @($audit.root_audit | Where-Object { -not [bool]$_.matched } | ForEach-Object { [string]$_.root } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
        $assessment.mismatched_roots = @($mismatchRoots)
        if (@($mismatchRoots).Count -gt 0) {
            $disallowed = @($mismatchRoots | Where-Object { $_ -notin $NonBlockingRoots })
            $assessment.all_non_blocking = (@($disallowed).Count -eq 0)
        }
    } catch {
        $assessment.parse_error = $_.Exception.Message
    }

    return [pscustomobject]$assessment
}

function Invoke-PreVipLabVIEWCloseBestEffort {
    param(
        [Parameter(Mandatory = $true)]
        [string]$IconEditorRepoPath
    )

    $targets = @(
        @{ year = '2026'; bitness = '32' },
        @{ year = '2026'; bitness = '64' },
        @{ year = '2020'; bitness = '32' },
        @{ year = '2020'; bitness = '64' }
    )

    foreach ($target in $targets) {
        $year = [string]$target.year
        $bitness = [string]$target.bitness

        $installRoot = if ($bitness -eq '32') {
            "C:\Program Files (x86)\National Instruments\LabVIEW $year"
        } else {
            "C:\Program Files\National Instruments\LabVIEW $year"
        }
        $normalizedInstallRoot = $installRoot.TrimEnd('\')

        Write-InstallerFeedback -Message ("Pre-VIP LabVIEW close (best-effort): year={0} bitness={1} root={2}" -f $year, $bitness, $normalizedInstallRoot)

        $candidateProcesses = @()
        try {
            $candidateProcesses = @(Get-CimInstance Win32_Process -Filter "Name='LabVIEW.exe'" -ErrorAction Stop | Where-Object {
                    -not [string]::IsNullOrWhiteSpace([string]$_.ExecutablePath) -and
                    [string]$_.ExecutablePath -like "$normalizedInstallRoot*"
                })
        } catch {
            Write-InstallerFeedback -Message ("Pre-VIP process query warning for year={0} bitness={1}: {2}" -f $year, $bitness, $_.Exception.Message)
            continue
        }

        if (@($candidateProcesses).Count -eq 0) {
            Write-InstallerFeedback -Message ("No running LabVIEW processes found for year={0} bitness={1}." -f $year, $bitness)
            continue
        }

        foreach ($processInfo in $candidateProcesses) {
            $processId = [int]$processInfo.ProcessId
            try {
                Stop-Process -Id $processId -Force -ErrorAction Stop
                Write-InstallerFeedback -Message ("Stopped LabVIEW process id={0} for year={1} bitness={2}." -f $processId, $year, $bitness)
            } catch {
                Write-InstallerFeedback -Message ("Pre-VIP close warning for process id={0} year={1} bitness={2}: {3}" -f $processId, $year, $bitness, $_.Exception.Message)
            }
        }
    }
}

function Invoke-RunnerCliPplCapabilityCheck {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RunnerCliPath,
        [Parameter(Mandatory = $true)]
        [string]$IconEditorRepoPath,
        [Parameter(Mandatory = $true)]
        [string]$PinnedSha,
        [Parameter(Mandatory = $true)]
        [string]$RequiredLabviewYear,
        [Parameter()]
        [string]$ExpectedExecutionLabviewYear = '',
        [Parameter(Mandatory = $true)]
        [ValidateSet('32', '64')]
        [string]$RequiredBitness
    )

    $statusRoot = Join-Path -Path $IconEditorRepoPath -ChildPath 'builds\status'

    $result = [ordered]@{
        status = 'pending'
        message = ''
        runner_cli_path = $RunnerCliPath
        repo_path = $IconEditorRepoPath
        required_labview_year = $RequiredLabviewYear
        expected_execution_labview_year = ''
        required_bitness = $RequiredBitness
        output_ppl_path = Join-Path $IconEditorRepoPath 'resource\plugins\lv_icon.lvlibp'
        output_ppl_snapshot_path = Join-Path $statusRoot ("workspace-installer-ppl-{0}.lvlibp" -f $RequiredBitness)
        command = @()
        exit_code = $null
        labview_install_root = ''
        labview_ini_path = ''
        expected_labview_cli_port = 0
        buildspec_log_path = ''
        detected_labview_executable = ''
        detected_labview_year = ''
    }

    try {
        if (-not (Test-Path -LiteralPath $RunnerCliPath -PathType Leaf)) {
            throw "runner-cli executable not found: $RunnerCliPath"
        }
        if (-not (Test-Path -LiteralPath $IconEditorRepoPath -PathType Container)) {
            throw "Icon editor repository path not found: $IconEditorRepoPath"
        }
        if ($PinnedSha -notmatch '^[0-9a-f]{40}$') {
            throw "Pinned SHA is invalid for capability check: $PinnedSha"
        }

        $effectiveExecutionLabviewYear = if ([string]::IsNullOrWhiteSpace($ExpectedExecutionLabviewYear)) {
            [string]$RequiredLabviewYear
        } else {
            [string]$ExpectedExecutionLabviewYear
        }
        if ($effectiveExecutionLabviewYear -notmatch '^\d{4}$') {
            throw "Expected execution LabVIEW year '$effectiveExecutionLabviewYear' is invalid. Expected a 4-digit year."
        }
        $result.expected_execution_labview_year = $effectiveExecutionLabviewYear

        Ensure-Directory -Path $statusRoot
        $logsRoot = Join-Path -Path $IconEditorRepoPath -ChildPath 'builds\logs'
        $preExistingExecuteBuildSpecLogs = @()
        if (Test-Path -LiteralPath $logsRoot -PathType Container) {
            $preExistingExecuteBuildSpecLogs = @(
                Get-ChildItem -Path $logsRoot -Filter 'labviewcli-executebuildspec-*.log' -File -ErrorAction SilentlyContinue |
                ForEach-Object { [string]$_.FullName }
            )
        }

        $labviewRoot = Get-LabVIEWInstallRoot -VersionYear $effectiveExecutionLabviewYear -Bitness $RequiredBitness
        if ([string]::IsNullOrWhiteSpace($labviewRoot)) {
            throw "LabVIEW $effectiveExecutionLabviewYear ($RequiredBitness-bit) is required for runner-cli PPL capability execution but was not found."
        }
        $result.labview_install_root = $labviewRoot

        $portContract = Get-LabVIEWCliContractExpectedPort `
            -IconEditorRepoPath $IconEditorRepoPath `
            -LabVIEWYear $effectiveExecutionLabviewYear `
            -Bitness $RequiredBitness
        $result.expected_labview_cli_port = [int]$portContract.expected_port

        $iniContract = Ensure-LabVIEWIniPortContract `
            -LabVIEWInstallRoot $labviewRoot `
            -LabVIEWYear $effectiveExecutionLabviewYear `
            -Bitness $RequiredBitness `
            -ExpectedPort ([int]$portContract.expected_port)
        $result.labview_ini_path = [string]$iniContract.ini_path
        Write-InstallerFeedback -Message ("Ensured LabVIEW.ini port contract: year={0} bitness={1} port={2} path={3} created={4}" -f $effectiveExecutionLabviewYear, $RequiredBitness, [int]$portContract.expected_port, [string]$iniContract.ini_path, [bool]$iniContract.created)

        $commitArg = if ($PinnedSha.Length -gt 12) { $PinnedSha.Substring(0, 12) } else { $PinnedSha }
        $commandArgs = @(
            'ppl', 'build',
            '--repo-root', $IconEditorRepoPath,
            '--labview-version', $RequiredLabviewYear,
            '--supported-bitness', $RequiredBitness,
            '--major', '0',
            '--minor', '0',
            '--patch', '0',
            '--build', '1',
            '--commit', $commitArg
        )
        $result.command = @($commandArgs)

        & $RunnerCliPath @commandArgs | ForEach-Object { Write-Host $_ }
        $result.exit_code = $LASTEXITCODE
        if ($result.exit_code -ne 0) {
            throw "runner-cli ppl build failed with exit code $($result.exit_code)."
        }

        if (-not (Test-Path -LiteralPath $result.output_ppl_path -PathType Leaf)) {
            throw "runner-cli reported success, but PPL output was not found: $($result.output_ppl_path)"
        }
        Copy-Item -LiteralPath $result.output_ppl_path -Destination $result.output_ppl_snapshot_path -Force

        $logAlignment = Test-PplBuildLabVIEWVersionAlignment `
            -IconEditorRepoPath $IconEditorRepoPath `
            -RequiredLabviewYear ([string]$effectiveExecutionLabviewYear) `
            -PreExistingExecuteBuildSpecLogs @($preExistingExecuteBuildSpecLogs)
        $result.buildspec_log_path = [string]$logAlignment.buildspec_log_path
        $result.detected_labview_executable = [string]$logAlignment.detected_labview_executable
        $result.detected_labview_year = [string]$logAlignment.detected_labview_year
        if ([string]$logAlignment.status -ne 'pass') {
            throw [string]$logAlignment.message
        }

        $result.status = 'pass'
        $result.message = "runner-cli PPL capability check passed (source LabVIEW $RequiredLabviewYear, execution LabVIEW $effectiveExecutionLabviewYear, x$RequiredBitness)."
    } catch {
        if ($null -eq $result.exit_code) {
            $result.exit_code = 1
        }
        $result.status = 'fail'
        $result.message = $_.Exception.Message
    }

    return [pscustomobject]$result
}

function Invoke-RunnerCliVipPackageHarnessCheck {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RunnerCliPath,
        [Parameter(Mandatory = $true)]
        [string]$PowerShellExecutable,
        [Parameter(Mandatory = $true)]
        [string]$IconEditorRepoPath,
        [Parameter(Mandatory = $true)]
        [string]$PinnedSha,
        [Parameter(Mandatory = $true)]
        [string]$RequiredLabviewYear,
        [Parameter(Mandatory = $true)]
        [string]$RequiredBitness
    )

    $statusRoot = Join-Path -Path $IconEditorRepoPath -ChildPath 'builds\status'
    $releaseNotesPath = Join-Path -Path $statusRoot -ChildPath 'workspace-installer-release-notes.md'
    $displayInfoPath = Join-Path -Path $statusRoot -ChildPath 'workspace-installer-vip-display-info.json'
    $vipcAuditPath = Join-Path -Path $statusRoot -ChildPath 'workspace-installer-vipc-audit.json'
    $vipBuildStatusPath = Join-Path -Path $statusRoot -ChildPath 'workspace-installer-vip-build.json'
    $vipcPath = '.github/actions/apply-vipc/runner_dependencies.vipc'
    $vipbPath = 'Tooling/deployment/NI Icon editor.vipb'
    $nonBlockingVipcMismatchRoots = @('sas_workshops_lib_lunit_for_g_cli')

    $result = [ordered]@{
        status = 'pending'
        message = ''
        runner_cli_path = $RunnerCliPath
        powershell_executable = $PowerShellExecutable
        repo_path = $IconEditorRepoPath
        required_labview_year = $RequiredLabviewYear
        required_bitness = $RequiredBitness
        vipb_path = $vipbPath
        vipc_path = $vipcPath
        vipc_assert_output_path = $vipcAuditPath
        vip_build_status_path = $vipBuildStatusPath
        release_notes_path = $releaseNotesPath
        display_information_path = $displayInfoPath
        output_vip_path = ''
        command = [ordered]@{
            vipc_assert = @()
            vipc_apply = @()
            vip_build = @()
        }
        exit_code = $null
        labview_install_root = ''
    }

    try {
        if (-not (Test-Path -LiteralPath $RunnerCliPath -PathType Leaf)) {
            throw "runner-cli executable not found: $RunnerCliPath"
        }
        if ([string]::IsNullOrWhiteSpace($PowerShellExecutable)) {
            throw 'PowerShell executable is required for VIP harness script execution.'
        }
        if (-not (Test-Path -LiteralPath $IconEditorRepoPath -PathType Container)) {
            throw "Icon editor repository path not found: $IconEditorRepoPath"
        }
        if ($PinnedSha -notmatch '^[0-9a-f]{40}$') {
            throw "Pinned SHA is invalid for VIP harness check: $PinnedSha"
        }
        if ($RequiredBitness -ne '64') {
            throw "VIP harness currently supports only 64-bit execution. requested=$RequiredBitness"
        }

        $labviewRoot = Get-LabVIEWInstallRoot -VersionYear $RequiredLabviewYear -Bitness $RequiredBitness
        if ([string]::IsNullOrWhiteSpace($labviewRoot)) {
            throw "LabVIEW $RequiredLabviewYear ($RequiredBitness-bit) is required for runner-cli VIP harness but was not found."
        }
        $result.labview_install_root = $labviewRoot

        Ensure-Directory -Path $statusRoot
        if (-not (Test-Path -LiteralPath $releaseNotesPath -PathType Leaf)) {
            @(
                "# Workspace Installer Harness"
                ""
                "Automated VI package build initiated by the workspace bootstrap installer."
            ) | Set-Content -LiteralPath $releaseNotesPath -Encoding UTF8
        }

        $displayPayload = [ordered]@{
            'Company Name' = 'LabVIEW Community CI/CD'
            'Product Name' = 'LabVIEW Icon Editor'
            'Product Description Summary' = 'Automated VI Package harness build from workspace installer.'
            'Product Description' = 'Workspace bootstrap installer harness execution.'
            'License Agreement Name' = ''
            'Author Name (Person or Company)' = 'LabVIEW Community CI/CD'
            'Product Homepage (URL)' = 'https://github.com/LabVIEW-Community-CI-CD/labview-icon-editor'
            'Legal Copyright' = '(c) LabVIEW Community CI/CD'
            'Release Notes - Change Log' = 'Workspace installer harness run.'
            'Package Version' = [ordered]@{
                major = 0
                minor = 0
                patch = 0
                build = 1
            }
        }
        $displayPayload | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $displayInfoPath -Encoding UTF8

        Invoke-PreVipLabVIEWCloseBestEffort -IconEditorRepoPath $IconEditorRepoPath

        $vipcAssertArgs = @(
            'vipc', 'assert',
            '--repo-root', $IconEditorRepoPath,
            '--supported-bitness', $RequiredBitness,
            '--vipc-path', $vipcPath,
            '--labview-version', $RequiredLabviewYear,
            '--output-path', $vipcAuditPath,
            '--fail-on-mismatch'
        )
        $result.command.vipc_assert = @($vipcAssertArgs)
        Write-InstallerFeedback -Message 'Running runner-cli vipc assert.'
        & $RunnerCliPath @vipcAssertArgs | ForEach-Object { Write-Host $_ }
        $vipcAssertExit = $LASTEXITCODE
        if ($vipcAssertExit -ne 0) {
            $mismatchAssessment = Get-VipcMismatchAssessment `
                -VipcAuditPath $vipcAuditPath `
                -NonBlockingRoots $nonBlockingVipcMismatchRoots

            if ([bool]$mismatchAssessment.all_non_blocking -and @($mismatchAssessment.mismatched_roots).Count -gt 0) {
                $rootsLabel = [string]::Join(', ', @($mismatchAssessment.mismatched_roots))
                Write-InstallerFeedback -Message ("VIPC assert mismatch is non-blocking for harness mode (roots: {0}); attempting best-effort native VIPC apply before VIP build." -f $rootsLabel)
                $nonBlockingApplyWarning = $null
                try {
                    $nativeApply = Invoke-VipcApplyWithVipmCli `
                        -IconEditorRepoPath $IconEditorRepoPath `
                        -VipcPath $vipcPath `
                        -RequiredLabviewYear ([string]$RequiredLabviewYear) `
                        -RequiredBitness ([string]$RequiredBitness)
                    $result.command.vipc_apply = @('vipm_best_effort', @($nativeApply.command))
                    if ([string]$nativeApply.status -ne 'pass') {
                        throw $nativeApply.message
                    }
                } catch {
                    $nonBlockingApplyWarning = $_.Exception.Message
                    Write-Warning ("Non-blocking VIPC apply attempt failed; continuing to post-action gates. {0}" -f $nonBlockingApplyWarning)
                    $result.command.vipc_apply = @('vipm_best_effort_failed', $nonBlockingApplyWarning, @($mismatchAssessment.mismatched_roots))
                }

                Write-InstallerFeedback -Message 'Re-running runner-cli vipc assert after non-blocking remediation attempt.'
                & $RunnerCliPath @vipcAssertArgs | ForEach-Object { Write-Host $_ }
                if ($LASTEXITCODE -ne 0) {
                    $postApplyAssessment = Get-VipcMismatchAssessment `
                        -VipcAuditPath $vipcAuditPath `
                        -NonBlockingRoots $nonBlockingVipcMismatchRoots
                    if (-not [bool]$postApplyAssessment.all_non_blocking) {
                        throw "runner-cli vipc assert failed after non-blocking remediation and introduced blocking mismatches."
                    }
                    $postRootsLabel = [string]::Join(', ', @($postApplyAssessment.mismatched_roots))
                    Write-InstallerFeedback -Message ("VIPC assert still reports non-blocking mismatch roots after remediation (roots: {0}); continuing." -f $postRootsLabel)
                }
            } else {
                Write-InstallerFeedback -Message 'VIPC assert reported dependency drift; applying VIPC dependencies via native VIPM CLI.'
                $nativeApply = Invoke-VipcApplyWithVipmCli `
                    -IconEditorRepoPath $IconEditorRepoPath `
                    -VipcPath $vipcPath `
                    -RequiredLabviewYear ([string]$RequiredLabviewYear) `
                    -RequiredBitness ([string]$RequiredBitness)
                $result.command.vipc_apply = @('vipm', @($nativeApply.command))
                if ([string]$nativeApply.status -ne 'pass') {
                    throw $nativeApply.message
                }

                Write-InstallerFeedback -Message 'Re-running runner-cli vipc assert after apply.'
                & $RunnerCliPath @vipcAssertArgs | ForEach-Object { Write-Host $_ }
                if ($LASTEXITCODE -ne 0) {
                    throw "runner-cli vipc assert failed after apply with exit code $LASTEXITCODE."
                }
            }
        }

        $commitArg = if ($PinnedSha.Length -gt 12) { $PinnedSha.Substring(0, 12) } else { $PinnedSha }
        $invokeVipBuildScriptPath = Join-Path -Path $IconEditorRepoPath -ChildPath 'Tooling\Invoke-VipBuild.ps1'
        if (-not (Test-Path -LiteralPath $invokeVipBuildScriptPath -PathType Leaf)) {
            throw "Invoke-VipBuild.ps1 was not found: $invokeVipBuildScriptPath"
        }
        $baseVipBuildArgs = @(
            '-SupportedBitness', $RequiredBitness,
            '-RepoRoot', $IconEditorRepoPath,
            '-VIPBPath', $vipbPath,
            '-LabVIEWVersion', $RequiredLabviewYear,
            '-ExecutionLabVIEWYear', $RequiredLabviewYear,
            '-DisplayInformationJsonPath', $displayInfoPath,
            '-LabVIEWMinorRevision', '0',
            '-Major', '0',
            '-Minor', '0',
            '-Patch', '0',
            '-Build', '1',
            '-Commit', $commitArg,
            '-ReleaseNotesFile', $releaseNotesPath,
            '-StatusPath', $vipBuildStatusPath
        )

        $maxVipBuildAttempts = 2
        $vipBuildSucceeded = $false
        $result.command.vip_build = @()
        for ($vipBuildAttempt = 1; $vipBuildAttempt -le $maxVipBuildAttempts; $vipBuildAttempt++) {
            $attemptTimeoutSeconds = if ($vipBuildAttempt -eq 1) { '1200' } else { '1800' }
            $nativeVipBuildArgs = @($baseVipBuildArgs + @('-VipmTimeoutSeconds', $attemptTimeoutSeconds))
            $result.command.vip_build = @($PowerShellExecutable, '-File', $invokeVipBuildScriptPath, @($nativeVipBuildArgs))

            Write-InstallerFeedback -Message ("Running native VIP build harness via Invoke-VipBuild.ps1 (ExecutionLabVIEWYear=2020 contract). attempt={0}/{1} vipm_timeout_seconds={2}" -f $vipBuildAttempt, $maxVipBuildAttempts, $attemptTimeoutSeconds)
            $result.exit_code = Invoke-PowerShellFile `
                -PowerShellExecutable $PowerShellExecutable `
                -ScriptPath $invokeVipBuildScriptPath `
                -ScriptArguments @($nativeVipBuildArgs)

            if ($result.exit_code -eq 0) {
                $vipBuildSucceeded = $true
                break
            }

            $timeoutReasonDetected = $false
            $retryDiagnosticReason = 'first_attempt_failure'
            if (Test-Path -LiteralPath $vipBuildStatusPath -PathType Leaf) {
                try {
                    $vipBuildStatus = Get-Content -LiteralPath $vipBuildStatusPath -Raw | ConvertFrom-Json -ErrorAction Stop
                    if ([string]$vipBuildStatus.reason -eq 'vipm_timeout') {
                        $timeoutReasonDetected = $true
                        $retryDiagnosticReason = 'vipm_timeout_reason'
                    } else {
                        foreach ($timeoutLogPath in @([string]$vipBuildStatus.vipm_log, [string]$vipBuildStatus.gcli_log)) {
                            if ([string]::IsNullOrWhiteSpace($timeoutLogPath) -or -not (Test-Path -LiteralPath $timeoutLogPath -PathType Leaf)) {
                                continue
                            }
                            $timeoutPatternMatched = Select-String -Path $timeoutLogPath -Pattern 'timed out after|Timeout waiting on VIPM' -SimpleMatch:$false -Quiet
                            if ($timeoutPatternMatched) {
                                $timeoutReasonDetected = $true
                                $retryDiagnosticReason = 'vipm_timeout_log'
                                break
                            }
                        }
                    }
                } catch {
                    $retryDiagnosticReason = 'status_parse_failed'
                }
            }

            if ($vipBuildAttempt -lt $maxVipBuildAttempts) {
                if (-not $timeoutReasonDetected -and $retryDiagnosticReason -eq 'first_attempt_failure') {
                    $retryDiagnosticReason = 'non_timeout_first_failure'
                }
                Write-InstallerFeedback -Message ("Native VIP build attempt {0} failed (reason={1}); retrying once after best-effort LabVIEW cleanup." -f $vipBuildAttempt, $retryDiagnosticReason)
                Invoke-PreVipLabVIEWCloseBestEffort -IconEditorRepoPath $IconEditorRepoPath
                Start-Sleep -Seconds 10
                continue
            }

            break
        }

        if (-not $vipBuildSucceeded) {
            throw "native VIP build failed with exit code $($result.exit_code)."
        }

        $vipPath = ''
        if (Test-Path -LiteralPath $vipBuildStatusPath -PathType Leaf) {
            try {
                $vipStatus = Get-Content -LiteralPath $vipBuildStatusPath -Raw | ConvertFrom-Json -ErrorAction Stop
                $vipPath = [string]$vipStatus.vip_path
            } catch {
                # Fall back to filesystem scan when status parsing fails.
            }
        }
        if ([string]::IsNullOrWhiteSpace($vipPath)) {
            $vipPath = Get-LatestVipPath -RepoRoot $IconEditorRepoPath
        }
        $result.output_vip_path = $vipPath

        if ([string]::IsNullOrWhiteSpace($vipPath) -or -not (Test-Path -LiteralPath $vipPath -PathType Leaf)) {
            throw "runner-cli vip build reported success, but no .vip output was found."
        }

        $result.status = 'pass'
        $result.message = 'runner-cli VIP harness build passed.'
    } catch {
        if ($null -eq $result.exit_code) {
            $result.exit_code = 1
        }
        $result.status = 'fail'
        $result.message = $_.Exception.Message
    }

    return [pscustomobject]$result
}

$resolvedWorkspaceRoot = [System.IO.Path]::GetFullPath($WorkspaceRoot)
$resolvedManifestPath = [System.IO.Path]::GetFullPath($ManifestPath)
$resolvedOutputPath = [System.IO.Path]::GetFullPath($OutputPath)
$governancePayloadRoot = Split-Path -Parent $resolvedManifestPath
$payloadRoot = Split-Path -Parent $governancePayloadRoot
if ([string]::IsNullOrWhiteSpace($payloadRoot)) {
    $payloadRoot = $governancePayloadRoot
}
if (-not (Test-Path -LiteralPath (Join-Path $payloadRoot 'tools') -PathType Container) -and (Test-Path -LiteralPath (Join-Path $governancePayloadRoot 'tools') -PathType Container)) {
    # Backward compatibility for payloads that still place tools under workspace-governance.
    $payloadRoot = $governancePayloadRoot
}

$errors = @()
$warnings = @()
$dependencyChecks = @()
$repositoryResults = @()
$payloadSync = [ordered]@{
    status = 'pending'
    files = @()
    message = ''
}
$runnerCliBundle = [ordered]@{
    status = 'not_checked'
    message = ''
    root = Join-Path $payloadRoot 'tools\runner-cli\win-x64'
    exe_path = ''
    sha_file = ''
    metadata_file = ''
    expected_sha256 = ''
    actual_sha256 = ''
}
$cliBundle = [ordered]@{
    status = 'not_checked'
    message = ''
    repo = ''
    version = ''
    source_commit = ''
    payload_root = Join-Path $payloadRoot 'tools\cdev-cli'
    asset_win = ''
    asset_win_path = ''
    asset_win_expected_sha256 = ''
    asset_win_actual_sha256 = ''
    asset_win_sha_file = ''
    asset_linux = ''
    asset_linux_path = ''
    asset_linux_expected_sha256 = ''
    asset_linux_actual_sha256 = ''
    asset_linux_sha_file = ''
    entrypoint_win = ''
    entrypoint_linux = ''
    extracted_win_root = ''
    entrypoint_win_path = ''
}
$pplCapabilityChecks = [ordered]@{
    '32' = [ordered]@{
        status = 'not_run'
        message = ''
        runner_cli_path = ''
        repo_path = ''
        required_labview_year = '2020'
        expected_execution_labview_year = '2020'
        required_bitness = '32'
        output_ppl_path = ''
        output_ppl_snapshot_path = ''
        command = @()
        exit_code = $null
        labview_install_root = ''
        buildspec_log_path = ''
        detected_labview_executable = ''
        detected_labview_year = ''
    }
    '64' = [ordered]@{
        status = 'not_run'
        message = ''
        runner_cli_path = ''
        repo_path = ''
        required_labview_year = '2020'
        expected_execution_labview_year = '2020'
        required_bitness = '64'
        output_ppl_path = ''
        output_ppl_snapshot_path = ''
        command = @()
        exit_code = $null
        labview_install_root = ''
        buildspec_log_path = ''
        detected_labview_executable = ''
        detected_labview_year = ''
    }
}
$vipPackageBuildCheck = [ordered]@{
    status = 'not_run'
    message = ''
    runner_cli_path = ''
    repo_path = ''
    required_labview_year = '2020'
    required_bitness = '64'
    vipb_path = ''
    vipc_path = ''
    vipc_assert_output_path = ''
    vip_build_status_path = ''
    release_notes_path = ''
    display_information_path = ''
    output_vip_path = ''
    command = [ordered]@{
        vipc_assert = @()
        vipc_apply = @()
        vip_build = @()
    }
    exit_code = $null
    labview_install_root = ''
}
$governanceAudit = [ordered]@{
    invoked = $false
    status = 'not_run'
    exit_code = $null
    report_path = Join-Path $resolvedWorkspaceRoot 'artifacts\workspace-governance-latest.json'
    branch_only_failure = $false
    branch_failures = @()
    non_branch_failures = @()
    message = ''
}
$postActionSequence = New-Object System.Collections.ArrayList
$contractSplit = [ordered]@{
    execution_profile = 'host-release'
    skip_vip_harness = $false
    active_artifact_root = 'artifacts\release'
    release_build_contract = [ordered]@{
        required_year = '2020'
        required_ppl_bitnesses = @('32', '64')
        required_vip_bitness = '64'
        artifact_root = 'artifacts\release'
    }
    container_parity_contract = [ordered]@{
        artifact_root = 'artifacts\parity'
        build_spec_kind = 'ppl'
        build_spec_placeholder = 'srcdist'
        allowed_windows_tags = @()
        lvcontainer_raw = ''
        windows_tag = ''
    }
}

try {
    Write-InstallerFeedback -Message ("Starting workspace {0} run. workspace={1}" -f $Mode.ToLowerInvariant(), $resolvedWorkspaceRoot)
    Ensure-Directory -Path $resolvedWorkspaceRoot
    Ensure-Directory -Path (Split-Path -Parent $resolvedOutputPath)

    Write-InstallerFeedback -Message 'Checking required commands on PATH.'
    $powershellCmd = Get-Command 'powershell' -ErrorAction SilentlyContinue
    $pwshCmd = Get-Command 'pwsh' -ErrorAction SilentlyContinue
    $runtimePowerShellExecutable = ''
    try {
        $runtimePowerShellExecutable = Get-PreferredPowerShellExecutable
    } catch {
        $runtimePowerShellExecutable = ''
    }

    foreach ($commandName in @('powershell', 'pwsh')) {
        $cmd = if ($commandName -eq 'powershell') { $powershellCmd } else { $pwshCmd }
        $check = [ordered]@{
            command = $commandName
            required = if ($commandName -eq 'powershell') { $true } else { $false }
            present = To-Bool ($null -ne $cmd)
            path = if ($null -ne $cmd) { $cmd.Source } else { '' }
        }
        $dependencyChecks += [pscustomobject]$check
    }
    if ([string]::IsNullOrWhiteSpace($runtimePowerShellExecutable)) {
        $errors += "Required command 'powershell' (or fallback 'pwsh') was not found on PATH."
    }

    foreach ($commandName in @('git', 'gh', 'g-cli')) {
        $cmd = Get-Command $commandName -ErrorAction SilentlyContinue
        $check = [ordered]@{
            command = $commandName
            required = $true
            present = To-Bool ($null -ne $cmd)
            path = if ($null -ne $cmd) { $cmd.Source } else { '' }
        }
        $dependencyChecks += [pscustomobject]$check
        if (-not $check.present) {
            $errors += "Required command '$commandName' was not found on PATH."
        }
    }

    if (-not (Test-Path -LiteralPath $resolvedManifestPath -PathType Leaf)) {
        throw "Manifest not found: $resolvedManifestPath"
    }

    Write-InstallerFeedback -Message ("Loading manifest: {0}" -f $resolvedManifestPath)
    $manifest = Get-Content -LiteralPath $resolvedManifestPath -Raw | ConvertFrom-Json -ErrorAction Stop
    if ($null -eq $manifest.managed_repos -or @($manifest.managed_repos).Count -eq 0) {
        throw "Manifest does not contain managed_repos entries: $resolvedManifestPath"
    }

    $offlineGitModeRaw = [string]$env:LVIE_OFFLINE_GIT_MODE
    $offlineGitMode = ($offlineGitModeRaw -match '^(1|true|yes)$')
    if ($offlineGitMode) {
        Write-InstallerFeedback -Message 'LVIE_OFFLINE_GIT_MODE is enabled; git network fetch/clone operations will be skipped.'
    }

    $releaseRequiredLabviewYear = '2020'
    $releaseRequiredPplBitnesses = @('32', '64')
    $releaseRequiredVipBitness = '64'
    $releaseArtifactRoot = 'artifacts\release'
    $containerParityArtifactRoot = 'artifacts\parity'
    $containerParityBuildSpecKind = 'ppl'
    $containerParityBuildSpecPlaceholder = 'srcdist'
    $containerParityAllowedWindowsTags = @()
    $executionProfile = 'host-release'
    $skipVipHarness = $false
    $requiredLabviewYear = $releaseRequiredLabviewYear
    $requiredPplBitnesses = @($releaseRequiredPplBitnesses)
    $requiredVipBitness = $releaseRequiredVipBitness
    $activeArtifactRoot = $releaseArtifactRoot
    $runnerCliRelativeRoot = 'tools\runner-cli\win-x64'
    $cliBundleRelativeRoot = 'tools\cdev-cli'
    $cliBundleAssetWin = 'cdev-cli-win-x64.zip'
    $cliBundleAssetWinSha = ''
    $cliBundleAssetLinux = 'cdev-cli-linux-x64.tar.gz'
    $cliBundleAssetLinuxSha = ''
    $cliBundleEntrypointWin = 'tools\cdev-cli\win-x64\cdev-cli\scripts\Invoke-CdevCli.ps1'
    $cliBundleEntrypointLinux = 'tools/cdev-cli/linux-x64/cdev-cli/scripts/Invoke-CdevCli.ps1'
    $executionProfileOverride = [string]$env:LVIE_INSTALLER_EXECUTION_PROFILE
    if (-not [string]::IsNullOrWhiteSpace($executionProfileOverride)) {
        if ($executionProfileOverride -notin @('host-release', 'container-parity')) {
            throw "Invalid LVIE_INSTALLER_EXECUTION_PROFILE '$executionProfileOverride'. Expected 'host-release' or 'container-parity'."
        }
        $executionProfile = $executionProfileOverride
    }
    $parityLvcontainerRaw = [string]$env:LVIE_PARITY_LVCONTAINER_RAW
    $parityWindowsTag = [string]$env:LVIE_PARITY_WINDOWS_TAG
    $parityBuildSpecKindOverride = [string]$env:LVIE_PARITY_BUILD_SPEC_KIND
    $parityBuildSpecPlaceholderOverride = [string]$env:LVIE_PARITY_BUILD_SPEC_PLACEHOLDER
    if ($null -ne $manifest.PSObject.Properties['installer_contract']) {
        $installerContract = $manifest.installer_contract
        if ($null -ne $installerContract.PSObject.Properties['labview_gate']) {
            $labviewGate = $installerContract.labview_gate
            if (-not [string]::IsNullOrWhiteSpace([string]$labviewGate.required_year)) {
                $releaseRequiredLabviewYear = [string]$labviewGate.required_year
            }
            if ($null -ne $labviewGate.PSObject.Properties['required_ppl_bitnesses']) {
                $releaseRequiredPplBitnesses = @($labviewGate.required_ppl_bitnesses)
            }
            if (-not [string]::IsNullOrWhiteSpace([string]$labviewGate.required_vip_bitness)) {
                $releaseRequiredVipBitness = [string]$labviewGate.required_vip_bitness
            }
            if (($null -ne $labviewGate.PSObject.Properties['required_bitness']) -and (-not [string]::IsNullOrWhiteSpace([string]$labviewGate.required_bitness))) {
                $releaseRequiredVipBitness = [string]$labviewGate.required_bitness
            }
        }
        if ($null -ne $installerContract.PSObject.Properties['release_build_contract']) {
            $releaseBuildContract = $installerContract.release_build_contract
            if (-not [string]::IsNullOrWhiteSpace([string]$releaseBuildContract.required_year)) {
                $releaseRequiredLabviewYear = [string]$releaseBuildContract.required_year
            }
            if ($null -ne $releaseBuildContract.PSObject.Properties['required_ppl_bitnesses']) {
                $releaseRequiredPplBitnesses = @($releaseBuildContract.required_ppl_bitnesses)
            }
            if (-not [string]::IsNullOrWhiteSpace([string]$releaseBuildContract.required_vip_bitness)) {
                $releaseRequiredVipBitness = [string]$releaseBuildContract.required_vip_bitness
            }
            if (-not [string]::IsNullOrWhiteSpace([string]$releaseBuildContract.artifact_root)) {
                $releaseArtifactRoot = [string]$releaseBuildContract.artifact_root
            }
            if (-not [string]::IsNullOrWhiteSpace([string]$releaseBuildContract.required_execution_profile)) {
                $expectedReleaseExecutionProfile = [string]$releaseBuildContract.required_execution_profile
                if ($expectedReleaseExecutionProfile -notin @('host-release', 'container-parity')) {
                    throw "Installer contract release_build_contract.required_execution_profile is invalid: '$expectedReleaseExecutionProfile'."
                }
            }
        }
        if ($null -ne $installerContract.PSObject.Properties['container_parity_contract']) {
            $containerParityContract = $installerContract.container_parity_contract
            if (-not [string]::IsNullOrWhiteSpace([string]$containerParityContract.artifact_root)) {
                $containerParityArtifactRoot = [string]$containerParityContract.artifact_root
            }
            if (-not [string]::IsNullOrWhiteSpace([string]$containerParityContract.build_spec_kind)) {
                $containerParityBuildSpecKind = [string]$containerParityContract.build_spec_kind
            }
            if (-not [string]::IsNullOrWhiteSpace([string]$containerParityContract.build_spec_placeholder)) {
                $containerParityBuildSpecPlaceholder = [string]$containerParityContract.build_spec_placeholder
            }
            if ($null -ne $containerParityContract.PSObject.Properties['allowed_windows_tags']) {
                $containerParityAllowedWindowsTags = @(
                    @($containerParityContract.allowed_windows_tags) |
                    ForEach-Object { [string]$_ } |
                    Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
                )
            }
            if (-not [string]::IsNullOrWhiteSpace([string]$containerParityContract.required_execution_profile)) {
                $expectedParityExecutionProfile = [string]$containerParityContract.required_execution_profile
                if ($expectedParityExecutionProfile -notin @('host-release', 'container-parity')) {
                    throw "Installer contract container_parity_contract.required_execution_profile is invalid: '$expectedParityExecutionProfile'."
                }
            }
        }
        if ($null -ne $installerContract.PSObject.Properties['runner_cli_bundle']) {
            $runnerCliBundleContract = $installerContract.runner_cli_bundle
            if (-not [string]::IsNullOrWhiteSpace([string]$runnerCliBundleContract.relative_root)) {
                $runnerCliRelativeRoot = [string]$runnerCliBundleContract.relative_root
            }
        }
        if ($null -eq $installerContract.PSObject.Properties['cli_bundle']) {
            throw "Installer contract requires 'cli_bundle' metadata."
        }
        $cliBundleContract = $installerContract.cli_bundle
        if (-not [string]::IsNullOrWhiteSpace([string]$cliBundleContract.payload_root)) {
            $cliBundleRelativeRoot = [string]$cliBundleContract.payload_root
        }
        if (-not [string]::IsNullOrWhiteSpace([string]$cliBundleContract.asset_win)) {
            $cliBundleAssetWin = [string]$cliBundleContract.asset_win
        }
        if (-not [string]::IsNullOrWhiteSpace([string]$cliBundleContract.asset_win_sha256)) {
            $cliBundleAssetWinSha = ([string]$cliBundleContract.asset_win_sha256).ToLowerInvariant()
        }
        if (-not [string]::IsNullOrWhiteSpace([string]$cliBundleContract.asset_linux)) {
            $cliBundleAssetLinux = [string]$cliBundleContract.asset_linux
        }
        if (-not [string]::IsNullOrWhiteSpace([string]$cliBundleContract.asset_linux_sha256)) {
            $cliBundleAssetLinuxSha = ([string]$cliBundleContract.asset_linux_sha256).ToLowerInvariant()
        }
        if (-not [string]::IsNullOrWhiteSpace([string]$cliBundleContract.entrypoint_win)) {
            $cliBundleEntrypointWin = [string]$cliBundleContract.entrypoint_win
        }
        if (-not [string]::IsNullOrWhiteSpace([string]$cliBundleContract.entrypoint_linux)) {
            $cliBundleEntrypointLinux = [string]$cliBundleContract.entrypoint_linux
        }
        $cliBundle.repo = [string]$cliBundleContract.repo
        $cliBundle.version = [string]$cliBundleContract.version
        $cliBundle.source_commit = ([string]$cliBundleContract.source_commit).ToLowerInvariant()
    }

    if ($executionProfile -eq 'container-parity') {
        $skipVipHarness = $true
        $requiredLabviewYear = $releaseRequiredLabviewYear
        $requiredPplBitnesses = @($releaseRequiredPplBitnesses)
        $requiredVipBitness = $releaseRequiredVipBitness
        $activeArtifactRoot = $containerParityArtifactRoot
    } else {
        $requiredLabviewYear = $releaseRequiredLabviewYear
        $requiredPplBitnesses = @($releaseRequiredPplBitnesses)
        $requiredVipBitness = $releaseRequiredVipBitness
        $activeArtifactRoot = $releaseArtifactRoot
    }

    if (-not [string]::IsNullOrWhiteSpace($parityBuildSpecKindOverride)) {
        $containerParityBuildSpecKind = $parityBuildSpecKindOverride
    }
    if (-not [string]::IsNullOrWhiteSpace($parityBuildSpecPlaceholderOverride)) {
        $containerParityBuildSpecPlaceholder = $parityBuildSpecPlaceholderOverride
    }

    $requiredLabviewYearOverride = [string]$env:LVIE_GATE_REQUIRED_LABVIEW_YEAR
    if (-not [string]::IsNullOrWhiteSpace($requiredLabviewYearOverride)) {
        if ($requiredLabviewYearOverride -notmatch '^\d{4}$') {
            throw "Invalid LVIE_GATE_REQUIRED_LABVIEW_YEAR override '$requiredLabviewYearOverride'. Expected a 4-digit year."
        }
        Write-InstallerFeedback -Message ("Overriding required LabVIEW year from environment: {0}" -f $requiredLabviewYearOverride)
        $requiredLabviewYear = $requiredLabviewYearOverride
    }

    $pplExpectedExecutionLabviewYear = [string]$env:LVIE_RUNNERCLI_EXECUTION_LABVIEW_YEAR
    if ([string]::IsNullOrWhiteSpace($pplExpectedExecutionLabviewYear)) {
        $pplExpectedExecutionLabviewYear = $requiredLabviewYear
    } else {
        if ($pplExpectedExecutionLabviewYear -notmatch '^\d{4}$') {
            throw "Invalid LVIE_RUNNERCLI_EXECUTION_LABVIEW_YEAR override '$pplExpectedExecutionLabviewYear'. Expected a 4-digit year."
        }
        Write-InstallerFeedback -Message ("Overriding expected PPL execution LabVIEW year from environment: {0}" -f $pplExpectedExecutionLabviewYear)
    }

    $singlePplBitnessOverride = [string]$env:LVIE_GATE_SINGLE_PPL_BITNESS
    if (-not [string]::IsNullOrWhiteSpace($singlePplBitnessOverride)) {
        if ($singlePplBitnessOverride -notin @('32', '64')) {
            throw "Invalid LVIE_GATE_SINGLE_PPL_BITNESS override '$singlePplBitnessOverride'. Expected '32' or '64'."
        }
        Write-InstallerFeedback -Message ("Overriding required PPL bitnesses from environment: {0}" -f $singlePplBitnessOverride)
        $requiredPplBitnesses = @($singlePplBitnessOverride)
    }

    $requiredPplBitnesses = @(
        @($requiredPplBitnesses |
            ForEach-Object { [string]$_ } |
            Where-Object { $_ -in @('32', '64') } |
            Select-Object -Unique |
            Sort-Object)
    )
    $requiredPplBitnessLabel = [string]::Join(',', @($requiredPplBitnesses))
    if ($executionProfile -eq 'host-release') {
        if ([string]::IsNullOrWhiteSpace($singlePplBitnessOverride)) {
            if ($requiredPplBitnessLabel -ne '32,64') {
                throw "Installer contract requires dual PPL bitness gating ['32','64']; received '$requiredPplBitnessLabel'."
            }
        } elseif ($requiredPplBitnessLabel -ne $singlePplBitnessOverride) {
            throw "PPL bitness override '$singlePplBitnessOverride' was not applied; effective set is '$requiredPplBitnessLabel'."
        }
    } else {
        if ([string]::IsNullOrWhiteSpace($singlePplBitnessOverride)) {
            throw "Container parity profile requires LVIE_GATE_SINGLE_PPL_BITNESS ('32' or '64')."
        }
        if ($requiredPplBitnessLabel -ne $singlePplBitnessOverride) {
            throw "PPL bitness override '$singlePplBitnessOverride' was not applied; effective set is '$requiredPplBitnessLabel'."
        }
    }
    if (($executionProfile -eq 'host-release') -and ($requiredVipBitness -ne '64')) {
        throw "Installer contract requires VIP bitness '64'; received '$requiredVipBitness'."
    }
    if ([string]::IsNullOrWhiteSpace($cliBundleAssetWin) -or [string]::IsNullOrWhiteSpace($cliBundleAssetLinux)) {
        throw "Installer contract requires cli_bundle asset names for both Windows and Linux."
    }
    if ($cliBundleAssetWinSha -notmatch '^[0-9a-f]{64}$') {
        throw "Installer contract has invalid cli_bundle.asset_win_sha256 '$cliBundleAssetWinSha'."
    }
    if ($cliBundleAssetLinuxSha -notmatch '^[0-9a-f]{64}$') {
        throw "Installer contract has invalid cli_bundle.asset_linux_sha256 '$cliBundleAssetLinuxSha'."
    }

    if ($Mode -eq 'Install') {
        if ([string]::IsNullOrWhiteSpace($InstallerExecutionContext)) {
            throw "Install mode requires -InstallerExecutionContext NsisInstall (or LocalInstallerExercise)."
        }
        if ($InstallerExecutionContext -notin @('NsisInstall', 'LocalInstallerExercise')) {
            throw "Unsupported execution context '$InstallerExecutionContext'. Expected NsisInstall or LocalInstallerExercise."
        }
    }

    foreach ($bitness in $requiredPplBitnesses) {
        $pplCapabilityChecks[$bitness].required_labview_year = $requiredLabviewYear
        $pplCapabilityChecks[$bitness].expected_execution_labview_year = $pplExpectedExecutionLabviewYear
        $pplCapabilityChecks[$bitness].required_bitness = $bitness
    }
    $vipPackageBuildCheck.required_labview_year = $requiredLabviewYear
    $vipPackageBuildCheck.required_bitness = $requiredVipBitness
    $contractSplit = [ordered]@{
        execution_profile = $executionProfile
        skip_vip_harness = $skipVipHarness
        active_artifact_root = $activeArtifactRoot
        release_build_contract = [ordered]@{
            required_year = $releaseRequiredLabviewYear
            required_ppl_bitnesses = @($releaseRequiredPplBitnesses)
            required_vip_bitness = $releaseRequiredVipBitness
            artifact_root = $releaseArtifactRoot
        }
        container_parity_contract = [ordered]@{
            artifact_root = $containerParityArtifactRoot
            build_spec_kind = $containerParityBuildSpecKind
            build_spec_placeholder = $containerParityBuildSpecPlaceholder
            allowed_windows_tags = @($containerParityAllowedWindowsTags)
            lvcontainer_raw = $parityLvcontainerRaw
            windows_tag = $parityWindowsTag
        }
    }

    $repoTotal = @($manifest.managed_repos).Count
    $repoIndex = 0
    foreach ($repo in @($manifest.managed_repos)) {
        $repoIndex++
        $repoPath = [string]$repo.path
        $repoName = [string]$repo.repo_name
        $defaultBranch = [string]$repo.default_branch
        $requiredGhRepo = [string]$repo.required_gh_repo
        $pinnedSha = ([string]$repo.pinned_sha).ToLowerInvariant()
        $existsBefore = Test-Path -LiteralPath $repoPath -PathType Container

        $repoResult = [ordered]@{
            path = $repoPath
            repo_name = $repoName
            required_gh_repo = $requiredGhRepo
            default_branch = $defaultBranch
            pinned_sha = $pinnedSha
            exists_before = $existsBefore
            action = if ($existsBefore) { 'verify_existing' } else { 'clone_missing' }
            status = 'pass'
            issues = @()
            message = ''
            remote_checks = @()
            head_sha = ''
            branch_state = ''
        }

        try {
            Write-InstallerFeedback -Message ("[{0}/{1}] Verifying repository contract: {2}" -f $repoIndex, $repoTotal, $repoPath)
            if ($pinnedSha -notmatch '^[0-9a-f]{40}$') {
                throw "Manifest entry '$repoPath' has invalid pinned_sha '$pinnedSha'."
            }

            if (-not $existsBefore) {
                if ($Mode -eq 'Verify') {
                    throw "Repository path missing in Verify mode: $repoPath"
                }
                if ($offlineGitMode) {
                    throw "Repository path missing in offline git mode: $repoPath"
                }

                $originUrl = [string]$repo.required_remotes.origin
                if ([string]::IsNullOrWhiteSpace($originUrl)) {
                    throw "Manifest entry '$repoPath' is missing required_remotes.origin."
                }

                Ensure-Directory -Path (Split-Path -Parent $repoPath)
                $cloneOutput = & git clone $originUrl $repoPath 2>&1
                if ($LASTEXITCODE -ne 0) {
                    throw "git clone failed for '$repoPath'. $([string]::Join("`n", @($cloneOutput)))"
                }
            }

            if (-not (Test-Path -LiteralPath (Join-Path $repoPath '.git') -PathType Container)) {
                throw "Path is not a git repository: $repoPath"
            }

            foreach ($remoteProp in $repo.required_remotes.PSObject.Properties) {
                $remoteName = [string]$remoteProp.Name
                $expectedUrl = [string]$remoteProp.Value
                if ([string]::IsNullOrWhiteSpace($remoteName) -or [string]::IsNullOrWhiteSpace($expectedUrl)) {
                    continue
                }

                $currentUrlRaw = & git -C $repoPath remote get-url $remoteName 2>$null
                $currentExit = $LASTEXITCODE
                $currentUrl = if ($currentExit -eq 0) { [string]$currentUrlRaw.Trim() } else { '' }
                $remoteCheck = [ordered]@{
                    remote = $remoteName
                    expected = $expectedUrl
                    before = $currentUrl
                    after = $currentUrl
                    status = 'ok'
                    message = ''
                }

                if ($currentExit -ne 0) {
                    if ($existsBefore -or $Mode -eq 'Verify') {
                        $remoteCheck.status = 'missing'
                        $remoteCheck.message = 'Remote is missing on an existing repository.'
                        $repoResult.status = 'fail'
                        $repoResult.issues += "remote_missing_$remoteName"
                    } else {
                        $addOutput = & git -C $repoPath remote add $remoteName $expectedUrl 2>&1
                        if ($LASTEXITCODE -ne 0) {
                            throw "Failed to add remote '$remoteName' on '$repoPath'. $([string]::Join("`n", @($addOutput)))"
                        }
                        $afterUrl = (& git -C $repoPath remote get-url $remoteName).Trim()
                        $remoteCheck.after = $afterUrl
                        if ((Normalize-Url $afterUrl) -eq (Normalize-Url $expectedUrl)) {
                            $remoteCheck.status = 'added'
                        } else {
                            $remoteCheck.status = 'add_mismatch'
                            $remoteCheck.message = 'Added remote URL does not match expected value.'
                            $repoResult.status = 'fail'
                            $repoResult.issues += "remote_add_mismatch_$remoteName"
                        }
                    }
                } elseif ((Normalize-Url $currentUrl) -ne (Normalize-Url $expectedUrl)) {
                    if ($existsBefore -or $Mode -eq 'Verify') {
                        $remoteCheck.status = 'mismatch'
                        $remoteCheck.message = 'Existing remote URL does not match expected value.'
                        $repoResult.status = 'fail'
                        $repoResult.issues += "remote_mismatch_$remoteName"
                    } else {
                        $setOutput = & git -C $repoPath remote set-url $remoteName $expectedUrl 2>&1
                        if ($LASTEXITCODE -ne 0) {
                            throw "Failed to set remote '$remoteName' on '$repoPath'. $([string]::Join("`n", @($setOutput)))"
                        }
                        $afterUrl = (& git -C $repoPath remote get-url $remoteName).Trim()
                        $remoteCheck.after = $afterUrl
                        if ((Normalize-Url $afterUrl) -eq (Normalize-Url $expectedUrl)) {
                            $remoteCheck.status = 'updated'
                        } else {
                            $remoteCheck.status = 'update_mismatch'
                            $remoteCheck.message = 'Updated remote URL does not match expected value.'
                            $repoResult.status = 'fail'
                            $repoResult.issues += "remote_update_mismatch_$remoteName"
                        }
                    }
                }

                $repoResult.remote_checks += [pscustomobject]$remoteCheck
            }

            if (-not [string]::IsNullOrWhiteSpace($defaultBranch)) {
                if ($offlineGitMode) {
                    & git -C $repoPath cat-file -e "$pinnedSha`^{commit}" 2>$null
                    if ($LASTEXITCODE -ne 0) {
                        throw "Pinned SHA '$pinnedSha' is not present in local object database for '$repoPath' while offline git mode is enabled."
                    }
                } else {
                    $fetchOutput = & git -C $repoPath fetch --no-tags origin $defaultBranch 2>&1
                    if ($LASTEXITCODE -ne 0) {
                        throw "Failed to fetch origin/$defaultBranch for '$repoPath'. $([string]::Join("`n", @($fetchOutput)))"
                    }

                    & git -C $repoPath show-ref --verify "refs/remotes/origin/$defaultBranch" *> $null
                    if ($LASTEXITCODE -ne 0) {
                        $repoResult.status = 'fail'
                        $repoResult.issues += 'default_branch_missing_on_origin'
                    }
                }
            }

            if (-not $existsBefore -and $Mode -eq 'Install') {
                $checkoutOutput = & git -C $repoPath checkout --detach $pinnedSha 2>&1
                if ($LASTEXITCODE -ne 0) {
                    throw "Failed to checkout pinned_sha '$pinnedSha' in '$repoPath'. $([string]::Join("`n", @($checkoutOutput)))"
                }
            }

            $headOutput = & git -C $repoPath rev-parse HEAD 2>&1
            if ($LASTEXITCODE -ne 0) {
                throw "Failed to resolve HEAD for '$repoPath'. $([string]::Join("`n", @($headOutput)))"
            }
            $headSha = [string]$headOutput.Trim().ToLowerInvariant()
            $repoResult.head_sha = $headSha
            if ($headSha -ne $pinnedSha) {
                $repoResult.status = 'fail'
                $repoResult.issues += 'head_sha_mismatch'
            }

            $branchOutput = & git -C $repoPath symbolic-ref --quiet --short HEAD 2>$null
            if ($LASTEXITCODE -eq 0) {
                $branchName = [string]$branchOutput.Trim()
                $repoResult.branch_state = $branchName
                if (-not [string]::IsNullOrWhiteSpace($defaultBranch) -and $branchName -ne $defaultBranch) {
                    $repoResult.status = 'fail'
                    $repoResult.issues += 'branch_identity_mismatch'
                }
            } else {
                $repoResult.branch_state = 'detached'
            }

            if ($repoResult.status -eq 'pass') {
                $repoResult.message = 'Repository satisfies deterministic manifest contract.'
            } else {
                $repoResult.message = 'Repository violates deterministic manifest contract.'
            }
        } catch {
            $repoResult.status = 'fail'
            $repoResult.issues += 'exception'
            $repoResult.message = $_.Exception.Message
        }

        if ($repoResult.status -ne 'pass') {
            $errors += "$repoPath :: $($repoResult.message)"
        }

        $repositoryResults += [pscustomobject]$repoResult
    }
    $repoFailureCount = @($repositoryResults | Where-Object { [string]$_.status -ne 'pass' }).Count
    if ($repoFailureCount -eq 0) {
        Add-PostActionSequenceEntry `
            -Sequence $postActionSequence `
            -Phase 'repository-contracts' `
            -Status 'pass' `
            -Message ("Verified repository contract for {0} managed repos." -f $repoTotal)
    } else {
        Add-PostActionSequenceEntry `
            -Sequence $postActionSequence `
            -Phase 'repository-contracts' `
            -Status 'fail' `
            -Message ("Repository contract checks failed for {0} managed repos." -f $repoFailureCount)
    }

    Write-InstallerFeedback -Message 'Syncing governance payload into workspace root.'
    $cliBundle.asset_win = $cliBundleAssetWin
    $cliBundle.asset_linux = $cliBundleAssetLinux
    $cliBundle.asset_win_expected_sha256 = $cliBundleAssetWinSha
    $cliBundle.asset_linux_expected_sha256 = $cliBundleAssetLinuxSha
    $cliBundle.entrypoint_win = $cliBundleEntrypointWin
    $cliBundle.entrypoint_linux = $cliBundleEntrypointLinux
    $cliBundle.payload_root = Join-Path $payloadRoot $cliBundleRelativeRoot
    $cliBundle.asset_win_path = Join-Path $resolvedWorkspaceRoot (Join-Path $cliBundleRelativeRoot $cliBundleAssetWin)
    $cliBundle.asset_linux_path = Join-Path $resolvedWorkspaceRoot (Join-Path $cliBundleRelativeRoot $cliBundleAssetLinux)
    $cliBundle.asset_win_sha_file = "$($cliBundle.asset_win_path).sha256"
    $cliBundle.asset_linux_sha_file = "$($cliBundle.asset_linux_path).sha256"
    $cliBundle.entrypoint_win_path = Join-Path $resolvedWorkspaceRoot $cliBundleEntrypointWin
    $cliBundle.extracted_win_root = Join-Path $resolvedWorkspaceRoot 'tools\cdev-cli\win-x64'

    $payloadFiles = @(
        @{ source = (Join-Path $governancePayloadRoot 'AGENTS.md'); destination = (Join-Path $resolvedWorkspaceRoot 'AGENTS.md') },
        @{ source = (Join-Path $governancePayloadRoot 'workspace-governance.json'); destination = (Join-Path $resolvedWorkspaceRoot 'workspace-governance.json') },
        @{ source = (Join-Path $governancePayloadRoot 'scripts\Assert-WorkspaceGovernance.ps1'); destination = (Join-Path $resolvedWorkspaceRoot 'scripts\Assert-WorkspaceGovernance.ps1') },
        @{ source = (Join-Path $governancePayloadRoot 'scripts\Test-PolicyContracts.ps1'); destination = (Join-Path $resolvedWorkspaceRoot 'scripts\Test-PolicyContracts.ps1') },
        @{ source = (Join-Path $payloadRoot 'tools\runner-cli\win-x64\runner-cli.exe'); destination = (Join-Path $resolvedWorkspaceRoot 'tools\runner-cli\win-x64\runner-cli.exe') },
        @{ source = (Join-Path $payloadRoot 'tools\runner-cli\win-x64\runner-cli.exe.sha256'); destination = (Join-Path $resolvedWorkspaceRoot 'tools\runner-cli\win-x64\runner-cli.exe.sha256') },
        @{ source = (Join-Path $payloadRoot 'tools\runner-cli\win-x64\runner-cli.metadata.json'); destination = (Join-Path $resolvedWorkspaceRoot 'tools\runner-cli\win-x64\runner-cli.metadata.json') },
        @{ source = (Join-Path $payloadRoot (Join-Path $cliBundleRelativeRoot $cliBundleAssetWin)); destination = $cliBundle.asset_win_path },
        @{ source = (Join-Path $payloadRoot (Join-Path $cliBundleRelativeRoot "$cliBundleAssetWin.sha256")); destination = $cliBundle.asset_win_sha_file },
        @{ source = (Join-Path $payloadRoot (Join-Path $cliBundleRelativeRoot $cliBundleAssetLinux)); destination = $cliBundle.asset_linux_path },
        @{ source = (Join-Path $payloadRoot (Join-Path $cliBundleRelativeRoot "$cliBundleAssetLinux.sha256")); destination = $cliBundle.asset_linux_sha_file },
        @{ source = (Join-Path $payloadRoot (Join-Path $cliBundleRelativeRoot 'cli-contract.json')); destination = (Join-Path $resolvedWorkspaceRoot (Join-Path $cliBundleRelativeRoot 'cli-contract.json')) }
    )

    try {
        Ensure-Directory -Path (Join-Path $resolvedWorkspaceRoot 'scripts')

        foreach ($item in $payloadFiles) {
            $sourcePath = [string]$item.source
            $destinationPath = [string]$item.destination
            if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
                throw "Payload file is missing: $sourcePath"
            }
            Ensure-Directory -Path (Split-Path -Parent $destinationPath)
            Copy-Item -LiteralPath $sourcePath -Destination $destinationPath -Force
            $payloadSync.files += [pscustomobject]@{
                source = $sourcePath
                destination = $destinationPath
                status = 'copied'
            }
        }

        $payloadSync.status = 'success'
        $payloadSync.message = 'Workspace governance payload copied to workspace root.'
    } catch {
        $payloadSync.status = 'failed'
        $payloadSync.message = $_.Exception.Message
        $errors += "Payload sync failed. $($payloadSync.message)"
    }
    Add-PostActionSequenceEntry `
        -Sequence $postActionSequence `
        -Phase 'payload-sync' `
        -Status ([string]$payloadSync.status) `
        -Message ([string]$payloadSync.message)

    $runnerCliBundleRoot = Join-Path $resolvedWorkspaceRoot $runnerCliRelativeRoot
    $runnerCliExePath = Join-Path $runnerCliBundleRoot 'runner-cli.exe'
    $runnerCliShaPath = Join-Path $runnerCliBundleRoot 'runner-cli.exe.sha256'
    $runnerCliMetadataPath = Join-Path $runnerCliBundleRoot 'runner-cli.metadata.json'
    $runnerCliBundle.root = $runnerCliBundleRoot
    $runnerCliBundle.exe_path = $runnerCliExePath
    $runnerCliBundle.sha_file = $runnerCliShaPath
    $runnerCliBundle.metadata_file = $runnerCliMetadataPath

    $iconEditorRepoEntry = @($manifest.managed_repos | Where-Object { [string]$_.repo_name -eq 'labview-icon-editor' }) | Select-Object -First 1
    $iconEditorRepoPath = if ($null -ne $iconEditorRepoEntry) { [string]$iconEditorRepoEntry.path } else { '' }
    $iconEditorPinnedSha = if ($null -ne $iconEditorRepoEntry) { ([string]$iconEditorRepoEntry.pinned_sha).ToLowerInvariant() } else { '' }

    try {
        Write-InstallerFeedback -Message 'Verifying bundled runner-cli integrity.'
        if ([string]::IsNullOrWhiteSpace($iconEditorRepoPath)) {
            throw "Manifest does not define managed repo entry 'labview-icon-editor'."
        }
        if ([string]::IsNullOrWhiteSpace($iconEditorPinnedSha) -or $iconEditorPinnedSha -notmatch '^[0-9a-f]{40}$') {
            throw "Manifest entry 'labview-icon-editor' has invalid pinned_sha '$iconEditorPinnedSha'."
        }
        if (-not (Test-Path -LiteralPath $runnerCliExePath -PathType Leaf)) {
            throw "Bundled runner-cli executable was not found: $runnerCliExePath"
        }
        $expectedSha = Get-ExpectedShaFromFile -ShaFilePath $runnerCliShaPath
        $actualSha = Get-Sha256Hex -Path $runnerCliExePath
        $runnerCliBundle.expected_sha256 = $expectedSha
        $runnerCliBundle.actual_sha256 = $actualSha
        if ($expectedSha -ne $actualSha) {
            throw "Bundled runner-cli SHA256 mismatch. expected=$expectedSha actual=$actualSha"
        }

        if (-not (Test-Path -LiteralPath $runnerCliMetadataPath -PathType Leaf)) {
            throw "Bundled runner-cli metadata was not found: $runnerCliMetadataPath"
        }

        $runnerCliMetadata = Get-Content -LiteralPath $runnerCliMetadataPath -Raw | ConvertFrom-Json -ErrorAction Stop
        $metadataSourceCommit = ([string]$runnerCliMetadata.source_commit).ToLowerInvariant()
        if ($metadataSourceCommit -notmatch '^[0-9a-f]{40}$') {
            throw "runner-cli metadata source_commit is invalid: $metadataSourceCommit"
        }
        if ($metadataSourceCommit -ne $iconEditorPinnedSha) {
            throw "runner-cli metadata source_commit does not match manifest pin for labview-icon-editor."
        }

        $runnerCliBundle.status = 'pass'
        $runnerCliBundle.message = 'Bundled runner-cli payload integrity checks passed.'
    } catch {
        $runnerCliBundle.status = 'fail'
        $runnerCliBundle.message = $_.Exception.Message
        $errors += "Runner CLI bundle verification failed. $($runnerCliBundle.message)"
    }
    Add-PostActionSequenceEntry `
        -Sequence $postActionSequence `
        -Phase 'runner-cli-bundle' `
        -Status ([string]$runnerCliBundle.status) `
        -Message ([string]$runnerCliBundle.message)

    try {
        Write-InstallerFeedback -Message 'Verifying bundled cdev-cli assets.'
        if ([string]::IsNullOrWhiteSpace($cliBundle.asset_win_path) -or -not (Test-Path -LiteralPath $cliBundle.asset_win_path -PathType Leaf)) {
            throw "Bundled cdev-cli Windows asset was not found: $($cliBundle.asset_win_path)"
        }
        if ([string]::IsNullOrWhiteSpace($cliBundle.asset_linux_path) -or -not (Test-Path -LiteralPath $cliBundle.asset_linux_path -PathType Leaf)) {
            throw "Bundled cdev-cli Linux asset was not found: $($cliBundle.asset_linux_path)"
        }

        $winExpectedFromFile = Get-ExpectedShaFromFile -ShaFilePath $cliBundle.asset_win_sha_file
        if ($winExpectedFromFile -ne [string]$cliBundle.asset_win_expected_sha256) {
            throw "cdev-cli Windows SHA file does not match installer contract. expected=$($cliBundle.asset_win_expected_sha256) actual=$winExpectedFromFile"
        }
        $linuxExpectedFromFile = Get-ExpectedShaFromFile -ShaFilePath $cliBundle.asset_linux_sha_file
        if ($linuxExpectedFromFile -ne [string]$cliBundle.asset_linux_expected_sha256) {
            throw "cdev-cli Linux SHA file does not match installer contract. expected=$($cliBundle.asset_linux_expected_sha256) actual=$linuxExpectedFromFile"
        }

        $cliBundle.asset_win_actual_sha256 = Get-Sha256Hex -Path $cliBundle.asset_win_path
        if ($cliBundle.asset_win_actual_sha256 -ne [string]$cliBundle.asset_win_expected_sha256) {
            throw "cdev-cli Windows asset hash mismatch. expected=$($cliBundle.asset_win_expected_sha256) actual=$($cliBundle.asset_win_actual_sha256)"
        }
        $cliBundle.asset_linux_actual_sha256 = Get-Sha256Hex -Path $cliBundle.asset_linux_path
        if ($cliBundle.asset_linux_actual_sha256 -ne [string]$cliBundle.asset_linux_expected_sha256) {
            throw "cdev-cli Linux asset hash mismatch. expected=$($cliBundle.asset_linux_expected_sha256) actual=$($cliBundle.asset_linux_actual_sha256)"
        }

        Expand-CdevCliWindowsBundle -ZipPath $cliBundle.asset_win_path -DestinationPath $cliBundle.extracted_win_root
        if (-not (Test-Path -LiteralPath $cliBundle.entrypoint_win_path -PathType Leaf)) {
            throw "cdev-cli Windows entrypoint was not found after extraction: $($cliBundle.entrypoint_win_path)"
        }

        if (-not [string]::IsNullOrWhiteSpace([string]$cliBundle.source_commit) -and ([string]$cliBundle.source_commit -notmatch '^[0-9a-f]{40}$')) {
            throw "Installer contract has invalid cli_bundle.source_commit '$($cliBundle.source_commit)'."
        }

        $cliBundle.status = 'pass'
        $cliBundle.message = 'Bundled cdev-cli assets passed hash verification and Windows extraction checks.'
    } catch {
        $cliBundle.status = 'fail'
        $cliBundle.message = $_.Exception.Message
        $errors += "cdev-cli bundle verification failed. $($cliBundle.message)"
    }
    Add-PostActionSequenceEntry `
        -Sequence $postActionSequence `
        -Phase 'cli-bundle' `
        -Status ([string]$cliBundle.status) `
        -Message ([string]$cliBundle.message)

    $originalWorktreeRoot = $env:LVIE_WORKTREE_ROOT
    $effectiveWorktreeRoot = if ([string]::IsNullOrWhiteSpace($originalWorktreeRoot)) { $resolvedWorkspaceRoot } else { $originalWorktreeRoot }
    $worktreeRootOverridden = $false
    if ([string]::IsNullOrWhiteSpace($originalWorktreeRoot)) {
        if (-not [string]::IsNullOrWhiteSpace($effectiveWorktreeRoot)) {
            Write-InstallerFeedback -Message ("Setting LVIE_WORKTREE_ROOT to workspace root for post-actions: {0}" -f $effectiveWorktreeRoot)
            $worktreeRootOverridden = $true
        }
    } else {
        Write-InstallerFeedback -Message ("Using existing LVIE_WORKTREE_ROOT for post-actions: {0}" -f $effectiveWorktreeRoot)
    }

    try {
        if (-not [string]::IsNullOrWhiteSpace($effectiveWorktreeRoot)) {
            $env:LVIE_WORKTREE_ROOT = $effectiveWorktreeRoot
        }

        if ($runnerCliBundle.status -eq 'pass') {
            $repoContractStatus = $repositoryResults | Where-Object { [string]$_.path -eq $iconEditorRepoPath } | Select-Object -First 1
            if ($null -eq $repoContractStatus -or [string]$repoContractStatus.status -ne 'pass') {
                $blockingMessage = "Cannot run runner-cli PPL capability checks because icon-editor repo contract failed at '$iconEditorRepoPath'."
                foreach ($bitness in $requiredPplBitnesses) {
                    $pplCapabilityChecks[$bitness].status = 'fail'
                    $pplCapabilityChecks[$bitness].message = $blockingMessage
                    Add-PostActionSequenceEntry -Sequence $postActionSequence -Phase 'ppl-build' -Bitness $bitness -Status 'fail' -Message $blockingMessage
                }
                if ($skipVipHarness) {
                    $vipPackageBuildCheck.status = 'skipped'
                    $vipPackageBuildCheck.message = "VIP harness is skipped for execution profile '$executionProfile'."
                    Add-PostActionSequenceEntry -Sequence $postActionSequence -Phase 'vip-harness' -Bitness $requiredVipBitness -Status 'skipped' -Message $vipPackageBuildCheck.message
                } else {
                    $vipPackageBuildCheck.status = 'blocked'
                    $vipPackageBuildCheck.message = 'VIP harness was not run because icon-editor repository contract failed.'
                    Add-PostActionSequenceEntry -Sequence $postActionSequence -Phase 'vip-harness' -Bitness $requiredVipBitness -Status 'blocked' -Message $vipPackageBuildCheck.message
                }
                $errors += $blockingMessage
            } else {
                $allPplPass = $true
                foreach ($bitness in $requiredPplBitnesses) {
                    Write-InstallerFeedback -Message ("Running pre-PPL LabVIEW close sweep before {0}-bit gate." -f $bitness)
                    Invoke-PreVipLabVIEWCloseBestEffort -IconEditorRepoPath $iconEditorRepoPath
                    Start-Sleep -Seconds 3

                    try {
                        Write-InstallerFeedback -Message ("Running runner-cli PPL capability gate ({0}-bit)." -f $bitness)
                        $capabilityResult = Invoke-RunnerCliPplCapabilityCheck `
                            -RunnerCliPath $runnerCliExePath `
                            -IconEditorRepoPath $iconEditorRepoPath `
                            -PinnedSha $iconEditorPinnedSha `
                            -RequiredLabviewYear ([string]$requiredLabviewYear) `
                            -ExpectedExecutionLabviewYear ([string]$pplExpectedExecutionLabviewYear) `
                            -RequiredBitness $bitness

                        if ([string]$capabilityResult.status -ne 'pass') {
                            $firstAttemptMessage = [string]$capabilityResult.message
                            Write-InstallerFeedback -Message ("runner-cli PPL capability gate ({0}-bit) failed on first attempt; retrying once after additional LabVIEW cleanup." -f $bitness)
                            Invoke-PreVipLabVIEWCloseBestEffort -IconEditorRepoPath $iconEditorRepoPath
                            Start-Sleep -Seconds 5

                            $retryCapabilityResult = Invoke-RunnerCliPplCapabilityCheck `
                                -RunnerCliPath $runnerCliExePath `
                                -IconEditorRepoPath $iconEditorRepoPath `
                                -PinnedSha $iconEditorPinnedSha `
                                -RequiredLabviewYear ([string]$requiredLabviewYear) `
                                -ExpectedExecutionLabviewYear ([string]$pplExpectedExecutionLabviewYear) `
                                -RequiredBitness $bitness

                            if ([string]$retryCapabilityResult.status -eq 'pass') {
                                $retryCapabilityResult.message = ("{0} (passed on retry after additional cleanup)." -f [string]$retryCapabilityResult.message)
                                $capabilityResult = $retryCapabilityResult
                            } else {
                                $retryCapabilityResult.message = ("First attempt: {0} Retry attempt: {1}" -f $firstAttemptMessage, [string]$retryCapabilityResult.message)
                                $capabilityResult = $retryCapabilityResult
                            }
                        }

                        $pplCapabilityChecks[$bitness] = [ordered]@{
                            status = [string]$capabilityResult.status
                            message = [string]$capabilityResult.message
                            runner_cli_path = [string]$capabilityResult.runner_cli_path
                            repo_path = [string]$capabilityResult.repo_path
                            required_labview_year = [string]$capabilityResult.required_labview_year
                            expected_execution_labview_year = [string]$capabilityResult.expected_execution_labview_year
                            required_bitness = [string]$capabilityResult.required_bitness
                            output_ppl_path = [string]$capabilityResult.output_ppl_path
                            output_ppl_snapshot_path = [string]$capabilityResult.output_ppl_snapshot_path
                            command = @($capabilityResult.command)
                            exit_code = $capabilityResult.exit_code
                            labview_install_root = [string]$capabilityResult.labview_install_root
                            labview_ini_path = [string]$capabilityResult.labview_ini_path
                            expected_labview_cli_port = $capabilityResult.expected_labview_cli_port
                            buildspec_log_path = [string]$capabilityResult.buildspec_log_path
                            detected_labview_executable = [string]$capabilityResult.detected_labview_executable
                            detected_labview_year = [string]$capabilityResult.detected_labview_year
                        }

                        Add-PostActionSequenceEntry -Sequence $postActionSequence -Phase 'ppl-build' -Bitness $bitness -Status ([string]$capabilityResult.status) -Message ([string]$capabilityResult.message)

                        if ([string]$capabilityResult.status -ne 'pass') {
                            $allPplPass = $false
                            $errors += "Runner CLI PPL capability check failed ($bitness-bit). $([string]$capabilityResult.message)"
                        }
                    } finally {
                        Write-InstallerFeedback -Message ("Running post-PPL LabVIEW close sweep after {0}-bit gate." -f $bitness)
                        Invoke-PreVipLabVIEWCloseBestEffort -IconEditorRepoPath $iconEditorRepoPath
                    }
                }

                if (-not $allPplPass) {
                    if ($skipVipHarness) {
                        $vipPackageBuildCheck.status = 'skipped'
                        $vipPackageBuildCheck.message = "VIP harness is skipped for execution profile '$executionProfile'."
                        Add-PostActionSequenceEntry -Sequence $postActionSequence -Phase 'vip-harness' -Bitness $requiredVipBitness -Status 'skipped' -Message $vipPackageBuildCheck.message
                    } else {
                        $vipPackageBuildCheck.status = 'blocked'
                        $vipPackageBuildCheck.message = 'VIP harness was not run because one or more PPL capability checks failed.'
                        Add-PostActionSequenceEntry -Sequence $postActionSequence -Phase 'vip-harness' -Bitness $requiredVipBitness -Status 'blocked' -Message $vipPackageBuildCheck.message
                    }
                } else {
                    if ($skipVipHarness) {
                        $vipPackageBuildCheck.status = 'skipped'
                        $vipPackageBuildCheck.message = "VIP harness is skipped for execution profile '$executionProfile'."
                        Add-PostActionSequenceEntry -Sequence $postActionSequence -Phase 'vip-harness' -Bitness $requiredVipBitness -Status 'skipped' -Message $vipPackageBuildCheck.message
                    } else {
                        Write-InstallerFeedback -Message 'Running runner-cli VI Package harness gate.'
                        $vipResult = Invoke-RunnerCliVipPackageHarnessCheck `
                            -RunnerCliPath $runnerCliExePath `
                            -PowerShellExecutable $runtimePowerShellExecutable `
                            -IconEditorRepoPath $iconEditorRepoPath `
                            -PinnedSha $iconEditorPinnedSha `
                            -RequiredLabviewYear ([string]$requiredLabviewYear) `
                            -RequiredBitness ([string]$requiredVipBitness)

                        $vipPackageBuildCheck = [ordered]@{
                            status = [string]$vipResult.status
                            message = [string]$vipResult.message
                            runner_cli_path = [string]$vipResult.runner_cli_path
                            repo_path = [string]$vipResult.repo_path
                            required_labview_year = [string]$vipResult.required_labview_year
                            required_bitness = [string]$vipResult.required_bitness
                            vipb_path = [string]$vipResult.vipb_path
                            vipc_path = [string]$vipResult.vipc_path
                            vipc_assert_output_path = [string]$vipResult.vipc_assert_output_path
                            vip_build_status_path = [string]$vipResult.vip_build_status_path
                            release_notes_path = [string]$vipResult.release_notes_path
                            display_information_path = [string]$vipResult.display_information_path
                            output_vip_path = [string]$vipResult.output_vip_path
                            command = [ordered]@{
                                vipc_assert = @($vipResult.command.vipc_assert)
                                vipc_apply = @($vipResult.command.vipc_apply)
                                vip_build = @($vipResult.command.vip_build)
                            }
                            exit_code = $vipResult.exit_code
                            labview_install_root = [string]$vipResult.labview_install_root
                        }
                        Add-PostActionSequenceEntry -Sequence $postActionSequence -Phase 'vip-harness' -Bitness $requiredVipBitness -Status ([string]$vipResult.status) -Message ([string]$vipResult.message)

                        if ($vipPackageBuildCheck.status -ne 'pass') {
                            $errors += "Runner CLI VIP harness check failed. $($vipPackageBuildCheck.message)"
                        }
                    }
                }
            }
        } else {
            $bundleBlockingMessage = "Runner CLI bundle verification failed; capability gates were not run. $([string]$runnerCliBundle.message)"
            foreach ($bitness in $requiredPplBitnesses) {
                $pplCapabilityChecks[$bitness].status = 'blocked'
                $pplCapabilityChecks[$bitness].message = $bundleBlockingMessage
                Add-PostActionSequenceEntry -Sequence $postActionSequence -Phase 'ppl-build' -Bitness $bitness -Status 'blocked' -Message $bundleBlockingMessage
            }
            $vipPackageBuildCheck.status = 'blocked'
            $vipPackageBuildCheck.message = 'VIP harness was not run because runner-cli bundle verification failed.'
            Add-PostActionSequenceEntry -Sequence $postActionSequence -Phase 'vip-harness' -Bitness $requiredVipBitness -Status 'blocked' -Message $vipPackageBuildCheck.message
        }
    } finally {
        if ($worktreeRootOverridden) {
            if ([string]::IsNullOrWhiteSpace($originalWorktreeRoot)) {
                Remove-Item Env:LVIE_WORKTREE_ROOT -ErrorAction SilentlyContinue
            } else {
                $env:LVIE_WORKTREE_ROOT = $originalWorktreeRoot
            }
        }
    }

    $assertScriptPath = Join-Path $resolvedWorkspaceRoot 'scripts\Assert-WorkspaceGovernance.ps1'
    $workspaceManifestPath = Join-Path $resolvedWorkspaceRoot 'workspace-governance.json'
    $auditOutputPath = [string]$governanceAudit.report_path

    if ($offlineGitMode) {
        $governanceAudit.status = 'skipped'
        $governanceAudit.message = 'Workspace governance audit skipped because LVIE_OFFLINE_GIT_MODE is enabled.'
    } elseif ((Test-Path -LiteralPath $assertScriptPath -PathType Leaf) -and (Test-Path -LiteralPath $workspaceManifestPath -PathType Leaf)) {
        Write-InstallerFeedback -Message 'Running workspace governance audit.'
        $governanceAudit.invoked = $true
        $governanceAudit.exit_code = Invoke-PowerShellFile `
            -PowerShellExecutable $runtimePowerShellExecutable `
            -ScriptPath $assertScriptPath `
            -ScriptArguments @(
                '-WorkspaceRoot', $resolvedWorkspaceRoot,
                '-ManifestPath', $workspaceManifestPath,
                '-Mode', 'Audit',
                '-OutputPath', $auditOutputPath
            )

        if (Test-Path -LiteralPath $auditOutputPath -PathType Leaf) {
            $auditReport = Get-Content -LiteralPath $auditOutputPath -Raw | ConvertFrom-Json -ErrorAction Stop
            $failingRepos = @($auditReport.repositories | Where-Object { $_.status -eq 'fail' })
            $nonBranchFailures = @()
            $branchFailures = @()

            foreach ($failingRepo in $failingRepos) {
                $issues = @($failingRepo.issues)
                $hasNonBranchIssue = $false
                foreach ($issue in $issues) {
                    $issueValue = [string]$issue
                    if ($issueValue.StartsWith('branch_protection_')) {
                        continue
                    }
                    $hasNonBranchIssue = $true
                }

                if ($hasNonBranchIssue) {
                    $nonBranchFailures += [string]$failingRepo.path
                } else {
                    $branchFailures += [string]$failingRepo.path
                }
            }

            $governanceAudit.branch_failures = $branchFailures
            $governanceAudit.non_branch_failures = $nonBranchFailures

            if ($governanceAudit.exit_code -eq 0) {
                $governanceAudit.status = 'pass'
                $governanceAudit.message = 'Workspace governance audit passed.'
            } elseif ($nonBranchFailures.Count -eq 0 -and $branchFailures.Count -gt 0) {
                $governanceAudit.status = 'branch_only_fail'
                $governanceAudit.branch_only_failure = $true
                $governanceAudit.message = 'Workspace governance audit has branch-protection-only failures.'
                $warnings += 'Branch protection contract is not fully satisfied; install continues in audit-only mode.'
            } else {
                $governanceAudit.status = 'fail'
                $governanceAudit.message = 'Workspace governance audit failed with non-branch-protection issues.'
                $errors += $governanceAudit.message
            }
        } else {
            $governanceAudit.status = 'fail'
            $governanceAudit.message = "Governance audit report missing: $auditOutputPath"
            $errors += $governanceAudit.message
        }
    } else {
        $governanceAudit.status = 'fail'
        $governanceAudit.message = 'Governance audit prerequisites are missing (assert script or manifest).'
        $errors += $governanceAudit.message
    }
    Add-PostActionSequenceEntry `
        -Sequence $postActionSequence `
        -Phase 'governance-audit' `
        -Status ([string]$governanceAudit.status) `
        -Message ([string]$governanceAudit.message)
} catch {
    $errors += $_.Exception.Message
}

$status = if ($errors.Count -gt 0) { 'failed' } else { 'succeeded' }
Write-InstallerFeedback -Message ("Completed with status: {0}" -f $status)
$report = [ordered]@{
    timestamp_utc = (Get-Date).ToUniversalTime().ToString('o')
    status = $status
    mode = $Mode
    execution_context = $InstallerExecutionContext
    execution_profile = $executionProfile
    workspace_root = $resolvedWorkspaceRoot
    manifest_path = $resolvedManifestPath
    output_path = $resolvedOutputPath
    contract_split = $contractSplit
    dependency_checks = $dependencyChecks
    payload_sync = $payloadSync
    repositories = $repositoryResults
    runner_cli_bundle = $runnerCliBundle
    cli_bundle = $cliBundle
    ppl_capability_checks = $pplCapabilityChecks
    vip_package_build_check = $vipPackageBuildCheck
    post_action_sequence = $postActionSequence
    governance_audit = $governanceAudit
    warnings = $warnings
    errors = $errors
}

$report | ConvertTo-Json -Depth 14 | Set-Content -LiteralPath $resolvedOutputPath -Encoding UTF8
Write-Host "Workspace install report: $resolvedOutputPath"

if ($status -ne 'succeeded') {
    exit 1
}

exit 0
