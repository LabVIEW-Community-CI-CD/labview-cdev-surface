#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter()]
    [ValidatePattern('^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$')]
    [string]$Repository = 'LabVIEW-Community-CI-CD/labview-cdev-surface-fork',

    [Parameter()]
    [ValidatePattern('^[A-Za-z0-9._/-]+$')]
    [string]$Branch = 'main',

    [Parameter()]
    [ValidateSet('Validate', 'CanaryCycle', 'PromotePrerelease', 'PromoteStable', 'FullCycle')]
    [string]$Mode = 'Validate',

    [Parameter()]
    [ValidateRange(1, 168)]
    [int]$SyncGuardMaxAgeHours = 12,

    [Parameter()]
    [ValidateRange(1, 10)]
    [int]$KeepLatestCanaryN = 1,

    [Parameter()]
    [switch]$IncludeOpsAutoRemediation,

    [Parameter()]
    [switch]$RunContractTests,

    [Parameter()]
    [switch]$DryRun,

    [Parameter()]
    [bool]$ForceStablePromotionOutsideWindow = $false,

    [Parameter()]
    [string]$ForceStablePromotionReason = '',

    [Parameter()]
    [switch]$AllowMutatingModes,

    [Parameter()]
    [string]$OutputRoot = 'artifacts/release-control-plane-local'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not [string]::Equals($Mode, 'Validate', [System.StringComparison]::OrdinalIgnoreCase) -and -not $AllowMutatingModes) {
    throw "mutating_mode_blocked: mode '$Mode' requires -AllowMutatingModes."
}

$repoRoot = (Resolve-Path -Path (Join-Path $PSScriptRoot '..')).Path
$resolvedOutputRoot = [System.IO.Path]::GetFullPath((Join-Path $repoRoot $OutputRoot))
if (-not (Test-Path -LiteralPath $resolvedOutputRoot -PathType Container)) {
    New-Item -Path $resolvedOutputRoot -ItemType Directory -Force | Out-Null
}

$opsSnapshotScript = Join-Path $PSScriptRoot 'Invoke-OpsMonitoringSnapshot.ps1'
$opsRemediateScript = Join-Path $PSScriptRoot 'Invoke-OpsAutoRemediation.ps1'
$controlPlaneScript = Join-Path $PSScriptRoot 'Invoke-ReleaseControlPlane.ps1'
$sloScript = Join-Path $PSScriptRoot 'Write-OpsSloReport.ps1'
foreach ($requiredScript in @($opsSnapshotScript, $opsRemediateScript, $controlPlaneScript, $sloScript)) {
    if (-not (Test-Path -LiteralPath $requiredScript -PathType Leaf)) {
        throw "required_script_missing: $requiredScript"
    }
}

$summary = [ordered]@{
    schema_version = '1.0'
    generated_at_utc = (Get-Date).ToUniversalTime().ToString('o')
    repository = $Repository
    branch = $Branch
    mode = $Mode
    dry_run = [bool]$DryRun
    allow_mutating_modes = [bool]$AllowMutatingModes
    output_root = $resolvedOutputRoot
    status = 'fail'
    steps = @()
}

function Add-StepResult {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,
        [Parameter(Mandatory = $true)]
        [string]$Status,
        [Parameter()]
        [string]$OutputPath = '',
        [Parameter()]
        [string]$Message = ''
    )

    $step = [ordered]@{
        name = $Name
        status = $Status
        output_path = $OutputPath
        message = $Message
    }
    $summary.steps += @($step)
}

try {
    $releaseRunnerLabels = @('self-hosted', 'windows', 'self-hosted-windows-lv')
    $releaseRunnerLabelsCsv = [string]::Join(',', $releaseRunnerLabels)

    $opsSnapshotPath = Join-Path $resolvedOutputRoot 'ops-monitoring-report.json'
    & pwsh -NoProfile -File $opsSnapshotScript `
        -SurfaceRepository $Repository `
        -RequiredRunnerLabelsCsv $releaseRunnerLabelsCsv `
        -SyncGuardMaxAgeHours $SyncGuardMaxAgeHours `
        -OutputPath $opsSnapshotPath
    if ($LASTEXITCODE -ne 0) {
        throw "ops_snapshot_failed: exit_code=$LASTEXITCODE"
    }
    Add-StepResult -Name 'ops_monitoring' -Status 'pass' -OutputPath $opsSnapshotPath

    if ($IncludeOpsAutoRemediation) {
        $opsRemediatePath = Join-Path $resolvedOutputRoot 'ops-autoremediate-report.json'
        & pwsh -NoProfile -File $opsRemediateScript `
            -SurfaceRepository $Repository `
            -RequiredRunnerLabelsCsv $releaseRunnerLabelsCsv `
            -SyncGuardMaxAgeHours $SyncGuardMaxAgeHours `
            -OutputPath $opsRemediatePath
        if ($LASTEXITCODE -ne 0) {
            throw "ops_autoremediation_failed: exit_code=$LASTEXITCODE"
        }
        Add-StepResult -Name 'ops_autoremediate' -Status 'pass' -OutputPath $opsRemediatePath
    } else {
        Add-StepResult -Name 'ops_autoremediate' -Status 'skipped' -Message 'IncludeOpsAutoRemediation not set.'
    }

    $controlPlanePath = Join-Path $resolvedOutputRoot 'release-control-plane-report.json'
    $controlPlaneOverrideAuditPath = Join-Path $resolvedOutputRoot 'release-control-plane-override-audit.json'
    & pwsh -NoProfile -File $controlPlaneScript `
        -Repository $Repository `
        -Branch $Branch `
        -Mode $Mode `
        -SyncGuardMaxAgeHours $SyncGuardMaxAgeHours `
        -KeepLatestCanaryN $KeepLatestCanaryN `
        -AutoRemediate:$false `
        -ForceStablePromotionOutsideWindow:$ForceStablePromotionOutsideWindow `
        -ForceStablePromotionReason $ForceStablePromotionReason `
        -DryRun:$DryRun `
        -OverrideAuditOutputPath $controlPlaneOverrideAuditPath `
        -OutputPath $controlPlanePath
    if ($LASTEXITCODE -ne 0) {
        throw "release_control_plane_failed: exit_code=$LASTEXITCODE"
    }
    Add-StepResult -Name 'release_control_plane' -Status 'pass' -OutputPath $controlPlanePath
    Add-StepResult -Name 'release_control_plane_override_audit' -Status 'pass' -OutputPath $controlPlaneOverrideAuditPath

    $sloPath = Join-Path $resolvedOutputRoot 'weekly-ops-slo-report.json'
    & pwsh -NoProfile -File $sloScript `
        -SurfaceRepository $Repository `
        -OutputPath $sloPath
    if ($LASTEXITCODE -ne 0) {
        throw "ops_slo_report_failed: exit_code=$LASTEXITCODE"
    }
    Add-StepResult -Name 'weekly_ops_slo' -Status 'pass' -OutputPath $sloPath

    if ($RunContractTests) {
        $pesterOutputPath = Join-Path $resolvedOutputRoot 'control-plane-contract-tests.xml'
        $pesterPaths = @(
            (Join-Path $repoRoot 'tests/OpsMonitoringWorkflowContract.Tests.ps1'),
            (Join-Path $repoRoot 'tests/OpsAutoRemediationWorkflowContract.Tests.ps1'),
            (Join-Path $repoRoot 'tests/ReleaseControlPlaneWorkflowContract.Tests.ps1'),
            (Join-Path $repoRoot 'tests/WeeklyOpsSloReportWorkflowContract.Tests.ps1')
        )
        $pesterConfig = New-PesterConfiguration
        $pesterConfig.Run.Path = $pesterPaths
        $pesterConfig.Run.Exit = $false
        $pesterConfig.Run.PassThru = $true
        $pesterConfig.Output.Verbosity = 'Detailed'
        $pesterConfig.TestResult.Enabled = $true
        $pesterConfig.TestResult.OutputFormat = 'NUnitXml'
        $pesterConfig.TestResult.OutputPath = $pesterOutputPath
        $pesterResult = Invoke-Pester -Configuration $pesterConfig
        if ($null -eq $pesterResult) {
            throw 'contract_tests_failed: pester_result_missing'
        }
        if ([int]$pesterResult.FailedCount -gt 0 -or [int]$pesterResult.FailedBlocksCount -gt 0) {
            throw ("contract_tests_failed: failed_count={0}" -f [int]$pesterResult.FailedCount)
        }
        Add-StepResult -Name 'contract_tests' -Status 'pass' -OutputPath $pesterOutputPath
    } else {
        Add-StepResult -Name 'contract_tests' -Status 'skipped' -Message 'RunContractTests not set.'
    }

    $summary.status = 'pass'
}
catch {
    Add-StepResult -Name 'harness' -Status 'fail' -Message ([string]$_.Exception.Message)
    $summary.status = 'fail'
}
finally {
    $summaryPath = Join-Path $resolvedOutputRoot 'release-control-plane-local-summary.json'
    $summary | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $summaryPath -Encoding utf8
    Write-Host "Summary written: $summaryPath"
}

if ([string]$summary.status -ne 'pass') {
    exit 1
}

exit 0
