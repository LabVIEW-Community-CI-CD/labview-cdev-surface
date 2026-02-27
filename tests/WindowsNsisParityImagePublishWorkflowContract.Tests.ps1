#Requires -Version 7.0
#Requires -Modules Pester

$ErrorActionPreference = 'Stop'

Describe 'Windows NSIS parity image publish workflow contract' {
    BeforeAll {
        $script:repoRoot = (Resolve-Path -Path (Join-Path $PSScriptRoot '..')).Path
        $script:workflowPath = Join-Path $script:repoRoot '.github/workflows/publish-windows-nsis-parity-image.yml'

        if (-not (Test-Path -LiteralPath $script:workflowPath -PathType Leaf)) {
            throw "Windows NSIS parity image publish workflow missing: $script:workflowPath"
        }

        $script:workflowContent = Get-Content -LiteralPath $script:workflowPath -Raw
    }

    It 'supports manual dispatch and deterministic main-path publish triggers including cdev-cli payload' {
        $script:workflowContent | Should -Match 'workflow_dispatch:'
        $script:workflowContent | Should -Match 'push:'
        $script:workflowContent | Should -Match 'tools/nsis-selftest-windows/Dockerfile'
        $script:workflowContent | Should -Match 'scripts/Invoke-WindowsContainerNsisSelfTest\.ps1'
        $script:workflowContent | Should -Match 'scripts/Build-RunnerCliBundleFromManifest\.ps1'
        $script:workflowContent | Should -Match 'scripts/Install-WorkspaceFromManifest\.ps1'
        $script:workflowContent | Should -Match 'workspace-governance-payload/tools/cdev-cli/\*\*'
        $script:workflowContent | Should -Match 'workspace-governance\.json'
    }

    It 'enforces windows container preflight and silent self-test gate before publish' {
        $script:workflowContent | Should -Match 'runs-on:\s*\[self-hosted,\s*windows,\s*windows-containers,\s*cdev-surface-windows-gate\]'
        $script:workflowContent | Should -Match 'windows_container_mode_required'
        $script:workflowContent | Should -Match 'Invoke-WindowsContainerNsisSelfTest\.ps1'
        $script:workflowContent | Should -Match '-BuildLocalImage'
        $script:workflowContent | Should -Match 'windows-container-nsis-selftest-publish'
        $script:workflowContent | Should -Match 'Silent self-test'
    }

    It 'publishes to GHCR with package write permission and deterministic digest reporting' {
        $script:workflowContent | Should -Match 'packages:\s*write'
        $script:workflowContent | Should -Match 'ghcr\.io/labview-community-ci-cd/labview-cdev-surface-nsis-windows-parity'
        $script:workflowContent | Should -Match 'docker/login-action@v3'
        $script:workflowContent | Should -Match 'docker push'
        $script:workflowContent | Should -Match 'sha-\$shortSha'
        $script:workflowContent | Should -Match 'BASE_TAG:\s*2026q1-windows'
        $script:workflowContent | Should -Match '\$env:BASE_TAG-\$dateUtc'
        $script:workflowContent | Should -Match 'digest=\$digest'
        $script:workflowContent | Should -Match 'digestMatch\s*=\s*\[regex\]::Match'
        $script:workflowContent | Should -Match 'sha256:\[0-9a-f\]\{64\}'
    }
}
