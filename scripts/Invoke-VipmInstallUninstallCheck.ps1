[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$VipPath,

    [Parameter()]
    [ValidatePattern('^\d{4}$')]
    [string]$TargetLabviewYear = '2020',

    [Parameter()]
    [ValidateSet('32', '64')]
    [string]$TargetBitness = '64',

    [Parameter(Mandatory = $true)]
    [string]$OutputPath,

    [Parameter()]
    [string]$ListBeforePath = '',

    [Parameter()]
    [string]$ListAfterInstallPath = '',

    [Parameter()]
    [string]$ListAfterUninstallPath = '',

    [Parameter()]
    [string]$LogPath = '',

    [Parameter()]
    [bool]$AllowLegacyFallback = $true
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$reasonCodeTaxonomy = @(
    'ok',
    'vip_path_missing',
    'target_labview_missing',
    'vipm_cli_missing',
    'vipm_activate_failed',
    'vipm_list_before_failed',
    'vipm_install_failed',
    'vipm_list_after_install_failed',
    'uninstall_target_resolution_failed',
    'vipm_uninstall_failed',
    'vipm_list_after_uninstall_failed',
    'vipm_uninstall_verification_failed',
    'vip_lifecycle_passed',
    'vipm_lifecycle_runtime_error'
)

function Ensure-ParentDirectory {
    param([Parameter(Mandatory = $true)][string]$Path)

    $parent = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -Path $parent -ItemType Directory -Force | Out-Null
    }
}

function Throw-VipmCheckError {
    param(
        [Parameter(Mandatory = $true)][string]$ReasonCode,
        [Parameter(Mandatory = $true)][string]$Message
    )

    throw "[reason:$ReasonCode] $Message"
}

function Resolve-ReasonCodeFromException {
    param([Parameter(Mandatory = $true)][string]$Message)

    if ($Message -match '^\[reason:(?<reason>[a-z0-9_]+)\]') {
        return [string]$Matches.reason
    }

    return 'vipm_lifecycle_runtime_error'
}

function Resolve-TargetLabviewRoot {
    param(
        [Parameter(Mandatory = $true)][string]$Year,
        [Parameter(Mandatory = $true)][ValidateSet('32', '64')][string]$Bitness
    )

    if ($Bitness -eq '32') {
        return "C:\Program Files (x86)\National Instruments\LabVIEW $Year"
    }

    return "C:\Program Files\National Instruments\LabVIEW $Year"
}

function Write-Report {
    param(
        [Parameter(Mandatory = $true)]$Report,
        [Parameter(Mandatory = $true)][string]$Path
    )

    Ensure-ParentDirectory -Path $Path
    $Report | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $Path -Encoding utf8
}

$resolvedOutputPath = [System.IO.Path]::GetFullPath($OutputPath)
$resolvedVipPath = [System.IO.Path]::GetFullPath($VipPath)
$outputRoot = Split-Path -Parent $resolvedOutputPath

if ([string]::IsNullOrWhiteSpace($ListBeforePath)) {
    $ListBeforePath = Join-Path $outputRoot ("vipm-list-before-install.{0}x{1}.txt" -f $TargetLabviewYear, $TargetBitness)
}
if ([string]::IsNullOrWhiteSpace($ListAfterInstallPath)) {
    $ListAfterInstallPath = Join-Path $outputRoot ("vipm-list-after-install.{0}x{1}.txt" -f $TargetLabviewYear, $TargetBitness)
}
if ([string]::IsNullOrWhiteSpace($ListAfterUninstallPath)) {
    $ListAfterUninstallPath = Join-Path $outputRoot ("vipm-list-after-uninstall.{0}x{1}.txt" -f $TargetLabviewYear, $TargetBitness)
}
if ([string]::IsNullOrWhiteSpace($LogPath)) {
    $LogPath = Join-Path $outputRoot ("vipm-install-uninstall-check.{0}x{1}.log" -f $TargetLabviewYear, $TargetBitness)
}

$resolvedListBeforePath = [System.IO.Path]::GetFullPath($ListBeforePath)
$resolvedListAfterInstallPath = [System.IO.Path]::GetFullPath($ListAfterInstallPath)
$resolvedListAfterUninstallPath = [System.IO.Path]::GetFullPath($ListAfterUninstallPath)
$resolvedLogPath = [System.IO.Path]::GetFullPath($LogPath)

Ensure-ParentDirectory -Path $resolvedOutputPath
Ensure-ParentDirectory -Path $resolvedListBeforePath
Ensure-ParentDirectory -Path $resolvedListAfterInstallPath
Ensure-ParentDirectory -Path $resolvedListAfterUninstallPath
Ensure-ParentDirectory -Path $resolvedLogPath
if (Test-Path -LiteralPath $resolvedLogPath -PathType Leaf) {
    Remove-Item -LiteralPath $resolvedLogPath -Force
}

function Write-VipmCheckLog {
    param([Parameter(Mandatory = $true)][string]$Message)

    $line = "[{0}] {1}" -f ((Get-Date).ToUniversalTime().ToString('o')), $Message
    Add-Content -LiteralPath $resolvedLogPath -Value $line -Encoding utf8
    Write-Host $line
}

function Invoke-VipmScoped {
    param(
        [Parameter(Mandatory = $true)][string]$VipmExe,
        [Parameter(Mandatory = $true)][string[]]$CommandArgs,
        [Parameter(Mandatory = $true)][ValidateSet('labview-version', 'labview')][string]$PrimaryOptionsStyle,
        [Parameter(Mandatory = $true)][bool]$AllowFallback
    )

    $attempts = @()
    if ($PrimaryOptionsStyle -eq 'labview-version') {
        $attempts += [ordered]@{
            name = 'labview-version'
            prefix = @('--labview-version', $TargetLabviewYear, '--labview-bitness', $TargetBitness)
        }
    } else {
        $attempts += [ordered]@{
            name = 'labview'
            prefix = @('--labview', $TargetLabviewYear, '--bitness', $TargetBitness)
        }
    }

    if ($AllowFallback -and $PrimaryOptionsStyle -eq 'labview-version') {
        $attempts += [ordered]@{
            name = 'labview'
            prefix = @('--labview', $TargetLabviewYear, '--bitness', $TargetBitness)
        }
    }

    $lastFailure = $null
    foreach ($attempt in @($attempts)) {
        $args = @($attempt.prefix + $CommandArgs)
        Write-VipmCheckLog ("Executing: {0} {1}" -f $VipmExe, ($args -join ' '))
        $commandOutput = & $VipmExe @args 2>&1
        $exitCode = if ($null -eq $LASTEXITCODE) { 0 } else { [int]$LASTEXITCODE }

        if ($null -ne $commandOutput) {
            foreach ($line in @($commandOutput)) {
                Add-Content -LiteralPath $resolvedLogPath -Value ([string]$line) -Encoding utf8
            }
        }

        if ($exitCode -eq 0) {
            return [pscustomobject]@{
                status = 'pass'
                exit_code = $exitCode
                output = @($commandOutput)
                options_style = [string]$attempt.name
            }
        }

        $outputText = [string]::Join("`n", @($commandOutput | ForEach-Object { [string]$_ }))
        if (
            $AllowFallback -and
            $attempt.name -eq 'labview-version' -and
            $outputText -match '(?i)(unknown|invalid|unrecognized).*(labview-version|labview-bitness|--labview-version|--labview-bitness)'
        ) {
            Write-VipmCheckLog 'VIPM did not accept --labview-version/--labview-bitness; retrying with --labview/--bitness.'
            continue
        }

        $lastFailure = [pscustomobject]@{
            status = 'fail'
            exit_code = $exitCode
            output = @($commandOutput)
            options_style = [string]$attempt.name
        }
        break
    }

    if ($null -ne $lastFailure) {
        return $lastFailure
    }

    return [pscustomobject]@{
        status = 'fail'
        exit_code = 1
        output = @('vipm_command_failed_without_output')
        options_style = [string]$PrimaryOptionsStyle
    }
}

function Get-VipmInstalledPackages {
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$OutputLines)

    $packages = @()
    foreach ($line in @($OutputLines)) {
        if ([string]::IsNullOrWhiteSpace([string]$line)) {
            continue
        }

        $trimmed = ([string]$line).Trim()
        $match = [regex]::Match($trimmed, '^(?<name>.+?)\s+\((?<id>[\w\.\-]+)\s+v(?<version>[^)]+)\)$')
        if ($match.Success) {
            $packages += [pscustomobject]@{
                name = $match.Groups['name'].Value.Trim()
                id = $match.Groups['id'].Value.Trim()
                version = $match.Groups['version'].Value.Trim()
            }
        }
    }

    return @($packages)
}

$report = [ordered]@{
    schema_version = '1.0'
    generated_at_utc = (Get-Date).ToUniversalTime().ToString('o')
    status = 'fail'
    reason_code = ''
    message = ''
    target_labview_year = $TargetLabviewYear
    target_bitness = $TargetBitness
    vip_path = $resolvedVipPath
    vipm_cli_path = ''
    options_style = ''
    activation_exit_code = $null
    uninstall_target = ''
    detected_added_packages = @()
    paths = [ordered]@{
        output_report = $resolvedOutputPath
        log = $resolvedLogPath
        list_before = $resolvedListBeforePath
        list_after_install = $resolvedListAfterInstallPath
        list_after_uninstall = $resolvedListAfterUninstallPath
    }
    reason_code_taxonomy = @($reasonCodeTaxonomy)
}

try {
    if (-not (Test-Path -LiteralPath $resolvedVipPath -PathType Leaf)) {
        Throw-VipmCheckError -ReasonCode 'vip_path_missing' -Message ("VIP package path is missing: {0}" -f $resolvedVipPath)
    }

    $targetLabviewRoot = Resolve-TargetLabviewRoot -Year $TargetLabviewYear -Bitness $TargetBitness
    if (-not (Test-Path -LiteralPath $targetLabviewRoot -PathType Container)) {
        Throw-VipmCheckError -ReasonCode 'target_labview_missing' -Message ("LabVIEW target path is missing: {0}" -f $targetLabviewRoot)
    }

    $vipmCommand = Get-Command -Name 'vipm' -ErrorAction SilentlyContinue
    if ($null -eq $vipmCommand -or [string]::IsNullOrWhiteSpace([string]$vipmCommand.Source)) {
        Throw-VipmCheckError -ReasonCode 'vipm_cli_missing' -Message 'VIPM CLI executable was not found in PATH.'
    }
    $vipmExe = [string]$vipmCommand.Source
    $report.vipm_cli_path = $vipmExe

    $env:VIPM_COMMUNITY_EDITION = 'true'
    Write-VipmCheckLog 'Running vipm activate prior to install/uninstall verification.'
    $activateOutput = & $vipmExe activate 2>&1
    $activateExitCode = if ($null -eq $LASTEXITCODE) { 0 } else { [int]$LASTEXITCODE }
    $report.activation_exit_code = $activateExitCode
    if ($null -ne $activateOutput) {
        foreach ($line in @($activateOutput)) {
            Add-Content -LiteralPath $resolvedLogPath -Value ([string]$line) -Encoding utf8
        }
    }
    if ($activateExitCode -ne 0) {
        Throw-VipmCheckError -ReasonCode 'vipm_activate_failed' -Message ("vipm activate failed with exit code {0}." -f $activateExitCode)
    }

    Write-VipmCheckLog 'Capturing installed package list before install.'
    $listBefore = Invoke-VipmScoped -VipmExe $vipmExe -CommandArgs @('list', '--installed') -PrimaryOptionsStyle 'labview-version' -AllowFallback $AllowLegacyFallback
    if ([string]$listBefore.status -ne 'pass') {
        Throw-VipmCheckError -ReasonCode 'vipm_list_before_failed' -Message ("vipm list --installed (before install) failed with exit code {0}." -f [int]$listBefore.exit_code)
    }
    $report.options_style = [string]$listBefore.options_style
    @($listBefore.output) | Set-Content -LiteralPath $resolvedListBeforePath -Encoding utf8
    $beforePackages = Get-VipmInstalledPackages -OutputLines @($listBefore.output | ForEach-Object { [string]$_ })

    Write-VipmCheckLog ("Installing VIP package: {0}" -f $resolvedVipPath)
    $installResult = Invoke-VipmScoped -VipmExe $vipmExe -CommandArgs @('install', $resolvedVipPath) -PrimaryOptionsStyle $report.options_style -AllowFallback:$false
    if ([string]$installResult.status -ne 'pass') {
        Throw-VipmCheckError -ReasonCode 'vipm_install_failed' -Message ("vipm install failed with exit code {0}." -f [int]$installResult.exit_code)
    }

    Write-VipmCheckLog 'Capturing installed package list after install.'
    $listAfterInstall = Invoke-VipmScoped -VipmExe $vipmExe -CommandArgs @('list', '--installed') -PrimaryOptionsStyle $report.options_style -AllowFallback:$false
    if ([string]$listAfterInstall.status -ne 'pass') {
        Throw-VipmCheckError -ReasonCode 'vipm_list_after_install_failed' -Message ("vipm list --installed (after install) failed with exit code {0}." -f [int]$listAfterInstall.exit_code)
    }
    @($listAfterInstall.output) | Set-Content -LiteralPath $resolvedListAfterInstallPath -Encoding utf8
    $afterInstallPackages = Get-VipmInstalledPackages -OutputLines @($listAfterInstall.output | ForEach-Object { [string]$_ })

    $beforeById = @{}
    foreach ($package in @($beforePackages)) {
        $beforeById[[string]$package.id] = $package
    }
    $addedPackages = @($afterInstallPackages | Where-Object { -not $beforeById.ContainsKey([string]$_.id) })
    $report.detected_added_packages = @($addedPackages | ForEach-Object { [string]$_.id })
    if (@($addedPackages).Count -ne 1) {
        Throw-VipmCheckError -ReasonCode 'uninstall_target_resolution_failed' -Message ("Deterministic uninstall target resolution failed. expected_added_count=1 actual_added_count={0}" -f @($addedPackages).Count)
    }
    $uninstallTarget = [string]$addedPackages[0].id
    $report.uninstall_target = $uninstallTarget

    Write-VipmCheckLog ("Uninstalling package id: {0}" -f $uninstallTarget)
    $uninstallResult = Invoke-VipmScoped -VipmExe $vipmExe -CommandArgs @('uninstall', $uninstallTarget) -PrimaryOptionsStyle $report.options_style -AllowFallback:$false
    if ([string]$uninstallResult.status -ne 'pass') {
        Throw-VipmCheckError -ReasonCode 'vipm_uninstall_failed' -Message ("vipm uninstall failed with exit code {0}." -f [int]$uninstallResult.exit_code)
    }

    Write-VipmCheckLog 'Capturing installed package list after uninstall.'
    $listAfterUninstall = Invoke-VipmScoped -VipmExe $vipmExe -CommandArgs @('list', '--installed') -PrimaryOptionsStyle $report.options_style -AllowFallback:$false
    if ([string]$listAfterUninstall.status -ne 'pass') {
        Throw-VipmCheckError -ReasonCode 'vipm_list_after_uninstall_failed' -Message ("vipm list --installed (after uninstall) failed with exit code {0}." -f [int]$listAfterUninstall.exit_code)
    }
    @($listAfterUninstall.output) | Set-Content -LiteralPath $resolvedListAfterUninstallPath -Encoding utf8
    $afterUninstallPackages = Get-VipmInstalledPackages -OutputLines @($listAfterUninstall.output | ForEach-Object { [string]$_ })

    $targetStillInstalled = @($afterUninstallPackages | Where-Object { [string]$_.id -eq $uninstallTarget })
    if (@($targetStillInstalled).Count -gt 0) {
        Throw-VipmCheckError -ReasonCode 'vipm_uninstall_verification_failed' -Message ("Package id '{0}' is still installed after uninstall." -f $uninstallTarget)
    }

    $report.status = 'pass'
    $report.reason_code = 'vip_lifecycle_passed'
    $report.message = ("VIP install/uninstall verification succeeded for LabVIEW {0} {1}-bit." -f $TargetLabviewYear, $TargetBitness)
}
catch {
    $failureMessage = [string]$_.Exception.Message
    $report.status = 'fail'
    $report.reason_code = Resolve-ReasonCodeFromException -Message $failureMessage
    $report.message = $failureMessage
}
finally {
    Write-Report -Report $report -Path $resolvedOutputPath
}

if ([string]$report.status -eq 'fail') {
    exit 1
}

exit 0
