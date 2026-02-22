#Requires -Version 7.0
#Requires -Modules Pester

$ErrorActionPreference = 'Stop'

Describe 'CI workflow reliability contract' {
    BeforeAll {
        $script:repoRoot = (Resolve-Path -Path (Join-Path $PSScriptRoot '..')).Path
        $script:workflowPath = Join-Path $script:repoRoot '.github/workflows/ci.yml'
        if (-not (Test-Path -LiteralPath $script:workflowPath -PathType Leaf)) {
            throw "CI workflow missing: $script:workflowPath"
        }

        $script:workflowContent = Get-Content -LiteralPath $script:workflowPath -Raw
    }

    It 'defines workflow-level concurrency dedupe by workflow and ref identity' {
        $script:workflowContent | Should -Match 'concurrency:'
        $script:workflowContent | Should -Match 'group:\s*ci-pipeline-\$\{\{\s*github\.workflow\s*\}\}-\$\{\{\s*github\.event\.pull_request\.head\.repo\.full_name\s*\|\|\s*github\.repository\s*\}\}-\$\{\{\s*github\.event\.pull_request\.head\.ref\s*\|\|\s*github\.ref_name\s*\}\}'
        $script:workflowContent | Should -Match 'cancel-in-progress:\s*true'
    }

    It 'uses two-attempt retry for workspace installer artifact uploads' {
        $script:workflowContent | Should -Match 'id:\s*upload-workspace-installer-artifact-attempt-1'
        $script:workflowContent | Should -Match 'id:\s*upload-workspace-installer-artifact-attempt-2'
        $script:workflowContent | Should -Match 'if:\s*steps\.upload-workspace-installer-artifact-attempt-1\.outcome == ''failure'''
        $script:workflowContent | Should -Match 'Validate workspace bootstrap installer artifact upload'
        $script:workflowContent | Should -Match 'steps\.upload-workspace-installer-artifact-attempt-2\.outcome'
    }

    It 'uses two-attempt retry for reproducibility artifact uploads' {
        $script:workflowContent | Should -Match 'id:\s*upload-reproducibility-artifacts-attempt-1'
        $script:workflowContent | Should -Match 'id:\s*upload-reproducibility-artifacts-attempt-2'
        $script:workflowContent | Should -Match 'if:\s*steps\.upload-reproducibility-artifacts-attempt-1\.outcome == ''failure'''
        $script:workflowContent | Should -Match 'Validate reproducibility artifact upload'
        $script:workflowContent | Should -Match 'steps\.upload-reproducibility-artifacts-attempt-2\.outcome'
    }

    It 'uses two-attempt retry for provenance artifact uploads' {
        $script:workflowContent | Should -Match 'id:\s*upload-provenance-artifacts-attempt-1'
        $script:workflowContent | Should -Match 'id:\s*upload-provenance-artifacts-attempt-2'
        $script:workflowContent | Should -Match 'if:\s*steps\.upload-provenance-artifacts-attempt-1\.outcome == ''failure'''
        $script:workflowContent | Should -Match 'Validate provenance artifact upload'
        $script:workflowContent | Should -Match 'steps\.upload-provenance-artifacts-attempt-2\.outcome'
    }
}
