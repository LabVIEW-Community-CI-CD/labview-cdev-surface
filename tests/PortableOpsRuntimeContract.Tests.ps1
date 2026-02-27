#Requires -Version 7.0
#Requires -Modules Pester

$ErrorActionPreference = 'Stop'

Describe 'Portable ops runtime contract' {
    BeforeAll {
        $script:repoRoot = (Resolve-Path -Path (Join-Path $PSScriptRoot '..')).Path
        $script:dockerfile = Join-Path $script:repoRoot 'tools/ops-runtime/Dockerfile'
        $script:wrapper = Join-Path $script:repoRoot 'scripts/Invoke-PortableOps.ps1'
        if (-not (Test-Path -LiteralPath $script:dockerfile -PathType Leaf)) {
            throw "Dockerfile missing: $script:dockerfile"
        }
        if (-not (Test-Path -LiteralPath $script:wrapper -PathType Leaf)) {
            throw "Wrapper missing: $script:wrapper"
        }
        $script:dockerContent = Get-Content -LiteralPath $script:dockerfile -Raw
        $script:wrapperContent = Get-Content -LiteralPath $script:wrapper -Raw
    }

    It 'pins cdev-cli runtime base by digest and resets entrypoint for ops scripts' {
        $script:dockerContent | Should -Match 'ghcr\.io/labview-community-ci-cd/labview-cdev-cli-runtime@sha256:0506e8789680ce1c941ca9f005b75d804150aed6ad36a5ac59458b802d358423'
        $script:dockerContent | Should -Match 'ENTRYPOINT \[\]'
        $script:dockerContent | Should -Match 'Install-Module -Name Pester'
    }

    It 'mounts workspace and forwards GH_TOKEN to containerized ops scripts' {
        $script:wrapperContent | Should -Match "'-v'"
        $script:wrapperContent | Should -Match '/workspace'
        $script:wrapperContent | Should -Match 'GH_TOKEN='
        $script:wrapperContent | Should -Match 'docker_not_ready'
    }
}
