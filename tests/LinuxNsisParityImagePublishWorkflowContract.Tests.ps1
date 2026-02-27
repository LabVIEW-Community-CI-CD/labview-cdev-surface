#Requires -Version 7.0
#Requires -Modules Pester

$ErrorActionPreference = 'Stop'

Describe 'Linux NSIS parity image publish workflow contract' {
    BeforeAll {
        $script:repoRoot = (Resolve-Path -Path (Join-Path $PSScriptRoot '..')).Path
        $script:workflowPath = Join-Path $script:repoRoot '.github/workflows/publish-linux-nsis-parity-image.yml'

        if (-not (Test-Path -LiteralPath $script:workflowPath -PathType Leaf)) {
            throw "Linux NSIS parity image publish workflow missing: $script:workflowPath"
        }

        $script:workflowContent = Get-Content -LiteralPath $script:workflowPath -Raw
    }

    It 'supports manual dispatch and deterministic main-path publish triggers' {
        $script:workflowContent | Should -Match 'workflow_dispatch:'
        $script:workflowContent | Should -Match 'push:'
        $script:workflowContent | Should -Match 'tools/nsis-selftest-linux/Dockerfile'
        $script:workflowContent | Should -Match 'scripts/Invoke-LinuxContainerNsisParity\.ps1'
    }

    It 'publishes to GHCR with package write permission' {
        $script:workflowContent | Should -Match 'packages:\s*write'
        $script:workflowContent | Should -Match 'ghcr\.io/labview-community-ci-cd/labview-cdev-surface-nsis-linux-parity'
        $script:workflowContent | Should -Match 'docker/login-action@v3'
        $script:workflowContent | Should -Match 'docker/build-push-action@v6'
    }

    It 'derives immutable tags and reports pushed digest' {
        $script:workflowContent | Should -Match 'sha-\$\{short_sha\}'
        $script:workflowContent | Should -Match 'BASE_TAG:\s*2026q1-linux'
        $script:workflowContent | Should -Match '\$\{BASE_TAG\}-\$\{date_utc\}'
        $script:workflowContent | Should -Match 'steps\.build\.outputs\.digest'
    }
}
