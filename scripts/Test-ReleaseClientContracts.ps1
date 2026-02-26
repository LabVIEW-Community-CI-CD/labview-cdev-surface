#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter()]
    [string]$WorkspaceRoot = 'C:\dev',

    [Parameter()]
    [switch]$FailOnWarning
)

$ErrorActionPreference = 'Stop'

$manifestPath = Join-Path $WorkspaceRoot 'workspace-governance.json'
$policyPath = Join-Path $WorkspaceRoot 'workspace-governance\release-policy.json'

if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    throw "Manifest not found: $manifestPath"
}

$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json -Depth 100
$checks = @()
$failures = @()
$warnings = @()

function Add-Check {
    param(
        [string]$Name,
        [bool]$Passed,
        [string]$Detail,
        [ValidateSet('error', 'warning')]
        [string]$Severity = 'error'
    )

    $entry = [ordered]@{
        name = $Name
        passed = $Passed
        detail = $Detail
        severity = $Severity
    }
    $script:checks += [pscustomobject]$entry

    if (-not $Passed) {
        if ($Severity -eq 'warning') {
            $script:warnings += "$Name :: $Detail"
        } else {
            $script:failures += "$Name :: $Detail"
        }
    }
}

$releaseClient = $null
if ($null -ne $manifest.installer_contract) {
    $releaseClient = $manifest.installer_contract.release_client
}

Add-Check -Name 'release_client_exists' -Passed ($null -ne $releaseClient) -Detail 'installer_contract.release_client'

if ($null -ne $releaseClient) {
    Add-Check -Name 'schema_version' -Passed ([string]$releaseClient.schema_version -eq '1.0') -Detail ([string]$releaseClient.schema_version)

    foreach ($repo in @('LabVIEW-Community-CI-CD/labview-cdev-surface', 'svelderrainruiz/labview-cdev-surface')) {
        Add-Check -Name "allowed_repository:$repo" -Passed ((@($releaseClient.allowed_repositories) -contains $repo)) -Detail ([string]::Join(',', @($releaseClient.allowed_repositories)))
    }

    foreach ($channel in @('stable', 'prerelease', 'canary')) {
        Add-Check -Name "allowed_channel:$channel" -Passed ((@($releaseClient.channel_rules.allowed_channels) -contains $channel)) -Detail ([string]::Join(',', @($releaseClient.channel_rules.allowed_channels)))
    }

    Add-Check -Name 'default_channel_stable' -Passed ([string]$releaseClient.channel_rules.default_channel -eq 'stable') -Detail ([string]$releaseClient.channel_rules.default_channel)
    Add-Check -Name 'signature_provider_authenticode' -Passed ([string]$releaseClient.signature_policy.provider -eq 'authenticode') -Detail ([string]$releaseClient.signature_policy.provider)
    Add-Check -Name 'signature_mode_dual_mode' -Passed ([string]$releaseClient.signature_policy.mode -eq 'dual-mode-transition') -Detail ([string]$releaseClient.signature_policy.mode)
    Add-Check -Name 'signature_grace_end' -Passed (([DateTime]$releaseClient.signature_policy.grace_end_utc).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') -eq '2026-07-01T00:00:00Z') -Detail ([string]$releaseClient.signature_policy.grace_end_utc)
    Add-Check -Name 'signature_canary_enforce' -Passed (([DateTime]$releaseClient.signature_policy.canary_enforce_utc).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') -eq '2026-05-15T00:00:00Z') -Detail ([string]$releaseClient.signature_policy.canary_enforce_utc)
    Add-Check -Name 'signature_dual_mode_start' -Passed (([DateTime]$releaseClient.signature_policy.dual_mode_start_utc).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') -eq '2026-03-15T00:00:00Z') -Detail ([string]$releaseClient.signature_policy.dual_mode_start_utc)
    Add-Check -Name 'provenance_required_true' -Passed ([bool]$releaseClient.provenance_required) -Detail ([string]$releaseClient.provenance_required)
    Add-Check -Name 'default_install_root' -Passed ([string]$releaseClient.default_install_root -eq 'C:\dev') -Detail ([string]$releaseClient.default_install_root)
    Add-Check -Name 'upgrade_allow_major_false' -Passed (-not [bool]$releaseClient.upgrade_policy.allow_major_upgrade) -Detail ([string]$releaseClient.upgrade_policy.allow_major_upgrade)
    Add-Check -Name 'upgrade_allow_downgrade_false' -Passed (-not [bool]$releaseClient.upgrade_policy.allow_downgrade) -Detail ([string]$releaseClient.upgrade_policy.allow_downgrade)
    Add-Check -Name 'state_path' -Passed ([string]$releaseClient.state_path -eq 'C:\dev\artifacts\workspace-release-state.json') -Detail ([string]$releaseClient.state_path)
    Add-Check -Name 'latest_report_path' -Passed ([string]$releaseClient.latest_report_path -eq 'C:\dev\artifacts\workspace-release-client-latest.json') -Detail ([string]$releaseClient.latest_report_path)
    Add-Check -Name 'policy_path' -Passed ([string]$releaseClient.policy_path -eq 'C:\dev\workspace-governance\release-policy.json') -Detail ([string]$releaseClient.policy_path)

    Add-Check -Name 'cdev_cli_sync_primary_repo' -Passed ([string]$releaseClient.cdev_cli_sync.primary_repo -eq 'svelderrainruiz/labview-cdev-cli') -Detail ([string]$releaseClient.cdev_cli_sync.primary_repo)
    Add-Check -Name 'cdev_cli_sync_mirror_repo' -Passed ([string]$releaseClient.cdev_cli_sync.mirror_repo -eq 'LabVIEW-Community-CI-CD/labview-cdev-cli') -Detail ([string]$releaseClient.cdev_cli_sync.mirror_repo)
    Add-Check -Name 'cdev_cli_sync_strategy' -Passed ([string]$releaseClient.cdev_cli_sync.strategy -eq 'fork-and-upstream-full-sync') -Detail ([string]$releaseClient.cdev_cli_sync.strategy)

    if ([DateTime]::Parse([string]$releaseClient.signature_policy.dual_mode_start_utc) -gt [DateTime]::Parse([string]$releaseClient.signature_policy.canary_enforce_utc)) {
        Add-Check -Name 'signature_date_order_dual_before_canary' -Passed $false -Detail 'dual_mode_start_utc must be <= canary_enforce_utc'
    } else {
        Add-Check -Name 'signature_date_order_dual_before_canary' -Passed $true -Detail 'ok'
    }

    if ([DateTime]::Parse([string]$releaseClient.signature_policy.canary_enforce_utc) -gt [DateTime]::Parse([string]$releaseClient.signature_policy.grace_end_utc)) {
        Add-Check -Name 'signature_date_order_canary_before_grace_end' -Passed $false -Detail 'canary_enforce_utc must be <= grace_end_utc'
    } else {
        Add-Check -Name 'signature_date_order_canary_before_grace_end' -Passed $true -Detail 'ok'
    }
}

if (-not (Test-Path -LiteralPath $policyPath -PathType Leaf)) {
    Add-Check -Name 'policy_file_exists' -Passed $false -Detail $policyPath -Severity 'warning'
} else {
    Add-Check -Name 'policy_file_exists' -Passed $true -Detail $policyPath
}

$report = [ordered]@{
    timestamp_utc = (Get-Date).ToUniversalTime().ToString('o')
    workspace_root = $WorkspaceRoot
    summary = [ordered]@{
        checks = $checks.Count
        failures = $failures.Count
        warnings = $warnings.Count
    }
    checks = $checks
    failures = $failures
    warnings = $warnings
}

$report | ConvertTo-Json -Depth 20 | Write-Output

if ($failures.Count -gt 0) {
    exit 1
}
if ($FailOnWarning -and $warnings.Count -gt 0) {
    exit 1
}

exit 0
