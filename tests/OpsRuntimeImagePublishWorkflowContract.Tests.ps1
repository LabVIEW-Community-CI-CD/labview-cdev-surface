#Requires -Version 7.0
#Requires -Modules Pester

$ErrorActionPreference = 'Stop'

Describe 'Ops runtime image publish workflow contract' {
    BeforeAll {
        $script:repoRoot = (Resolve-Path -Path (Join-Path $PSScriptRoot '..')).Path
        $script:workflowPath = Join-Path $script:repoRoot '.github/workflows/publish-ops-runtime-image.yml'

        if (-not (Test-Path -LiteralPath $script:workflowPath -PathType Leaf)) {
            throw "Ops runtime publish workflow missing: $script:workflowPath"
        }

        $script:workflowContent = Get-Content -LiteralPath $script:workflowPath -Raw
    }

    It 'supports manual dispatch and deterministic main-path publish triggers' {
        $script:workflowContent | Should -Match 'workflow_dispatch:'
        $script:workflowContent | Should -Match 'push:'
        $script:workflowContent | Should -Match 'tools/ops-runtime/Dockerfile'
        $script:workflowContent | Should -Match 'Invoke-PortableOps\.ps1'
        $script:workflowContent | Should -Match 'Invoke-ReleaseControlPlaneLocalDocker\.ps1'
    }

    It 'publishes to GHCR with package write permission' {
        $script:workflowContent | Should -Match 'packages:\s*write'
        $script:workflowContent | Should -Match 'ghcr\.io/labview-community-ci-cd/labview-cdev-surface-ops'
        $script:workflowContent | Should -Match 'docker/login-action@v3'
        $script:workflowContent | Should -Match 'docker/build-push-action@v6'
    }

    It 'derives immutable tags and reports pushed digest' {
        $script:workflowContent | Should -Match 'sha-\$\{short_sha\}'
        $script:workflowContent | Should -Match 'v1-\$\{date_utc\}'
        $script:workflowContent | Should -Match 'steps\.build\.outputs\.digest'
    }
}
