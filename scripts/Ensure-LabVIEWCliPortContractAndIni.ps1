#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$RepoPath,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^\d{4}$')]
    [string]$ExecutionLabviewYear,

    [Parameter(Mandatory = $true)]
    [ValidateSet('32', '64')]
    [string]$SupportedBitness,

    [Parameter()]
    [Alias('PortPlatform')]
    [ValidateSet('windows-host', 'windows-container', 'linux-host', 'linux-container', 'windows', 'linux')]
    [string]$PortContext = 'windows-host',

    [Parameter()]
    [switch]$SkipIniUpdate,

    [Parameter(Mandatory = $true)]
    [string]$ArtifactRoot
)

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

function Resolve-PortContext {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Context
    )

    $normalized = [string]$Context
    switch ($normalized.ToLowerInvariant()) {
        'windows' { return 'windows-host' }
        'linux' { return 'linux-host' }
        default { return $normalized.ToLowerInvariant() }
    }
}

function Get-PortContextDefinition {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('windows-host', 'windows-container', 'linux-host', 'linux-container')]
        [string]$Context
    )

    switch ($Context) {
        'windows-host' { return [pscustomobject]@{ platform = 'windows'; scope = 'host'; updates_ini = $true } }
        'windows-container' { return [pscustomobject]@{ platform = 'windows'; scope = 'container'; updates_ini = $true } }
        'linux-host' { return [pscustomobject]@{ platform = 'linux'; scope = 'host'; updates_ini = $false } }
        'linux-container' { return [pscustomobject]@{ platform = 'linux'; scope = 'container'; updates_ini = $false } }
    }
}

function Test-EnabledBool {
    param(
        [Parameter()]
        [string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $false
    }

    switch ($Value.Trim().ToLowerInvariant()) {
        '1' { return $true }
        'true' { return $true }
        'yes' { return $true }
        default { return $false }
    }
}

function Assert-OfficialContainerSupport {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('windows-host', 'windows-container', 'linux-host', 'linux-container')]
        [string]$Context,
        [Parameter(Mandatory = $true)]
        [string]$Year,
        [Parameter(Mandatory = $true)]
        [ValidateSet('32', '64')]
        [string]$Bitness
    )

    if ($Context -notlike '*-container') {
        return
    }

    $allowUnofficial = Test-EnabledBool -Value ([string]$env:LVIE_ALLOW_UNOFFICIAL_CONTAINERS)
    if ($allowUnofficial) {
        return
    }

    if ($Year -eq '2020') {
        throw "official_ni_container_unsupported_2020: NI does not publish official LabVIEW 2020 containers. Set LVIE_ALLOW_UNOFFICIAL_CONTAINERS=true only for non-NI developer container experiments."
    }

    if ($Context -eq 'windows-container' -and $Year -eq '2025') {
        throw ("official_ni_container_unsupported_2025_windows: NI does not publish/support LabVIEW 2025q3 windows containers (requested bitness={0})." -f $Bitness)
    }
}

function Set-IniValueStrict {
    param(
        [Parameter(Mandatory = $true)]
        [string]$IniPath,
        [Parameter(Mandatory = $true)]
        [string]$Key,
        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    $lines = @()
    if (Test-Path -LiteralPath $IniPath -PathType Leaf) {
        $lines = @(Get-Content -LiteralPath $IniPath -ErrorAction Stop)
    }

    $updated = $false
    for ($index = 0; $index -lt $lines.Count; $index++) {
        $line = [string]$lines[$index]
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
            $lines[$index] = ('{0}={1}' -f $Key, $Value)
            $updated = $true
            break
        }
    }

    if (-not $updated) {
        $lines += ('{0}={1}' -f $Key, $Value)
    }

    Set-Content -LiteralPath $IniPath -Value $lines -Encoding ascii
}

function Get-LabviewExecutablePath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Year,
        [Parameter(Mandatory = $true)]
        [ValidateSet('32', '64')]
        [string]$Bitness
    )

    if ($Bitness -eq '64') {
        return "C:\Program Files\National Instruments\LabVIEW $Year\LabVIEW.exe"
    }

    return "C:\Program Files (x86)\National Instruments\LabVIEW $Year\LabVIEW.exe"
}

function Get-PortValueOrNull {
    param(
        [Parameter()]
        [object]$Node,
        [Parameter(Mandatory = $true)]
        [ValidateSet('32', '64')]
        [string]$Bitness,
        [Parameter(Mandatory = $true)]
        [string]$Context
    )

    if ($null -eq $Node) {
        return $null
    }
    if ($null -eq $Node.PSObject.Properties[$Bitness]) {
        return $null
    }

    $parsedPort = 0
    $rawValue = [string]$Node.$Bitness
    if (-not [int]::TryParse($rawValue, [ref]$parsedPort) -or $parsedPort -lt 1 -or $parsedPort -gt 65535) {
        throw ("Contract value is invalid for {0} bitness '{1}': '{2}'." -f $Context, $Bitness, $rawValue)
    }
    return [int]$parsedPort
}

function Get-YearPortMap {
    param(
        [Parameter(Mandatory = $true)]
        [object]$YearNode,
        [Parameter(Mandatory = $true)]
        [string]$Year,
        [Parameter(Mandatory = $true)]
        [string]$ContractPath
    )

    $hasWindowsNode = $null -ne $YearNode.PSObject.Properties['windows']
    $hasLinuxNode = $null -ne $YearNode.PSObject.Properties['linux']
    $isLegacyFlat = $null -ne $YearNode.PSObject.Properties['32'] -or $null -ne $YearNode.PSObject.Properties['64']

    $windowsHostNode = if ($hasWindowsNode) { $YearNode.windows } elseif ($isLegacyFlat) { $YearNode } else { $null }
    $linuxHostNode = if ($hasLinuxNode) { $YearNode.linux } else { $null }

    $containersNode = if ($null -ne $YearNode.PSObject.Properties['containers']) { $YearNode.containers } else { $null }
    $windowsContainerNode = $null
    $linuxContainerNode = $null
    if ($null -ne $containersNode) {
        $windowsContainerNode = $containersNode.windows
        $linuxContainerNode = $containersNode.linux
    }
    if ($null -eq $windowsContainerNode -and $null -ne $YearNode.PSObject.Properties['windows_container']) {
        $windowsContainerNode = $YearNode.windows_container
    }
    if ($null -eq $linuxContainerNode -and $null -ne $YearNode.PSObject.Properties['linux_container']) {
        $linuxContainerNode = $YearNode.linux_container
    }

    return [pscustomobject]@{
        windows_host_32 = Get-PortValueOrNull -Node $windowsHostNode -Bitness '32' -Context ("year '{0}' context 'windows-host' in {1}" -f $Year, $ContractPath)
        windows_host_64 = Get-PortValueOrNull -Node $windowsHostNode -Bitness '64' -Context ("year '{0}' context 'windows-host' in {1}" -f $Year, $ContractPath)
        linux_host_32 = Get-PortValueOrNull -Node $linuxHostNode -Bitness '32' -Context ("year '{0}' context 'linux-host' in {1}" -f $Year, $ContractPath)
        linux_host_64 = Get-PortValueOrNull -Node $linuxHostNode -Bitness '64' -Context ("year '{0}' context 'linux-host' in {1}" -f $Year, $ContractPath)
        windows_container_32 = Get-PortValueOrNull -Node $windowsContainerNode -Bitness '32' -Context ("year '{0}' context 'windows-container' in {1}" -f $Year, $ContractPath)
        windows_container_64 = Get-PortValueOrNull -Node $windowsContainerNode -Bitness '64' -Context ("year '{0}' context 'windows-container' in {1}" -f $Year, $ContractPath)
        linux_container_32 = Get-PortValueOrNull -Node $linuxContainerNode -Bitness '32' -Context ("year '{0}' context 'linux-container' in {1}" -f $Year, $ContractPath)
        linux_container_64 = Get-PortValueOrNull -Node $linuxContainerNode -Bitness '64' -Context ("year '{0}' context 'linux-container' in {1}" -f $Year, $ContractPath)
    }
}

function New-NormalizedYearNode {
    param(
        [Parameter(Mandatory = $true)]
        [int]$WindowsHost32,
        [Parameter(Mandatory = $true)]
        [int]$WindowsHost64,
        [Parameter(Mandatory = $true)]
        [int]$LinuxHost32,
        [Parameter(Mandatory = $true)]
        [int]$LinuxHost64,
        [Parameter(Mandatory = $true)]
        [int]$WindowsContainer32,
        [Parameter(Mandatory = $true)]
        [int]$WindowsContainer64,
        [Parameter(Mandatory = $true)]
        [int]$LinuxContainer32,
        [Parameter(Mandatory = $true)]
        [int]$LinuxContainer64
    )

    return [pscustomobject]@{
        windows = [pscustomobject]@{
            '32' = $WindowsHost32
            '64' = $WindowsHost64
        }
        linux = [pscustomobject]@{
            '32' = $LinuxHost32
            '64' = $LinuxHost64
        }
        containers = [pscustomobject]@{
            windows = [pscustomobject]@{
                '32' = $WindowsContainer32
                '64' = $WindowsContainer64
            }
            linux = [pscustomobject]@{
                '32' = $LinuxContainer32
                '64' = $LinuxContainer64
            }
        }
    }
}

$normalizedPortContext = Resolve-PortContext -Context $PortContext
$contextDefinition = Get-PortContextDefinition -Context $normalizedPortContext

$report = [ordered]@{
    status = 'pending'
    repo_path = ''
    contract_path = ''
    execution_labview_year = $ExecutionLabviewYear
    supported_bitness = $SupportedBitness
    port_context = $normalizedPortContext
    platform = $contextDefinition.platform
    context_scope = $contextDefinition.scope
    unofficial_container_override = (Test-EnabledBool -Value ([string]$env:LVIE_ALLOW_UNOFFICIAL_CONTAINERS)
)
    template_year = ''
    contract_updated = $false
    expected_port = $null
    port_strategy = 'base-year-context-sequenced'
    base_year = ''
    port_stride = 10
    context_port_offsets = [ordered]@{
        windows_host = 0
        windows_container = 200
        linux_host = 1000
        linux_container = 1200
    }
    duplicate_port_assignments = @()
    ini_path = ''
    ini_update_skipped = $false
    timestamp_utc = (Get-Date).ToUniversalTime().ToString('o')
}

try {
    Ensure-Directory -Path $ArtifactRoot

    Assert-OfficialContainerSupport -Context $normalizedPortContext -Year $ExecutionLabviewYear -Bitness $SupportedBitness

    $resolvedRepoPath = [System.IO.Path]::GetFullPath($RepoPath)
    if (-not (Test-Path -LiteralPath $resolvedRepoPath -PathType Container)) {
        throw "Repo path not found: $resolvedRepoPath"
    }
    $report.repo_path = $resolvedRepoPath

    $contractPath = Join-Path $resolvedRepoPath 'Tooling\labviewcli-port-contract.json'
    if (-not (Test-Path -LiteralPath $contractPath -PathType Leaf)) {
        throw "LabVIEW CLI port contract file missing: $contractPath"
    }
    $report.contract_path = $contractPath

    $contract = Get-Content -LiteralPath $contractPath -Raw | ConvertFrom-Json -ErrorAction Stop
    if ($null -eq $contract.PSObject.Properties['labview_cli_ports']) {
        throw "Contract is missing 'labview_cli_ports': $contractPath"
    }

    $portsNode = $contract.labview_cli_ports
    $yearKey = [string]$ExecutionLabviewYear
    $templateYear = ''
    $contractUpdated = $false

    $availableYears = @(
        $portsNode.PSObject.Properties |
        ForEach-Object { [string]$_.Name } |
        Where-Object { $_ -match '^\d{4}$' } |
        Sort-Object
    )
    if (@($availableYears).Count -eq 0) {
        throw "Contract has no resolvable year entries: $contractPath"
    }

    $portStride = 10
    $contextPortOffsets = [ordered]@{
        windows_host = 0
        windows_container = 200
        linux_host = 1000
        linux_container = 1200
    }

    $yearPortMaps = @{}
    foreach ($year in $availableYears) {
        $yearPortMaps[$year] = Get-YearPortMap -YearNode $portsNode.$year -Year $year -ContractPath $contractPath
    }

    $baseYear = ''
    if ($availableYears -contains '2020') {
        $candidate = $yearPortMaps['2020']
        if ($null -ne $candidate.windows_host_32 -and $null -ne $candidate.windows_host_64) {
            $baseYear = '2020'
        }
    }
    if ([string]::IsNullOrWhiteSpace($baseYear)) {
        foreach ($year in $availableYears) {
            $candidate = $yearPortMaps[$year]
            if ($null -ne $candidate.windows_host_32 -and $null -ne $candidate.windows_host_64) {
                $baseYear = [string]$year
                break
            }
        }
    }
    if ([string]::IsNullOrWhiteSpace($baseYear)) {
        throw "Could not resolve base windows-host ports from labview_cli_ports in $contractPath"
    }

    $basePort32 = [int]$yearPortMaps[$baseYear].windows_host_32
    $basePort64 = [int]$yearPortMaps[$baseYear].windows_host_64

    $allYears = @($availableYears + @($yearKey) | Sort-Object -Unique)
    $normalizedYears = [ordered]@{}

    foreach ($year in $allYears) {
        $sourceMap = if ($yearPortMaps.ContainsKey($year)) { $yearPortMaps[$year] } else { $null }

        $yearDelta = ([int]$year) - ([int]$baseYear)
        $derivedWindowsHost32 = $basePort32 + ($yearDelta * $portStride)
        $derivedWindowsHost64 = $basePort64 + ($yearDelta * $portStride)
        if ($derivedWindowsHost32 -lt 1 -or $derivedWindowsHost32 -gt 65535 -or $derivedWindowsHost64 -lt 1 -or $derivedWindowsHost64 -gt 65535) {
            throw "Derived windows-host port assignment for year '$year' is out of valid range. Derived windows-host-32=$derivedWindowsHost32 windows-host-64=$derivedWindowsHost64."
        }

        $resolvedWindowsHost32 = if ($null -ne $sourceMap -and $null -ne $sourceMap.windows_host_32) { [int]$sourceMap.windows_host_32 } else { $derivedWindowsHost32 }
        $resolvedWindowsHost64 = if ($null -ne $sourceMap -and $null -ne $sourceMap.windows_host_64) { [int]$sourceMap.windows_host_64 } else { $derivedWindowsHost64 }
        $resolvedWindowsContainer32 = if ($null -ne $sourceMap -and $null -ne $sourceMap.windows_container_32) { [int]$sourceMap.windows_container_32 } else { $resolvedWindowsHost32 + [int]$contextPortOffsets.windows_container }
        $resolvedWindowsContainer64 = if ($null -ne $sourceMap -and $null -ne $sourceMap.windows_container_64) { [int]$sourceMap.windows_container_64 } else { $resolvedWindowsHost64 + [int]$contextPortOffsets.windows_container }
        $resolvedLinuxHost32 = if ($null -ne $sourceMap -and $null -ne $sourceMap.linux_host_32) { [int]$sourceMap.linux_host_32 } else { $resolvedWindowsHost32 + [int]$contextPortOffsets.linux_host }
        $resolvedLinuxHost64 = if ($null -ne $sourceMap -and $null -ne $sourceMap.linux_host_64) { [int]$sourceMap.linux_host_64 } else { $resolvedWindowsHost64 + [int]$contextPortOffsets.linux_host }
        $resolvedLinuxContainer32 = if ($null -ne $sourceMap -and $null -ne $sourceMap.linux_container_32) { [int]$sourceMap.linux_container_32 } else { $resolvedWindowsHost32 + [int]$contextPortOffsets.linux_container }
        $resolvedLinuxContainer64 = if ($null -ne $sourceMap -and $null -ne $sourceMap.linux_container_64) { [int]$sourceMap.linux_container_64 } else { $resolvedWindowsHost64 + [int]$contextPortOffsets.linux_container }

        foreach ($candidatePort in @(
            $resolvedWindowsHost32, $resolvedWindowsHost64,
            $resolvedWindowsContainer32, $resolvedWindowsContainer64,
            $resolvedLinuxHost32, $resolvedLinuxHost64,
            $resolvedLinuxContainer32, $resolvedLinuxContainer64
        )) {
            if ($candidatePort -lt 1 -or $candidatePort -gt 65535) {
                throw "Resolved context-aware port assignment is out of valid range for year '$year'."
            }
        }

        $normalizedYears[$year] = New-NormalizedYearNode `
            -WindowsHost32 $resolvedWindowsHost32 `
            -WindowsHost64 $resolvedWindowsHost64 `
            -LinuxHost32 $resolvedLinuxHost32 `
            -LinuxHost64 $resolvedLinuxHost64 `
            -WindowsContainer32 $resolvedWindowsContainer32 `
            -WindowsContainer64 $resolvedWindowsContainer64 `
            -LinuxContainer32 $resolvedLinuxContainer32 `
            -LinuxContainer64 $resolvedLinuxContainer64

        if ($null -eq $sourceMap) {
            $contractUpdated = $true
            if ($year -eq $yearKey) {
                $templateYear = $baseYear
            }
        } else {
            if (
                $sourceMap.windows_host_32 -ne $resolvedWindowsHost32 -or
                $sourceMap.windows_host_64 -ne $resolvedWindowsHost64 -or
                $sourceMap.windows_container_32 -ne $resolvedWindowsContainer32 -or
                $sourceMap.windows_container_64 -ne $resolvedWindowsContainer64 -or
                $sourceMap.linux_host_32 -ne $resolvedLinuxHost32 -or
                $sourceMap.linux_host_64 -ne $resolvedLinuxHost64 -or
                $sourceMap.linux_container_32 -ne $resolvedLinuxContainer32 -or
                $sourceMap.linux_container_64 -ne $resolvedLinuxContainer64
            ) {
                $contractUpdated = $true
            }
        }
    }

    $yearNode = $normalizedYears[$yearKey]
    if ($null -eq $yearNode) {
        throw "Year '$yearKey' could not be resolved from contract after remediation: $contractPath"
    }

    $expectedPortRaw = ''
    switch ($normalizedPortContext) {
        'windows-host' { $expectedPortRaw = [string]$yearNode.windows.$SupportedBitness }
        'windows-container' { $expectedPortRaw = [string]$yearNode.containers.windows.$SupportedBitness }
        'linux-host' { $expectedPortRaw = [string]$yearNode.linux.$SupportedBitness }
        'linux-container' { $expectedPortRaw = [string]$yearNode.containers.linux.$SupportedBitness }
        default { throw "Unsupported resolved port context '$normalizedPortContext'" }
    }

    $expectedPort = 0
    if (-not [int]::TryParse($expectedPortRaw, [ref]$expectedPort) -or $expectedPort -lt 1 -or $expectedPort -gt 65535) {
        throw "Contract value is invalid for year '$yearKey' context '$normalizedPortContext' bitness '$SupportedBitness' in $contractPath"
    }

    $portAssignments = @()
    foreach ($year in $allYears) {
        $node = $normalizedYears[$year]
        if ($null -eq $node) { continue }
        foreach ($contextKey in @('windows-host', 'windows-container', 'linux-host', 'linux-container')) {
            foreach ($bitnessKey in @('32', '64')) {
                $candidatePort = 0
                $candidateRaw = ''
                switch ($contextKey) {
                    'windows-host' { $candidateRaw = [string]$node.windows.$bitnessKey }
                    'windows-container' { $candidateRaw = [string]$node.containers.windows.$bitnessKey }
                    'linux-host' { $candidateRaw = [string]$node.linux.$bitnessKey }
                    'linux-container' { $candidateRaw = [string]$node.containers.linux.$bitnessKey }
                }
                if (-not [int]::TryParse($candidateRaw, [ref]$candidatePort) -or $candidatePort -lt 1 -or $candidatePort -gt 65535) {
                    throw "Contract value is invalid for year '$year' context '$contextKey' bitness '$bitnessKey' in $contractPath"
                }
                $portAssignments += [pscustomobject]@{
                    year = [string]$year
                    context = [string]$contextKey
                    bitness = [string]$bitnessKey
                    port = $candidatePort
                }
            }
        }
    }

    $duplicatePortGroups = @($portAssignments | Group-Object -Property port | Where-Object { $_.Count -gt 1 })
    if (@($duplicatePortGroups).Count -gt 0) {
        $duplicateSummaries = @(
            foreach ($group in $duplicatePortGroups) {
                $port = [int]$group.Name
                $owners = @($group.Group | ForEach-Object { "{0}/{1}/{2}" -f $_.year, $_.context, $_.bitness })
                [ordered]@{
                    port = $port
                    assignments = @($owners)
                }
            }
        )
        $report.duplicate_port_assignments = @($duplicateSummaries)
        throw ("Duplicate LabVIEW CLI port assignments detected in contract '{0}': {1}" -f $contractPath, (($duplicateSummaries | ConvertTo-Json -Depth 6 -Compress)))
    }

    if ($contractUpdated) {
        $normalizedPortsRoot = [ordered]@{}
        foreach ($property in $portsNode.PSObject.Properties) {
            $name = [string]$property.Name
            if ($name -notmatch '^\d{4}$') {
                $normalizedPortsRoot[$name] = $property.Value
            }
        }
        foreach ($year in $allYears) {
            $normalizedPortsRoot[[string]$year] = $normalizedYears[$year]
        }
        $contract.labview_cli_ports = [pscustomobject]$normalizedPortsRoot
        $contract | ConvertTo-Json -Depth 16 | Set-Content -LiteralPath $contractPath -Encoding utf8
    }

    $shouldUpdateIni = [bool]$contextDefinition.updates_ini -and (-not $SkipIniUpdate)
    if ($shouldUpdateIni) {
        $labviewExe = Get-LabviewExecutablePath -Year $ExecutionLabviewYear -Bitness $SupportedBitness
        if (-not (Test-Path -LiteralPath $labviewExe -PathType Leaf)) {
            throw "LabVIEW executable not found for ini remediation: $labviewExe"
        }

        $iniPath = Join-Path (Split-Path -Parent $labviewExe) 'LabVIEW.ini'
        try {
            if (-not (Test-Path -LiteralPath $iniPath -PathType Leaf)) {
                New-Item -Path $iniPath -ItemType File -Force | Out-Null
            }

            Set-IniValueStrict -IniPath $iniPath -Key 'server.tcp.enabled' -Value 'true'
            Set-IniValueStrict -IniPath $iniPath -Key 'server.tcp.port' -Value $expectedPort.ToString()
        } catch {
            throw ("Unable to update LabVIEW.ini '{0}'. Administrative permissions are required for Program Files writes. Use the user-session gate runner lane." -f $iniPath)
        }
        $report.ini_path = $iniPath
    } else {
        $report.ini_update_skipped = $true
    }

    $report.template_year = $templateYear
    $report.contract_updated = $contractUpdated
    $report.expected_port = $expectedPort
    $report.base_year = $baseYear
    $report.port_stride = $portStride
    $report.status = 'pass'
} catch {
    $report.status = 'fail'
    $report.error = $_.Exception.Message
    throw
} finally {
    $reportPath = Join-Path $ArtifactRoot 'labview-cli-port-contract-remediation-report.json'
    $report | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $reportPath -Encoding utf8
    Write-Host ("LabVIEW CLI port contract remediation report: {0}" -f $reportPath)
}
