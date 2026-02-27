#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter()]
    [ValidatePattern('^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$')]
    [string]$Repository = 'LabVIEW-Community-CI-CD/labview-cdev-surface-fork',

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

function Resolve-TokenFailureReason {
    param(
        [Parameter()][string]$MessageText = ''
    )

    $normalized = ([string]$MessageText).ToLowerInvariant()
    foreach ($token in @(
            'bad credentials',
            'authentication required',
            'requires authentication',
            'not logged into any hosts',
            'http 401'
        )) {
        if ($normalized.Contains([string]$token)) {
            return 'token_invalid'
        }
    }

    foreach ($token in @(
            'resource not accessible by integration',
            'insufficient permissions',
            'must have admin rights',
            'requires admin access',
            'http 403',
            'forbidden'
        )) {
        if ($normalized.Contains([string]$token)) {
            return 'token_scope_insufficient'
        }
    }

    return 'token_health_runtime_error'
}

function Invoke-TokenCheck {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][ScriptBlock]$Action
    )

    try {
        & $Action | Out-Null
        return [pscustomobject]@{
            name = $Name
            status = 'pass'
            message = 'ok'
            reason_code = 'ok'
        }
    } catch {
        $message = [string]$_.Exception.Message
        $reasonCode = Resolve-TokenFailureReason -MessageText $message
        return [pscustomobject]@{
            name = $Name
            status = 'fail'
            message = $message
            reason_code = $reasonCode
        }
    }
}

$report = [ordered]@{
    schema_version = '1.0'
    generated_at_utc = Get-UtcNowIso
    repository = $Repository
    status = 'fail'
    reason_codes = @()
    message = ''
    checks = @()
}

$reasonCodes = [System.Collections.Generic.List[string]]::new()
$checks = [System.Collections.Generic.List[object]]::new()

try {
    if ([string]::IsNullOrWhiteSpace([string]$env:GH_TOKEN)) {
        Add-ReasonCode -Target $reasonCodes -ReasonCode 'token_missing'
        $checks.Add([ordered]@{
                name = 'token_present'
                status = 'fail'
                message = 'GH_TOKEN is not set in environment.'
                reason_code = 'token_missing'
            }) | Out-Null
    } else {
        $checks.Add([ordered]@{
                name = 'token_present'
                status = 'pass'
                message = 'GH_TOKEN is present.'
                reason_code = 'ok'
            }) | Out-Null

        $repoParts = $Repository.Split('/')
        if ($repoParts.Count -ne 2) {
            Add-ReasonCode -Target $reasonCodes -ReasonCode 'repository_invalid'
            $checks.Add([ordered]@{
                    name = 'repository_slug'
                    status = 'fail'
                    message = "Repository slug is invalid: $Repository"
                    reason_code = 'repository_invalid'
                }) | Out-Null
        } else {
            $owner = [string]$repoParts[0]
            $name = [string]$repoParts[1]
            $branchProtectionQuery = @'
query($owner:String!, $name:String!) {
  repository(owner:$owner, name:$name) {
    branchProtectionRules(first:5) {
      nodes {
        pattern
      }
    }
  }
}
'@

            $checkResults = @(
                Invoke-TokenCheck -Name 'viewer_query' -Action {
                    Invoke-GhJson -Arguments @(
                        'api', 'graphql',
                        '-f', 'query=query { viewer { login } }'
                    )
                },
                Invoke-TokenCheck -Name 'repo_read' -Action {
                    Invoke-GhJson -Arguments @(
                        'api', "repos/$Repository"
                    )
                },
                Invoke-TokenCheck -Name 'actions_runners_read' -Action {
                    Invoke-GhJson -Arguments @(
                        'api', "repos/$Repository/actions/runners?per_page=1"
                    )
                },
                Invoke-TokenCheck -Name 'branch_protection_graphql_read' -Action {
                    Invoke-GhJson -Arguments @(
                        'api', 'graphql',
                        '-f', ("query={0}" -f $branchProtectionQuery),
                        '-F', ("owner={0}" -f $owner),
                        '-F', ("name={0}" -f $name)
                    )
                }
            )

            foreach ($entry in @($checkResults)) {
                $checks.Add([ordered]@{
                        name = [string]$entry.name
                        status = [string]$entry.status
                        message = [string]$entry.message
                        reason_code = [string]$entry.reason_code
                    }) | Out-Null
                if ([string]$entry.status -ne 'pass' -and [string]$entry.reason_code -ne 'ok') {
                    Add-ReasonCode -Target $reasonCodes -ReasonCode ([string]$entry.reason_code)
                }
            }
        }
    }

    $report.checks = @($checks)
    if ($reasonCodes.Count -eq 0) {
        $report.status = 'pass'
        $report.reason_codes = @('ok')
        $report.message = 'Workflow bot token health checks passed.'
    } else {
        $report.status = 'fail'
        $report.reason_codes = @($reasonCodes)
        $report.message = "Workflow bot token health checks failed. reason_codes=$([string]::Join(',', @($reasonCodes)))"
    }
}
catch {
    $report.status = 'fail'
    $report.reason_codes = @('token_health_runtime_error')
    $report.message = [string]$_.Exception.Message
}
finally {
    Write-WorkflowOpsReport -Report $report -OutputPath $OutputPath | Out-Null
}

if ([string]$report.status -eq 'pass') {
    exit 0
}

exit 1
