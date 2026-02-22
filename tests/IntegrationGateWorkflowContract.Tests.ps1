#Requires -Version 7.0
#Requires -Modules Pester

$ErrorActionPreference = 'Stop'

Describe 'Integration gate workflow contract' {
    BeforeAll {
        $script:repoRoot = (Resolve-Path -Path (Join-Path $PSScriptRoot '..')).Path
        $script:workflowPath = Join-Path $script:repoRoot '.github/workflows/integration-gate.yml'
        if (-not (Test-Path -LiteralPath $script:workflowPath -PathType Leaf)) {
            throw "Integration gate workflow not found: $script:workflowPath"
        }
        $script:workflowContent = Get-Content -LiteralPath $script:workflowPath -Raw
    }

    It 'runs on integration branch pushes and on demand' {
        $script:workflowContent | Should -Match 'name:\s*Integration Gate'
        $script:workflowContent | Should -Match 'push:'
        $script:workflowContent | Should -Match 'integration/\*\*'
        $script:workflowContent | Should -Match 'workflow_dispatch:'
        $script:workflowContent | Should -Match 'ref:'
    }

    It 'waits for all required cdev surface contexts' {
        foreach ($context in @(
            'CI Pipeline',
            'Workspace Installer Contract',
            'Reproducibility Contract',
            'Provenance Contract'
        )) {
            $script:workflowContent | Should -Match ([regex]::Escape($context))
        }
        $script:workflowContent | Should -Match 'repos/\$repo/commits/\$sha/status'
        $script:workflowContent | Should -Match 'Start-Sleep -Seconds'
        $script:workflowContent | Should -Match 'Integration gate passed'
        $script:workflowContent | Should -Match 'Integration gate timed out'
    }
}
