[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$OutputPath,

    [Parameter()]
    [string]$IterationOutputRoot = (Join-Path $env:TEMP 'host-release-2020-vipm-lifecycle'),

    [Parameter()]
    [string]$SmokeWorkspaceRoot = 'C:\dev-smoke-lvie-2020',

    [Parameter()]
    [ValidateSet('32', '64')]
    [string]$SelectedPplBitness = '64',

    [Parameter()]
    [ValidatePattern('^\d{4}$')]
    [string]$TargetLabviewYear = '2020',

    [Parameter()]
    [ValidateSet('32', '64')]
    [string]$TargetVipmBitness = '64',

    [Parameter()]
    [string]$NsisRoot = 'C:\Program Files (x86)\NSIS',

    [Parameter()]
    [switch]$KeepSmokeWorkspace
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$reasonCodeTaxonomy = @(
    'ok',
    'iteration_failed',
    'iteration_summary_missing',
    'exercise_report_missing',
    'smoke_report_missing',
    'smoke_status_failed',
    'smoke_execution_profile_mismatch',
    'ppl_gate_failed',
    'vip_build_not_pass',
    'vip_output_missing',
    'vipm_lifecycle_failed',
    'vip_lifecycle_drill_passed',
    'drill_runtime_error'
)

function Ensure-ParentDirectory {
    param([Parameter(Mandatory = $true)][string]$Path)

    $parent = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -Path $parent -ItemType Directory -Force | Out-Null
    }
}

function Add-PhaseResult {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][System.Collections.Generic.List[object]]$Target,
        [Parameter(Mandatory = $true)][string]$Phase,
        [Parameter(Mandatory = $true)][ValidateSet('pass', 'fail', 'warn', 'skipped')]$Status,
        [Parameter(Mandatory = $true)][string]$ReasonCode,
        [Parameter()][string]$Message = ''
    )

    $Target.Add([ordered]@{
            phase = $Phase
            status = $Status
            reason_code = $ReasonCode
            message = $Message
        }) | Out-Null
}

function Throw-DrillError {
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

    return 'drill_runtime_error'
}

function Set-TemporaryEnvironmentVariables {
    param([Parameter(Mandatory = $true)][hashtable]$Variables)

    $snapshot = @{}
    foreach ($name in $Variables.Keys) {
        $entry = Get-Item -Path ("Env:{0}" -f $name) -ErrorAction SilentlyContinue
        $snapshot[$name] = [pscustomobject]@{
            exists = ($null -ne $entry)
            value = if ($null -ne $entry) { [string]$entry.Value } else { '' }
        }

        $value = [string]$Variables[$name]
        if ([string]::IsNullOrWhiteSpace($value)) {
            Remove-Item -Path ("Env:{0}" -f $name) -ErrorAction SilentlyContinue
        } else {
            Set-Item -Path ("Env:{0}" -f $name) -Value $value
        }
    }

    return $snapshot
}

function Restore-TemporaryEnvironmentVariables {
    param([Parameter(Mandatory = $true)][hashtable]$Snapshot)

    foreach ($name in $Snapshot.Keys) {
        $entry = $Snapshot[$name]
        if ([bool]$entry.exists) {
            Set-Item -Path ("Env:{0}" -f $name) -Value ([string]$entry.value)
        } else {
            Remove-Item -Path ("Env:{0}" -f $name) -ErrorAction SilentlyContinue
        }
    }
}

function Write-Report {
    param(
        [Parameter(Mandatory = $true)]$Report,
        [Parameter(Mandatory = $true)][string]$Path
    )

    Ensure-ParentDirectory -Path $Path
    $Report | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $Path -Encoding utf8
}

$repoRoot = (Resolve-Path -Path (Join-Path $PSScriptRoot '..')).Path
$iterationScriptPath = Join-Path $repoRoot 'scripts\Invoke-WorkspaceInstallerIteration.ps1'
$vipmLifecycleScriptPath = Join-Path $repoRoot 'scripts\Invoke-VipmInstallUninstallCheck.ps1'

$resolvedOutputPath = [System.IO.Path]::GetFullPath($OutputPath)
$resolvedIterationOutputRoot = [System.IO.Path]::GetFullPath($IterationOutputRoot)
$resolvedSmokeWorkspaceRoot = [System.IO.Path]::GetFullPath($SmokeWorkspaceRoot)

$phaseResults = [System.Collections.Generic.List[object]]::new()
$report = [ordered]@{
    schema_version = '1.0'
    generated_at_utc = (Get-Date).ToUniversalTime().ToString('o')
    status = 'fail'
    reason_code = ''
    message = ''
    target_labview_year = $TargetLabviewYear
    selected_ppl_bitness = $SelectedPplBitness
    target_vipm_bitness = $TargetVipmBitness
    keep_smoke_workspace = [bool]$KeepSmokeWorkspace
    nsis_root = $NsisRoot
    phase_results = @()
    reason_code_taxonomy = @($reasonCodeTaxonomy)
    artifacts = [ordered]@{
        iteration_summary = Join-Path $resolvedIterationOutputRoot 'iteration-summary.json'
        exercise_report = ''
        smoke_report = ''
        vipm_lifecycle_report = Join-Path $resolvedIterationOutputRoot ("vipm-install-uninstall-check.{0}x{1}.json" -f $TargetLabviewYear, $TargetVipmBitness)
        vipm_lifecycle_log = Join-Path $resolvedIterationOutputRoot ("vipm-install-uninstall-check.{0}x{1}.log" -f $TargetLabviewYear, $TargetVipmBitness)
        vipm_list_before = Join-Path $resolvedIterationOutputRoot ("vipm-list-before-install.{0}x{1}.txt" -f $TargetLabviewYear, $TargetVipmBitness)
        vipm_list_after_install = Join-Path $resolvedIterationOutputRoot ("vipm-list-after-install.{0}x{1}.txt" -f $TargetLabviewYear, $TargetVipmBitness)
        vipm_list_after_uninstall = Join-Path $resolvedIterationOutputRoot ("vipm-list-after-uninstall.{0}x{1}.txt" -f $TargetLabviewYear, $TargetVipmBitness)
    }
    details = [ordered]@{
        iteration = [ordered]@{
            output_root = $resolvedIterationOutputRoot
            smoke_workspace_root = $resolvedSmokeWorkspaceRoot
            script_path = $iterationScriptPath
        }
        smoke = [ordered]@{}
        vipm_lifecycle = [ordered]@{
            script_path = $vipmLifecycleScriptPath
        }
        failure_message = ''
    }
}

$environmentOverrides = @{
    'VIPM_COMMUNITY_EDITION' = 'true'
    'LVIE_INSTALLER_EXECUTION_PROFILE' = 'host-release'
    'LVIE_GATE_REQUIRED_LABVIEW_YEAR' = $TargetLabviewYear
    'LVIE_RUNNERCLI_EXECUTION_LABVIEW_YEAR' = $TargetLabviewYear
    'LVIE_GATE_SINGLE_PPL_BITNESS' = $SelectedPplBitness
}
$environmentSnapshot = @{}

try {
    if (-not (Test-Path -LiteralPath $iterationScriptPath -PathType Leaf)) {
        Throw-DrillError -ReasonCode 'iteration_failed' -Message ("Iteration runtime is missing: {0}" -f $iterationScriptPath)
    }
    if (-not (Test-Path -LiteralPath $vipmLifecycleScriptPath -PathType Leaf)) {
        Throw-DrillError -ReasonCode 'vipm_lifecycle_failed' -Message ("VIPM lifecycle runtime is missing: {0}" -f $vipmLifecycleScriptPath)
    }

    Ensure-ParentDirectory -Path $resolvedOutputPath
    if (-not (Test-Path -LiteralPath $resolvedIterationOutputRoot -PathType Container)) {
        New-Item -Path $resolvedIterationOutputRoot -ItemType Directory -Force | Out-Null
    }

    $environmentSnapshot = Set-TemporaryEnvironmentVariables -Variables $environmentOverrides
    Add-PhaseResult -Target $phaseResults -Phase 'preflight' -Status 'pass' -ReasonCode 'ok'

    $iterationArgs = @(
        '-NoProfile',
        '-File', $iterationScriptPath,
        '-Mode', 'full',
        '-Iterations', '1',
        '-OutputRoot', $resolvedIterationOutputRoot,
        '-SmokeWorkspaceRoot', $resolvedSmokeWorkspaceRoot,
        '-NsisRoot', $NsisRoot
    )
    if ($KeepSmokeWorkspace) {
        $iterationArgs += '-KeepSmokeWorkspace'
    }

    & pwsh @iterationArgs | Out-Host
    $iterationExitCode = if ($null -eq $LASTEXITCODE) { 0 } else { [int]$LASTEXITCODE }
    if ($iterationExitCode -ne 0) {
        Throw-DrillError -ReasonCode 'iteration_failed' -Message ("Invoke-WorkspaceInstallerIteration.ps1 exited with code {0}." -f $iterationExitCode)
    }
    Add-PhaseResult -Target $phaseResults -Phase 'iteration' -Status 'pass' -ReasonCode 'ok'

    $iterationSummaryPath = [string]$report.artifacts.iteration_summary
    if (-not (Test-Path -LiteralPath $iterationSummaryPath -PathType Leaf)) {
        Throw-DrillError -ReasonCode 'iteration_summary_missing' -Message ("Iteration summary is missing: {0}" -f $iterationSummaryPath)
    }

    $summary = Get-Content -LiteralPath $iterationSummaryPath -Raw | ConvertFrom-Json -Depth 50
    $runOutputRoot = [string]$summary.latest.output_root
    if ([string]::IsNullOrWhiteSpace($runOutputRoot) -or -not (Test-Path -LiteralPath $runOutputRoot -PathType Container)) {
        Throw-DrillError -ReasonCode 'exercise_report_missing' -Message ("Latest iteration output_root is missing: {0}" -f $runOutputRoot)
    }

    $exerciseReportPath = Join-Path $runOutputRoot 'exercise-report.json'
    $report.artifacts.exercise_report = $exerciseReportPath
    if (-not (Test-Path -LiteralPath $exerciseReportPath -PathType Leaf)) {
        Throw-DrillError -ReasonCode 'exercise_report_missing' -Message ("Exercise report is missing: {0}" -f $exerciseReportPath)
    }

    $exerciseReport = Get-Content -LiteralPath $exerciseReportPath -Raw | ConvertFrom-Json -Depth 50
    $smokeReportPath = [string]$exerciseReport.smoke_installer.report_path
    if ([string]::IsNullOrWhiteSpace($smokeReportPath)) {
        $smokeReportPath = Join-Path $resolvedSmokeWorkspaceRoot 'artifacts\workspace-install-latest.json'
    }
    $report.artifacts.smoke_report = $smokeReportPath
    if (-not (Test-Path -LiteralPath $smokeReportPath -PathType Leaf)) {
        Throw-DrillError -ReasonCode 'smoke_report_missing' -Message ("Smoke report is missing: {0}" -f $smokeReportPath)
    }

    $smokeReport = Get-Content -LiteralPath $smokeReportPath -Raw | ConvertFrom-Json -Depth 100
    $smokeStatus = [string]$smokeReport.status
    $executionProfile = [string]$smokeReport.execution_profile
    $selectedPplStatus = ''
    if ($null -ne $smokeReport.ppl_capability_checks -and $null -ne $smokeReport.ppl_capability_checks.PSObject.Properties[$SelectedPplBitness]) {
        $selectedPplStatus = [string]$smokeReport.ppl_capability_checks.PSObject.Properties[$SelectedPplBitness].Value.status
    }
    $vipBuildStatus = [string]$smokeReport.vip_package_build_check.status
    $vipOutputPath = [string]$smokeReport.vip_package_build_check.output_vip_path

    $report.details.smoke = [ordered]@{
        status = $smokeStatus
        execution_profile = $executionProfile
        selected_ppl_status = $selectedPplStatus
        vip_build_status = $vipBuildStatus
        vip_output_path = $vipOutputPath
    }

    if ($smokeStatus -ne 'succeeded') {
        Throw-DrillError -ReasonCode 'smoke_status_failed' -Message ("Smoke installer report status is not succeeded: {0}" -f $smokeStatus)
    }
    if ($executionProfile -ne 'host-release') {
        Throw-DrillError -ReasonCode 'smoke_execution_profile_mismatch' -Message ("Smoke execution profile is not host-release: {0}" -f $executionProfile)
    }
    if ($selectedPplStatus -ne 'pass') {
        Throw-DrillError -ReasonCode 'ppl_gate_failed' -Message ("PPL gate status for bitness {0} is not pass: {1}" -f $SelectedPplBitness, $selectedPplStatus)
    }
    if ($vipBuildStatus -ne 'pass') {
        Throw-DrillError -ReasonCode 'vip_build_not_pass' -Message ("VIP package build status is not pass: {0}" -f $vipBuildStatus)
    }
    if ([string]::IsNullOrWhiteSpace($vipOutputPath) -or -not (Test-Path -LiteralPath $vipOutputPath -PathType Leaf)) {
        Throw-DrillError -ReasonCode 'vip_output_missing' -Message ("VIP output package is missing: {0}" -f $vipOutputPath)
    }
    Add-PhaseResult -Target $phaseResults -Phase 'smoke_contract' -Status 'pass' -ReasonCode 'ok'

    $vipmReportPath = [string]$report.artifacts.vipm_lifecycle_report
    $vipmArgs = @(
        '-NoProfile',
        '-File', $vipmLifecycleScriptPath,
        '-VipPath', $vipOutputPath,
        '-TargetLabviewYear', $TargetLabviewYear,
        '-TargetBitness', $TargetVipmBitness,
        '-OutputPath', $vipmReportPath,
        '-ListBeforePath', ([string]$report.artifacts.vipm_list_before),
        '-ListAfterInstallPath', ([string]$report.artifacts.vipm_list_after_install),
        '-ListAfterUninstallPath', ([string]$report.artifacts.vipm_list_after_uninstall),
        '-LogPath', ([string]$report.artifacts.vipm_lifecycle_log)
    )

    & pwsh @vipmArgs | Out-Host
    $vipmExitCode = if ($null -eq $LASTEXITCODE) { 0 } else { [int]$LASTEXITCODE }
    if (-not (Test-Path -LiteralPath $vipmReportPath -PathType Leaf)) {
        Throw-DrillError -ReasonCode 'vipm_lifecycle_failed' -Message ("VIPM lifecycle report is missing: {0}" -f $vipmReportPath)
    }

    $vipmReport = Get-Content -LiteralPath $vipmReportPath -Raw | ConvertFrom-Json -Depth 100
    $report.details.vipm_lifecycle = [ordered]@{
        exit_code = $vipmExitCode
        status = [string]$vipmReport.status
        reason_code = [string]$vipmReport.reason_code
        message = [string]$vipmReport.message
        report_path = $vipmReportPath
        log_path = [string]$report.artifacts.vipm_lifecycle_log
    }

    if ($vipmExitCode -ne 0 -or [string]$vipmReport.status -ne 'pass') {
        Throw-DrillError -ReasonCode 'vipm_lifecycle_failed' -Message ("VIPM lifecycle check failed. exit_code={0} reason_code={1}" -f $vipmExitCode, [string]$vipmReport.reason_code)
    }
    Add-PhaseResult -Target $phaseResults -Phase 'vipm_lifecycle' -Status 'pass' -ReasonCode 'ok'

    $report.status = 'pass'
    $report.reason_code = 'vip_lifecycle_drill_passed'
    $report.message = ("Host-release LabVIEW {0} VIPM lifecycle drill passed." -f $TargetLabviewYear)
}
catch {
    $failureMessage = [string]$_.Exception.Message
    $report.status = 'fail'
    $report.reason_code = Resolve-ReasonCodeFromException -Message $failureMessage
    $report.message = $failureMessage
    $report.details.failure_message = $failureMessage
    Add-PhaseResult -Target $phaseResults -Phase 'failure' -Status 'fail' -ReasonCode $report.reason_code -Message $failureMessage
}
finally {
    if ($environmentSnapshot.Count -gt 0) {
        Restore-TemporaryEnvironmentVariables -Snapshot $environmentSnapshot
    }

    $report.phase_results = @($phaseResults)
    Write-Report -Report $report -Path $resolvedOutputPath
}

if ([string]$report.status -eq 'fail') {
    exit 1
}

exit 0
