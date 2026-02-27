#Requires -Version 7.0
#Requires -Modules Pester

$ErrorActionPreference = 'Stop'

Describe 'Workflow bot token drill contract' {
    BeforeAll {
        $script:repoRoot = (Resolve-Path -Path (Join-Path $PSScriptRoot '..')).Path
        $script:workflowPath = Join-Path $script:repoRoot '.github/workflows/workflow-bot-token-drill.yml'
        $script:runtimePath = Join-Path $script:repoRoot 'scripts/Test-WorkflowBotTokenHealth.ps1'

        foreach ($path in @($script:workflowPath, $script:runtimePath)) {
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
                throw "Workflow bot token drill contract file missing: $path"
            }
        }

        $script:workflowContent = Get-Content -LiteralPath $script:workflowPath -Raw
        $script:runtimeContent = Get-Content -LiteralPath $script:runtimePath -Raw
    }

    It 'is scheduled and dispatchable with explicit workflow bot token preflight' {
        $script:workflowContent | Should -Match 'schedule:'
        $script:workflowContent | Should -Match 'workflow_dispatch:'
        $script:workflowContent | Should -Match 'WORKFLOW_BOT_TOKEN'
        $script:workflowContent | Should -Match 'workflow_bot_token_missing'
    }

    It 'runs token health checks, publishes a report, and manages incidents' {
        $script:workflowContent | Should -Match 'Test-WorkflowBotTokenHealth\.ps1'
        $script:workflowContent | Should -Match 'workflow-bot-token-drill-report\.json'
        $script:workflowContent | Should -Match 'Invoke-OpsIncidentLifecycle\.ps1'
        $script:workflowContent | Should -Match 'Workflow Bot Token Health Alert'
        $script:workflowContent | Should -Match '-Mode Fail'
        $script:workflowContent | Should -Match '-Mode Recover'
    }

    It 'keeps deterministic token health reason codes explicit' {
        foreach ($reasonCode in @(
            'ok',
            'token_missing',
            'token_invalid',
            'token_scope_insufficient',
            'token_health_runtime_error'
        )) {
            $pattern = [regex]::Escape($reasonCode)
            $script:runtimeContent | Should -Match $pattern
        }
    }
}
