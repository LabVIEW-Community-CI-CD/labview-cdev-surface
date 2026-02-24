#Requires -Version 7.0
#Requires -Modules Pester

$ErrorActionPreference = 'Stop'

Describe 'Release with Windows gate workflow contract' {
    BeforeAll {
        $script:repoRoot = (Resolve-Path -Path (Join-Path $PSScriptRoot '..')).Path
        $script:workflowPath = Join-Path $script:repoRoot '.github/workflows/release-with-windows-gate.yml'
        if (-not (Test-Path -LiteralPath $script:workflowPath -PathType Leaf)) {
            throw "Release orchestrator workflow missing: $script:workflowPath"
        }
        $script:workflowContent = Get-Content -LiteralPath $script:workflowPath -Raw
    }

    It 'is dispatch-only with required release and controlled override inputs' {
        $script:workflowContent | Should -Match 'workflow_dispatch:'
        $script:workflowContent | Should -Not -Match '(?m)^\s*push:'
        $script:workflowContent | Should -Not -Match '(?m)^\s*pull_request:'
        $script:workflowContent | Should -Not -Match '(?m)^\s*schedule:'
        $script:workflowContent | Should -Match 'release_tag:'
        $script:workflowContent | Should -Match 'allow_existing_tag:'
        $script:workflowContent | Should -Match 'prerelease:'
        $script:workflowContent | Should -Match 'allow_gate_override:'
        $script:workflowContent | Should -Match 'override_reason:'
        $script:workflowContent | Should -Match 'override_incident_url:'
    }

    It 'contains repo guard, hard gate ordering, and reusable workflow chaining' {
        $script:workflowContent | Should -Match "expectedRepo = 'LabVIEW-Community-CI-CD/labview-cdev-surface'"
        $script:workflowContent | Should -Match 'windows_gate:'
        $script:workflowContent | Should -Match 'linux_gate:'
        $script:workflowContent | Should -Match 'needs:\s*\[repo_guard\]'
        $script:workflowContent | Should -Match 'uses:\s*\./\.github/workflows/_windows-labview-image-gate-core\.yml'
        $script:workflowContent | Should -Match 'uses:\s*\./\.github/workflows/_linux-labview-image-gate-core\.yml'
        $script:workflowContent | Should -Match 'gate_policy:'
        $script:workflowContent | Should -Match 'needs:\s*\[repo_guard,\s*windows_gate,\s*linux_gate\]'
        $script:workflowContent | Should -Match 'if:\s*\$\{\{\s*always\(\)\s*\}\}'
        $script:workflowContent | Should -Match 'release_publish:'
        $script:workflowContent | Should -Match 'needs:\s*\[gate_policy\]'
        $script:workflowContent | Should -Match 'uses:\s*\./\.github/workflows/_release-workspace-installer-core\.yml'
    }

    It 'enforces hard block and controlled override metadata requirements' {
        $script:workflowContent | Should -Match 'Repository guard did not succeed'
        $script:workflowContent | Should -Match 'One or more gates failed and override is not enabled'
        $script:workflowContent | Should -Match 'allow_gate_override=true requires non-empty override_reason'
        $script:workflowContent | Should -Match 'allow_gate_override=true requires override_incident_url'
        $script:workflowContent | Should -Match 'overrideIncidentUrl -notmatch'
        $script:workflowContent | Should -Match 'GitHub issue/discussion URL'
        $script:workflowContent | Should -Match '::warning::One or more gates failed but controlled override is active'
    }

    It 'defines non-canceling release-tag concurrency' {
        $script:workflowContent | Should -Match 'group:\s*release-with-gate-\$\{\{\s*inputs\.release_tag\s*\}\}'
        $script:workflowContent | Should -Match 'cancel-in-progress:\s*false'
    }
}
