#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter()]
    [ValidatePattern('^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$')]
    [string]$Repository = 'LabVIEW-Community-CI-CD/labview-cdev-surface-fork',

    [Parameter()]
    [ValidatePattern('^[A-Za-z0-9._/-]+$')]
    [string]$MainPattern = 'main',

    [Parameter()]
    [ValidatePattern('^[A-Za-z0-9._/*-]+$')]
    [string]$IntegrationPattern = 'integration/*',

    [Parameter()]
    [Alias('MainRequiredContext')]
    [string[]]$MainRequiredContexts = @(
        'CI Pipeline',
        'Integration Gate',
        'Release Race Hardening Drill'
    ),

    [Parameter()]
    [Alias('IntegrationRequiredContext')]
    [string[]]$IntegrationRequiredContexts = @(
        'CI Pipeline',
        'Integration Gate',
        'Release Race Hardening Drill'
    ),

    [Parameter()]
    [string]$OutputPath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'lib/WorkflowOps.Common.ps1')

function Add-ReasonCode {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][System.Collections.Generic.List[string]]$Target,
        [Parameter(Mandatory = $true)][string]$ReasonCode
    )

    if (-not $Target.Contains($ReasonCode)) {
        [void]$Target.Add($ReasonCode)
    }
}

function Test-RuleContract {
    param(
        [Parameter(Mandatory = $true)]$Rule,
        [Parameter(Mandatory = $true)][string]$Pattern,
        [Parameter(Mandatory = $true)][string[]]$RequiredContexts
    )

    $issues = [System.Collections.Generic.List[string]]::new()
    if ($null -eq $Rule) {
        [void]$issues.Add('rule_missing')
        return [ordered]@{
            status = 'fail'
            issues = @($issues)
            actual_contexts = @()
            requires_status_checks = $false
            requires_strict_status_checks = $false
            allows_force_pushes = $false
            allows_deletions = $false
        }
    }

    if (-not [bool]$Rule.requiresStatusChecks) {
        [void]$issues.Add('requires_status_checks_false')
    }
    if (-not [bool]$Rule.requiresStrictStatusChecks) {
        [void]$issues.Add('requires_strict_status_checks_false')
    }
    if ([bool]$Rule.allowsForcePushes) {
        [void]$issues.Add('allows_force_pushes_true')
    }
    if ([bool]$Rule.allowsDeletions) {
        [void]$issues.Add('allows_deletions_true')
    }

    $actualContexts = @($Rule.requiredStatusCheckContexts | ForEach-Object { [string]$_ })
    foreach ($required in @($RequiredContexts)) {
        if ($actualContexts -notcontains [string]$required) {
            [void]$issues.Add("missing_context:$required")
        }
    }

    return [ordered]@{
        status = if ($issues.Count -eq 0) { 'pass' } else { 'fail' }
        issues = @($issues)
        actual_contexts = @($actualContexts)
        requires_status_checks = [bool]$Rule.requiresStatusChecks
        requires_strict_status_checks = [bool]$Rule.requiresStrictStatusChecks
        allows_force_pushes = [bool]$Rule.allowsForcePushes
        allows_deletions = [bool]$Rule.allowsDeletions
    }
}

$reasonCodes = [System.Collections.Generic.List[string]]::new()

$report = [ordered]@{
    schema_version = '1.0'
    generated_at_utc = Get-UtcNowIso
    repository = $Repository
    status = 'fail'
    reason_codes = @()
    message = ''
    expected = [ordered]@{
        main_pattern = $MainPattern
        integration_pattern = $IntegrationPattern
        main_required_contexts = @($MainRequiredContexts)
        integration_required_contexts = @($IntegrationRequiredContexts)
    }
    actual = [ordered]@{
        main_rule = $null
        integration_rule = $null
    }
}

try {
    $repoParts = $Repository.Split('/')
    if ($repoParts.Count -ne 2) {
        Add-ReasonCode -Target $reasonCodes -ReasonCode 'repository_invalid'
        throw "Repository slug is invalid: $Repository"
    }

    $owner = [string]$repoParts[0]
    $name = [string]$repoParts[1]
    $query = @'
query($owner:String!, $name:String!) {
  repository(owner:$owner, name:$name) {
    branchProtectionRules(first:100) {
      nodes {
        id
        pattern
        requiresStatusChecks
        requiresStrictStatusChecks
        requiredStatusCheckContexts
        allowsForcePushes
        allowsDeletions
      }
    }
  }
}
'@
    $result = Invoke-GhJson -Arguments @(
        'api', 'graphql',
        '-f', ("query={0}" -f $query),
        '-F', ("owner={0}" -f $owner),
        '-F', ("name={0}" -f $name)
    )

    $rules = @($result.data.repository.branchProtectionRules.nodes)
    $mainRule = @($rules | Where-Object { [string]$_.pattern -eq $MainPattern } | Select-Object -First 1)
    $integrationRule = @($rules | Where-Object { [string]$_.pattern -eq $IntegrationPattern } | Select-Object -First 1)

    $mainCheck = Test-RuleContract -Rule ($mainRule | Select-Object -First 1) -Pattern $MainPattern -RequiredContexts @($MainRequiredContexts)
    $integrationCheck = Test-RuleContract -Rule ($integrationRule | Select-Object -First 1) -Pattern $IntegrationPattern -RequiredContexts @($IntegrationRequiredContexts)

    $report.actual.main_rule = [ordered]@{
        pattern = $MainPattern
        check = $mainCheck
    }
    $report.actual.integration_rule = [ordered]@{
        pattern = $IntegrationPattern
        check = $integrationCheck
    }

    if ([string]$mainCheck.status -ne 'pass') {
        if (@($mainCheck.issues) -contains 'rule_missing') {
            Add-ReasonCode -Target $reasonCodes -ReasonCode 'main_rule_missing'
        } else {
            Add-ReasonCode -Target $reasonCodes -ReasonCode 'main_rule_mismatch'
        }
    }
    if ([string]$integrationCheck.status -ne 'pass') {
        if (@($integrationCheck.issues) -contains 'rule_missing') {
            Add-ReasonCode -Target $reasonCodes -ReasonCode 'integration_rule_missing'
        } else {
            Add-ReasonCode -Target $reasonCodes -ReasonCode 'integration_rule_mismatch'
        }
    }

    if ($reasonCodes.Count -eq 0) {
        $report.status = 'pass'
        $report.reason_codes = @('ok')
        $report.message = 'Release branch-protection policy is satisfied.'
    } else {
        $report.status = 'fail'
        $report.reason_codes = @($reasonCodes)
        $report.message = "Release branch-protection policy drift detected. reason_codes=$([string]::Join(',', @($reasonCodes)))"
    }
}
catch {
    if ($reasonCodes.Count -eq 0) {
        Add-ReasonCode -Target $reasonCodes -ReasonCode 'branch_protection_query_failed'
    }
    $report.status = 'fail'
    $report.reason_codes = @($reasonCodes)
    $report.message = [string]$_.Exception.Message
}
finally {
    Write-WorkflowOpsReport -Report $report -OutputPath $OutputPath | Out-Null
}

if ([string]$report.status -eq 'pass') {
    exit 0
}

exit 1
