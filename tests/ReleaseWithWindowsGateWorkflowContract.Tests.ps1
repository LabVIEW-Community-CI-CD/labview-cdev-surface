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

    It 'contains repo guard, windows+linux hard gate ordering, and reusable workflow chaining' {
        $script:workflowContent | Should -Match "expectedRepo = 'LabVIEW-Community-CI-CD/labview-cdev-surface'"
        $script:workflowContent | Should -Match 'windows_gate:'
        $script:workflowContent | Should -Match 'needs:\s*\[repo_guard\]'
        $script:workflowContent | Should -Match 'uses:\s*\./\.github/workflows/_windows-labview-image-gate-core\.yml'
        $script:workflowContent | Should -Match 'linux_parity_gate:'
        $script:workflowContent | Should -Match 'needs:\s*\[repo_guard,\s*windows_gate\]'
        $script:workflowContent | Should -Match 'uses:\s*\./\.github/workflows/_linux-labview-image-gate-core\.yml'
        $script:workflowContent | Should -Match 'windows_prereq_x86_artifact_name:'
        $script:workflowContent | Should -Match 'windows_prereq_x64_artifact_name:'
        $script:workflowContent | Should -Match 'windows_prereq_native_labview_version:'
        $script:workflowContent | Should -Match 'gate_policy:'
        $script:workflowContent | Should -Match 'needs:\s*\[repo_guard,\s*windows_gate,\s*linux_parity_gate\]'
        $script:workflowContent | Should -Match 'if:\s*\$\{\{\s*always\(\)\s*\}\}'
        $script:workflowContent | Should -Match 'effective_allow_existing_tag:\s*\$\{\{\s*steps\.evaluate\.outputs\.effective_allow_existing_tag\s*\}\}'
        $script:workflowContent | Should -Match 'release_publish:'
        $script:workflowContent | Should -Match 'needs:\s*\[gate_policy\]'
        $script:workflowContent | Should -Match 'uses:\s*\./\.github/workflows/_release-workspace-installer-core\.yml'
        $script:workflowContent | Should -Match 'allow_existing_tag:\s*\$\{\{\s*fromJSON\(needs\.gate_policy\.outputs\.effective_allow_existing_tag\)\s*\}\}'
    }

    It 'enforces hard block, release artifact policy, and controlled override metadata requirements' {
        $script:workflowContent | Should -Match 'Repository guard did not succeed'
        $script:workflowContent | Should -Match 'Gate failed and override is not enabled'
        $script:workflowContent | Should -Match 'Release artifact policy violation'
        $script:workflowContent | Should -Match 'artifacts/parity/linux/\*'
        $script:workflowContent | Should -Match 'allow_gate_override=true requires non-empty override_reason'
        $script:workflowContent | Should -Match 'allow_gate_override=true requires override_incident_url'
        $script:workflowContent | Should -Match 'overrideIncidentUrl -notmatch'
        $script:workflowContent | Should -Match 'GitHub issue/discussion URL'
        $script:workflowContent | Should -Match '::warning::Gate failure override is active'
        $script:workflowContent | Should -Match 'ALLOW_EXISTING_TAG_INPUT'
        $script:workflowContent | Should -Match '\$refName -ne ''main'' -and -not \$allowExistingTagInput'
        $script:workflowContent | Should -Match 'allow_existing_tag normalized to true for non-main ref'
        $script:workflowContent | Should -Match 'effective_allow_existing_tag='
    }

    It 'defines non-canceling release-tag concurrency' {
        $script:workflowContent | Should -Match 'group:\s*release-with-gate-\$\{\{\s*inputs\.release_tag\s*\}\}'
        $script:workflowContent | Should -Match 'cancel-in-progress:\s*false'
    }
}
