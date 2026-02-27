#Requires -Version 7.0
#Requires -Modules Pester

$ErrorActionPreference = 'Stop'

Describe 'Branch protection drift workflow contract' {
    BeforeAll {
        $script:repoRoot = (Resolve-Path -Path (Join-Path $PSScriptRoot '..')).Path
        $script:workflowPath = Join-Path $script:repoRoot '.github/workflows/branch-protection-drift-check.yml'
        $script:verifyPath = Join-Path $script:repoRoot 'scripts/Test-ReleaseBranchProtectionPolicy.ps1'
        $script:applyPath = Join-Path $script:repoRoot 'scripts/Set-ReleaseBranchProtectionPolicy.ps1'

        foreach ($path in @($script:workflowPath, $script:verifyPath, $script:applyPath)) {
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
                throw "Branch-protection drift contract file missing: $path"
            }
        }

        $script:workflowContent = Get-Content -LiteralPath $script:workflowPath -Raw
        $script:verifyContent = Get-Content -LiteralPath $script:verifyPath -Raw
        $script:applyContent = Get-Content -LiteralPath $script:applyPath -Raw
    }

    It 'runs on schedule, main push, and manual dispatch' {
        $script:workflowContent | Should -Match 'schedule:'
        $script:workflowContent | Should -Match 'push:'
        $script:workflowContent | Should -Match 'main'
        $script:workflowContent | Should -Match 'workflow_dispatch:'
    }

    It 'verifies policy and publishes a machine-readable drift report' {
        $script:workflowContent | Should -Match 'Test-ReleaseBranchProtectionPolicy\.ps1'
        $script:workflowContent | Should -Match 'branch-protection-drift-report\.json'
        $script:workflowContent | Should -Match 'Branch Protection Drift Check'
    }

    It 'manages failure and recovery incidents for branch-protection drift' {
        $script:workflowContent | Should -Match 'Branch Protection Drift Alert'
        $script:workflowContent | Should -Match 'Invoke-OpsIncidentLifecycle\.ps1'
        $script:workflowContent | Should -Match '-Mode Fail'
        $script:workflowContent | Should -Match '-Mode Recover'
        $script:workflowContent | Should -Match 'issues:\s*write'
    }

    It 'defines release branch-protection policy contract for main and integration lanes' {
        $script:verifyContent | Should -Match 'main'
        $script:verifyContent | Should -Match 'integration/\*'
        $script:verifyContent | Should -Match 'CI Pipeline'
        $script:verifyContent | Should -Match 'Integration Gate'
        $script:verifyContent | Should -Match 'Release Race Hardening Drill'
        $script:verifyContent | Should -Match 'main_rule_missing'
        $script:verifyContent | Should -Match 'integration_rule_missing'
        $script:verifyContent | Should -Match 'branch_protection_query_failed'
    }

    It 'supports deterministic apply and verification of branch-protection policy' {
        $script:applyContent | Should -Match 'createBranchProtectionRule'
        $script:applyContent | Should -Match 'updateBranchProtectionRule'
        $script:applyContent | Should -Match 'Test-ReleaseBranchProtectionPolicy\.ps1'
        $script:applyContent | Should -Match 'reason_codes = if \(\$DryRun\)'
        $script:applyContent | Should -Match "@\('dry_run'\)"
        $script:applyContent | Should -Match "@\('applied'\)"
        $script:applyContent | Should -Match 'verification_failed'
        $script:applyContent | Should -Match 'apply_runtime_error'
    }
}
