#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$SeedContractPath,

    [Parameter()]
    [string[]]$Years = @('2020', '2025', '2026'),

    [Parameter()]
    [ValidateSet('32', '64')]
    [string[]]$Bitnesses = @('32', '64'),

    [Parameter()]
    [ValidateSet('windows-host', 'windows-container', 'linux-host', 'linux-container')]
    [string[]]$Contexts = @('windows-host', 'windows-container', 'linux-host', 'linux-container'),

    [Parameter()]
    [switch]$SkipHostIniMutation,

    [Parameter()]
    [switch]$SkipOverridePhase,

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

function Get-BoolToken {
    param([bool]$Value)
    if ($Value) { return 'true' }
    return 'false'
}

function Get-ReportPropertyValue {
    param(
        [Parameter()]
        [object]$Report,
        [Parameter(Mandatory = $true)]
        [string]$PropertyName,
        [Parameter()]
        [object]$Default = $null
    )

    if ($null -eq $Report) {
        return $Default
    }

    $property = $Report.PSObject.Properties[$PropertyName]
    if ($null -eq $property) {
        return $Default
    }

    return $property.Value
}

$repoRoot = (Resolve-Path -Path (Join-Path $PSScriptRoot '..')).Path
$resolvedSeedContractPath = (Resolve-Path -Path $SeedContractPath -ErrorAction Stop).Path
if (-not (Test-Path -LiteralPath $resolvedSeedContractPath -PathType Leaf)) {
    throw "Seed contract not found: $resolvedSeedContractPath"
}

$stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss')
$defaultWorkRoot = Join-Path $repoRoot (".tmp-port-matrix-{0}" -f $stamp)
$workRoot = if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $defaultWorkRoot
} else {
    [System.IO.Path]::GetFullPath($OutputPath)
}
$toolingRoot = Join-Path $workRoot 'Tooling'
$artifactsRoot = Join-Path $workRoot 'artifacts'
Ensure-Directory -Path $toolingRoot
Ensure-Directory -Path $artifactsRoot
Copy-Item -LiteralPath $resolvedSeedContractPath -Destination (Join-Path $toolingRoot 'labviewcli-port-contract.json') -Force

$ensureScript = Join-Path $repoRoot 'scripts\Ensure-LabVIEWCliPortContractAndIni.ps1'
if (-not (Test-Path -LiteralPath $ensureScript -PathType Leaf)) {
    throw "Required script missing: $ensureScript"
}
$powerShellExecutable = 'powershell'
$pwshCommand = Get-Command -Name 'pwsh' -ErrorAction SilentlyContinue
if ($null -ne $pwshCommand -and -not [string]::IsNullOrWhiteSpace([string]$pwshCommand.Source)) {
    $powerShellExecutable = [string]$pwshCommand.Source
}

$strictRows = @()
foreach ($year in $Years) {
    foreach ($bitness in $Bitnesses) {
        foreach ($context in $Contexts) {
            $expectedPass = $true
            $expectedSignature = ''
            if ($context -like '*-container' -and $year -eq '2020') {
                $expectedPass = $false
                $expectedSignature = 'official_ni_container_unsupported_2020'
            } elseif ($context -eq 'windows-container' -and $year -eq '2025') {
                $expectedPass = $false
                $expectedSignature = 'official_ni_container_unsupported_2025_windows'
            }

            $caseId = "strict-y{0}-b{1}-{2}" -f $year, $bitness, $context
            $caseArtifact = Join-Path $artifactsRoot $caseId
            Ensure-Directory -Path $caseArtifact

            $invokeArgs = @(
                '-NoProfile',
                '-File', $ensureScript,
                '-RepoPath', $workRoot,
                '-ExecutionLabviewYear', $year,
                '-SupportedBitness', $bitness,
                '-PortContext', $context,
                '-ArtifactRoot', $caseArtifact
            )
            if ($SkipHostIniMutation -or $context -ne 'windows-host') {
                $invokeArgs += '-SkipIniUpdate'
            }

            & $powerShellExecutable @invokeArgs | Out-Null
            $exitCode = if ($null -eq $LASTEXITCODE) { 0 } else { [int]$LASTEXITCODE }

            $reportPath = Join-Path $caseArtifact 'labview-cli-port-contract-remediation-report.json'
            $report = $null
            if (Test-Path -LiteralPath $reportPath -PathType Leaf) {
                $report = Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json -ErrorAction Stop
            }

            $actualPass = ($exitCode -eq 0)
            $errorText = [string](Get-ReportPropertyValue -Report $report -PropertyName 'error' -Default '')
            $signatureMatch = if ($expectedPass) { $true } else { $errorText -like ("*{0}*" -f $expectedSignature) }

            $strictRows += [pscustomobject]@{
                phase = 'strict'
                year = [string]$year
                bitness = [string]$bitness
                context = [string]$context
                expected_pass = $expectedPass
                actual_pass = $actualPass
                expected_signature = $expectedSignature
                error_contains_expected_signature = $signatureMatch
                expected_port = (Get-ReportPropertyValue -Report $report -PropertyName 'expected_port' -Default $null)
                contract_updated = (Get-ReportPropertyValue -Report $report -PropertyName 'contract_updated' -Default $null)
                report_status = [string](Get-ReportPropertyValue -Report $report -PropertyName 'status' -Default 'missing')
                artifact_root = $caseArtifact
            }
        }
    }
}

$strictFailures = @(
    $strictRows |
    Where-Object {
        ($_.expected_pass -ne $_.actual_pass) -or
        (-not $_.expected_pass -and -not $_.error_contains_expected_signature)
    }
)

$overrideRows = @()
if (-not $SkipOverridePhase) {
    $env:LVIE_ALLOW_UNOFFICIAL_CONTAINERS = 'true'
    try {
        foreach ($row in @($strictRows | Where-Object { -not $_.expected_pass })) {
            $year = [string]$row.year
            $bitness = [string]$row.bitness
            $context = [string]$row.context

            $caseId = "override-y{0}-b{1}-{2}" -f $year, $bitness, $context
            $caseArtifact = Join-Path $artifactsRoot $caseId
            Ensure-Directory -Path $caseArtifact

            $invokeArgs = @(
                '-NoProfile',
                '-File', $ensureScript,
                '-RepoPath', $workRoot,
                '-ExecutionLabviewYear', $year,
                '-SupportedBitness', $bitness,
                '-PortContext', $context,
                '-ArtifactRoot', $caseArtifact,
                '-SkipIniUpdate'
            )

            & $powerShellExecutable @invokeArgs | Out-Null
            $exitCode = if ($null -eq $LASTEXITCODE) { 0 } else { [int]$LASTEXITCODE }
            $reportPath = Join-Path $caseArtifact 'labview-cli-port-contract-remediation-report.json'
            $report = $null
            if (Test-Path -LiteralPath $reportPath -PathType Leaf) {
                $report = Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json -ErrorAction Stop
            }

            $overrideRows += [pscustomobject]@{
                phase = 'override'
                year = [string]$year
                bitness = [string]$bitness
                context = [string]$context
                actual_pass = ($exitCode -eq 0)
                expected_port = (Get-ReportPropertyValue -Report $report -PropertyName 'expected_port' -Default $null)
                report_status = [string](Get-ReportPropertyValue -Report $report -PropertyName 'status' -Default 'missing')
                artifact_root = $caseArtifact
            }
        }
    } finally {
        Remove-Item Env:LVIE_ALLOW_UNOFFICIAL_CONTAINERS -ErrorAction SilentlyContinue
    }
}

$overrideFailures = @($overrideRows | Where-Object { -not $_.actual_pass })

$finalContractPath = Join-Path $toolingRoot 'labviewcli-port-contract.json'
$finalContract = Get-Content -LiteralPath $finalContractPath -Raw | ConvertFrom-Json -ErrorAction Stop
$assignments = @()
foreach ($yearProp in $finalContract.labview_cli_ports.PSObject.Properties) {
    $year = [string]$yearProp.Name
    if ($year -notmatch '^\d{4}$') { continue }
    $node = $yearProp.Value
    foreach ($ctx in @('windows-host', 'windows-container', 'linux-host', 'linux-container')) {
        foreach ($bit in @('32', '64')) {
            $port = $null
            switch ($ctx) {
                'windows-host' { $port = [int]$node.windows.$bit }
                'windows-container' { $port = [int]$node.containers.windows.$bit }
                'linux-host' { $port = [int]$node.linux.$bit }
                'linux-container' { $port = [int]$node.containers.linux.$bit }
            }
            $assignments += [pscustomobject]@{
                year = $year
                context = $ctx
                bitness = $bit
                port = $port
            }
        }
    }
}

$duplicateGroups = @($assignments | Group-Object -Property port | Where-Object { $_.Count -gt 1 })

$summary = [ordered]@{
    generated_at_utc = (Get-Date).ToUniversalTime().ToString('o')
    work_root = $workRoot
    seed_contract_path = $resolvedSeedContractPath
    strict_total = @($strictRows).Count
    strict_failures = @($strictFailures).Count
    override_total = @($overrideRows).Count
    override_failures = @($overrideFailures).Count
    duplicate_port_groups = @($duplicateGroups | ForEach-Object {
        [ordered]@{
            port = [int]$_.Name
            owners = @($_.Group | ForEach-Object { "{0}/{1}/{2}" -f $_.year, $_.context, $_.bitness })
        }
    })
}

$report = [ordered]@{
    summary = $summary
    strict = @($strictRows)
    strict_failures = @($strictFailures)
    override = @($overrideRows)
    override_failures = @($overrideFailures)
}

$reportPath = Join-Path $artifactsRoot 'port-matrix-summary.json'
$report | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $reportPath -Encoding utf8

Write-Host ("MATRIX_SUMMARY_PATH={0}" -f $reportPath)
Write-Host ("STRICT_TOTAL={0}" -f $summary.strict_total)
Write-Host ("STRICT_FAILURES={0}" -f $summary.strict_failures)
Write-Host ("OVERRIDE_TOTAL={0}" -f $summary.override_total)
Write-Host ("OVERRIDE_FAILURES={0}" -f $summary.override_failures)
Write-Host ("DUPLICATE_PORT_GROUPS={0}" -f @($summary.duplicate_port_groups).Count)

if (@($strictFailures).Count -gt 0 -or @($overrideFailures).Count -gt 0 -or @($duplicateGroups).Count -gt 0) {
    exit 1
}
