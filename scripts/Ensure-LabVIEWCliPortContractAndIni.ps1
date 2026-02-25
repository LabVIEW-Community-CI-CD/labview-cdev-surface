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

$report = [ordered]@{
    status = 'pending'
    repo_path = ''
    contract_path = ''
    execution_labview_year = $ExecutionLabviewYear
    supported_bitness = $SupportedBitness
    template_year = ''
    contract_updated = $false
    expected_port = $null
    ini_path = ''
    timestamp_utc = (Get-Date).ToUniversalTime().ToString('o')
}

try {
    Ensure-Directory -Path $ArtifactRoot

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

    if ($null -eq $portsNode.PSObject.Properties[$yearKey]) {
        $availableYears = @(
            $portsNode.PSObject.Properties |
            ForEach-Object { [string]$_.Name } |
            Where-Object { $_ -match '^\d{4}$' } |
            Sort-Object
        )
        if (@($availableYears).Count -eq 0) {
            throw "Contract has no resolvable year entries: $contractPath"
        }

        if ($availableYears -contains '2026') {
            $templateYear = '2026'
        } elseif ($availableYears -contains '2025') {
            $templateYear = '2025'
        } else {
            $templateYear = [string]$availableYears[-1]
        }

        $templateNode = $portsNode.$templateYear
        $templatePort32 = 0
        $templatePort64 = 0
        if (-not [int]::TryParse([string]$templateNode.'32', [ref]$templatePort32) -or $templatePort32 -lt 1 -or $templatePort32 -gt 65535) {
            throw "Template year '$templateYear' has invalid 32-bit port in contract: $contractPath"
        }
        if (-not [int]::TryParse([string]$templateNode.'64', [ref]$templatePort64) -or $templatePort64 -lt 1 -or $templatePort64 -gt 65535) {
            throw "Template year '$templateYear' has invalid 64-bit port in contract: $contractPath"
        }

        $newYearNode = [pscustomobject]@{
            '32' = $templatePort32
            '64' = $templatePort64
        }
        Add-Member -InputObject $portsNode -MemberType NoteProperty -Name $yearKey -Value $newYearNode -Force
        $contract | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $contractPath -Encoding utf8
        $contractUpdated = $true
    }

    $yearNode = $portsNode.$yearKey
    if ($null -eq $yearNode) {
        throw "Year '$yearKey' could not be resolved from contract after remediation: $contractPath"
    }

    $expectedPort = 0
    if (-not [int]::TryParse([string]$yearNode.$SupportedBitness, [ref]$expectedPort) -or $expectedPort -lt 1 -or $expectedPort -gt 65535) {
        throw "Contract value is invalid for year '$yearKey' bitness '$SupportedBitness' in $contractPath"
    }

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

    $report.template_year = $templateYear
    $report.contract_updated = $contractUpdated
    $report.expected_port = $expectedPort
    $report.ini_path = $iniPath
    $report.status = 'pass'
} catch {
    $report.status = 'fail'
    $report.error = $_.Exception.Message
    throw
} finally {
    $reportPath = Join-Path $ArtifactRoot 'labview-cli-port-contract-remediation-report.json'
    $report | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $reportPath -Encoding utf8
    Write-Host ("LabVIEW CLI port contract remediation report: {0}" -f $reportPath)
}
