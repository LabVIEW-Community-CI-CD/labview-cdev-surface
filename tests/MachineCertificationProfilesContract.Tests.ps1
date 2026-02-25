#Requires -Version 7.0
#Requires -Modules Pester

$ErrorActionPreference = 'Stop'

Describe 'Machine certification setup profile contract' {
    BeforeAll {
        $script:repoRoot = (Resolve-Path -Path (Join-Path $PSScriptRoot '..')).Path
        $script:profilesPath = Join-Path $script:repoRoot 'tools/machine-certification/setup-profiles.json'
        if (-not (Test-Path -LiteralPath $script:profilesPath -PathType Leaf)) {
            throw "Setup profiles not found: $script:profilesPath"
        }
        $script:profiles = Get-Content -LiteralPath $script:profilesPath -Raw | ConvertFrom-Json -ErrorAction Stop
        $script:activeSetups = @($script:profiles.setups | Where-Object { $_.active -eq $true })
    }

    It 'defines at least one active setup' {
        @($script:activeSetups).Count | Should -BeGreaterThan 0
    }

    It 'requires upstream collision-guard labels on active setups' {
        foreach ($setup in $script:activeSetups) {
            [string]$setup.collision_guard_label | Should -Not -BeNullOrEmpty
        }
    }

    It 'requires docker context switch flag on active setups' {
        foreach ($setup in $script:activeSetups) {
            $property = $setup.PSObject.Properties['switch_docker_context']
            $property | Should -Not -BeNullOrEmpty
            [bool]$property.Value | Should -Be $true
        }
    }

    It 'requires docker desktop startup flag on active setups' {
        foreach ($setup in $script:activeSetups) {
            $property = $setup.PSObject.Properties['start_docker_desktop_if_needed']
            $property | Should -Not -BeNullOrEmpty
            [bool]$property.Value | Should -Be $true
        }
    }
}
