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
    [switch]$DryRun,

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

function Invoke-GraphQl {
    param(
        [Parameter(Mandatory = $true)][string]$Query,
        [Parameter(Mandatory = $true)][hashtable]$Variables
    )

    $args = @('api', 'graphql', '-f', ("query={0}" -f $Query))
    foreach ($key in $Variables.Keys) {
        $args += @('-F', ("{0}={1}" -f $key, [string]$Variables[$key]))
    }

    return (Invoke-GhJson -Arguments $args)
}

function ConvertTo-GraphQlStringLiteral {
    param([Parameter(Mandatory = $true)][string]$Value)

    $escaped = $Value.Replace('\', '\\').Replace('"', '\"').Replace("`r", '\r').Replace("`n", '\n')
    return '"' + $escaped + '"'
}

function ConvertTo-GraphQlBooleanLiteral {
    param([Parameter(Mandatory = $true)][bool]$Value)

    if ($Value) {
        return 'true'
    }

    return 'false'
}

function ConvertTo-GraphQlStringArrayLiteral {
    param([Parameter(Mandatory = $true)][string[]]$Values)

    if (@($Values).Count -eq 0) {
        return '[]'
    }

    $encoded = @($Values | ForEach-Object { ConvertTo-GraphQlStringLiteral -Value ([string]$_) })
    return ('[' + ([string]::Join(',', $encoded)) + ']')
}

function Resolve-ExistingRules {
    param(
        [Parameter(Mandatory = $true)][string]$Owner,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $query = @'
query($owner:String!, $name:String!) {
  repository(owner:$owner, name:$name) {
    id
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
    return (Invoke-GraphQl -Query $query -Variables @{
            owner = $Owner
            name = $Name
        })
}

function New-DesiredRuleSpec {
    param(
        [Parameter(Mandatory = $true)][string]$Pattern,
        [Parameter(Mandatory = $true)][string[]]$Contexts
    )

    return [ordered]@{
        pattern = $Pattern
        requiresStatusChecks = $true
        requiresStrictStatusChecks = $true
        requiredStatusCheckContexts = @($Contexts)
        allowsForcePushes = $false
        allowsDeletions = $false
    }
}

function Test-RuleMatchesSpec {
    param(
        [Parameter()][AllowNull()]$Rule,
        [Parameter(Mandatory = $true)]$Spec
    )

    if ($null -eq $Rule) {
        return $false
    }

    if ([bool]$Rule.requiresStatusChecks -ne [bool]$Spec.requiresStatusChecks) {
        return $false
    }
    if ([bool]$Rule.requiresStrictStatusChecks -ne [bool]$Spec.requiresStrictStatusChecks) {
        return $false
    }
    if ([bool]$Rule.allowsForcePushes -ne [bool]$Spec.allowsForcePushes) {
        return $false
    }
    if ([bool]$Rule.allowsDeletions -ne [bool]$Spec.allowsDeletions) {
        return $false
    }

    $actual = @($Rule.requiredStatusCheckContexts | ForEach-Object { [string]$_ })
    $expected = @($Spec.requiredStatusCheckContexts | ForEach-Object { [string]$_ })
    foreach ($ctx in $expected) {
        if ($actual -notcontains $ctx) {
            return $false
        }
    }

    return $true
}

$reasonCodes = [System.Collections.Generic.List[string]]::new()

$report = [ordered]@{
    schema_version = '1.0'
    generated_at_utc = Get-UtcNowIso
    repository = $Repository
    dry_run = [bool]$DryRun
    status = 'fail'
    reason_codes = @()
    message = ''
    actions = @()
}

try {
    $repoParts = $Repository.Split('/')
    if ($repoParts.Count -ne 2) {
        Add-ReasonCode -Target $reasonCodes -ReasonCode 'repository_invalid'
        throw "Repository slug is invalid: $Repository"
    }

    $owner = [string]$repoParts[0]
    $name = [string]$repoParts[1]
    $existingPayload = Resolve-ExistingRules -Owner $owner -Name $name
    $repositoryNode = $existingPayload.data.repository
    if ($null -eq $repositoryNode -or [string]::IsNullOrWhiteSpace([string]$repositoryNode.id)) {
        Add-ReasonCode -Target $reasonCodes -ReasonCode 'repository_not_found'
        throw "Repository GraphQL node not found: $Repository"
    }
    $repositoryId = [string]$repositoryNode.id
    $existingRules = @($repositoryNode.branchProtectionRules.nodes)

    $desired = @(
        (New-DesiredRuleSpec -Pattern $MainPattern -Contexts @($MainRequiredContexts))
        (New-DesiredRuleSpec -Pattern $IntegrationPattern -Contexts @($IntegrationRequiredContexts))
    )

    $actionRecords = [System.Collections.Generic.List[object]]::new()

    foreach ($spec in @($desired)) {
        $current = @($existingRules | Where-Object { [string]$_.pattern -eq [string]$spec.pattern } | Select-Object -First 1)
        $currentRule = if (@($current).Count -eq 1) { $current[0] } else { $null }
        $matches = Test-RuleMatchesSpec -Rule $currentRule -Spec $spec
        if ($matches) {
            [void]$actionRecords.Add([ordered]@{
                    pattern = [string]$spec.pattern
                    action = 'noop'
                    rule_id = if ($null -eq $currentRule) { '' } else { [string]$currentRule.id }
                })
            continue
        }

        if ($DryRun) {
            [void]$actionRecords.Add([ordered]@{
                    pattern = [string]$spec.pattern
                    action = if ($null -eq $currentRule) { 'create_dry_run' } else { 'update_dry_run' }
                    rule_id = if ($null -eq $currentRule) { '' } else { [string]$currentRule.id }
                    desired = $spec
                })
            continue
        }

        $repositoryIdLiteral = ConvertTo-GraphQlStringLiteral -Value $repositoryId
        $patternLiteral = ConvertTo-GraphQlStringLiteral -Value ([string]$spec.pattern)
        $requiresStatusChecksLiteral = ConvertTo-GraphQlBooleanLiteral -Value ([bool]$spec.requiresStatusChecks)
        $requiresStrictStatusChecksLiteral = ConvertTo-GraphQlBooleanLiteral -Value ([bool]$spec.requiresStrictStatusChecks)
        $requiredStatusCheckContextsLiteral = ConvertTo-GraphQlStringArrayLiteral -Values @($spec.requiredStatusCheckContexts | ForEach-Object { [string]$_ })
        $allowsForcePushesLiteral = ConvertTo-GraphQlBooleanLiteral -Value ([bool]$spec.allowsForcePushes)
        $allowsDeletionsLiteral = ConvertTo-GraphQlBooleanLiteral -Value ([bool]$spec.allowsDeletions)

        if ($null -eq $currentRule) {
            $createMutation = @"
mutation {
  createBranchProtectionRule(
    input: {
      repositoryId: $repositoryIdLiteral
      pattern: $patternLiteral
      requiresStatusChecks: $requiresStatusChecksLiteral
      requiresStrictStatusChecks: $requiresStrictStatusChecksLiteral
      requiredStatusCheckContexts: $requiredStatusCheckContextsLiteral
      allowsForcePushes: $allowsForcePushesLiteral
      allowsDeletions: $allowsDeletionsLiteral
    }
  ) {
    branchProtectionRule {
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
"@

            $createResult = Invoke-GhJson -Arguments @(
                'api', 'graphql',
                '-f', ("query={0}" -f $createMutation)
            )
            $createdRule = $createResult.data.createBranchProtectionRule.branchProtectionRule
            [void]$actionRecords.Add([ordered]@{
                    pattern = [string]$spec.pattern
                    action = 'created'
                    rule_id = [string]$createdRule.id
                })
        } else {
            $ruleIdLiteral = ConvertTo-GraphQlStringLiteral -Value ([string]$currentRule.id)
            $updateMutation = @"
mutation {
  updateBranchProtectionRule(
    input: {
      branchProtectionRuleId: $ruleIdLiteral
      pattern: $patternLiteral
      requiresStatusChecks: $requiresStatusChecksLiteral
      requiresStrictStatusChecks: $requiresStrictStatusChecksLiteral
      requiredStatusCheckContexts: $requiredStatusCheckContextsLiteral
      allowsForcePushes: $allowsForcePushesLiteral
      allowsDeletions: $allowsDeletionsLiteral
    }
  ) {
    branchProtectionRule {
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
"@

            $updateResult = Invoke-GhJson -Arguments @(
                'api', 'graphql',
                '-f', ("query={0}" -f $updateMutation)
            )
            $updatedRule = $updateResult.data.updateBranchProtectionRule.branchProtectionRule
            [void]$actionRecords.Add([ordered]@{
                    pattern = [string]$spec.pattern
                    action = 'updated'
                    rule_id = [string]$updatedRule.id
                })
        }
    }

    $report.actions = @($actionRecords)

    if (-not $DryRun) {
        $verifyScript = Join-Path $PSScriptRoot 'Test-ReleaseBranchProtectionPolicy.ps1'
        if (-not (Test-Path -LiteralPath $verifyScript -PathType Leaf)) {
            Add-ReasonCode -Target $reasonCodes -ReasonCode 'verify_script_missing'
            throw "Verification script missing: $verifyScript"
        }

        $verifyPath = Join-Path ([System.IO.Path]::GetTempPath()) ("branch-protection-verify-" + [Guid]::NewGuid().ToString('N') + '.json')
        $mainContextsCsv = [string]::Join(',', @($MainRequiredContexts | ForEach-Object { [string]$_ }))
        $integrationContextsCsv = [string]::Join(',', @($IntegrationRequiredContexts | ForEach-Object { [string]$_ }))
        & pwsh -NoProfile -File $verifyScript `
            -Repository $Repository `
            -MainPattern $MainPattern `
            -IntegrationPattern $IntegrationPattern `
            -MainRequiredContexts $mainContextsCsv `
            -IntegrationRequiredContexts $integrationContextsCsv `
            -OutputPath $verifyPath | Out-Null
        $verifyExit = if ($null -eq $LASTEXITCODE) { 0 } else { [int]$LASTEXITCODE }
        if ($verifyExit -ne 0) {
            Add-ReasonCode -Target $reasonCodes -ReasonCode 'verification_failed'
            if (Test-Path -LiteralPath $verifyPath -PathType Leaf) {
                $verifyReport = Get-Content -LiteralPath $verifyPath -Raw | ConvertFrom-Json -Depth 100
                throw ("Post-apply verification failed. reason_codes={0}" -f [string]::Join(',', @($verifyReport.reason_codes | ForEach-Object { [string]$_ })))
            }
            throw 'Post-apply verification failed without report payload.'
        }
    }

    if ($reasonCodes.Count -eq 0) {
        $report.status = 'pass'
        $report.reason_codes = if ($DryRun) { @('dry_run') } else { @('applied') }
        $report.message = if ($DryRun) { 'Release branch-protection apply dry-run completed.' } else { 'Release branch-protection policy applied and verified.' }
    } else {
        $report.status = 'fail'
        $report.reason_codes = @($reasonCodes)
        $report.message = "Release branch-protection apply failed. reason_codes=$([string]::Join(',', @($reasonCodes)))"
    }
}
catch {
    if ($reasonCodes.Count -eq 0) {
        Add-ReasonCode -Target $reasonCodes -ReasonCode 'apply_runtime_error'
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
