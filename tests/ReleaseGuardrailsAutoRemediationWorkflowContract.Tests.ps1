#Requires -Version 7.0
#Requires -Modules Pester

$ErrorActionPreference = 'Stop'

Describe 'Release guardrails auto-remediation workflow contract' {
    BeforeAll {
        $script:repoRoot = (Resolve-Path -Path (Join-Path $PSScriptRoot '..')).Path
        $script:workflowPath = Join-Path $script:repoRoot '.github/workflows/release-guardrails-autoremediate.yml'
        $script:runtimePath = Join-Path $script:repoRoot 'scripts/Invoke-ReleaseGuardrailsSelfHealing.ps1'

        foreach ($path in @($script:workflowPath, $script:runtimePath)) {
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
                throw "Release guardrails contract file missing: $path"
            }
        }

        $script:workflowContent = Get-Content -LiteralPath $script:workflowPath -Raw
        $script:runtimeContent = Get-Content -LiteralPath $script:runtimePath -Raw
    }

    It 'is scheduled and dispatchable with deterministic inputs' {
        $script:workflowContent | Should -Match 'schedule:'
        $script:workflowContent | Should -Match 'workflow_dispatch:'
        $script:workflowContent | Should -Match 'race_gate_max_age_hours'
        $script:workflowContent | Should -Match 'auto_self_heal'
        $script:workflowContent | Should -Match 'max_attempts'
        $script:workflowContent | Should -Match 'drill_watch_timeout_minutes'
        $script:workflowContent | Should -Match 'actions:\s*write'
        $script:workflowContent | Should -Match 'issues:\s*write'
    }

    It 'executes guardrail runtime and incident lifecycle management' {
        $script:workflowContent | Should -Match 'Validate workflow bot token'
        $script:workflowContent | Should -Match 'Invoke-ReleaseGuardrailsSelfHealing\.ps1'
        $script:workflowContent | Should -Match 'release-guardrails-autoremediate-report\.json'
        $script:workflowContent | Should -Match 'Invoke-OpsIncidentLifecycle\.ps1'
        $script:workflowContent | Should -Match 'Release Guardrails Auto-Remediation Alert'
        $script:workflowContent | Should -Match 'WORKFLOW_BOT_TOKEN'
        $script:workflowContent | Should -Match 'workflow_bot_token_missing'
        $script:workflowContent | Should -Match 'GH_TOKEN:\s*\${{\s*secrets\.WORKFLOW_BOT_TOKEN\s*}}'
        $script:workflowContent | Should -Not -Match 'github\.token'
        $script:workflowContent | Should -Match '-Mode Fail'
        $script:workflowContent | Should -Match '-Mode Recover'
    }

    It 'writes a deterministic invalid_input report when workflow input guards fail' {
        $script:workflowContent | Should -Match 'Write-InvalidInputReport'
        $script:workflowContent | Should -Match "reason_code = 'invalid_input'"
        $script:workflowContent | Should -Match 'invalid_input:'
        $script:workflowContent | Should -Match 'race_gate_max_age_hours must be between 1 and 720'
        $script:workflowContent | Should -Match 'max_attempts must be between 1 and 5'
        $script:workflowContent | Should -Match 'drill_watch_timeout_minutes must be between 5 and 240'
        $script:workflowContent | Should -Match 'Set-Content -LiteralPath \$reportPath'
    }

    It 'enforces autonomous remediation paths for branch protection and race gate freshness' {
        $script:runtimeContent | Should -Match 'Test-ReleaseBranchProtectionPolicy\.ps1'
        $script:runtimeContent | Should -Match 'Set-ReleaseBranchProtectionPolicy\.ps1'
        $script:runtimeContent | Should -Match 'Test-ReleaseRaceHardeningGate\.ps1'
        $script:runtimeContent | Should -Match 'Dispatch-WorkflowAtRemoteHead\.ps1'
        $script:runtimeContent | Should -Match 'Watch-WorkflowRun\.ps1'
        $script:runtimeContent | Should -Match 'drill_run_missing'
        $script:runtimeContent | Should -Match 'drill_run_stale'
        $script:runtimeContent | Should -Match 'apply_branch_protection_policy'
        $script:runtimeContent | Should -Match 'dispatch_release_race_hardening_drill'
        $script:runtimeContent | Should -Match 'remediation_hints'
        $script:runtimeContent | Should -Match 'branch_protection_authentication_missing'
        $script:runtimeContent | Should -Match 'branch_protection_authz_denied'
    }

    It 'keeps deterministic self-healing reason codes explicit' {
        foreach ($reasonCode in @(
            'already_healthy',
            'remediated',
            'auto_remediation_disabled',
            'no_automatable_action',
            'remediation_execution_failed',
            'remediation_verify_failed',
            'guardrails_self_heal_runtime_error'
        )) {
            $pattern = [regex]::Escape($reasonCode)
            $script:runtimeContent | Should -Match $pattern
        }
    }
}
